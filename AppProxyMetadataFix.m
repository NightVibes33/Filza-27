@import Foundation;
@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

#import "AppsMusicFix.h"

static IMP gOriginalIconDataForVariant = NULL;
static IMP gOriginalStaticDiskUsage = NULL;
static IMP gOriginalDynamicDiskUsage = NULL;
static NSMutableDictionary<NSString *, NSNumber *> *gContainerSizeCache;

static NSString *FilzaMetadataProxyIdentifier(id proxy)
{
    SEL selector = NSSelectorFromString(@"applicationIdentifier");
    if ([proxy respondsToSelector:selector]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(proxy, selector);
        if ([value isKindOfClass:NSString.class] && [value length] > 0)
            return value;
    }
    selector = NSSelectorFromString(@"bundleIdentifier");
    if ([proxy respondsToSelector:selector]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(proxy, selector);
        if ([value isKindOfClass:NSString.class] && [value length] > 0)
            return value;
    }
    return nil;
}

static unsigned long long FilzaAllocatedContainerBytes(NSString *identifier)
{
    if (identifier.length == 0) return 0;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gContainerSizeCache = [NSMutableDictionary dictionary];
    });

    @synchronized (gContainerSizeCache) {
        NSNumber *cached = gContainerSizeCache[identifier];
        if (cached) return cached.unsignedLongLongValue;
    }

    // Reuse the exact path resolver used when the user opens an app from
    // Filza's Apps Manager. This keeps the metadata and browser backends in
    // lockstep: MHA class-2 first, then the pinned bad_query per-container
    // fallback, followed by an actual readdir verification before returning.
    NSString *detail = nil;
    NSString *root = FilzaEnsureVirtualAppDataPath(identifier, &detail);
    if (root.length == 0) {
        NSLog(@"[AppProxyMetadataFix] size unavailable id=%@ detail=%@", identifier, detail);
        return 0;
    }

    NSURL *rootURL = [NSURL fileURLWithPath:root isDirectory:YES];
    NSArray<NSURLResourceKey> *keys = @[
        NSURLIsRegularFileKey,
        NSURLFileAllocatedSizeKey,
        NSURLTotalFileAllocatedSizeKey,
    ];
    __block BOOL partial = NO;
    NSDirectoryEnumerator<NSURL *> *enumerator =
        [NSFileManager.defaultManager enumeratorAtURL:rootURL
                           includingPropertiesForKeys:keys
                                              options:0
                                         errorHandler:^BOOL(NSURL *url, NSError *error) {
        partial = YES;
        NSLog(@"[AppProxyMetadataFix] size traversal skipped path=%@ error=%@",
              url.path, error.localizedDescription);
        return YES;
    }];

    unsigned long long total = 0;
    for (NSURL *url in enumerator) {
        NSError *error = nil;
        NSDictionary<NSURLResourceKey, id> *values =
            [url resourceValuesForKeys:keys error:&error];
        if (error) {
            partial = YES;
            continue;
        }
        if (![values[NSURLIsRegularFileKey] boolValue]) continue;
        NSNumber *allocated = values[NSURLTotalFileAllocatedSizeKey];
        if (![allocated isKindOfClass:NSNumber.class])
            allocated = values[NSURLFileAllocatedSizeKey];
        total += allocated.unsignedLongLongValue;
    }

    @synchronized (gContainerSizeCache) {
        gContainerSizeCache[identifier] = @(total);
    }
    NSLog(@"[AppProxyMetadataFix] measured id=%@ bytes=%llu root=%@ partial=%d detail=%@",
          identifier, total, root, partial, detail);
    return total;
}

static NSData *FilzaMetadataIconDataForVariant(id self, SEL _cmd, NSUInteger variant)
{
    NSData *original = gOriginalIconDataForVariant
        ? ((id (*)(id, SEL, NSUInteger))gOriginalIconDataForVariant)(self, _cmd, variant)
        : nil;

    // LaunchServices can return a non-empty private/raw icon representation.
    // Only treat it as complete when UIKit can actually decode it; otherwise
    // continue to the image-cache fallback below so Filza receives real PNG
    // data rather than a non-empty blob it cannot render.
    if ([original isKindOfClass:NSData.class] && original.length > 0 &&
        [UIImage imageWithData:original] != nil)
        return original;

    NSString *identifier = FilzaMetadataProxyIdentifier(self);
    if (identifier.length == 0) return original;

    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![UIImage respondsToSelector:selector]) return original;

    CGFloat scale = UIScreen.mainScreen.scale ?: 2.0;
    for (NSInteger format = 2; format >= 0; format--) {
        UIImage *image = nil;
        @try {
            image = ((id (*)(id, SEL, id, NSInteger, CGFloat))objc_msgSend)(
                UIImage.class, selector, identifier, format, scale);
        } @catch (__unused NSException *exception) {
            image = nil;
        }
        if (![image isKindOfClass:UIImage.class]) continue;
        NSData *png = UIImagePNGRepresentation(image);
        if (png.length > 0) {
            NSLog(@"[AppProxyMetadataFix] icon fallback id=%@ variant=%lu format=%ld",
                  identifier, (unsigned long)variant, (long)format);
            return png;
        }
    }
    return original;
}

static NSNumber *FilzaMetadataStaticDiskUsage(id self, SEL _cmd)
{
    NSNumber *original = gOriginalStaticDiskUsage
        ? ((id (*)(id, SEL))gOriginalStaticDiskUsage)(self, _cmd)
        : nil;
    if ([original isKindOfClass:NSNumber.class] && original.unsignedLongLongValue > 0)
        return original;

    NSString *identifier = FilzaMetadataProxyIdentifier(self);
    unsigned long long bytes = FilzaAllocatedContainerBytes(identifier);
    return bytes > 0 ? @(bytes) : original;
}

static NSNumber *FilzaMetadataDynamicDiskUsage(id self, SEL _cmd)
{
    NSNumber *original = gOriginalDynamicDiskUsage
        ? ((id (*)(id, SEL))gOriginalDynamicDiskUsage)(self, _cmd)
        : nil;
    if ([original isKindOfClass:NSNumber.class] && original.unsignedLongLongValue > 0)
        return original;

    // Avoid double-counting when callers sum static + dynamic. The static
    // fallback above carries the measured live data-container size.
    return original ?: @0;
}

static IMP FilzaMetadataInstallHook(Class cls, SEL selector, IMP replacement)
{
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return NULL;
    const char *types = method_getTypeEncoding(method);
    IMP original = method_getImplementation(method);
    if (class_addMethod(cls, selector, replacement, types)) return original;
    method = class_getInstanceMethod(cls, selector);
    if (method && method_getImplementation(method) != replacement)
        method_setImplementation(method, replacement);
    return original;
}

static void FilzaInstallAppProxyMetadataFix(void)
{
    Class proxy = NSClassFromString(@"LSApplicationProxy");
    if (!proxy) return;

    if (!gOriginalIconDataForVariant) {
        gOriginalIconDataForVariant = FilzaMetadataInstallHook(
            proxy, NSSelectorFromString(@"iconDataForVariant:"),
            (IMP)FilzaMetadataIconDataForVariant);
    }
    if (!gOriginalStaticDiskUsage) {
        gOriginalStaticDiskUsage = FilzaMetadataInstallHook(
            proxy, NSSelectorFromString(@"staticDiskUsage"),
            (IMP)FilzaMetadataStaticDiskUsage);
    }
    if (!gOriginalDynamicDiskUsage) {
        gOriginalDynamicDiskUsage = FilzaMetadataInstallHook(
            proxy, NSSelectorFromString(@"dynamicDiskUsage"),
            (IMP)FilzaMetadataDynamicDiskUsage);
    }

    NSLog(@"[AppProxyMetadataFix] installed icon=%d static=%d dynamic=%d",
          gOriginalIconDataForVariant != NULL,
          gOriginalStaticDiskUsage != NULL,
          gOriginalDynamicDiskUsage != NULL);
}

__attribute__((constructor)) static void FilzaAppProxyMetadataFixInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        FilzaInstallAppProxyMetadataFix();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            FilzaInstallAppProxyMetadataFix();
        });
    });
}
