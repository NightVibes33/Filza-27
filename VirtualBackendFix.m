@import Foundation;

#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MCMFilzaIntegration.h"

static IMP gPreviousVirtualIsDirectory = NULL;
static BOOL gVirtualBackendHookInstalled = NO;

static IMP gPreviousTrashDir = NULL;
static IMP gParentDoTrashSelectedItems = NULL;
static BOOL gTrashDirectoryHookInstalled = NO;
static BOOL gTrashOperationHookInstalled = NO;

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

static BOOL FZTrashDirectoryIsUsable(NSString *path)
{
    if (![path isKindOfClass:NSString.class] || path.length == 0) return NO;

    NSFileManager *manager = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    BOOL exists = [manager fileExistsAtPath:path isDirectory:&isDirectory];
    if (exists && !isDirectory) return NO;

    if (!exists) {
        NSError *error = nil;
        if (![manager createDirectoryAtPath:path
                 withIntermediateDirectories:YES
                                  attributes:nil
                                       error:&error]) {
            NSLog(@"[TrashFix] cannot create trash path=%@ error=%@", path, error);
            return NO;
        }
    }

    // Existence alone is not sufficient on a jailed device: Filza's historical
    // /var/mobile/Library/Filza/.Trash may be visible but still unwritable.
    return access(path.fileSystemRepresentation, W_OK | X_OK) == 0;
}

static NSString *FZSandboxTrashDirectory(void)
{
    NSArray<NSString *> *libraries = NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *library = libraries.firstObject;
    if (library.length == 0)
        library = [NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
    return [library stringByAppendingPathComponent:@"Filza/.Trash"];
}

static NSString *FZResolvedTrashDirectory(id preferences, SEL selector)
{
    NSString *nativeTrash = nil;
    if (gPreviousTrashDir) {
        id value = ((id (*)(id, SEL))gPreviousTrashDir)(preferences, selector);
        if ([value isKindOfClass:NSString.class]) nativeTrash = value;
    }
    if (nativeTrash.length == 0)
        nativeTrash = @"/var/mobile/Library/Filza/.Trash";

    // Preserve Filza's native trash location whenever the process genuinely has
    // access to it (normal jailbreak/root/unrestricted filesystem operation).
    if (FZTrashDirectoryIsUsable(nativeTrash)) return nativeTrash;

    // Jailed Filza cannot create /var/mobile/Library/Filza. Keep the same Filza
    // trash semantics, but place the directory in this app's writable Library.
    NSString *sandboxTrash = FZSandboxTrashDirectory();
    if (FZTrashDirectoryIsUsable(sandboxTrash)) {
        static dispatch_once_t logOnce;
        dispatch_once(&logOnce, ^{
            NSLog(@"[TrashFix] native trash unavailable; using jailed trash %@",
                  sandboxTrash);
        });
        return sandboxTrash;
    }

    // Library should always be writable in a healthy app container, but use a
    // final process-local directory rather than returning a known-broken path.
    NSString *temporaryTrash = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"Filza/.Trash"];
    if (FZTrashDirectoryIsUsable(temporaryTrash)) {
        NSLog(@"[TrashFix] Library trash unavailable; using temporary trash %@",
              temporaryTrash);
        return temporaryTrash;
    }

    // Returning the sandbox candidate produces an honest filesystem error if
    // the app container itself is damaged instead of silently deleting data.
    return sandboxTrash;
}

static NSString *FZTrashDir(id self, SEL _cmd)
{
    return FZResolvedTrashDirectory(self, _cmd);
}

static void FZDoTrashSelectedItems(id self, SEL _cmd, NSArray *indexPaths,
                                   void (^completion)(NSArray *))
{
    // TGFileSystemListViewController's shipped jailed implementation is a
    // literal no-op that only invokes the completion block. The superclass
    // TGPageViewController contains Filza's real trash implementation: it
    // creates trashDir, resolves collisions, moves each item, and records the
    // original path/name/type metadata. Forward to that implementation after
    // our trashDir hook has selected a path writable in the current runtime.
    Class preferencesClass = NSClassFromString(@"TGPreferences");
    id preferences = [preferencesClass respondsToSelector:@selector(sharedInstance)]
        ? ((id (*)(id, SEL))objc_msgSend)(preferencesClass, @selector(sharedInstance))
        : nil;
    NSString *trash = [preferences respondsToSelector:NSSelectorFromString(@"trashDir")]
        ? ((id (*)(id, SEL))objc_msgSend)(preferences,
            NSSelectorFromString(@"trashDir")) : nil;

    if (!FZTrashDirectoryIsUsable(trash)) {
        NSLog(@"[TrashFix] refusing trash operation: no writable trash directory");
        if (gParentDoTrashSelectedItems) {
            ((void (*)(id, SEL, id, id))gParentDoTrashSelectedItems)(
                self, _cmd, indexPaths ?: @[], completion);
        } else if (completion) {
            completion(@[]);
        }
        return;
    }

    if (gParentDoTrashSelectedItems) {
        NSLog(@"[TrashFix] trashing %lu selected item(s) via %@",
              (unsigned long)indexPaths.count, trash);
        ((void (*)(id, SEL, id, id))gParentDoTrashSelectedItems)(
            self, _cmd, indexPaths ?: @[], completion);
        return;
    }

    if (completion) completion(@[]);
}

static void FZInstallTrashBackendFix(void)
{
    if (!gTrashDirectoryHookInstalled) {
        Class preferences = NSClassFromString(@"TGPreferences");
        SEL trashDirSelector = NSSelectorFromString(@"trashDir");
        Method trashDir = preferences
            ? class_getInstanceMethod(preferences, trashDirSelector) : NULL;
        if (trashDir) {
            IMP original = method_getImplementation(trashDir);
            if (original != (IMP)FZTrashDir) {
                gPreviousTrashDir = original;
                method_setImplementation(trashDir, (IMP)FZTrashDir);
            }
            gTrashDirectoryHookInstalled = YES;
            NSLog(@"[TrashFix] adaptive trash directory installed");
        }
    }

    if (!gTrashOperationHookInstalled) {
        Class fileSystem = NSClassFromString(@"TGFileSystemListViewController");
        SEL selector = NSSelectorFromString(@"doTrashSelectedIndexPaths:completion:");
        Method localMethod = fileSystem
            ? class_getInstanceMethod(fileSystem, selector) : NULL;
        Class superclass = fileSystem ? class_getSuperclass(fileSystem) : Nil;
        Method parentMethod = superclass
            ? class_getInstanceMethod(superclass, selector) : NULL;
        if (localMethod && parentMethod) {
            gParentDoTrashSelectedItems = method_getImplementation(parentMethod);
            if (gParentDoTrashSelectedItems != (IMP)FZDoTrashSelectedItems) {
                method_setImplementation(localMethod, (IMP)FZDoTrashSelectedItems);
                gTrashOperationHookInstalled = YES;
                NSLog(@"[TrashFix] restored TGPageViewController trash backend");
            }
        }
    }
}

static void FZInstallVirtualBackendFix(void)
{
    if (!gVirtualBackendHookInstalled) {
        Class fileItem = NSClassFromString(@"FileItem");
        if (fileItem) {
            gPreviousVirtualIsDirectory = FZInstallVirtualClassLocalHook(
                fileItem, NSSelectorFromString(@"isDirectory"),
                (IMP)FZVirtualIsDirectory);
            if (gPreviousVirtualIsDirectory) {
                gVirtualBackendHookInstalled = YES;
                NSLog(@"[VirtualBackendFix] Device Storage directory typing installed");
            }
        }
    }

    FZInstallTrashBackendFix();
}

__attribute__((constructor)) static void FZVirtualBackendInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        FZInstallVirtualBackendFix();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ FZInstallVirtualBackendFix(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ FZInstallVirtualBackendFix(); });
    });
}
