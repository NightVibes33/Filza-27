@import Foundation;
@import UIKit;

#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP gMetadataPreviousSetAppProxy = NULL;
static IMP gMetadataPreviousCalculateDiskUsage = NULL;
static BOOL gMetadataHooksInstalled = NO;

static id FilzaMetadataObject(id object, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static unsigned long long FilzaMetadataUnsignedLongLong(id object,
                                                         NSString *selectorName)
{
    id value = FilzaMetadataObject(object, selectorName);
    if ([value respondsToSelector:@selector(unsignedLongLongValue)])
        return [value unsignedLongLongValue];
    return 0;
}

static NSString *FilzaMetadataSafeName(NSString *value)
{
    if (!value.length) return @"unknown";
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    NSMutableString *result = [NSMutableString stringWithCapacity:value.length];
    for (NSUInteger index = 0; index < value.length; index++) {
        unichar character = [value characterAtIndex:index];
        [result appendFormat:@"%@", [allowed characterIsMember:character]
            ? [NSString stringWithCharacters:&character length:1] : @"_"];
    }
    return result;
}

static UIImage *FilzaMetadataImageFromIconData(NSData *data)
{
    if (![data isKindOfClass:NSData.class] || data.length == 0) return nil;

    UIImage *normalImage = [UIImage imageWithData:data];
    if (normalImage) return normalImage;

    // LSApplicationProxy's legacy iconDataForVariant: representation is a
    // 32-byte header followed by premultiplied BGRA rows. Do not assume a
    // fixed icon dimension: infer it only when the payload has the exact
    // width * (width + 1) * 4 layout used by LaunchServices.
    if (data.length <= 32 || ((data.length - 32) % 4) != 0) return nil;
    NSUInteger pixelsWithPadding = (data.length - 32) / 4;
    double root = (sqrt(1.0 + (4.0 * (double)pixelsWithPadding)) - 1.0) / 2.0;
    NSUInteger width = (NSUInteger)llround(root);
    if (width < 16 || width > 1024 ||
        width * (width + 1) != pixelsWithPadding) return nil;

    size_t payloadLength = data.length - 32;
    void *pixels = malloc(payloadLength);
    if (!pixels) return nil;
    [data getBytes:pixels range:NSMakeRange(32, payloadLength)];

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, width, width, 8,
        (width + 1) * sizeof(uint32_t), colorSpace,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGImageRef imageRef = context ? CGBitmapContextCreateImage(context) : NULL;
    UIImage *image = imageRef ? [UIImage imageWithCGImage:imageRef] : nil;

    if (imageRef) CGImageRelease(imageRef);
    if (context) CGContextRelease(context);
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    free(pixels);
    return image;
}

static NSString *FilzaMetadataCachedIconPath(id proxy, NSString *identifier)
{
    if (!proxy || !identifier.length) return nil;
    SEL selector = NSSelectorFromString(@"iconDataForVariant:");
    if (![proxy respondsToSelector:selector]) return nil;

    NSString *cacheRoot = [NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"FilzaAppIcons"];
    if (!cacheRoot.length) return nil;
    [NSFileManager.defaultManager createDirectoryAtPath:cacheRoot
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    NSString *cachePath = [cacheRoot stringByAppendingPathComponent:
        [[FilzaMetadataSafeName(identifier) stringByAppendingString:@".png"] copy]];
    if ([NSFileManager.defaultManager fileExistsAtPath:cachePath]) return cachePath;

    const int variants[] = { 2, 1, 0, 4, 5, 6, 10, 15 };
    for (NSUInteger index = 0; index < sizeof(variants) / sizeof(variants[0]); index++) {
        id candidate = ((id (*)(id, SEL, int))objc_msgSend)(proxy, selector,
                                                           variants[index]);
        if (![candidate isKindOfClass:NSData.class]) continue;
        UIImage *image = FilzaMetadataImageFromIconData(candidate);
        if (!image) continue;
        NSData *png = UIImagePNGRepresentation(image);
        if (png.length && [png writeToFile:cachePath atomically:YES]) {
            NSLog(@"[AppsMetadataFix] cached LS icon id=%@ variant=%d path=%@",
                  identifier, variants[index], cachePath);
            return cachePath;
        }
    }
    return nil;
}

static uint64_t FilzaMetadataReadableTreeSize(NSString *path, BOOL *partial)
{
    if (partial) *partial = NO;
    if (!path.length || !path.isAbsolutePath) return 0;

    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory])
        return 0;
    if (!directory) {
        NSDictionary *attributes = [NSFileManager.defaultManager
            attributesOfItemAtPath:path error:nil];
        return [attributes[NSFileSize] unsignedLongLongValue];
    }

    __block BOOL incomplete = NO;
    NSArray *keys = @[
        NSURLIsRegularFileKey,
        NSURLIsSymbolicLinkKey,
        NSURLFileAllocatedSizeKey,
        NSURLFileSizeKey,
    ];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager
        enumeratorAtURL:[NSURL fileURLWithPath:path isDirectory:YES]
        includingPropertiesForKeys:keys
        options:0
        errorHandler:^BOOL(NSURL *url, NSError *error) {
            (void)url;
            (void)error;
            incomplete = YES;
            return YES;
        }];

    uint64_t total = 0;
    NSUInteger entries = 0;
    for (NSURL *url in enumerator) {
        if (++entries > 250000) {
            incomplete = YES;
            break;
        }
        NSNumber *isSymlink = nil;
        NSNumber *isRegular = nil;
        NSNumber *allocated = nil;
        NSNumber *logical = nil;
        NSError *resourceError = nil;
        BOOL ok = [url getResourceValue:&isSymlink forKey:NSURLIsSymbolicLinkKey
                                  error:&resourceError];
        if (!ok) {
            incomplete = YES;
            continue;
        }
        if (isSymlink.boolValue) continue;
        [url getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil];
        if (!isRegular.boolValue) continue;
        [url getResourceValue:&allocated forKey:NSURLFileAllocatedSizeKey error:nil];
        [url getResourceValue:&logical forKey:NSURLFileSizeKey error:nil];
        total += allocated.unsignedLongLongValue ?: logical.unsignedLongLongValue;
    }
    if (partial) *partial = incomplete;
    return total;
}

static void FilzaMetadataSetDisplayedSize(id item, uint64_t bytes, BOOL partial)
{
    SEL fileSizeSetter = NSSelectorFromString(@"setFileSize:");
    if ([item respondsToSelector:fileSizeSetter])
        ((void (*)(id, SEL, unsigned long long))objc_msgSend)(item,
            fileSizeSetter, bytes);

    NSString *formatted = bytes
        ? [NSByteCountFormatter stringFromByteCount:(long long)bytes
                                         countStyle:NSByteCountFormatterCountStyleFile]
        : @"Unknown";
    if (partial && bytes) formatted = [formatted stringByAppendingString:@"+"];
    SEL stringSetter = NSSelectorFromString(@"setAFileSizeString:");
    if ([item respondsToSelector:stringSetter])
        ((void (*)(id, SEL, id))objc_msgSend)(item, stringSetter, formatted);
}

static void FilzaMetadataSetAppProxy(id self, SEL _cmd, id proxy)
{
    if (gMetadataPreviousSetAppProxy)
        ((void (*)(id, SEL, id))gMetadataPreviousSetAppProxy)(self, _cmd, proxy);

    NSString *identifier = FilzaMetadataObject(proxy, @"applicationIdentifier");
    if (!identifier.length) identifier = FilzaMetadataObject(self, @"bundleId");

    NSString *iconPath = FilzaMetadataObject(self, @"iconPath");
    if (!iconPath.length && identifier.length) {
        NSString *cached = FilzaMetadataCachedIconPath(proxy, identifier);
        SEL setter = NSSelectorFromString(@"setIconPath:");
        if (cached.length && [self respondsToSelector:setter])
            ((void (*)(id, SEL, id))objc_msgSend)(self, setter, cached);
    }
}

static void FilzaMetadataCalculateDiskUsage(id self, SEL _cmd)
{
    if (gMetadataPreviousCalculateDiskUsage)
        ((void (*)(id, SEL))gMetadataPreviousCalculateDiskUsage)(self, _cmd);

    SEL fileSizeSelector = NSSelectorFromString(@"fileSize");
    uint64_t current = [self respondsToSelector:fileSizeSelector]
        ? ((unsigned long long (*)(id, SEL))objc_msgSend)(self, fileSizeSelector) : 0;
    if (current > 0) return;

    id proxy = FilzaMetadataObject(self, @"appProxy");
    uint64_t proxyTotal = FilzaMetadataUnsignedLongLong(proxy, @"staticDiskUsage") +
                          FilzaMetadataUnsignedLongLong(proxy, @"dynamicDiskUsage");
    if (proxyTotal > 0) {
        FilzaMetadataSetDisplayedSize(self, proxyTotal, NO);
        return;
    }

    // Fall back only to paths the current Filza process can already enumerate.
    // This is deliberately a metadata/UI repair, not an access-bypass path.
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    for (NSString *selectorName in @[@"filePath", @"documentPath"]) {
        NSString *value = FilzaMetadataObject(self, selectorName);
        if (value.length && value.isAbsolutePath)
            [paths addObject:value.stringByStandardizingPath];
    }

    uint64_t total = 0;
    BOOL anyReadable = NO;
    BOOL partial = NO;
    for (NSString *path in paths) {
        BOOL isDirectory = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory])
            continue;
        anyReadable = YES;
        BOOL pathPartial = NO;
        total += FilzaMetadataReadableTreeSize(path, &pathPartial);
        partial |= pathPartial;
    }

    if (total > 0 || anyReadable)
        FilzaMetadataSetDisplayedSize(self, total, partial);
    else
        FilzaMetadataSetDisplayedSize(self, 0, YES);
}

static IMP FilzaMetadataInstallInstanceHook(Class cls, SEL selector,
                                             IMP replacement)
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

static void FilzaInstallAppsMetadataFixes(void)
{
    if (gMetadataHooksInstalled) return;
    Class applicationItem = NSClassFromString(@"ApplicationItem");
    if (!applicationItem) return;

    gMetadataPreviousSetAppProxy = FilzaMetadataInstallInstanceHook(applicationItem,
        NSSelectorFromString(@"setAppProxy:"), (IMP)FilzaMetadataSetAppProxy);
    gMetadataPreviousCalculateDiskUsage = FilzaMetadataInstallInstanceHook(applicationItem,
        NSSelectorFromString(@"calculateDiskUsage"),
        (IMP)FilzaMetadataCalculateDiskUsage);
    if (!gMetadataPreviousSetAppProxy || !gMetadataPreviousCalculateDiskUsage)
        return;

    gMetadataHooksInstalled = YES;
    NSLog(@"[AppsMetadataFix] ApplicationItem icon/size fallbacks installed");
}

__attribute__((constructor)) static void FilzaAppsMetadataFixInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        FilzaInstallAppsMetadataFixes();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            FilzaInstallAppsMetadataFixes();
        });
    });
}
