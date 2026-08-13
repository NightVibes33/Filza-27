@import Foundation;
@import UIKit;

#import <dirent.h>
#import <errno.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <unistd.h>

static IMP gFZPreviousSetAppProxy = NULL;
static IMP gFZPreviousReload = NULL;
static IMP gFZPreviousCalculateDiskUsage = NULL;
static IMP gFZPreviousFileSizeString = NULL;
static BOOL gFZPresentationHooksInstalled = NO;

static const void *kFZReadableSizeKey = &kFZReadableSizeKey;
static const void *kFZReadableSizePartialKey = &kFZReadableSizePartialKey;
static const void *kFZReadableSizeAttemptedKey = &kFZReadableSizeAttemptedKey;

static id FZObjectSelector(id object, NSString *selectorName)
{
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *FZItemIdentifier(id item)
{
    id bundleId = FZObjectSelector(item, @"bundleId");
    if ([bundleId isKindOfClass:NSString.class] && [bundleId length]) return bundleId;

    id proxy = FZObjectSelector(item, @"appProxy");
    for (NSString *selectorName in @[@"applicationIdentifier", @"bundleIdentifier"]) {
        id value = FZObjectSelector(proxy, selectorName);
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return nil;
}

static NSString *FZSafeCacheComponent(NSString *identifier)
{
    if (!identifier.length) return @"unknown";
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    NSMutableString *result = [NSMutableString stringWithCapacity:identifier.length];
    for (NSUInteger index = 0; index < identifier.length; index++) {
        unichar value = [identifier characterAtIndex:index];
        if ([allowed characterIsMember:value]) [result appendFormat:@"%C", value];
        else [result appendString:@"_"];
    }
    return result;
}

static NSString *FZIconCacheDirectory(void)
{
    NSString *cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
        NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *directory = [cache stringByAppendingPathComponent:@"FilzaAppIcons"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}

static UIImage *FZProxyIconImage(id proxy)
{
    if (!proxy) return nil;
    SEL iconSelector = NSSelectorFromString(@"iconDataForVariant:");
    if (![proxy respondsToSelector:iconSelector]) return nil;

    UIImage *bestImage = nil;
    CGFloat bestArea = 0.0;
    // LaunchServices icon variants are private and have changed over time.
    // Probe the bounded historical range and accept only data UIKit can decode.
    for (int variant = 0; variant <= 20; variant++) {
        id data = ((id (*)(id, SEL, int))objc_msgSend)(proxy, iconSelector, variant);
        if (![data isKindOfClass:NSData.class] || [data length] == 0) continue;
        UIImage *image = [UIImage imageWithData:data];
        if (!image) continue;
        CGFloat width = image.size.width * MAX(image.scale, 1.0);
        CGFloat height = image.size.height * MAX(image.scale, 1.0);
        CGFloat area = width * height;
        if (area > bestArea) {
            bestArea = area;
            bestImage = image;
        }
    }
    return bestImage;
}

static UIImage *FZBundleIconImage(id proxy)
{
    NSURL *bundleURL = FZObjectSelector(proxy, @"bundleURL");
    if (![bundleURL isKindOfClass:NSURL.class] || !bundleURL.isFileURL) return nil;
    NSString *bundlePath = bundleURL.path;
    if (!bundlePath.length) return nil;

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSDictionary *icons = [info[@"CFBundleIcons"] isKindOfClass:NSDictionary.class]
        ? info[@"CFBundleIcons"] : nil;
    NSDictionary *primary = [icons[@"CFBundlePrimaryIcon"] isKindOfClass:NSDictionary.class]
        ? icons[@"CFBundlePrimaryIcon"] : nil;
    NSArray *primaryFiles = [primary[@"CFBundleIconFiles"] isKindOfClass:NSArray.class]
        ? primary[@"CFBundleIconFiles"] : nil;
    if (primaryFiles.count) [names addObjectsFromArray:primaryFiles];
    NSArray *legacy = [info[@"CFBundleIconFiles"] isKindOfClass:NSArray.class]
        ? info[@"CFBundleIconFiles"] : nil;
    if (legacy.count) [names addObjectsFromArray:legacy];

    UIImage *bestImage = nil;
    CGFloat bestArea = 0.0;
    for (NSString *rawName in names) {
        if (![rawName isKindOfClass:NSString.class] || !rawName.length) continue;
        NSString *base = [rawName stringByDeletingPathExtension];
        NSArray<NSString *> *candidates = @[
            rawName,
            [base stringByAppendingString:@"@3x.png"],
            [base stringByAppendingString:@"@2x.png"],
            [base stringByAppendingString:@".png"],
        ];
        for (NSString *name in candidates) {
            NSString *path = [bundlePath stringByAppendingPathComponent:name];
            UIImage *image = [UIImage imageWithContentsOfFile:path];
            if (!image) continue;
            CGFloat area = image.size.width * image.scale * image.size.height * image.scale;
            if (area > bestArea) {
                bestArea = area;
                bestImage = image;
            }
        }
    }
    return bestImage;
}

static void FZPopulateIconPath(id item)
{
    if (!item) return;
    id existing = FZObjectSelector(item, @"iconPath");
    if ([existing isKindOfClass:NSString.class] && [existing length] &&
        [NSFileManager.defaultManager fileExistsAtPath:existing]) return;

    id proxy = FZObjectSelector(item, @"appProxy");
    NSString *identifier = FZItemIdentifier(item);
    if (!proxy || !identifier.length) return;

    NSString *cachePath = [[FZIconCacheDirectory()
        stringByAppendingPathComponent:FZSafeCacheComponent(identifier)]
        stringByAppendingPathExtension:@"png"];
    if (![NSFileManager.defaultManager fileExistsAtPath:cachePath]) {
        UIImage *image = FZProxyIconImage(proxy) ?: FZBundleIconImage(proxy);
        NSData *png = image ? UIImagePNGRepresentation(image) : nil;
        if (png.length && ![png writeToFile:cachePath atomically:YES])
            cachePath = nil;
    }

    SEL setter = NSSelectorFromString(@"setIconPath:");
    if (cachePath.length && [item respondsToSelector:setter]) {
        ((void (*)(id, SEL, id))objc_msgSend)(item, setter, cachePath);
        NSLog(@"[AppsPresentationFix] icon ready id=%@ path=%@", identifier, cachePath);
    } else {
        NSLog(@"[AppsPresentationFix] icon unavailable id=%@", identifier);
    }
}

static uint64_t FZAllocatedBytesForStat(const struct stat *status)
{
    if (!status) return 0;
    if (status->st_blocks > 0) return (uint64_t)status->st_blocks * 512ULL;
    return status->st_size > 0 ? (uint64_t)status->st_size : 0;
}

static uint64_t FZReadableTreeSize(NSString *root, BOOL *partial)
{
    if (partial) *partial = NO;
    if (!root.length || !root.isAbsolutePath) {
        if (partial) *partial = YES;
        return 0;
    }

    struct stat rootStatus = {0};
    if (stat(root.fileSystemRepresentation, &rootStatus) != 0) {
        if (partial) *partial = YES;
        return 0;
    }

    uint64_t total = FZAllocatedBytesForStat(&rootStatus);
    if (!S_ISDIR(rootStatus.st_mode)) return total;

    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        NSString *directoryPath = stack.lastObject;
        [stack removeLastObject];

        errno = 0;
        DIR *directory = opendir(directoryPath.fileSystemRepresentation);
        if (!directory) {
            if (partial) *partial = YES;
            continue;
        }

        struct dirent *entry = NULL;
        while ((entry = readdir(directory)) != NULL) {
            if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
            NSString *name = [NSString stringWithUTF8String:entry->d_name];
            if (!name.length) continue;
            NSString *path = [directoryPath stringByAppendingPathComponent:name];

            struct stat status = {0};
            if (lstat(path.fileSystemRepresentation, &status) != 0) {
                if (partial) *partial = YES;
                continue;
            }
            total += FZAllocatedBytesForStat(&status);
            if (S_ISDIR(status.st_mode)) [stack addObject:path];
        }
        if (errno != 0 && partial) *partial = YES;
        closedir(directory);
    }
    return total;
}

static BOOL FZPathOpenableDirectory(NSString *path)
{
    if (!path.length || !path.isAbsolutePath) return NO;
    DIR *directory = opendir(path.fileSystemRepresentation);
    if (!directory) return NO;
    closedir(directory);
    return YES;
}

static void FZSetApplicationItemCalculated(id item)
{
    Ivar ivar = class_getInstanceVariable(object_getClass(item) ? [item class] : Nil,
                                           "_calculatedDiskUsage");
    if (!ivar) {
        Class cls = NSClassFromString(@"ApplicationItem");
        ivar = cls ? class_getInstanceVariable(cls, "_calculatedDiskUsage") : NULL;
    }
    if (!ivar) return;
    ptrdiff_t offset = ivar_getOffset(ivar);
    uint8_t *bytes = (__bridge void *)item;
    *((BOOL *)(bytes + offset)) = YES;
}

static uint64_t FZCurrentFileSize(id item)
{
    SEL selector = NSSelectorFromString(@"fileSize");
    if (![item respondsToSelector:selector]) return 0;
    return ((uint64_t (*)(id, SEL))objc_msgSend)(item, selector);
}

static void FZSetFileSize(id item, uint64_t size)
{
    SEL setter = NSSelectorFromString(@"setFileSize:");
    if ([item respondsToSelector:setter])
        ((void (*)(id, SEL, uint64_t))objc_msgSend)(item, setter, size);
}

static NSArray<NSString *> *FZReadableRootsForItem(id item)
{
    NSMutableOrderedSet<NSString *> *roots = [NSMutableOrderedSet orderedSet];

    id documentPath = FZObjectSelector(item, @"documentPath");
    if ([documentPath isKindOfClass:NSString.class] && [documentPath length] &&
        FZPathOpenableDirectory(documentPath))
        [roots addObject:[documentPath stringByStandardizingPath]];

    id proxy = FZObjectSelector(item, @"appProxy");
    for (NSString *selectorName in @[@"dataContainerURL", @"containerURL", @"bundleURL"]) {
        NSURL *url = FZObjectSelector(proxy, selectorName);
        if (![url isKindOfClass:NSURL.class] || !url.isFileURL || !url.path.length) continue;
        if (!FZPathOpenableDirectory(url.path)) continue;
        [roots addObject:url.path.stringByStandardizingPath];
    }
    return roots.array;
}

static void FZCalculateDiskUsage(id self, SEL _cmd)
{
    // Preserve Filza's native behavior first. Only repair the zero-size case.
    if (gFZPreviousCalculateDiskUsage)
        ((void (*)(id, SEL))gFZPreviousCalculateDiskUsage)(self, _cmd);

    if (FZCurrentFileSize(self) > 0) return;

    NSArray<NSString *> *roots = FZReadableRootsForItem(self);
    BOOL partial = NO;
    uint64_t total = 0;
    for (NSString *root in roots) {
        BOOL rootPartial = NO;
        total += FZReadableTreeSize(root, &rootPartial);
        partial |= rootPartial;
    }

    objc_setAssociatedObject(self, kFZReadableSizeAttemptedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kFZReadableSizeKey, @(total),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kFZReadableSizePartialKey, @(partial),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (total > 0) FZSetFileSize(self, total);
    FZSetApplicationItemCalculated(self);
    NSLog(@"[AppsPresentationFix] size id=%@ bytes=%llu roots=%lu partial=%d",
          FZItemIdentifier(self), total, (unsigned long)roots.count, partial);
}

static id FZFileSizeString(id self, SEL _cmd)
{
    NSNumber *attempted = objc_getAssociatedObject(self, kFZReadableSizeAttemptedKey);
    NSNumber *readableSize = objc_getAssociatedObject(self, kFZReadableSizeKey);
    if (attempted.boolValue && readableSize) {
        uint64_t size = readableSize.unsignedLongLongValue;
        if (size == 0) return @"—";
        NSString *formatted = [NSByteCountFormatter stringFromByteCount:(long long)size
                                                              countStyle:NSByteCountFormatterCountStyleFile];
        BOOL partial = [objc_getAssociatedObject(self, kFZReadableSizePartialKey) boolValue];
        return partial ? [formatted stringByAppendingString:@"+"] : formatted;
    }
    return gFZPreviousFileSizeString
        ? ((id (*)(id, SEL))gFZPreviousFileSizeString)(self, _cmd) : @"—";
}

static void FZSetAppProxy(id self, SEL _cmd, id proxy)
{
    if (gFZPreviousSetAppProxy)
        ((void (*)(id, SEL, id))gFZPreviousSetAppProxy)(self, _cmd, proxy);
    FZPopulateIconPath(self);
}

static void FZReload(id self, SEL _cmd)
{
    if (gFZPreviousReload)
        ((void (*)(id, SEL))gFZPreviousReload)(self, _cmd);
    FZPopulateIconPath(self);
}

static IMP FZInstallClassLocalHook(Class cls, SEL selector, IMP replacement)
{
    Method resolved = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!resolved) return NULL;
    IMP original = method_getImplementation(resolved);
    const char *types = method_getTypeEncoding(resolved);
    if (class_addMethod(cls, selector, replacement, types)) return original;
    Method owned = class_getInstanceMethod(cls, selector);
    if (!owned) return NULL;
    original = method_getImplementation(owned);
    if (original != replacement) method_setImplementation(owned, replacement);
    return original;
}

static void FZInstallPresentationFixes(void)
{
    if (gFZPresentationHooksInstalled) return;
    Class itemClass = NSClassFromString(@"ApplicationItem");
    if (!itemClass) return;

    gFZPreviousSetAppProxy = FZInstallClassLocalHook(itemClass,
        NSSelectorFromString(@"setAppProxy:"), (IMP)FZSetAppProxy);
    gFZPreviousReload = FZInstallClassLocalHook(itemClass,
        NSSelectorFromString(@"reload"), (IMP)FZReload);
    gFZPreviousCalculateDiskUsage = FZInstallClassLocalHook(itemClass,
        NSSelectorFromString(@"calculateDiskUsage"), (IMP)FZCalculateDiskUsage);
    gFZPreviousFileSizeString = FZInstallClassLocalHook(itemClass,
        NSSelectorFromString(@"fileSizeString"), (IMP)FZFileSizeString);

    gFZPresentationHooksInstalled = YES;
    NSLog(@"[AppsPresentationFix] ApplicationItem icon/size hooks installed");
}

__attribute__((constructor)) static void FZAppsPresentationInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        FZInstallPresentationFixes();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ FZInstallPresentationFixes(); });
    });
}
