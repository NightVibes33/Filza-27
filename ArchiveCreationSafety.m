#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef void *ZSZipFile;
typedef ZSZipFile (*ZSZipOpen64Fn)(const char *, int);
typedef int (*ZSZipOpenNewFileInZip64Fn)(ZSZipFile, const char *, const void *,
    const void *, unsigned, const void *, unsigned, const char *, int, int, int);
typedef int (*ZSZipWriteInFileInZipFn)(ZSZipFile, const void *, unsigned);
typedef int (*ZSZipCloseFileInZipFn)(ZSZipFile);
typedef int (*ZSZipCloseFn)(ZSZipFile, const char *);

static ZSZipOpen64Fn zs_zipOpen64;
static ZSZipOpenNewFileInZip64Fn zs_zipOpenNewFileInZip64;
static ZSZipWriteInFileInZipFn zs_zipWriteInFileInZip;
static ZSZipCloseFileInZipFn zs_zipCloseFileInZip;
static ZSZipCloseFn zs_zipClose;
static IMP zs_originalZip = NULL;

static BOOL ZSLoadZip(void)
{
    static dispatch_once_t onceToken;
    static BOOL available = NO;
    dispatch_once(&onceToken, ^{
        zs_zipOpen64 = (ZSZipOpen64Fn)dlsym(RTLD_DEFAULT, "zipOpen64");
        zs_zipOpenNewFileInZip64 = (ZSZipOpenNewFileInZip64Fn)dlsym(
            RTLD_DEFAULT, "zipOpenNewFileInZip64");
        zs_zipWriteInFileInZip = (ZSZipWriteInFileInZipFn)dlsym(
            RTLD_DEFAULT, "zipWriteInFileInZip");
        zs_zipCloseFileInZip = (ZSZipCloseFileInZipFn)dlsym(
            RTLD_DEFAULT, "zipCloseFileInZip");
        zs_zipClose = (ZSZipCloseFn)dlsym(RTLD_DEFAULT, "zipClose");
        available = zs_zipOpen64 && zs_zipOpenNewFileInZip64 &&
            zs_zipWriteInFileInZip && zs_zipCloseFileInZip && zs_zipClose;
        NSLog(@"[ArchiveCreationSafety] minizip create symbols=%d", available);
    });
    return available;
}

static NSString *ZSSafeRelativePath(NSString *raw)
{
    if (![raw isKindOfClass:NSString.class] || raw.length == 0 ||
        raw.isAbsolutePath || [raw hasPrefix:@"/"])
        return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [raw componentsSeparatedByString:@"/"]) {
        if (part.length == 0 || [part isEqualToString:@"."]) continue;
        if ([part isEqualToString:@".."] || [part containsString:@"\0"])
            return nil;
        [parts addObject:part];
    }
    return parts.count ? [parts componentsJoinedByString:@"/"] : nil;
}

static BOOL ZSOpenEntry(ZSZipFile archive, NSString *relativePath,
                        BOOL directory, unsigned long long size)
{
    NSString *entryName = directory && ![relativePath hasSuffix:@"/"]
        ? [relativePath stringByAppendingString:@"/"] : relativePath;
    int method = directory ? 0 : 8;
    int level = directory ? 0 : -1;
    int zip64 = size >= 0xffffffffULL;
    return zs_zipOpenNewFileInZip64(archive, entryName.UTF8String,
        NULL, NULL, 0, NULL, 0, NULL, method, level, zip64) == 0;
}

static BOOL ZSAddPath(ZSZipFile archive, NSString *basePath,
                      NSString *relativePath, NSString **message);

static BOOL ZSAddRegularFile(ZSZipFile archive, NSString *fullPath,
                             NSString *relativePath, const struct stat *status,
                             NSString **message)
{
    int input = open(fullPath.fileSystemRepresentation,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (input < 0) {
        if (message) *message = [NSString stringWithFormat:
            @"Could not open %@: %s", relativePath, strerror(errno)];
        return NO;
    }

    struct stat verified = {0};
    if (fstat(input, &verified) != 0 || !S_ISREG(verified.st_mode)) {
        if (message) *message = [NSString stringWithFormat:
            @"%@ changed while the archive was being created", relativePath];
        close(input);
        return NO;
    }

    unsigned long long size = verified.st_size < 0 ? 0 :
        (unsigned long long)verified.st_size;
    if (!ZSOpenEntry(archive, relativePath, NO, size)) {
        if (message) *message = [NSString stringWithFormat:
            @"Could not create archive entry %@", relativePath];
        close(input);
        return NO;
    }

    BOOL success = YES;
    uint8_t buffer[64 * 1024];
    for (;;) {
        ssize_t count = read(input, buffer, sizeof(buffer));
        if (count == 0) break;
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
            if (message) *message = [NSString stringWithFormat:
                @"Could not read %@: %s", relativePath, strerror(errno)];
            success = NO;
            break;
        }
        if (zs_zipWriteInFileInZip(archive, buffer, (unsigned)count) != 0) {
            if (message) *message = [NSString stringWithFormat:
                @"Could not write archive entry %@", relativePath];
            success = NO;
            break;
        }
    }
    close(input);
    if (zs_zipCloseFileInZip(archive) != 0) {
        if (message && !*message) *message = [NSString stringWithFormat:
            @"Could not finalize archive entry %@", relativePath];
        success = NO;
    }
    return success;
}

static BOOL ZSAddDirectory(ZSZipFile archive, NSString *fullPath,
                           NSString *relativePath, NSString **message)
{
    if (!ZSOpenEntry(archive, relativePath, YES, 0)) {
        if (message) *message = [NSString stringWithFormat:
            @"Could not create directory entry %@", relativePath];
        return NO;
    }
    if (zs_zipCloseFileInZip(archive) != 0) {
        if (message) *message = [NSString stringWithFormat:
            @"Could not finalize directory entry %@", relativePath];
        return NO;
    }

    int directoryFD = open(fullPath.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (directoryFD < 0) {
        if (message) *message = [NSString stringWithFormat:
            @"Could not open directory %@: %s", relativePath, strerror(errno)];
        return NO;
    }
    DIR *directory = fdopendir(directoryFD);
    if (!directory) {
        int saved = errno;
        close(directoryFD);
        if (message) *message = [NSString stringWithFormat:
            @"Could not enumerate directory %@: %s", relativePath, strerror(saved)];
        return NO;
    }

    BOOL success = YES;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (!entry) {
            if (errno != 0) {
                if (message) *message = [NSString stringWithFormat:
                    @"Directory enumeration failed for %@: %s",
                    relativePath, strerror(errno)];
                success = NO;
            }
            break;
        }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
            continue;
        NSString *name = [NSFileManager.defaultManager
            stringWithFileSystemRepresentation:entry->d_name
            length:strlen(entry->d_name)];
        if (!name.length || [name containsString:@"/"]) {
            if (message) *message = [NSString stringWithFormat:
                @"Unsupported filename inside %@", relativePath];
            success = NO;
            break;
        }
        NSString *child = [relativePath stringByAppendingPathComponent:name];
        if (!ZSAddPath(archive, fullPath.stringByDeletingLastPathComponent,
                       child, message)) {
            success = NO;
            break;
        }
    }
    closedir(directory);
    return success;
}

static BOOL ZSAddPath(ZSZipFile archive, NSString *basePath,
                      NSString *relativePath, NSString **message)
{
    NSString *safeRelative = ZSSafeRelativePath(relativePath);
    if (!safeRelative) {
        if (message) *message = @"Archive contains an unsafe relative path.";
        return NO;
    }
    NSString *fullPath = [basePath stringByAppendingPathComponent:safeRelative];
    struct stat status = {0};
    if (lstat(fullPath.fileSystemRepresentation, &status) != 0) {
        if (message) *message = [NSString stringWithFormat:
            @"Could not inspect %@: %s", safeRelative, strerror(errno)];
        return NO;
    }
    if (S_ISLNK(status.st_mode)) {
        if (message) *message = [NSString stringWithFormat:
            @"Refusing to follow symbolic link while archiving: %@", safeRelative];
        return NO;
    }
    if (S_ISREG(status.st_mode))
        return ZSAddRegularFile(archive, fullPath, safeRelative, &status, message);
    if (S_ISDIR(status.st_mode)) {
        if (!ZSOpenEntry(archive, safeRelative, YES, 0)) {
            if (message) *message = [NSString stringWithFormat:
                @"Could not create directory entry %@", safeRelative];
            return NO;
        }
        if (zs_zipCloseFileInZip(archive) != 0) {
            if (message) *message = [NSString stringWithFormat:
                @"Could not finalize directory entry %@", safeRelative];
            return NO;
        }
        int fd = open(fullPath.fileSystemRepresentation,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (fd < 0) {
            if (message) *message = [NSString stringWithFormat:
                @"Could not open directory %@: %s", safeRelative, strerror(errno)];
            return NO;
        }
        DIR *dir = fdopendir(fd);
        if (!dir) {
            int saved = errno;
            close(fd);
            if (message) *message = [NSString stringWithFormat:
                @"Could not enumerate directory %@: %s", safeRelative, strerror(saved)];
            return NO;
        }
        BOOL success = YES;
        for (;;) {
            errno = 0;
            struct dirent *entry = readdir(dir);
            if (!entry) {
                if (errno != 0) {
                    if (message) *message = [NSString stringWithFormat:
                        @"Directory enumeration failed for %@: %s",
                        safeRelative, strerror(errno)];
                    success = NO;
                }
                break;
            }
            if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
                continue;
            NSString *name = [NSFileManager.defaultManager
                stringWithFileSystemRepresentation:entry->d_name
                length:strlen(entry->d_name)];
            if (!name.length || [name containsString:@"/"]) {
                if (message) *message = [NSString stringWithFormat:
                    @"Unsupported filename inside %@", safeRelative];
                success = NO;
                break;
            }
            NSString *childRelative = [safeRelative stringByAppendingPathComponent:name];
            if (!ZSAddPath(archive, basePath, childRelative, message)) {
                success = NO;
                break;
            }
        }
        closedir(dir);
        return success;
    }
    if (message) *message = [NSString stringWithFormat:
        @"Unsupported filesystem object: %@", safeRelative];
    return NO;
}

static id ZSFileItemForPath(NSString *path)
{
    Class fileItemClass = NSClassFromString(@"FileItem");
    SEL setter = NSSelectorFromString(@"setFilePath:attribute:");
    if (!fileItemClass) return nil;
    id item = [[fileItemClass alloc] init];
    if (![item respondsToSelector:setter]) return nil;
    ((void (*)(id, SEL, id, id))objc_msgSend)(item, setter, path, nil);
    return item;
}

static id ZSHookZip(id self, SEL _cmd, id files, id toFilePath,
                    id currentDirectory)
{
    if (![toFilePath isKindOfClass:NSString.class] ||
        ![currentDirectory isKindOfClass:NSString.class] ||
        ![files isKindOfClass:NSArray.class]) {
        return zs_originalZip
            ? ((id (*)(id, SEL, id, id, id))zs_originalZip)(
                self, _cmd, files, toFilePath, currentDirectory)
            : nil;
    }

    if (!ZSLoadZip()) {
        // If zipOpen64 itself exists but the remaining API is incomplete, the
        // older compatibility hook can dereference a missing function pointer.
        // Fail closed instead of chaining into that partial implementation.
        if (zs_zipOpen64) {
            NSLog(@"[ArchiveCreationSafety] incomplete minizip API; archive creation disabled");
            return nil;
        }
        return zs_originalZip
            ? ((id (*)(id, SEL, id, id, id))zs_originalZip)(
                self, _cmd, files, toFilePath, currentDirectory)
            : nil;
    }

    ZSZipFile archive = zs_zipOpen64(((NSString *)toFilePath).fileSystemRepresentation, 0);
    if (!archive) {
        NSLog(@"[ArchiveCreationSafety] zipOpen64 failed for %@", toFilePath);
        return nil;
    }

    BOOL success = YES;
    NSString *message = nil;
    SEL fileNameSelector = NSSelectorFromString(@"fileName");
    for (id item in (NSArray *)files) {
        if (![item respondsToSelector:fileNameSelector]) {
            message = @"A selected item does not expose a filename.";
            success = NO;
            break;
        }
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(item, fileNameSelector);
        NSString *safeName = ZSSafeRelativePath(name);
        if (!safeName || !ZSAddPath(archive, currentDirectory, safeName, &message)) {
            success = NO;
            break;
        }
    }

    if (zs_zipClose(archive, NULL) != 0) {
        if (!message) message = @"Could not finalize the ZIP archive.";
        success = NO;
    }
    if (!success) {
        unlink(((NSString *)toFilePath).fileSystemRepresentation);
        NSLog(@"[ArchiveCreationSafety] archive creation failed: %@", message);
        return nil;
    }

    id result = ZSFileItemForPath(toFilePath);
    NSLog(@"[ArchiveCreationSafety] archive created: %@", toFilePath);
    return result;
}

static void ZSInstallHook(void)
{
    Class zipper = NSClassFromString(@"Zipper");
    if (!zipper) return;
    SEL selector = NSSelectorFromString(@"ZipFiles:toFilePath:currentDirectory:");
    Method method = class_getInstanceMethod(zipper, selector);
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (current == (IMP)ZSHookZip) return;
    zs_originalZip = current;
    method_setImplementation(method, (IMP)ZSHookZip);
    NSLog(@"[ArchiveCreationSafety] streaming ZIP hook installed");
}

__attribute__((constructor)) static void ZSArchiveCreationSafetyInit(void)
{
    // Tweak.m installs its compatibility method replacements during image
    // initialization. Queue this hook so it consistently wraps that layer.
    dispatch_async(dispatch_get_main_queue(), ^{
        ZSInstallHook();
    });
}
