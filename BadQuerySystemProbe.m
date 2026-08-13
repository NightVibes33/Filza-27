@import Foundation;

#import <dirent.h>
#import <errno.h>
#import <limits.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MCMFilzaIntegration.h"
#include "bad_query.h"

static NSMutableDictionary<NSString *, NSNumber *> *gBQSystemHandles;

static BOOL BQCanEnumerate(NSString *path, int *savedErrno)
{
    if (savedErrno) *savedErrno = 0;
    if (!path.length || !path.isAbsolutePath) {
        if (savedErrno) *savedErrno = EINVAL;
        return NO;
    }

    errno = 0;
    DIR *directory = opendir(path.fileSystemRepresentation);
    if (!directory) {
        if (savedErrno) *savedErrno = errno;
        return NO;
    }

    errno = 0;
    (void)readdir(directory);
    int readErrno = errno;
    closedir(directory);
    if (savedErrno) *savedErrno = readErrno;
    return readErrno == 0;
}

static NSString *BQErrorString(int error)
{
    if (error == 0) return @"none";
    const char *text = strerror(error);
    return text ? [NSString stringWithUTF8String:text] : @"unknown";
}

static BOOL BQInstallLink(NSString *directory, NSString *name, NSString *target,
                          NSString **error)
{
    NSString *link = [directory stringByAppendingPathComponent:name];
    struct stat status = {0};
    if (lstat(link.fileSystemRepresentation, &status) == 0) {
        if (!S_ISLNK(status.st_mode)) {
            if (error) *error = @"existing entry is not a symlink";
            return NO;
        }
        char current[PATH_MAX] = {0};
        ssize_t count = readlink(link.fileSystemRepresentation, current,
                                 sizeof(current) - 1);
        NSString *currentTarget = count > 0
            ? [NSString stringWithUTF8String:current] : nil;
        if ([currentTarget isEqualToString:target]) return YES;
        if (unlink(link.fileSystemRepresentation) != 0) {
            if (error) *error = [NSString stringWithFormat:
                @"stale link removal failed errno=%d", errno];
            return NO;
        }
    }

    if (symlink(target.fileSystemRepresentation, link.fileSystemRepresentation) != 0) {
        if (error) *error = [NSString stringWithFormat:@"symlink failed errno=%d", errno];
        return NO;
    }
    return YES;
}

static NSDictionary *BQProbe(NSString *directory, NSDictionary *candidate)
{
    NSString *name = candidate[@"Name"];
    NSString *path = candidate[@"Path"];
    NSString *scope = candidate[@"Scope"] ?: @"experimental";
    NSMutableDictionary *result = [candidate mutableCopy];

    int beforeErrno = 0;
    BOOL before = BQCanEnumerate(path, &beforeErrno);
    result[@"PreexistingEnumerate"] = @(before);
    result[@"PreexistingErrno"] = @(beforeErrno);
    result[@"PreexistingError"] = BQErrorString(beforeErrno);

    int64_t handle = -1;
    if (!before) {
        // create=true skips the pre-extension lstat. Verification below is the
        // authority: a returned handle is not considered useful unless the
        // requested directory can actually be enumerated afterwards.
        handle = bad_query((char *)path.fileSystemRepresentation,
                           true, NULL, false);
        result[@"bad_query_result"] = @(handle);
    } else {
        result[@"bad_query_result"] = @"not needed";
    }

    int afterErrno = 0;
    BOOL after = BQCanEnumerate(path, &afterErrno);
    result[@"EnumerateAfter"] = @(after);
    result[@"AfterErrno"] = @(afterErrno);
    result[@"AfterError"] = BQErrorString(afterErrno);

    if (!after) {
        if (handle >= 0) bad_query_release(handle);
        result[@"Status"] = @"denied";
        NSLog(@"[BadQuerySystemProbe] denied scope=%@ path=%@ result=%lld errno=%d",
              scope, path, handle, afterErrno);
        return result;
    }

    if (handle >= 0) {
        if (!gBQSystemHandles) gBQSystemHandles = [NSMutableDictionary dictionary];
        gBQSystemHandles[path] = @(handle);
        result[@"HandleRetained"] = @YES;
    } else {
        result[@"HandleRetained"] = @NO;
    }

    NSString *linkError = nil;
    BOOL linked = BQInstallLink(directory, name, path, &linkError);
    result[@"Status"] = linked ? @"verified" : @"verified-link-failed";
    result[@"LinkCreated"] = @(linked);
    if (linkError.length) result[@"LinkError"] = linkError;

    NSLog(@"[BadQuerySystemProbe] VERIFIED scope=%@ path=%@ handle=%lld link=%d",
          scope, path, handle, linked);
    return result;
}

static void BQWriteReadme(NSString *directory)
{
    NSString *text =
        @"bad_query verified system-root probe\n\n"
         "This folder contains only roots that this exact running process could enumerate after the probe.\n"
         "A bad_query return value alone is not treated as access. Every link requires a successful opendir/readdir check.\n\n"
         "Upstream-documented iOS 27 roots are tested first. Broader roots requested for full filesystem research are experimental and may remain denied.\n"
         "Denied candidates are recorded in Probe Results.plist and are intentionally not linked.\n"
         "Read-only system-volume policy, Data Protection, POSIX permissions, and sandbox policy can still restrict descendants even when a parent root is visible.\n";
    [text writeToFile:[directory stringByAppendingPathComponent:@"README.txt"]
              atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void BQRunSystemProbe(void)
{
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion != 27) return;

    NSString *directory = [MCMFilzaVirtualRoot()
        stringByAppendingPathComponent:@"[bad_query] Verified System Roots"];
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&directoryError]) {
        NSLog(@"[BadQuerySystemProbe] directory creation failed: %@", directoryError);
        return;
    }

    NSArray<NSDictionary *> *candidates = @[
        // Roots explicitly documented by forcequitOS/bad_query for iOS 27.
        @{ @"Name": @"01 System Data", @"Path": @"/private/var/containers/Data/System",
           @"Scope": @"upstream-documented" },
        @{ @"Name": @"02 Shared SystemGroup", @"Path": @"/private/var/containers/Shared/SystemGroup",
           @"Scope": @"upstream-documented" },
        @{ @"Name": @"03 App Data", @"Path": @"/private/var/mobile/Containers/Data/Application",
           @"Scope": @"upstream-documented" },
        @{ @"Name": @"04 Internal Daemon Data", @"Path": @"/private/var/mobile/Containers/Data/InternalDaemon",
           @"Scope": @"upstream-documented" },
        @{ @"Name": @"05 PluginKit Data", @"Path": @"/private/var/mobile/Containers/Data/PluginKitPlugin",
           @"Scope": @"upstream-documented" },
        @{ @"Name": @"06 App Groups", @"Path": @"/private/var/mobile/Containers/Shared/AppGroup",
           @"Scope": @"upstream-documented" },

        // Broader filesystem boundaries. These are hypotheses only; they are
        // exposed to Filza only if the post-extension enumeration proves them.
        @{ @"Name": @"20 private var", @"Path": @"/private/var", @"Scope": @"experimental-broader-root" },
        @{ @"Name": @"21 private", @"Path": @"/private", @"Scope": @"experimental-broader-root" },
        @{ @"Name": @"22 Library", @"Path": @"/Library", @"Scope": @"experimental-broader-root" },
        @{ @"Name": @"23 private etc", @"Path": @"/private/etc", @"Scope": @"experimental-broader-root" },
        @{ @"Name": @"24 Applications", @"Path": @"/Applications", @"Scope": @"experimental-broader-root" },
        @{ @"Name": @"25 System Library", @"Path": @"/System/Library", @"Scope": @"experimental-broader-root" },
        @{ @"Name": @"26 User App Bundles", @"Path": @"/private/var/containers/Bundle/Application",
           @"Scope": @"experimental-broader-root" },
        @{ @"Name": @"27 Mobile Library", @"Path": @"/private/var/mobile/Library",
           @"Scope": @"experimental-broader-root" },
    ];

    NSMutableArray *results = [NSMutableArray arrayWithCapacity:candidates.count];
    for (NSDictionary *candidate in candidates)
        [results addObject:BQProbe(directory, candidate)];

    [results writeToFile:[directory stringByAppendingPathComponent:@"Probe Results.plist"]
              atomically:YES];
    BQWriteReadme(directory);
}

__attribute__((constructor)) static void BQSystemProbeInit(void)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BQRunSystemProbe();
    });
}
