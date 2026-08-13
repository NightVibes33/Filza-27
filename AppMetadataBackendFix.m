@import Foundation;
@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/stat.h>

#import "MCMFilzaIntegration.h"

// Filza's shipped ApplicationItem/FileItem Objective-C metadata exposes these
// selectors. Keep this compatibility layer dynamic so it can fail closed if a
// future Filza build removes one of them.
static IMP gPreviousApplicationSetProxy = NULL;
static IMP gPreviousApplicationCalculateDiskUsage = NULL;
static IMP gPreviousApplicationFileSizeString = NULL;
static IMP gPreviousApplicationIcon = NULL;
static IMP gPreviousFileItemIsDirectory = NULL;
static BOOL gMetadataBackendHooksInstalled = NO;

static id FilzaSendObject(id object, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static unsigned long long FilzaNumberForSelector(id object, NSString *selectorName)
{
    id value = FilzaSendObject(object, selectorName);
    return [value respondsToSelector:@selector(unsignedLongLongValue)]
        ? [value unsignedLongLongValue] : 0;
}

static id FilzaApplicationProxyForItem(id item)
{
    id proxy = FilzaSendObject(item, @"appProxy");
    if (proxy) return proxy;

    NSString *identifier = FilzaSendObject(item, @"bundleId");
    if (![identifier isKindOfClass:NSString.class] || !identifier.length) return nil;

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, selector, identifier);
}

static NSString *FilzaApplicationIdentifierForItem(id item)
{
    NSString *identifier = FilzaSendObject(item, @"bundleId");
    if ([identifier isKindOfClass:NSString.class] && identifier.length) return identifier;

    id proxy = FilzaApplicationProxyForItem(item);
    identifier = FilzaSendObject(proxy, @"applicationIdentifier");
    return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}

static unsigned long long FilzaLaunchServicesDiskUsage(id proxy)
{
    if (!proxy) return 0;

    // LaunchServices exposes per-application disk-usage accounting without
    // requiring Filza to recursively traverse a foreign container. Prefer the
    // structured usage object when present; fall back to staticDiskUsage on
    // older proxy implementations.
    id usage = FilzaSendObject(proxy, @"diskUsage");
    unsigned long long total = 0;
    if (usage) {
        total += FilzaNumberForSelector(usage, @"staticUsage");
        total += FilzaNumberForSelector(usage, @"dynamicUsage");
        total += FilzaNumberForSelector(usage, @"onDemandResourcesUsage");
    }
    if (total == 0)
        total = FilzaNumberForSelector(proxy, @"staticDiskUsage");
    return total;
}

static void FilzaPopulateApplicationSize(id item)
{
    if (!item) return;

    SEL getSize = NSSelectorFromString(@"fileSize");
    SEL setSize = NSSelectorFromString(@"setFileSize:");
    if (![item respondsToSelector:getSize] || ![item respondsToSelector:setSize]) return;

    unsigned long long current = ((unsigned long long (*)(id, SEL))objc_msgSend)(item, getSize);
    if (current != 0) return;

    id proxy = FilzaApplicationProxyForItem(item);
    unsigned long long bytes = FilzaLaunchServicesDiskUsage(proxy);
    if (bytes == 0) return;

    ((void (*)(id, SEL, unsigned long long))objc_msgSend)(item, setSize, bytes);
    NSLog(@"[AppMetadataFix] size id=%@ bytes=%llu",
          FilzaApplicationIdentifierForItem(item), bytes);
}

static void FilzaApplicationSetProxy(id self, SEL _cmd, id proxy)
{
    if (gPreviousApplicationSetProxy)
        ((void (*)(id, SEL, id))gPreviousApplicationSetProxy)(self, _cmd, proxy);
    FilzaPopulateApplicationSize(self);
}

static void FilzaApplicationCalculateDiskUsage(id self, SEL _cmd)
{
    if (gPreviousApplicationCalculateDiskUsage)
        ((void (*)(id, SEL))gPreviousApplicationCalculateDiskUsage)(self, _cmd);
    FilzaPopulateApplicationSize(self);
}

static id FilzaApplicationFileSizeString(id self, SEL _cmd)
{
    FilzaPopulateApplicationSize(self);
    return gPreviousApplicationFileSizeString
        ? ((id (*)(id, SEL))gPreviousApplicationFileSizeString)(self, _cmd) : nil;
}

static UIImage *FilzaResolvedApplicationIcon(id item)
{
    NSString *identifier = FilzaApplicationIdentifierForItem(item);
    if (!identifier.length) return nil;

    // This selector is present in UIKit on Filza-era iOS builds and is used by
    // existing on-device app managers to resolve the installed icon without
    // opening the application's bundle directory directly.
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    Class imageClass = UIImage.class;
    if (![imageClass respondsToSelector:selector]) return nil;

    @try {
        CGFloat scale = UIScreen.mainScreen.scale;
        return ((id (*)(id, SEL, id, int, CGFloat))objc_msgSend)(
            imageClass, selector, identifier, 2, scale);
    } @catch (NSException *exception) {
        NSLog(@"[AppMetadataFix] icon resolver exception id=%@ exception=%@",
              identifier, exception);
        return nil;
    }
}

static id FilzaApplicationIcon(id self, SEL _cmd)
{
    UIImage *resolved = FilzaResolvedApplicationIcon(self);
    if (resolved) return resolved;
    return gPreviousApplicationIcon
        ? ((id (*)(id, SEL))gPreviousApplicationIcon)(self, _cmd) : nil;
}

static BOOL FilzaPathInsideVirtualRoot(NSString *path)
{
    if (![path isKindOfClass:NSString.class] || !path.length) return NO;
    NSString *candidate = path.stringByStandardizingPath;
    NSString *root = MCMFilzaVirtualRoot().stringByStandardizingPath;
    return [candidate isEqualToString:root] ||
        [candidate hasPrefix:[root stringByAppendingString:@"/"]];
}

static BOOL FilzaFileItemIsDirectory(id self, SEL _cmd)
{
    BOOL original = gPreviousFileItemIsDirectory
        ? ((BOOL (*)(id, SEL))gPreviousFileItemIsDirectory)(self, _cmd) : NO;
    if (original) return YES;

    NSString *path = FilzaSendObject(self, @"filePath");
    if (!FilzaPathInsideVirtualRoot(path)) return NO;

    // Follow only an already-created Device Storage link. This corrects
    // Filza's backend classification for a symlink whose target is genuinely
    // visible to the current process; it does not grant access to its target.
    struct stat status = {0};
    if (stat(path.fileSystemRepresentation, &status) == 0 && S_ISDIR(status.st_mode)) {
        NSLog(@"[VirtualBackendFix] treating accessible virtual target as directory path=%@", path);
        return YES;
    }
    return NO;
}

static IMP FilzaInstallClassLocalHook(Class cls, SEL selector, IMP replacement)
{
    if (!cls || !selector || !replacement) return NULL;
    Method resolved = class_getInstanceMethod(cls, selector);
    if (!resolved) return NULL;

    IMP original = method_getImplementation(resolved);
    const char *types = method_getTypeEncoding(resolved);

    // If the implementation is inherited, add a class-local override instead
    // of mutating the superclass method globally.
    if (class_addMethod(cls, selector, replacement, types)) return original;

    Method owned = class_getInstanceMethod(cls, selector);
    if (!owned) return NULL;
    original = method_getImplementation(owned);
    if (original != replacement) method_setImplementation(owned, replacement);
    return original;
}

static void FilzaInstallMetadataBackendFixes(void)
{
    if (gMetadataBackendHooksInstalled) return;

    Class applicationItem = NSClassFromString(@"ApplicationItem");
    Class fileItem = NSClassFromString(@"FileItem");
    if (!applicationItem || !fileItem) return;

    gPreviousApplicationSetProxy = FilzaInstallClassLocalHook(
        applicationItem, NSSelectorFromString(@"setAppProxy:"),
        (IMP)FilzaApplicationSetProxy);
    gPreviousApplicationCalculateDiskUsage = FilzaInstallClassLocalHook(
        applicationItem, NSSelectorFromString(@"calculateDiskUsage"),
        (IMP)FilzaApplicationCalculateDiskUsage);
    gPreviousApplicationFileSizeString = FilzaInstallClassLocalHook(
        applicationItem, NSSelectorFromString(@"fileSizeString"),
        (IMP)FilzaApplicationFileSizeString);
    gPreviousApplicationIcon = FilzaInstallClassLocalHook(
        applicationItem, NSSelectorFromString(@"icon"),
        (IMP)FilzaApplicationIcon);
    gPreviousFileItemIsDirectory = FilzaInstallClassLocalHook(
        fileItem, NSSelectorFromString(@"isDirectory"),
        (IMP)FilzaFileItemIsDirectory);

    gMetadataBackendHooksInstalled = YES;
    NSLog(@"[AppMetadataFix] Apps Manager size/icon and virtual backend hooks installed");
}

__attribute__((constructor)) static void FilzaMetadataBackendFixInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        FilzaInstallMetadataBackendFixes();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            FilzaInstallMetadataBackendFixes();
        });
    });
}
