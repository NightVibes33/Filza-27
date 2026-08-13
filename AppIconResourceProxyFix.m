@import Foundation;
@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

static IMP gIconResourcePreviousSetAppProxy = NULL;
static IMP gIconResourcePreviousReload = NULL;
static BOOL gIconResourceHooksInstalled = NO;
static const void *kIconResourceRetryKey = &kIconResourceRetryKey;

static id FZIconObjectSelector(id object, NSString *selectorName)
{
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *FZIconIdentifier(id item)
{
    id value = FZIconObjectSelector(item, @"bundleId");
    if ([value isKindOfClass:NSString.class] && [value length]) return value;
    id proxy = FZIconObjectSelector(item, @"appProxy");
    for (NSString *selectorName in @[@"applicationIdentifier", @"bundleIdentifier"]) {
        value = FZIconObjectSelector(proxy, selectorName);
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return nil;
}

static NSString *FZIconSafeComponent(NSString *identifier)
{
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    NSMutableString *result = [NSMutableString stringWithCapacity:identifier.length];
    for (NSUInteger index = 0; index < identifier.length; index++) {
        unichar value = [identifier characterAtIndex:index];
        [result appendString:[allowed characterIsMember:value]
            ? [NSString stringWithCharacters:&value length:1] : @"_"];
    }
    return result.length ? result : @"unknown";
}

static BOOL FZIconPathAlreadyUsable(id item)
{
    id path = FZIconObjectSelector(item, @"iconPath");
    return [path isKindOfClass:NSString.class] && [path length] &&
        [NSFileManager.defaultManager fileExistsAtPath:path];
}

static UIImage *FZIconFromResourceProxy(id proxy)
{
    if (!proxy) return nil;
    SEL selector = NSSelectorFromString(@"_iconForResourceProxy:variant:variantsScale:");
    if (![UIImage respondsToSelector:selector]) return nil;

    // SafariPlus uses variant 19 for a resource proxy and documents 26/36 as
    // additional valid variants. Try those exact observed values only.
    const int variants[] = {19, 26, 36};
    CGFloat scale = UIScreen.mainScreen.scale ?: 2.0;
    for (NSUInteger index = 0; index < sizeof(variants) / sizeof(variants[0]); index++) {
        UIImage *image = nil;
        @try {
            image = ((id (*)(id, SEL, id, int, float))objc_msgSend)(
                UIImage.class, selector, proxy, variants[index], (float)scale);
        } @catch (__unused NSException *exception) {
            image = nil;
        }
        if ([image isKindOfClass:UIImage.class] && image.size.width > 0 && image.size.height > 0) {
            NSLog(@"[AppIconResourceProxyFix] resource-proxy icon variant=%d", variants[index]);
            return image;
        }
    }
    return nil;
}

static UIImage *FZIconFromBundleIdentifier(NSString *identifier)
{
    if (!identifier.length) return nil;
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![UIImage respondsToSelector:selector]) return nil;
    CGFloat scale = UIScreen.mainScreen.scale ?: 2.0;
    UIImage *image = nil;
    @try {
        image = ((id (*)(id, SEL, id, int, double))objc_msgSend)(
            UIImage.class, selector, identifier, 10, (double)scale);
    } @catch (__unused NSException *exception) {
        image = nil;
    }
    return [image isKindOfClass:UIImage.class] ? image : nil;
}

static BOOL FZInstallResourceProxyIcon(id item)
{
    if (!item || FZIconPathAlreadyUsable(item)) return YES;
    id proxy = FZIconObjectSelector(item, @"appProxy");
    NSString *identifier = FZIconIdentifier(item);
    if (!proxy || !identifier.length) return NO;

    UIImage *image = FZIconFromResourceProxy(proxy) ?: FZIconFromBundleIdentifier(identifier);
    NSData *png = image ? UIImagePNGRepresentation(image) : nil;
    if (!png.length) return NO;

    NSString *cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
        NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *directory = [cache stringByAppendingPathComponent:@"FilzaAppIconsResourceProxy"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [[directory stringByAppendingPathComponent:FZIconSafeComponent(identifier)]
        stringByAppendingPathExtension:@"png"];
    if (![png writeToFile:path atomically:YES]) return NO;

    SEL setter = NSSelectorFromString(@"setIconPath:");
    if (![item respondsToSelector:setter]) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(item, setter, path);
    NSLog(@"[AppIconResourceProxyFix] icon ready id=%@ path=%@", identifier, path);
    return YES;
}

static void FZScheduleIconRetry(id item)
{
    if (!item || FZIconPathAlreadyUsable(item)) return;
    NSUInteger retry = [objc_getAssociatedObject(item, kIconResourceRetryKey) unsignedIntegerValue];
    if (retry >= 3) return;
    objc_setAssociatedObject(item, kIconResourceRetryKey, @(retry + 1),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id weakItem = item;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)((0.4 + (0.6 * retry)) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id strongItem = weakItem;
        if (!strongItem) return;
        if (!FZInstallResourceProxyIcon(strongItem)) FZScheduleIconRetry(strongItem);
    });
}

static void FZIconResourceSetAppProxy(id self, SEL _cmd, id proxy)
{
    if (gIconResourcePreviousSetAppProxy)
        ((void (*)(id, SEL, id))gIconResourcePreviousSetAppProxy)(self, _cmd, proxy);
    if (!FZInstallResourceProxyIcon(self)) FZScheduleIconRetry(self);
}

static void FZIconResourceReload(id self, SEL _cmd)
{
    if (gIconResourcePreviousReload)
        ((void (*)(id, SEL))gIconResourcePreviousReload)(self, _cmd);
    if (!FZInstallResourceProxyIcon(self)) FZScheduleIconRetry(self);
}

static IMP FZIconInstallHook(Class cls, SEL selector, IMP replacement)
{
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return NULL;
    const char *types = method_getTypeEncoding(method);
    IMP original = method_getImplementation(method);
    if (class_addMethod(cls, selector, replacement, types)) return original;
    method = class_getInstanceMethod(cls, selector);
    if (!method) return NULL;
    original = method_getImplementation(method);
    if (original != replacement) method_setImplementation(method, replacement);
    return original;
}

static void FZInstallIconResourceProxyFix(void)
{
    if (gIconResourceHooksInstalled) return;
    Class item = NSClassFromString(@"ApplicationItem");
    if (!item) return;

    gIconResourcePreviousSetAppProxy = FZIconInstallHook(
        item, NSSelectorFromString(@"setAppProxy:"), (IMP)FZIconResourceSetAppProxy);
    gIconResourcePreviousReload = FZIconInstallHook(
        item, NSSelectorFromString(@"reload"), (IMP)FZIconResourceReload);
    if (!gIconResourcePreviousSetAppProxy && !gIconResourcePreviousReload) return;

    gIconResourceHooksInstalled = YES;
    NSLog(@"[AppIconResourceProxyFix] hooks installed proxy=%d reload=%d",
          gIconResourcePreviousSetAppProxy != NULL,
          gIconResourcePreviousReload != NULL);
}

__attribute__((constructor)) static void FZIconResourceProxyInit(void)
{
    // The existing presentation and metadata retry layers install first.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        FZInstallIconResourceProxyFix();
    });
}
