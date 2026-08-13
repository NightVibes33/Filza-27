@import Foundation;

#import <dirent.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdint.h>

#import "AppsMusicFix.h"

static IMP gMetadataRetryPreviousSetAppProxy = NULL;
static IMP gMetadataRetryPreviousSetDocumentPath = NULL;
static IMP gMetadataRetryPreviousReload = NULL;
static BOOL gMetadataRetryHooksInstalled = NO;

static const void *kMetadataRetryPendingKey = &kMetadataRetryPendingKey;
static const void *kMetadataRetryCountKey = &kMetadataRetryCountKey;

static id FZRetryObjectSelector(id object, NSString *selectorName)
{
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *FZRetryIdentifier(id item)
{
    id value = FZRetryObjectSelector(item, @"bundleId");
    if ([value isKindOfClass:NSString.class] && [value length]) return value;

    id proxy = FZRetryObjectSelector(item, @"appProxy");
    for (NSString *selectorName in @[@"applicationIdentifier", @"bundleIdentifier"]) {
        value = FZRetryObjectSelector(proxy, selectorName);
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return nil;
}

static BOOL FZRetryCanEnumerate(NSString *path)
{
    if (![path isKindOfClass:NSString.class] || !path.length || !path.isAbsolutePath) return NO;
    DIR *directory = opendir(path.fileSystemRepresentation);
    if (!directory) return NO;
    errno = 0;
    (void)readdir(directory);
    int readError = errno;
    closedir(directory);
    return readError == 0;
}

static uint64_t FZRetryCurrentFileSize(id item)
{
    SEL selector = NSSelectorFromString(@"fileSize");
    if (![item respondsToSelector:selector]) return 0;
    return ((uint64_t (*)(id, SEL))objc_msgSend)(item, selector);
}

static void FZRetryResetCalculatedFlag(id item)
{
    Class cls = NSClassFromString(@"ApplicationItem");
    Ivar ivar = cls ? class_getInstanceVariable(cls, "_calculatedDiskUsage") : NULL;
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        uint8_t *bytes = (__bridge void *)item;
        *((BOOL *)(bytes + offset)) = NO;
    }

    SEL sizeSetter = NSSelectorFromString(@"setFileSize:");
    if ([item respondsToSelector:sizeSetter])
        ((void (*)(id, SEL, uint64_t))objc_msgSend)(item, sizeSetter, 0);
}

static void FZScheduleMetadataRefresh(id item, NSTimeInterval delay)
{
    if (!item || [objc_getAssociatedObject(item, kMetadataRetryPendingKey) boolValue]) return;
    objc_setAssociatedObject(item, kMetadataRetryPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak id weakItem = item;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id strongItem = weakItem;
        if (!strongItem) return;
        objc_setAssociatedObject(strongItem, kMetadataRetryPendingKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (FZRetryCurrentFileSize(strongItem) > 0) return;

        NSString *identifier = FZRetryIdentifier(strongItem);
        if (!identifier.length) return;

        NSString *documentPath = FZRetryObjectSelector(strongItem, @"documentPath");
        NSString *detail = nil;
        if (![documentPath isKindOfClass:NSString.class] || !FZRetryCanEnumerate(documentPath)) {
            NSString *resolved = FilzaEnsureVirtualAppDataPath(identifier, &detail);
            if (resolved.length && FZRetryCanEnumerate(resolved)) {
                SEL documentSetter = NSSelectorFromString(@"setDocumentPath:");
                if ([strongItem respondsToSelector:documentSetter])
                    ((void (*)(id, SEL, id))objc_msgSend)(strongItem, documentSetter, resolved);
                documentPath = resolved;
            }
        }

        if ([documentPath isKindOfClass:NSString.class] && FZRetryCanEnumerate(documentPath)) {
            FZRetryResetCalculatedFlag(strongItem);
            SEL calculate = NSSelectorFromString(@"calculateDiskUsage");
            if ([strongItem respondsToSelector:calculate])
                ((void (*)(id, SEL))objc_msgSend)(strongItem, calculate);
        }

        // bad_query_list discovery is asynchronous. A zero-size result before
        // the identifier->UUID map is ready must not become permanent UI state.
        if (FZRetryCurrentFileSize(strongItem) == 0) {
            NSUInteger retries = [objc_getAssociatedObject(strongItem, kMetadataRetryCountKey)
                unsignedIntegerValue];
            if (retries < 4) {
                objc_setAssociatedObject(strongItem, kMetadataRetryCountKey, @(retries + 1),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                FZScheduleMetadataRefresh(strongItem, 1.0 + (0.5 * retries));
            } else {
                NSLog(@"[AppMetadataRetryFix] unresolved size id=%@ detail=%@",
                      identifier, detail ?: @"no detail");
            }
        } else {
            objc_setAssociatedObject(strongItem, kMetadataRetryCountKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSLog(@"[AppMetadataRetryFix] live size refreshed id=%@ bytes=%llu",
                  identifier, FZRetryCurrentFileSize(strongItem));
        }
    });
}

static void FZRetrySetAppProxy(id self, SEL _cmd, id proxy)
{
    if (gMetadataRetryPreviousSetAppProxy)
        ((void (*)(id, SEL, id))gMetadataRetryPreviousSetAppProxy)(self, _cmd, proxy);
    FZScheduleMetadataRefresh(self, 0.75);
}

static void FZRetrySetDocumentPath(id self, SEL _cmd, id path)
{
    if (gMetadataRetryPreviousSetDocumentPath)
        ((void (*)(id, SEL, id))gMetadataRetryPreviousSetDocumentPath)(self, _cmd, path);
    FZScheduleMetadataRefresh(self, 0.05);
}

static void FZRetryReload(id self, SEL _cmd)
{
    if (gMetadataRetryPreviousReload)
        ((void (*)(id, SEL))gMetadataRetryPreviousReload)(self, _cmd);
    if (FZRetryCurrentFileSize(self) == 0)
        FZScheduleMetadataRefresh(self, 0.5);
}

static IMP FZRetryInstallHook(Class cls, SEL selector, IMP replacement)
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

static void FZInstallAppMetadataRetryFix(void)
{
    if (gMetadataRetryHooksInstalled) return;
    Class item = NSClassFromString(@"ApplicationItem");
    if (!item) return;

    gMetadataRetryPreviousSetAppProxy = FZRetryInstallHook(
        item, NSSelectorFromString(@"setAppProxy:"), (IMP)FZRetrySetAppProxy);
    gMetadataRetryPreviousSetDocumentPath = FZRetryInstallHook(
        item, NSSelectorFromString(@"setDocumentPath:"), (IMP)FZRetrySetDocumentPath);
    gMetadataRetryPreviousReload = FZRetryInstallHook(
        item, NSSelectorFromString(@"reload"), (IMP)FZRetryReload);

    if (!gMetadataRetryPreviousSetAppProxy && !gMetadataRetryPreviousSetDocumentPath &&
        !gMetadataRetryPreviousReload) return;

    gMetadataRetryHooksInstalled = YES;
    NSLog(@"[AppMetadataRetryFix] live metadata retry hooks installed proxy=%d path=%d reload=%d",
          gMetadataRetryPreviousSetAppProxy != NULL,
          gMetadataRetryPreviousSetDocumentPath != NULL,
          gMetadataRetryPreviousReload != NULL);
}

__attribute__((constructor)) static void FZAppMetadataRetryInit(void)
{
    // Install after the existing AppsManagerPresentationFix hooks so this layer
    // wraps them instead of replacing their icon/size behavior.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        FZInstallAppMetadataRetryFix();
    });
}
