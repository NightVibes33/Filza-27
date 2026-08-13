@import Foundation;
@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

static IMP gFZLatePreviousFileSizeString = NULL;
static IMP gFZLatePreviousIconPath = NULL;
static BOOL gFZLateMetadataInstalled = NO;

static id FZLateObject(id object, NSString *selectorName)
{
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *FZLateIdentifier(id item)
{
    id bundle = FZLateObject(item, @"bundleId");
    if ([bundle isKindOfClass:NSString.class] && [bundle length]) return bundle;
    id proxy = FZLateObject(item, @"appProxy");
    id identifier = FZLateObject(proxy, @"applicationIdentifier");
    return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}

static id FZLateProxy(id item)
{
    id proxy = FZLateObject(item, @"appProxy");
    if (proxy) return proxy;
    NSString *identifier = FZLateIdentifier(item);
    if (!identifier.length) return nil;
    Class cls = NSClassFromString(@"LSApplicationProxy");
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!cls || ![cls respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(cls, selector, identifier);
}

static unsigned long long FZLateNumber(id object, NSString *selectorName)
{
    id value = FZLateObject(object, selectorName);
    return [value respondsToSelector:@selector(unsignedLongLongValue)]
        ? [value unsignedLongLongValue] : 0;
}

static unsigned long long FZLateDiskUsage(id item)
{
    id proxy = FZLateProxy(item);
    if (!proxy) return 0;

    id usage = FZLateObject(proxy, @"diskUsage");
    unsigned long long total = 0;
    if (usage) {
        total += FZLateNumber(usage, @"staticUsage");
        total += FZLateNumber(usage, @"dynamicUsage");
        total += FZLateNumber(usage, @"onDemandResourcesUsage");
    }
    if (total == 0) total = FZLateNumber(proxy, @"staticDiskUsage");
    return total;
}

static NSString *FZLateFileSizeString(id self, SEL _cmd)
{
    id original = gFZLatePreviousFileSizeString
        ? ((id (*)(id, SEL))gFZLatePreviousFileSizeString)(self, _cmd) : nil;
    if ([original isKindOfClass:NSString.class] && [original length] &&
        ![original isEqualToString:@"—"] && ![original isEqualToString:@"0 KB"] &&
        ![original isEqualToString:@"0 bytes"]) return original;

    unsigned long long bytes = FZLateDiskUsage(self);
    if (bytes == 0) return original ?: @"—";
    NSString *formatted = [NSByteCountFormatter stringFromByteCount:(long long)bytes
                                                          countStyle:NSByteCountFormatterCountStyleFile];
    NSLog(@"[AppMetadataLateFallback] LS size id=%@ bytes=%llu",
          FZLateIdentifier(self), bytes);
    return formatted;
}

static NSString *FZLateCacheDirectory(void)
{
    NSString *base = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
        NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *directory = [base stringByAppendingPathComponent:@"FilzaAppIcons-LS"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}

static NSString *FZLateSafeName(NSString *identifier)
{
    if (!identifier.length) return @"unknown";
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    NSMutableString *result = [NSMutableString stringWithCapacity:identifier.length];
    for (NSUInteger index = 0; index < identifier.length; index++) {
        unichar c = [identifier characterAtIndex:index];
        if ([allowed characterIsMember:c]) [result appendFormat:@"%C", c];
        else [result appendString:@"_"];
    }
    return result;
}

static UIImage *FZLateResolveIcon(NSString *identifier)
{
    if (!identifier.length) return nil;
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    Class cls = UIImage.class;
    if (![cls respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL, id, int, CGFloat))objc_msgSend)(
            cls, selector, identifier, 2, UIScreen.mainScreen.scale);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *FZLateIconPath(id self, SEL _cmd)
{
    id original = gFZLatePreviousIconPath
        ? ((id (*)(id, SEL))gFZLatePreviousIconPath)(self, _cmd) : nil;
    if ([original isKindOfClass:NSString.class] && [original length] &&
        [NSFileManager.defaultManager fileExistsAtPath:original]) return original;

    NSString *identifier = FZLateIdentifier(self);
    if (!identifier.length) return original;
    NSString *path = [[FZLateCacheDirectory()
        stringByAppendingPathComponent:FZLateSafeName(identifier)]
        stringByAppendingPathExtension:@"png"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        UIImage *image = FZLateResolveIcon(identifier);
        NSData *png = image ? UIImagePNGRepresentation(image) : nil;
        if (!png.length || ![png writeToFile:path atomically:YES]) return original;
    }
    NSLog(@"[AppMetadataLateFallback] UIKit LS icon id=%@ path=%@", identifier, path);
    return path;
}

static IMP FZLateInstallHook(Class cls, SEL selector, IMP replacement)
{
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return NULL;
    IMP original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (class_addMethod(cls, selector, replacement, types)) return original;
    Method owned = class_getInstanceMethod(cls, selector);
    if (!owned) return NULL;
    original = method_getImplementation(owned);
    if (original != replacement) method_setImplementation(owned, replacement);
    return original;
}

static void FZInstallLateMetadataFallback(void)
{
    if (gFZLateMetadataInstalled) return;
    Class cls = NSClassFromString(@"ApplicationItem");
    if (!cls) return;

    gFZLatePreviousFileSizeString = FZLateInstallHook(cls,
        NSSelectorFromString(@"fileSizeString"), (IMP)FZLateFileSizeString);
    gFZLatePreviousIconPath = FZLateInstallHook(cls,
        NSSelectorFromString(@"iconPath"), (IMP)FZLateIconPath);
    gFZLateMetadataInstalled = YES;
    NSLog(@"[AppMetadataLateFallback] outer metadata hooks installed");
}

__attribute__((constructor)) static void FZLateMetadataInit(void)
{
    // AppsManagerPresentationFix installs immediately and retries at +1s.
    // Install this compatibility wrapper after that so it only handles cases
    // the primary implementation still leaves blank/zero.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ FZInstallLateMetadataFallback(); });
}
