@import Foundation;

#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MCMFilzaIntegration.h"

static NSString *const kFZSystemPathDirectoryName = @"System Paths - Measured";

static NSString *FZSystemErrnoString(int value)
{
    if (value == 0) return @"none";
    const char *text = strerror(value);
    return text ? [NSString stringWithUTF8String:text] : @"unknown";
}

static NSString *FZSystemKind(mode_t mode)
{
    if (S_ISDIR(mode)) return @"directory";
    if (S_ISREG(mode)) return @"file";
    if (S_ISLNK(mode)) return @"symlink";
    if (S_ISCHR(mode)) return @"character-device";
    if (S_ISBLK(mode)) return @"block-device";
    if (S_ISSOCK(mode)) return @"socket";
    if (S_ISFIFO(mode)) return @"fifo";
    return @"other";
}

static NSDictionary *FZMeasureSystemPath(NSString *path)
{
    NSMutableDictionary *result = [@{ @"Path": path ?: @"" } mutableCopy];
    if (!path.length || !path.isAbsolutePath) {
        result[@"Backend"] = @"invalid";
        return result;
    }

    struct stat lexical = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &lexical) != 0) {
        int saved = errno;
        result[@"Exists"] = @NO;
        result[@"Backend"] = saved == EACCES || saved == EPERM
            ? @"posix-denied" : @"posix-missing";
        result[@"LstatErrno"] = @(saved);
        result[@"LstatError"] = FZSystemErrnoString(saved);
        return result;
    }

    result[@"Exists"] = @YES;
    result[@"LexicalKind"] = FZSystemKind(lexical.st_mode);
    result[@"ReadAccess"] = @(access(path.fileSystemRepresentation, R_OK) == 0);
    result[@"WriteAccess"] = @(access(path.fileSystemRepresentation, W_OK) == 0);
    result[@"ExecuteAccess"] = @(access(path.fileSystemRepresentation, X_OK) == 0);

    struct stat resolved = {0};
    errno = 0;
    if (stat(path.fileSystemRepresentation, &resolved) != 0) {
        int saved = errno;
        result[@"Backend"] = @"posix-denied";
        result[@"StatErrno"] = @(saved);
        result[@"StatError"] = FZSystemErrnoString(saved);
        return result;
    }
    result[@"ResolvedKind"] = FZSystemKind(resolved.st_mode);

    if (S_ISDIR(resolved.st_mode)) {
        errno = 0;
        DIR *directory = opendir(path.fileSystemRepresentation);
        if (!directory) {
            int saved = errno;
            result[@"Enumerable"] = @NO;
            result[@"Backend"] = @"posix-directory-denied";
            result[@"OpenDirErrno"] = @(saved);
            result[@"OpenDirError"] = FZSystemErrnoString(saved);
            return result;
        }

        NSUInteger visibleEntries = 0;
        BOOL readSucceeded = YES;
        errno = 0;
        struct dirent *entry = NULL;
        while (visibleEntries < 16 && (entry = readdir(directory)) != NULL) {
            if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
            visibleEntries++;
        }
        if (errno != 0) readSucceeded = NO;
        int saved = errno;
        closedir(directory);

        result[@"Enumerable"] = @(readSucceeded);
        result[@"SampleEntryCount"] = @(visibleEntries);
        if (readSucceeded) {
            result[@"Backend"] = @"posix-local-directory";
        } else {
            result[@"Backend"] = @"posix-directory-partial";
            result[@"ReadDirErrno"] = @(saved);
            result[@"ReadDirError"] = FZSystemErrnoString(saved);
        }
        return result;
    }

    if (S_ISREG(resolved.st_mode)) {
        errno = 0;
        int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
        if (fd < 0) {
            int saved = errno;
            result[@"Readable"] = @NO;
            result[@"Backend"] = @"posix-file-denied";
            result[@"OpenErrno"] = @(saved);
            result[@"OpenError"] = FZSystemErrnoString(saved);
            return result;
        }
        unsigned char byte = 0;
        ssize_t count = read(fd, &byte, sizeof(byte));
        int saved = count < 0 ? errno : 0;
        close(fd);
        BOOL readable = count >= 0;
        result[@"Readable"] = @(readable);
        result[@"Backend"] = readable ? @"posix-local-file" : @"posix-file-partial";
        if (!readable) {
            result[@"ReadErrno"] = @(saved);
            result[@"ReadError"] = FZSystemErrnoString(saved);
        }
        return result;
    }

    result[@"Backend"] = @"posix-special";
    return result;
}

static BOOL FZSystemPathCanLink(NSDictionary *status)
{
    NSString *backend = status[@"Backend"];
    return [backend isEqualToString:@"posix-local-directory"] ||
           [backend isEqualToString:@"posix-local-file"];
}

static void FZInstallMeasuredSystemPaths(void)
{
    NSString *virtualRoot = MCMFilzaVirtualRoot();
    if (!virtualRoot.length) return;

    NSFileManager *manager = NSFileManager.defaultManager;
    NSError *rootError = nil;
    if (![manager createDirectoryAtPath:virtualRoot
             withIntermediateDirectories:YES attributes:nil error:&rootError]) {
        NSLog(@"[SystemPathDiagnostics] Device Storage unavailable error=%@", rootError);
        return;
    }

    NSString *directory = [virtualRoot stringByAppendingPathComponent:kFZSystemPathDirectoryName];
    NSError *directoryError = nil;
    if (![manager createDirectoryAtPath:directory
             withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        NSLog(@"[SystemPathDiagnostics] diagnostics directory unavailable error=%@", directoryError);
        return;
    }

    NSArray<NSDictionary *> *targets = @[
        @{ @"Name": @"01 Root", @"Path": @"/" },
        @{ @"Name": @"02 private", @"Path": @"/private" },
        @{ @"Name": @"03 var", @"Path": @"/var" },
        @{ @"Name": @"04 private-var", @"Path": @"/private/var" },
        @{ @"Name": @"05 Library", @"Path": @"/Library" },
        @{ @"Name": @"06 Applications", @"Path": @"/Applications" },
        @{ @"Name": @"07 etc", @"Path": @"/etc" },
        @{ @"Name": @"08 System-Library", @"Path": @"/System/Library" },
        @{ @"Name": @"09 usr", @"Path": @"/usr" },
        @{ @"Name": @"10 mobile", @"Path": @"/private/var/mobile" },
        @{ @"Name": @"11 mobile-Library", @"Path": @"/private/var/mobile/Library" },
        @{ @"Name": @"12 app-bundles", @"Path": @"/private/var/containers/Bundle/Application" },
    ];

    NSMutableArray<NSDictionary *> *results = [NSMutableArray arrayWithCapacity:targets.count];
    for (NSDictionary *target in targets) {
        NSString *name = target[@"Name"];
        NSString *path = target[@"Path"];
        NSMutableDictionary *status = [FZMeasureSystemPath(path) mutableCopy];
        status[@"Name"] = name;

        NSString *link = [directory stringByAppendingPathComponent:name];
        struct stat linkStatus = {0};
        if (lstat(link.fileSystemRepresentation, &linkStatus) == 0 && S_ISLNK(linkStatus.st_mode))
            unlink(link.fileSystemRepresentation);

        BOOL linked = NO;
        int linkErrno = 0;
        if (FZSystemPathCanLink(status)) {
            if (symlink(path.fileSystemRepresentation, link.fileSystemRepresentation) == 0) {
                linked = YES;
            } else {
                linkErrno = errno;
            }
        }
        status[@"Linked"] = @(linked);
        if (linkErrno) {
            status[@"LinkErrno"] = @(linkErrno);
            status[@"LinkError"] = FZSystemErrnoString(linkErrno);
        }
        [results addObject:status];
        NSLog(@"[SystemPathDiagnostics] path=%@ backend=%@ linked=%d",
              path, status[@"Backend"], linked);
    }

    NSString *statusPath = [directory stringByAppendingPathComponent:@"System Access Status.plist"];
    [results writeToFile:statusPath atomically:YES];

    NSString *readme =
        @"Measured system paths\n\n"
         "Each entry is tested by the Filza process at runtime. A link is created only when the target can actually be opened and enumerated/read by the current process. Missing links are not hidden successes: inspect System Access Status.plist for the exact errno and backend classification.\n\n"
         "Backend values describe observed access only. They do not grant privileges or imply write access. WriteAccess is reported separately.\n";
    [readme writeToFile:[directory stringByAppendingPathComponent:@"README.txt"]
              atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

__attribute__((constructor)) static void FZSystemPathDiagnosticsInit(void)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        FZInstallMeasuredSystemPaths();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ FZInstallMeasuredSystemPaths(); });
    });
}
