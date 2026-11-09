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
// Discover the data volume's live inode upper bound without assuming that a
// fixed two-million-inode range includes recently installed apps.
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

void FZContainerDiscoveryStart(void (^completion)(NSDictionary<NSString *, NSArray<NSString *> *> *roots)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            fsid_t volume = {{0}};
            int64_t probe = 0;
            int64_t upper = FZCurrentInodeBound(&volume, &probe);
            if (upper < 1 || upper > INT64_MAX - 32768) {
                FilzaDiagnosticsAppend(@"WQDiscovery", @"No same-volume inode bound; candidate scan unavailable");
                if (completion) completion(@{});
                return;
            }
            FilzaDiagnosticsAppend(@"WQDiscovery",
                [NSString stringWithFormat:@"Scanning inode candidates through %lld (background)",
                    (long long)upper]);
            NSArray<NSString *> *roots = FZRoots();
            NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *found = [NSMutableDictionary dictionary];
            for (NSString *root in roots) found[root] = [NSMutableSet set];
            NSObject *guard = [NSObject new];
            const int64_t chunk = 32768;
            size_t chunks = (size_t)((upper + chunk - 1) / chunk);
            dispatch_apply(chunks, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t batch) {
                @autoreleasepool {
                    int64_t begin = (int64_t)batch * chunk + 1;
                    int64_t end = MIN(begin + chunk - 1, upper);
                    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *local =
                        [NSMutableDictionary dictionary];
                    fsid_t vol = volume;
                    char buffer[1200];
                    for (int64_t ino = begin; ino <= end; ino++) {
                        ssize_t length = fsgetpath(buffer, sizeof(buffer), &vol, (uint64_t)ino);
                        if (length <= 0 || length >= (ssize_t)sizeof(buffer)) continue;
                        NSString *candidate = [NSString stringWithUTF8String:buffer];
                        if (!FZContainerDiscoveryIsSupportedTarget(candidate)) continue;
                        NSString *canonical = FZCanonical(candidate);
                        for (NSString *root in roots) {
                            if (![canonical hasPrefix:[root stringByAppendingString:@"/"]]) continue;
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
            });
            NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
            NSUInteger count = 0;
            for (NSString *root in roots) {
                NSArray *list = [found[root].allObjects sortedArrayUsingSelector:@selector(compare:)];
                snapshot[root] = list;
                count += list.count;
            }
            @synchronized (FZLock()) { gCached = [snapshot copy]; }
            int64_t check = 0;
            fsid_t checkVolume = {{0}};
            FZCurrentInodeBound(&checkVolume, &check);
            FilzaDiagnosticsAppend(@"WQDiscovery",
                [NSString stringWithFormat:@"Inode scan finished: %lu candidate paths; upper=%lld, followup=%lld. Paths are not permissions.",
                   (unsigned long)count, (long long)upper, (long long)check]);
            if (completion) completion([snapshot copy]);
        });
    });
}
