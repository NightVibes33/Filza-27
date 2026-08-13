@import Foundation;
@import UIKit;

#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MCMBridge.h"
#import "MCMFilzaIntegration.h"

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
@end

static IMP gPreviousAllApplications = NULL;
static IMP gPreviousAppsDidSelect = NULL;
static BOOL gAppsManagerHooksInstalled = NO;

static NSString *FilzaProxyIdentifier(id proxy)
{
    SEL selector = NSSelectorFromString(@"applicationIdentifier");
    if ([proxy respondsToSelector:selector])
        return ((id (*)(id, SEL))objc_msgSend)(proxy, selector);
    return nil;
}

static NSString *FilzaProxyDisplayName(id proxy)
{
    SEL selector = NSSelectorFromString(@"localizedName");
    if ([proxy respondsToSelector:selector]) {
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(proxy, selector);
        if (name.length) return name;
    }
    return FilzaProxyIdentifier(proxy) ?: @"";
}

static id FilzaAllApplications(id self, SEL _cmd)
{
    NSArray *existing = gPreviousAllApplications
        ? ((id (*)(id, SEL))gPreviousAllApplications)(self, _cmd) : @[];
    if (![existing isKindOfClass:NSArray.class]) existing = @[];

    NSMutableDictionary<NSString *, id> *byIdentifier = [NSMutableDictionary dictionary];
    for (id proxy in existing) {
        NSString *identifier = FilzaProxyIdentifier(proxy);
        if (identifier.length) byIdentifier[identifier] = proxy;
    }

    NSString *detail = nil;
    NSArray<NSString *> *identifiers = MCMEnumerateIdentifiersForClass(2, 2048, &detail);
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (proxyClass && [proxyClass respondsToSelector:proxySelector]) {
        for (NSString *identifier in identifiers ?: @[]) {
            if (!identifier.length || byIdentifier[identifier]) continue;
            id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass,
                proxySelector, identifier);
            if (proxy) byIdentifier[identifier] = proxy;
        }
    }

    NSArray *result = [byIdentifier.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(id left, id right) {
            return [FilzaProxyDisplayName(left) localizedCaseInsensitiveCompare:
                FilzaProxyDisplayName(right)];
        }];
    NSLog(@"[AppsManagerFix] workspace=%lu mcm=%lu merged=%lu detail=%@",
        (unsigned long)existing.count, (unsigned long)identifiers.count,
        (unsigned long)result.count, detail);
    return result;
}

static id FilzaObjectAtIndexSafely(id collection, NSUInteger index)
{
    if (![collection respondsToSelector:@selector(count)] ||
        ![collection respondsToSelector:@selector(objectAtIndex:)]) return nil;
    NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(collection, @selector(count));
    if (index >= count) return nil;
    return ((id (*)(id, SEL, NSUInteger))objc_msgSend)(collection,
        @selector(objectAtIndex:), index);
}

static NSString *FilzaApplicationItemIdentifier(id item)
{
    for (NSString *name in @[@"bundleId", @"applicationIdentifier"]) {
        SEL selector = NSSelectorFromString(name);
        if ([item respondsToSelector:selector]) {
            NSString *value = ((id (*)(id, SEL))objc_msgSend)(item, selector);
            if ([value isKindOfClass:NSString.class] && value.length) return value;
        }
    }
    SEL proxySelector = NSSelectorFromString(@"appProxy");
    if ([item respondsToSelector:proxySelector])
        return FilzaProxyIdentifier(((id (*)(id, SEL))objc_msgSend)(item, proxySelector));
    return nil;
}

static BOOL FilzaSameContainerPath(NSString *left, NSString *right)
{
    if (!left.length || !right.length) return NO;
    NSString *(^normalize)(NSString *) = ^NSString *(NSString *value) {
        NSString *path = value.stringByStandardizingPath;
        if ([path isEqualToString:@"/var"] || [path hasPrefix:@"/var/"])
            path = [@"/private" stringByAppendingString:path];
        return path;
    };
    return [normalize(left) isEqualToString:normalize(right)];
}

static NSString *FilzaEnsureVirtualAppDataPath(NSString *identifier, NSString **error)
{
    if (!identifier.length) {
        if (error) *error = @"missing application identifier";
        return nil;
    }

    NSString *activationDetail = nil;
    NSString *container = MCMFilzaDataContainerPath(identifier, &activationDetail);
    if (!container.length) {
        if (error) *error = activationDetail ?: @"class-2 container activation failed";
        return nil;
    }

    NSString *directory = [MCMFilzaVirtualRoot()
        stringByAppendingPathComponent:@"[MHA-C2] App Data"];
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&directoryError]) {
        if (error) *error = [NSString stringWithFormat:@"virtual app-data directory failed: %@",
            directoryError.localizedDescription ?: @"unknown"];
        return nil;
    }

    NSString *link = [directory stringByAppendingPathComponent:identifier];
    struct stat status = {0};
    if (lstat(link.fileSystemRepresentation, &status) == 0) {
        if (!S_ISLNK(status.st_mode)) {
            if (error) *error = @"virtual app-data entry exists but is not a symlink";
            return nil;
        }

        char targetBuffer[PATH_MAX] = {0};
        ssize_t count = readlink(link.fileSystemRepresentation,
                                 targetBuffer, sizeof(targetBuffer) - 1);
        NSString *existingTarget = count > 0
            ? [NSString stringWithUTF8String:targetBuffer] : nil;
        if (!FilzaSameContainerPath(existingTarget, container))
            unlink(link.fileSystemRepresentation);
    }

    if (lstat(link.fileSystemRepresentation, &status) != 0) {
        if (symlink(container.fileSystemRepresentation, link.fileSystemRepresentation) != 0) {
            if (error) *error = [NSString stringWithFormat:@"virtual app-data symlink failed errno=%d (%s)",
                errno, strerror(errno)];
            return nil;
        }
    }

    // Verify the exact path Filza will browse, not merely the raw MCM root.
    int descriptor = open(link.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (descriptor < 0) {
        if (error) *error = [NSString stringWithFormat:@"virtual app-data path open failed errno=%d (%s)",
            errno, strerror(errno)];
        return nil;
    }
    close(descriptor);

    if (error) *error = activationDetail;
    return link;
}

static void FilzaAppsDidSelect(id self, SEL _cmd, id browserView, id indexPath)
{
    SEL fileListSelector = NSSelectorFromString(@"fileList");
    id fileList = [self respondsToSelector:fileListSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(self, fileListSelector) : nil;
    NSUInteger row = [indexPath respondsToSelector:@selector(row)]
        ? ((NSUInteger (*)(id, SEL))objc_msgSend)(indexPath, @selector(row)) : NSNotFound;
    id item = row == NSNotFound ? nil : FilzaObjectAtIndexSafely(fileList, row);
    NSString *identifier = FilzaApplicationItemIdentifier(item);

    if (identifier.length) {
        NSString *detail = nil;
        NSString *browsePath = FilzaEnsureVirtualAppDataPath(identifier, &detail);
        SEL setter = NSSelectorFromString(@"setDocumentPath:");
        if (browsePath.length && [item respondsToSelector:setter])
            ((void (*)(id, SEL, id))objc_msgSend)(item, setter, browsePath);

        // The shipped Filza binary exposes -[TGApplicationsViewController openPath:].
        // Use it directly once the class-2 lease and virtual path are verified,
        // rather than allowing the stock selection path to recalculate an empty
        // jailed documentPath from LaunchServices.
        SEL openSelector = NSSelectorFromString(@"openPath:");
        if (browsePath.length && [self respondsToSelector:openSelector]) {
            NSLog(@"[AppsManagerFix] opening id=%@ via virtualPath=%@ detail=%@",
                  identifier, browsePath, detail);
            ((void (*)(id, SEL, id))objc_msgSend)(self, openSelector, browsePath);
            return;
        }

        NSLog(@"[AppsManagerFix] id=%@ virtualPath=%@ detail=%@; falling back to stock selection",
              identifier, browsePath, detail);
    }

    if (gPreviousAppsDidSelect)
        ((void (*)(id, SEL, id, id))gPreviousAppsDidSelect)(self, _cmd,
            browserView, indexPath);
}

static IMP FilzaInstallInstanceHook(Class cls, SEL selector, IMP replacement)
{
    Method resolved = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!resolved) return NULL;

    IMP original = method_getImplementation(resolved);
    const char *types = method_getTypeEncoding(resolved);

    if (class_addMethod(cls, selector, replacement, types))
        return original;

    Method owned = class_getInstanceMethod(cls, selector);
    if (!owned) return NULL;
    original = method_getImplementation(owned);
    if (original != replacement)
        method_setImplementation(owned, replacement);
    return original;
}

static void FilzaInstallAppsManagerFixes(void)
{
    if (gAppsManagerHooksInstalled) return;

    Class workspace = NSClassFromString(@"LSApplicationWorkspace");
    Class apps = NSClassFromString(@"TGApplicationsViewController");
    if (!workspace || !apps) return;

    gPreviousAllApplications = FilzaInstallInstanceHook(workspace,
        NSSelectorFromString(@"allApplications"), (IMP)FilzaAllApplications);
    gPreviousAppsDidSelect = FilzaInstallInstanceHook(apps,
        NSSelectorFromString(@"browserView:didSelectItemAtIndexPath:"),
        (IMP)FilzaAppsDidSelect);

    gAppsManagerHooksInstalled = YES;
    NSLog(@"[AppsManagerFix] ContainerManager-backed Apps Manager hooks installed");
}

__attribute__((constructor)) static void FilzaAppsManagerFixInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        FilzaInstallAppsManagerFixes();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            FilzaInstallAppsManagerFixes();
        });
    });
}
