@import Foundation;

#import <dirent.h>
#import <errno.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/stat.h>

#import "MCMFilzaIntegration.h"

static IMP gFZPreviousIsDirectory = NULL;
static IMP gFZPreviousIsDir = NULL;
static BOOL gFZBackendHooksInstalled = NO;

static id FZBackendObject(id object, NSString *selectorName)
{
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *FZBackendPath(id item)
{
    for (NSString *selectorName in @[@"filePath", @"path", @"fullPath"]) {
        id value = FZBackendObject(item, selectorName);
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return nil;
}

static BOOL FZBackendInsideVirtualRoot(NSString *path)
{
    if (!path.length) return NO;
    NSString *candidate = path.stringByStandardizingPath;
    NSString *root = MCMFilzaVirtualRoot().stringByStandardizingPath;
    return [candidate isEqualToString:root] ||
        [candidate hasPrefix:[root stringByAppendingString:@"/"]];
}

static BOOL FZBackendVerifiedDirectory(NSString *path)
{
    if (!FZBackendInsideVirtualRoot(path)) return NO;

    struct stat status = {0};
    if (stat(path.fileSystemRepresentation, &status) != 0 ||
        !S_ISDIR(status.st_mode)) return NO;

    errno = 0;
    DIR *directory = opendir(path.fileSystemRepresentation);
    if (!directory) return NO;

    // Force one directory read. NULL with errno == 0 is a valid empty folder.
    errno = 0;
    (void)readdir(directory);
    int readErrno = errno;
    closedir(directory);
    return readErrno == 0;
}

static BOOL FZBackendIsDirectory(id self, SEL _cmd)
{
    BOOL original = gFZPreviousIsDirectory
        ? ((BOOL (*)(id, SEL))gFZPreviousIsDirectory)(self, _cmd) : NO;
    if (original) return YES;

    NSString *path = FZBackendPath(self);
    BOOL verified = FZBackendVerifiedDirectory(path);
    if (verified)
        NSLog(@"[FileBackendFix] accessible virtual target is a directory path=%@", path);
    return verified;
}

static BOOL FZBackendIsDir(id self, SEL _cmd)
{
    BOOL original = gFZPreviousIsDir
        ? ((BOOL (*)(id, SEL))gFZPreviousIsDir)(self, _cmd) : NO;
    if (original) return YES;

    NSString *path = FZBackendPath(self);
    BOOL verified = FZBackendVerifiedDirectory(path);
    if (verified)
        NSLog(@"[FileBackendFix] accessible virtual target isDir path=%@", path);
    return verified;
}

static IMP FZBackendInstallHook(Class cls, SEL selector, IMP replacement)
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

static void FZInstallBackendFixes(void)
{
    if (gFZBackendHooksInstalled) return;
    Class fileItem = NSClassFromString(@"FileItem");
    if (!fileItem) return;

    SEL isDirectory = NSSelectorFromString(@"isDirectory");
    SEL isDir = NSSelectorFromString(@"isDir");
    if (class_getInstanceMethod(fileItem, isDirectory))
        gFZPreviousIsDirectory = FZBackendInstallHook(fileItem, isDirectory,
                                                       (IMP)FZBackendIsDirectory);
    if (class_getInstanceMethod(fileItem, isDir))
        gFZPreviousIsDir = FZBackendInstallHook(fileItem, isDir,
                                                 (IMP)FZBackendIsDir);

    gFZBackendHooksInstalled = YES;
    NSLog(@"[FileBackendFix] verified virtual-directory hooks installed");
}

__attribute__((constructor)) static void FZBackendInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        FZInstallBackendFixes();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ FZInstallBackendFixes(); });
    });
}
