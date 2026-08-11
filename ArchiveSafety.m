#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// Archive hardening for the jailed Filza compatibility layer.
// This intentionally does not change any sandbox/container-access primitive.
// It only replaces Filza's custom minizip hooks with bounded, path-safe,
// streaming implementations.

typedef void *ASZipFile;
typedef void *ASUnzFile;

typedef ASZipFile (*ASZipOpen64Fn)(const char *, int);
typedef int (*ASZipOpenNewFileInZip64Fn)(ASZipFile, const char *, const void *,
    const void *, unsigned, const void *, unsigned, const char *, int, int, int);
typedef int (*ASZipWriteInFileInZipFn)(ASZipFile, const void *, unsigned);
typedef int (*ASZipCloseFileInZipFn)(ASZipFile);
typedef int (*ASZipCloseFn)(ASZipFile, const char *);
typedef ASUnzFile (*ASUnzOpen64Fn)(const char *);
typedef int (*ASUnzGoToFirstFileFn)(ASUnzFile);
typedef int (*ASUnzGoToNextFileFn)(ASUnzFile);
typedef int (*ASUnzGetCurrentFileInfo64Fn)(ASUnzFile, void *, char *, unsigned long,
    void *, unsigned long, char *, unsigned long);
typedef int (*ASUnzOpenCurrentFilePasswordFn)(ASUnzFile, const char *);
typedef int (*ASUnzReadCurrentFileFn)(ASUnzFile, void *, unsigned);
typedef int (*ASUnzCloseCurrentFileFn)(ASUnzFile);
typedef int (*ASUnzCloseFn)(ASUnzFile);

static ASZipOpen64Fn as_zipOpen64;
static ASZipOpenNewFileInZip64Fn as_zipOpenNewFileInZip64;
static ASZipWriteInFileInZipFn as_zipWriteInFileInZip;
static ASZipCloseFileInZipFn as_zipCloseFileInZip;
static ASZipCloseFn as_zipClose;
static ASUnzOpen64Fn as_unzOpen64;
static ASUnzGoToFirstFileFn as_unzGoToFirstFile;
static ASUnzGoToNextFileFn as_unzGoToNextFile;
static ASUnzGetCurrentFileInfo64Fn as_unzGetCurrentFileInfo64;
static ASUnzOpenCurrentFilePasswordFn as_unzOpenCurrentFilePassword;
static ASUnzReadCurrentFileFn as_unzReadCurrentFile;
static ASUnzCloseCurrentFileFn as_unzCloseCurrentFile;
static ASUnzCloseFn as_unzClose;

static IMP as_origZip = NULL;
static IMP as_origUnzip = NULL;
static IMP as_origUnzipPassword = NULL;

static const unsigned long long ASMaxExpandedArchiveBytes = 8ULL * 1024ULL * 1024ULL * 1024ULL;
static const unsigned long long ASMaxExpandedFileBytes = 2ULL * 1024ULL * 1024ULL * 1024ULL;
static const NSUInteger ASMaxArchiveEntries = 100000;

static BOOL ASLoadMinizip(void) {
    static dispatch_once_t onceToken;
    static BOOL available = NO;
    dispatch_once(&onceToken, ^{
        as_zipOpen64 = (ASZipOpen64Fn)dlsym(RTLD_DEFAULT, "zipOpen64");
        as_zipOpenNewFileInZip64 = (ASZipOpenNewFileInZip64Fn)dlsym(RTLD_DEFAULT, "zipOpenNewFileInZip64");
        as_zipWriteInFileInZip = (ASZipWriteInFileInZipFn)dlsym(RTLD_DEFAULT, "zipWriteInFileInZip");
        as_zipCloseFileInZip = (ASZipCloseFileInZipFn)dlsym(RTLD_DEFAULT, "zipCloseFileInZip");
        as_zipClose = (ASZipCloseFn)dlsym(RTLD_DEFAULT, "zipClose");
        as_unzOpen64 = (ASUnzOpen64Fn)dlsym(RTLD_DEFAULT, "unzOpen64");
        as_unzGoToFirstFile = (ASUnzGoToFirstFileFn)dlsym(RTLD_DEFAULT, "unzGoToFirstFile");
        as_unzGoToNextFile = (ASUnzGoToNextFileFn)dlsym(RTLD_DEFAULT, "unzGoToNextFile");
        as_unzGetCurrentFileInfo64 = (ASUnzGetCurrentFileInfo64Fn)dlsym(RTLD_DEFAULT, "unzGetCurrentFileInfo64");
        as_unzOpenCurrentFilePassword = (ASUnzOpenCurrentFilePasswordFn)dlsym(RTLD_DEFAULT, "unzOpenCurrentFilePassword");
        as_unzReadCurrentFile = (ASUnzReadCurrentFileFn)dlsym(RTLD_DEFAULT, "unzReadCurrentFile");
        as_unzCloseCurrentFile = (ASUnzCloseCurrentFileFn)dlsym(RTLD_DEFAULT, "unzCloseCurrentFile");
        as_unzClose = (ASUnzCloseFn)dlsym(RTLD_DEFAULT, "unzClose");
        available = as_zipOpen64 && as_zipOpenNewFileInZip64 && as_zipWriteInFileInZip &&
            as_zipCloseFileInZip && as_zipClose && as_unzOpen64 && as_unzGoToFirstFile &&
            as_unzGoToNextFile && as_unzGetCurrentFileInfo64 && as_unzOpenCurrentFilePassword &&
            as_unzReadCurrentFile && as_unzCloseCurrentFile && as_unzClose;
        NSLog(@"[ArchiveSafety] minizip=%d", available);
    });
    return available;
}

static NSString *ASMessageForErrno(NSString *operation, NSString *path, int code) {
    return [NSString stringWithFormat:@"%@ failed for %@: %s", operation,
        path ?: @"(unknown)", strerror(code ?: EIO)];
}

static NSString *ASSafeRelativeArchivePath(NSString *raw) {
    if (![raw isKindOfClass:NSString.class] || raw.length == 0 || [raw hasPrefix:@"/"])
        return nil;
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    for (NSString *component in [raw componentsSeparatedByString:@"/"]) {
        if (component.length == 0 || [component isEqualToString:@"."]) continue;
        if ([component isEqualToString:@".."] || [component rangeOfString:@"\0"].location != NSNotFound)
            return nil;
        [components addObject:component];
    }
    if (components.count == 0) return nil;
    return [components componentsJoinedByString:@"/"];
}

static BOOL ASDirectoryIsReal(NSString *path) {
    struct stat st = {0};
    return lstat(path.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode);
}

static BOOL ASEnsureSafeDirectoryTree(NSString *root, NSString *relativeDir, NSString **message) {
    if (!ASDirectoryIsReal(root)) {
        if (message) *message = @"Destination root is not a real directory.";
        return NO;
    }
    NSString *cursor = root;
    for (NSString *component in [relativeDir componentsSeparatedByString:@"/"]) {
        if (component.length == 0 || [component isEqualToString:@"."]) continue;
        if ([component isEqualToString:@".."]) {
            if (message) *message = @"Archive contains an unsafe parent-directory component.";
            return NO;
        }
        cursor = [cursor stringByAppendingPathComponent:component];
        struct stat st = {0};
        if (lstat(cursor.fileSystemRepresentation, &st) == 0) {
            if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
                if (message) *message = @"Archive extraction encountered a non-directory or symlink parent.";
                return NO;
            }
            continue;
        }
        if (errno != ENOENT || mkdir(cursor.fileSystemRepresentation, 0700) != 0) {
            if (message) *message = ASMessageForErrno(@"mkdir", cursor, errno);
            return NO;
        }
    }
    return YES;
}

static BOOL ASWriteAll(int fd, const uint8_t *bytes, size_t length, NSString **message) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t written = write(fd, bytes + offset, length - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            if (message) *message = ASMessageForErrno(@"write", @"archive output", written < 0 ? errno : EIO);
            return NO;
        }
        offset += (size_t)written;
    }
    return YES;
}

static BOOL ASExtractArchive(NSString *archivePath, NSString *destination,
                             NSString *password, NSString **message) {
    if (!ASLoadMinizip()) {
        if (message) *message = @"Archive engine unavailable.";
        return NO;
    }
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:destination
        withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        if (message) *message = directoryError.localizedDescription;
        return NO;
    }
    if (!ASDirectoryIsReal(destination)) {
        if (message) *message = @"Destination is not a real directory.";
        return NO;
    }

    ASUnzFile archive = as_unzOpen64(archivePath.fileSystemRepresentation);
    if (!archive) {
        if (message) *message = @"Failed to open zip archive.";
        return NO;
    }

    BOOL success = YES;
    NSUInteger entries = 0;
    unsigned long long totalExpanded = 0;
    int iterator = as_unzGoToFirstFile(archive);
    uint8_t buffer[64 * 1024];

    while (iterator == 0 && success) {
        if (++entries > ASMaxArchiveEntries) {
            if (message) *message = @"Archive contains too many entries.";
            success = NO;
            break;
        }

        char filename[PATH_MAX * 2];
        memset(filename, 0, sizeof(filename));
        int infoResult = as_unzGetCurrentFileInfo64(archive, NULL, filename,
            sizeof(filename) - 1, NULL, 0, NULL, 0);
        if (infoResult != 0) {
            if (message) *message = @"Could not read an archive entry name.";
            success = NO;
            break;
        }
        NSString *rawName = [NSString stringWithUTF8String:filename];
        NSString *relative = ASSafeRelativeArchivePath(rawName);
        if (!relative) {
            if (message) *message = [NSString stringWithFormat:@"Unsafe archive entry rejected: %@",
                rawName ?: @"(invalid UTF-8)"];
            success = NO;
            break;
        }

        BOOL isDirectory = [rawName hasSuffix:@"/"];
        NSString *parentRelative = isDirectory ? relative : relative.stringByDeletingLastPathComponent;
        if (![parentRelative isEqualToString:@"."] && parentRelative.length > 0 &&
            !ASEnsureSafeDirectoryTree(destination, parentRelative, message)) {
            success = NO;
            break;
        }
        NSString *fullPath = [destination stringByAppendingPathComponent:relative];

        if (isDirectory) {
            if (!ASEnsureSafeDirectoryTree(destination, relative, message)) {
                success = NO;
                break;
            }
        } else {
            int openResult = as_unzOpenCurrentFilePassword(archive,
                password.length ? password.UTF8String : NULL);
            if (openResult != 0) {
                if (message) *message = @"Could not open an archive entry. The password may be incorrect.";
                success = NO;
                break;
            }

            int output = open(fullPath.fileSystemRepresentation,
                O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
            if (output < 0) {
                if (message) *message = ASMessageForErrno(@"open output", fullPath, errno);
                as_unzCloseCurrentFile(archive);
                success = NO;
                break;
            }

            unsigned long long fileExpanded = 0;
            for (;;) {
                int count = as_unzReadCurrentFile(archive, buffer, sizeof(buffer));
                if (count == 0) break;
                if (count < 0) {
                    if (message) *message = @"Archive decompression failed.";
                    success = NO;
                    break;
                }
                fileExpanded += (unsigned long long)count;
                totalExpanded += (unsigned long long)count;
                if (fileExpanded > ASMaxExpandedFileBytes || totalExpanded > ASMaxExpandedArchiveBytes) {
                    if (message) *message = @"Archive expansion limit exceeded.";
                    success = NO;
                    break;
                }
                if (!ASWriteAll(output, buffer, (size_t)count, message)) {
                    success = NO;
                    break;
                }
            }
            if (success && fsync(output) != 0) {
                if (message) *message = ASMessageForErrno(@"fsync", fullPath, errno);
                success = NO;
            }
            close(output);
            int closeResult = as_unzCloseCurrentFile(archive);
            if (success && closeResult != 0) {
                if (message) *message = @"Archive entry integrity check failed.";
                success = NO;
            }
            if (!success) unlink(fullPath.fileSystemRepresentation);
        }

        if (success) iterator = as_unzGoToNextFile(archive);
    }

    if (success && iterator != 0 && iterator != -100) {
        // UNZ_END_OF_LIST_OF_FILE is -100 in minizip. Other values indicate failure.
        if (message) *message = @"Archive iteration failed.";
        success = NO;
    }
    as_unzClose(archive);
    return success;
}

static id ASFileItemForPath(NSString *path) {
    Class fileItemClass = NSClassFromString(@"FileItem");
    if (!fileItemClass) return nil;
    id item = [[fileItemClass alloc] init];
    SEL setter = NSSelectorFromString(@"setFilePath:attribute:");
    if ([item respondsToSelector:setter])
        ((void (*)(id, SEL, id, id))objc_msgSend)(item, setter, path, nil);
    return item;
}

static id ASHookUnzip(id self, SEL _cmd, id zipPath, id toPath,
                      id currentDirectory, id *outMessage) {
    NSString *archivePath = [zipPath isKindOfClass:NSString.class] ? zipPath : nil;
    SEL filePathSelector = NSSelectorFromString(@"filePath");
    if (!archivePath && [zipPath respondsToSelector:filePathSelector])
        archivePath = ((id (*)(id, SEL))objc_msgSend)(zipPath, filePathSelector);
    NSString *destination = [toPath isKindOfClass:NSString.class] ? toPath : nil;
    if (!archivePath.length || !destination.length || !ASLoadMinizip()) {
        return as_origUnzip ? ((id (*)(id, SEL, id, id, id, id *))as_origUnzip)(
            self, _cmd, zipPath, toPath, currentDirectory, outMessage) : nil;
    }

    NSString *message = nil;
    BOOL ok = ASExtractArchive(archivePath, destination, nil, &message);
    if (!ok) {
        if (outMessage) *outMessage = message ?: @"Extraction failed.";
        NSLog(@"[ArchiveSafety] unzip failed: %@", message);
        return nil;
    }
    if (outMessage) *outMessage = @"OK";
    id item = ASFileItemForPath(destination);
    return item ? @[item] : nil;
}

static id ASHookUnzipPassword(id self, SEL _cmd, id zipPath, id toPath,
                              id currentDirectory, id password, id *outMessage) {
    NSString *archivePath = [zipPath isKindOfClass:NSString.class] ? zipPath : nil;
    SEL filePathSelector = NSSelectorFromString(@"filePath");
    if (!archivePath && [zipPath respondsToSelector:filePathSelector])
        archivePath = ((id (*)(id, SEL))objc_msgSend)(zipPath, filePathSelector);
    NSString *destination = [toPath isKindOfClass:NSString.class] ? toPath : nil;
    NSString *passwordString = [password isKindOfClass:NSString.class] ? password : nil;
    if (!archivePath.length || !destination.length || !ASLoadMinizip()) {
        return as_origUnzipPassword ? ((id (*)(id, SEL, id, id, id, id, id *))as_origUnzipPassword)(
            self, _cmd, zipPath, toPath, currentDirectory, password, outMessage) : nil;
    }

    NSString *message = nil;
    BOOL ok = ASExtractArchive(archivePath, destination, passwordString, &message);
    if (!ok) {
        if (outMessage) *outMessage = message ?: @"Extraction failed.";
        NSLog(@"[ArchiveSafety] password unzip failed: %@", message);
        return nil;
    }
    if (outMessage) *outMessage = @"OK";
    id item = ASFileItemForPath(destination);
    return item ? @[item] : nil;
}

static void ASInstallArchiveHooks(void) {
    Class zipper = NSClassFromString(@"Zipper");
    if (!zipper) return;

    SEL unzipSelector = NSSelectorFromString(@"unZipFile:toPath:currentDirectory:outMessage:");
    Method unzipMethod = class_getInstanceMethod(zipper, unzipSelector);
    if (unzipMethod) {
        as_origUnzip = method_getImplementation(unzipMethod);
        method_setImplementation(unzipMethod, (IMP)ASHookUnzip);
    }

    SEL passwordSelector = NSSelectorFromString(@"unZipFile:toPath:currentDirectory:withPassword:outMessage:");
    Method passwordMethod = class_getInstanceMethod(zipper, passwordSelector);
    if (passwordMethod) {
        as_origUnzipPassword = method_getImplementation(passwordMethod);
        method_setImplementation(passwordMethod, (IMP)ASHookUnzipPassword);
    }

    NSLog(@"[ArchiveSafety] hardened unzip hooks installed");
}

__attribute__((constructor)) static void ASArchiveSafetyInit(void) {
    // Tweak.m installs its compatibility hooks during image initialization.
    // Queue this replacement so it runs after those constructors complete.
    dispatch_async(dispatch_get_main_queue(), ^{
        ASInstallArchiveHooks();
    });
}
