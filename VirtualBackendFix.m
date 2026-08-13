@import Foundation;

#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/stat.h>

#import "MCMFilzaIntegration.h"

static IMP gPreviousVirtualIsDirectory = NULL;
static BOOL gVirtualBackendHookInstalled = NO;

static BOOL FZVirtualPathInsideDeviceStorage(NSString *path)
{
    if (![path isKindOfClass:NSString.class] || !path.length) return NO;
    NSString *candidate = path.stringByStandardizingPath;
    NSString *root = MCMFilzaVirtualRoot().stringByStandardizingPath;
    return [candidate isEqualToString:root] ||
        [candidate hasPrefix:[root stringByAppendingString:@"/"]];
}

static NSString *FZVirtualFileItemPath(id item)
{
    SEL selector = NSSelectorFromString(@"filePath");
    if (![item respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(item, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static BOOL FZVirtualIsDirectory(id self, SEL _cmd)
{
    BOOL original = gPreviousVirtualIsDirectory
        ? ((BOOL (*)(id, SEL))gPreviousVirtualIsDirectory)(self, _cmd) : NO;
    if (original) return YES;

    NSString *path = FZVirtualFileItemPath(self);
    if (!FZVirtualPathInsideDeviceStorage(path)) return NO;

    // stat() follows the already-created Device Storage symlink. Returning YES
    // here only corrects Filza's local file-model classification when the
    // target is already visible to the current process. It does not create or
    // consume a sandbox extension and cannot make a denied target readable.
    struct stat status = {0};
    if (stat(path.fileSystemRepresentation, &status) == 0 && S_ISDIR(status.st_mode)) {
        NSLog(@"[VirtualBackendFix] directory target path=%@", path);
        return YES;
    }
    return NO;
}

static IMP FZInstallVirtualClassLocalHook(Class cls, SEL selector, IMP replacement)
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

static void FZInstallVirtualBackendFix(void)
{
    if (gVirtualBackendHookInstalled) return;
    Class fileItem = NSClassFromString(@"FileItem");
    if (!fileItem) return;

    gPreviousVirtualIsDirectory = FZInstallVirtualClassLocalHook(
        fileItem, NSSelectorFromString(@"isDirectory"),
        (IMP)FZVirtualIsDirectory);
    if (!gPreviousVirtualIsDirectory) return;

    gVirtualBackendHookInstalled = YES;
    NSLog(@"[VirtualBackendFix] Device Storage directory typing installed");
}

__attribute__((constructor)) static void FZVirtualBackendInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        FZInstallVirtualBackendFix();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ FZInstallVirtualBackendFix(); });
    });
}
