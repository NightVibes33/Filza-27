/*
 * Filza 27: read-only APFS directory discovery for its ORIGINAL file browser.
 * The fsgetpath/inode-bound approach was researched against kolbicz/WQFiles
 * (GPL-3.0). Independent integration: no WQFiles UI or direct source copied.
 * Enumeration returns candidate paths; a verified OS grant is required before
 * any cross-container file browsing or creation of a live Filza alias.
 */
#import "FZContainerDiscovery.h"
#import "FilzaDiagnostics.h"
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <fcntl.h>
#import <unistd.h>
#import <limits.h>
#import <errno.h>

extern ssize_t fsgetpath(char *buf, size_t buflen, fsid_t *fsid, uint64_t objid);

static NSString *FZCanonical(NSString *path) {
    if (![path isKindOfClass:NSString.class] || ![path hasPrefix:@"/"]) return nil;
    NSString *value = path.stringByStandardizingPath;
    if ([value isEqualToString:@"/var"] || [value hasPrefix:@"/var/"])
        value = [@"/private" stringByAppendingString:value];
    return value;
}
static NSArray<NSString *> *FZRoots(void) {
    return @[
        @"/private/var/mobile/Containers/Data/Application",
        @"/private/var/mobile/Containers/Shared/AppGroup",
        @"/private/var/mobile/Containers/Data/PluginKitPlugin",
        @"/private/var/mobile/Containers/Data/InternalDaemon",
        @"/private/var/containers/Shared/SystemGroup",
        @"/private/var/containers/Data/System"
    ];
}
BOOL FZContainerDiscoveryIsSupportedTarget(NSString *path) {
    NSString *p = FZCanonical(path);
    if (!p) return NO;
    for (NSString *root in FZRoots()) {
        if (![p hasPrefix:[root stringByAppendingString:@"/"]]) continue;
        NSString *leaf = [p substringFromIndex:root.length + 1];
        if (!leaf.length || [leaf containsString:@"/"]) return NO;
        // SystemGroup physical containers also use UUID names. The named
        // systemgroup identifier is read separately from verified metadata.
        if ([root hasSuffix:@"/SystemGroup"] &&
            [leaf isEqualToString:@"systemgroup.com.apple.mobilegestaltcache"])
            return YES;
        return [[NSUUID alloc] initWithUUIDString:leaf] != nil;
    }
    return NO;
}
static NSDictionary<NSString *, NSArray<NSString *> *> *gCached;
static NSObject *FZLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
        gCached = @{};
    });
    return lock;
}
NSArray<NSString *> *FZContainerDiscoveryCachedPaths(NSString *root) {
    NSString *key = FZCanonical(root);
    @synchronized (FZLock()) { return [gCached[key] copy] ?: @[]; }
}
NSString *FZContainerDiscoveryIdentifier(NSString *path) {
    if (!FZContainerDiscoveryIsSupportedTarget(path)) return nil;
    char identifier[512] = {0};
    ssize_t n = getxattr(path.fileSystemRepresentation,
        "com.apple.containermanager.identifier", identifier,
        sizeof(identifier) - 1, 0, 0);
    if (n > 0 && n < (ssize_t)sizeof(identifier)) {
        identifier[n] = 0;
        NSString *label = [NSString stringWithUTF8String:identifier];
        if (label.length && ![label containsString:@"/"] &&
            ![label isEqualToString:@"."] && ![label isEqualToString:@".."])
            return label;
    }
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:
        [path stringByAppendingPathComponent:
            @".com.apple.mobile_container_manager.metadata.plist"]];
    NSString *name = [metadata[@"MCMMetadataIdentifier"]
        isKindOfClass:NSString.class] ? metadata[@"MCMMetadataIdentifier"] : nil;
    return name.length && ![name containsString:@"/"] ? name : nil;
}
// Discover the data volume's live inode upper bound. Persist completed
// scans so the next launch checks *new* IDs rather than rescanning 178M.
static const NSTimeInterval kFZFullScanMaxAge = 7 * 24 * 60 * 60;
static const NSInteger kFZScanCacheVersion = 2;

static NSString *FZScanCachePath(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!support.length) return nil;
    NSString *dir = [support stringByAppendingPathComponent:@"Filza27"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
         withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"WQInodeScanCache.plist"];
}

static int64_t FZCurrentInodeBound(fsid_t *volume, int64_t *probe) {
    NSString *temp = NSTemporaryDirectory();
    NSString *path = [temp stringByAppendingPathComponent:
        [NSString stringWithFormat:@".filza-inode-%@", [NSUUID UUID].UUIDString]];
    int fd = open(path.fileSystemRepresentation,
                  O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
    if (fd < 0) return 0;
    struct stat st = {0};
    struct statfs sfs = {0};
    BOOL ok = fstat(fd, &st) == 0 && fstatfs(fd, &sfs) == 0;
    close(fd);
    unlink(path.fileSystemRepresentation);
    if (!ok || st.st_ino > INT64_MAX - 100000) return 0;
    if (volume) *volume = sfs.f_fsid;
    if (probe) *probe = (int64_t)st.st_ino;
    return (int64_t)st.st_ino + 100000;
}

// Upgrade existing Filza installations without repeating an eight-minute
// inode pass. Build 394 already logged each *verified* discovered candidate.
// These paths are metadata only: all aliases must still pass a fresh WQ grant.
// Refuse partial log sets; a missing/incomplete log falls back to a full scan.
static NSDictionary *FZLegacyLogSeed(fsid_t volume, int64_t currentProbe) {
    NSString *logPath = [FilzaDiagnosticsDirectory()
        stringByAppendingPathComponent:@"Runtime.log"];
    NSDictionary *attrs = [NSFileManager.defaultManager
        attributesOfItemAtPath:logPath error:nil];
    unsigned long long length = [attrs[NSFileSize] unsignedLongLongValue];
    if (length == 0 || length > 8 * 1024 * 1024) return nil;
    NSString *contents = [NSString stringWithContentsOfFile:logPath
                               encoding:NSUTF8StringEncoding error:nil];
    if (!contents.length) return nil;
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *found =
        [NSMutableDictionary dictionary];
    for (NSString *root in FZRoots()) found[root] = [NSMutableSet set];
    long long expected = 0, lastUpper = 0;
    NSString *grantMarker = @" | WorseQuery | Confirmed live directory: ";
    for (NSString *line in [contents componentsSeparatedByString:@"\n"]) {
        NSRange done = [line rangeOfString:@" | WQDiscovery | Inode scan finished: "];
        if (done.location != NSNotFound) {
            NSScanner *count = [NSScanner scannerWithString:
                [line substringFromIndex:NSMaxRange(done)]];
            long long readCount = 0;
            if (![count scanLongLong:&readCount]) continue;
            NSRange upperTag = [line rangeOfString:@"; upper="];
            long long readUpper = 0;
            if (upperTag.location == NSNotFound ||
                ![[NSScanner scannerWithString:
                    [line substringFromIndex:NSMaxRange(upperTag)]]
                    scanLongLong:&readUpper]) continue;
            if (readCount > 0 && readUpper > 100000) {
                expected = readCount;
                lastUpper = readUpper;
            }
        }
        NSRange marker = [line rangeOfString:grantMarker];
        if (marker.location == NSNotFound) continue;
        NSString *candidate = FZCanonical(
            [line substringFromIndex:NSMaxRange(marker)]);
        if (!FZContainerDiscoveryIsSupportedTarget(candidate)) continue;
        for (NSString *root in FZRoots())
            if ([candidate hasPrefix:[root stringByAppendingString:@"/"]]) {
                [found[root] addObject:candidate];
                break;
            }
    }
    NSUInteger total = 0;
    NSMutableDictionary *roots = [NSMutableDictionary dictionary];
    for (NSString *root in FZRoots()) {
        roots[root] = [found[root].allObjects
            sortedArrayUsingSelector:@selector(compare:)];
        total += found[root].count;
    }
    if (expected < 100 || total < (NSUInteger)expected ||
        lastUpper <= 100000 ||
        lastUpper - 100000 > currentProbe) return nil;
    FilzaDiagnosticsAppend(@"WQDiscovery",
        [NSString stringWithFormat:
         @"Restored %lu previously confirmed inode candidates from Runtime.log; grants will be reverified",
         (unsigned long)total]);
    return @{
        @"version": @(kFZScanCacheVersion),
        @"fsid0": @(volume.val[0]), @"fsid1": @(volume.val[1]),
        @"probe": @(lastUpper - 100000),
        @"fullAt": @(NSDate.date.timeIntervalSince1970),
        @"roots": roots
    };
}

static NSDictionary *FZLoadScanCache(fsid_t volume, int64_t currentProbe) {
    NSString *path = FZScanCachePath();
    NSDictionary *saved = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    if (![saved isKindOfClass:NSDictionary.class] ||
        [saved[@"version"] integerValue] != kFZScanCacheVersion ||
        [saved[@"fsid0"] intValue] != volume.val[0] ||
        [saved[@"fsid1"] intValue] != volume.val[1]) return nil;
    int64_t prior = [saved[@"probe"] longLongValue];
    NSTimeInterval age = NSDate.date.timeIntervalSince1970 -
        [saved[@"fullAt"] doubleValue];
    if (age < 0 || age >= kFZFullScanMaxAge ||
        prior < 1 || prior > currentProbe) return nil;
    NSDictionary *roots = saved[@"roots"];
    if (![roots isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *root in FZRoots()) {
        NSArray *items = roots[root];
        if (![items isKindOfClass:NSArray.class]) return nil;
        for (id candidate in items)
            if (![candidate isKindOfClass:NSString.class] ||
                !FZContainerDiscoveryIsSupportedTarget(candidate)) return nil;
    }
    return saved;
}

static void FZStoreScanCache(fsid_t volume, int64_t probe,
                             NSTimeInterval fullAt, NSDictionary *roots) {
    NSString *path = FZScanCachePath();
    if (!path.length) return;
    NSDictionary *saved = @{
        @"version": @(kFZScanCacheVersion),
        @"fsid0": @(volume.val[0]),
        @"fsid1": @(volume.val[1]),
        @"probe": @(probe),
        @"fullAt": @(fullAt),
        @"roots": roots ?: @{}
    };
    if (![saved writeToFile:path atomically:YES])
        FilzaDiagnosticsAppend(@"WQDiscovery",
            @"Cannot persist inode scan cache. Next launch may rescan all IDs.");
}

void FZContainerDiscoveryStart(void (^completion)(NSDictionary<NSString *, NSArray<NSString *> *> *roots)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            fsid_t volume = {{0}};
            int64_t probe = 0;
            int64_t upper = FZCurrentInodeBound(&volume, &probe);
            if (upper < 1 || upper > INT64_MAX - 32768) {
                FilzaDiagnosticsAppend(@"WQDiscovery",
                    @"No same-volume inode bound; discovery unavailable");
                if (completion) completion(@{});
                return;
            }

            NSDictionary *saved = FZLoadScanCache(volume, probe);
            if (!saved) saved = FZLegacyLogSeed(volume, probe);
            int64_t begin = saved ? [saved[@"probe"] longLongValue] + 1 : 1;
            NSTimeInterval fullAt = saved ? [saved[@"fullAt"] doubleValue]
                : NSDate.date.timeIntervalSince1970;
            NSArray<NSString *> *roots = FZRoots();
            NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *found =
                [NSMutableDictionary dictionary];
            for (NSString *root in roots)
                found[root] = [NSMutableSet setWithArray:saved[@"roots"][root] ?: @[]];

            FilzaDiagnosticsAppend(@"WQDiscovery",
                [NSString stringWithFormat:
                    @"%@ inode scan: range %lld-%lld (%lld IDs), max four utility workers",
                    saved ? @"Incremental cached" : @"First full",
                    (long long)begin, (long long)upper,
                    (long long)MAX((int64_t)0, upper - begin + 1)]);

            NSObject *guard = [NSObject new];
            NSLock *counterLock = [NSLock new];
            __block int64_t nextChunk = 0;
            const int64_t chunk = 32768;
            int64_t total = MAX((int64_t)0, upper - begin + 1);
            int64_t chunkCount = (total + chunk - 1) / chunk;
            NSUInteger cores = NSProcessInfo.processInfo.activeProcessorCount;
            size_t workers = (size_t)MAX((NSUInteger)1,
                MIN((NSUInteger)4, cores / 2));

            dispatch_apply(workers, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
              ^(size_t __unused worker) {
                fsid_t vol = volume;
                char buffer[1200];
                for (;;) {
                    [counterLock lock];
                    int64_t selected = nextChunk++;
                    [counterLock unlock];
                    if (selected >= chunkCount) break;
                    @autoreleasepool {
                        int64_t first = begin + selected * chunk;
                        int64_t last = MIN(first + chunk - 1, upper);
                        NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *local =
                            [NSMutableDictionary dictionary];
                        for (int64_t ino = first; ino <= last; ino++) {
                            ssize_t length = fsgetpath(buffer, sizeof(buffer),
                                                       &vol, (uint64_t)ino);
                            if (length <= 0 || length >= (ssize_t)sizeof(buffer)) continue;
                            NSString *candidate = [NSString stringWithUTF8String:buffer];
                            if (!FZContainerDiscoveryIsSupportedTarget(candidate)) continue;
                            NSString *canonical = FZCanonical(candidate);
                            for (NSString *root in roots) {
                                if (![canonical hasPrefix:[root stringByAppendingString:@"/"]])
                                    continue;
                                if (!local[root]) local[root] = [NSMutableArray array];
                                [local[root] addObject:canonical];
                                break;
                            }
                        }
                        @synchronized (guard) {
                            for (NSString *root in local)
                                for (NSString *candidate in local[root])
                                    [found[root] addObject:candidate];
                        }
                    }
                }
            });

            NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
            NSUInteger count = 0;
            for (NSString *root in roots) {
                NSArray *list = [found[root].allObjects
                    sortedArrayUsingSelector:@selector(compare:)];
                snapshot[root] = list;
                count += list.count;
            }
            @synchronized (FZLock()) { gCached = [snapshot copy]; }
            FZStoreScanCache(volume, probe, fullAt, snapshot);
            FilzaDiagnosticsAppend(@"WQDiscovery",
                [NSString stringWithFormat:
                    @"%@ scan complete: %lu candidate paths; %lld new inode IDs inspected",
                    saved ? @"Incremental" : @"Full", (unsigned long)count,
                    (long long)total]);
            if (completion) completion([snapshot copy]);
        });
    });
}
