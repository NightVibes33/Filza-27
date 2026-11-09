/*
 * Filza 27 adapter for UNMODIFIED GPLv3 forcequitOS/worse_query PoC.
 * Source commit: bd41f874b3f4d28c4d61b51c7dfb98f0e8a5e9ec
 * The host must be provisioned for its own dedicated disposable App Group.
 */
#import "FilzaWorseQueryBridge.h"
#import "ThirdParty/worse_query/worse_query.h"
#import "FilzaDiagnostics.h"
#import <objc/message.h>
#import <fcntl.h>
#import <errno.h>
#import <sys/stat.h>
#import <limits.h>
#import <stdlib.h>
#import <unistd.h>

typedef CFTypeRef FZWQSecTaskRef;
extern FZWQSecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(FZWQSecTaskRef task, CFStringRef name, CFErrorRef *error);

static NSString *const kFZWQGroupBase = @"group.com.filza27.nigtvibes33.worsequery";
static NSString *const kFZWQCacheRestoreStop = @"filza.worseQueryCacheRestoreStop.v1";
static NSMutableDictionary<NSString *, NSNumber *> *gHandles;
static NSString *gStatus;

static NSObject *FZWQLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
        gHandles = [NSMutableDictionary dictionary];
        gStatus = @"Not attempted";
    });
    return lock;
}

static void FZWQReport(NSString *message) {
    gStatus = [message copy];
    FilzaDiagnosticsAppend(@"WorseQuery", message);
}

NSString *FZWorseQueryLastStatus(void) {
    @synchronized (FZWQLock()) { return [gStatus copy]; }
}

// SideStore requests the base group from the IPA's ad-hoc entitlement
// signature, then registers a per-team group (typically BASE.TEAMID).
// Resolve what iOS actually granted. Do not assume a loose plist is authority.
static NSString *FZWQInstalledGroup(void) {
    FZWQSecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return nil;
    CFErrorRef error = NULL;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task,
        CFSTR("com.apple.security.application-groups"), &error);
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    if (value && CFGetTypeID(value) == CFArrayGetTypeID()) {
        NSCharacterSet *validTeamChars = [NSCharacterSet
            characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"];
        NSString *prefix = [kFZWQGroupBase stringByAppendingString:@"."];
        for (id raw in (__bridge NSArray *)value) {
            if (![raw isKindOfClass:NSString.class]) continue;
            NSString *group = (NSString *)raw;
            BOOL eligible = [group isEqualToString:kFZWQGroupBase];
            if (!eligible && [group hasPrefix:prefix]) {
                NSString *team = [group substringFromIndex:prefix.length];
                eligible = team.length == 10 &&
                    [team rangeOfCharacterFromSet:validTeamChars.invertedSet].location == NSNotFound;
            }
            if (eligible && [NSFileManager.defaultManager
                containerURLForSecurityApplicationGroupIdentifier:group] != nil)
                [matches addObject:group];
        }
    }
    if (value) CFRelease(value);
    if (error) CFRelease(error);
    CFRelease(task);
    // An ambiguous entitlement set must not select an arbitrary cache path.
    return matches.count == 1 ? matches.firstObject : nil;
}

// Inspect the live signature after SideStore installation, without running
// the cache/symlink exploit or implying a grant for another app's directory.
NSString *FZWorseQueryInstalledGroupIdentifier(void) {
    return FZWQInstalledGroup();
}

BOOL FZWorseQueryEntitlementPresent(void) {
    return FZWQInstalledGroup() != nil;
}

static BOOL FZWQAllowed(NSString *path, NSInteger major) {
    for (NSString *root in @[
        @"/private/var/mobile/Containers/Data/Application/",
        @"/private/var/mobile/Containers/Data/InternalDaemon/",
        @"/private/var/mobile/Containers/Data/PluginKitPlugin/",
        @"/private/var/mobile/Containers/Shared/AppGroup/",
        @"/private/var/containers/Data/System/",
        @"/private/var/containers/Shared/SystemGroup/"
    ]) if ([path hasPrefix:root] && path.length > root.length) return YES;
    return major == 27 &&
        [path isEqualToString:@"/private/var/mobile/Containers/Shared/AppGroup"];
}

static NSString *FZWQNormalized(NSString *path, NSInteger major) {
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath)
        return nil;
    for (NSString *component in path.pathComponents)
        if ([component isEqualToString:@"."] || [component isEqualToString:@".."])
            return nil;
    NSString *p = path.stringByStandardizingPath;
    if ([p isEqualToString:@"/var"] || [p hasPrefix:@"/var/"])
        p = [@"/private" stringByAppendingString:p];
    return FZWQAllowed(p, major) ? p : nil;
}

// Upstream temporarily REPLACES App Group Library/Caches with a symlink.
// Never allow that against an App Group containing any existing data.
static BOOL FZWQDedicatedEmptyCaches(NSString *groupID, NSString **reason) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *group = [fm containerURLForSecurityApplicationGroupIdentifier:groupID];
    if (!group) {
        if (reason) *reason = @"App Group not available in the signed host app";
        return NO;
    }
    NSURL *caches = [group URLByAppendingPathComponent:@"Library/Caches" isDirectory:YES];
    NSError *error = nil;
    NSURL *library = [group URLByAppendingPathComponent:@"Library" isDirectory:YES];
    if (![fm createDirectoryAtURL:library withIntermediateDirectories:YES
                      attributes:nil error:&error]) {
        if (reason) *reason = error.localizedDescription;
        return NO;
    }
    struct stat st = {0};
    if (lstat(caches.fileSystemRepresentation, &st) == 0) {
        if (!S_ISDIR(st.st_mode)) {
            if (reason) *reason = @"Dedicated cache path is a symlink or non-directory";
            return NO;
        }
    } else if (errno == ENOENT) {
        if (![fm createDirectoryAtURL:caches withIntermediateDirectories:NO
                          attributes:nil error:&error]) {
            if (reason) *reason = error.localizedDescription;
            return NO;
        }
    } else {
        if (reason) *reason = @"Dedicated cache directory could not be inspected";
        return NO;
    }
    NSArray *contents = [fm contentsOfDirectoryAtPath:caches.path error:&error];
    if (!contents || contents.count) {
        if (reason) *reason = @"Dedicated cache is not empty; refusing destructive symlink setup";
        return NO;
    }
    return YES;
}

// Upstream changes the dedicated App Group Caches directory into a symlink,
// then tries to restore it. Never infer a safe restoration from the returned
// sandbox-extension handle: verify lstat, non-symlink directory type and
// empty contents after EVERY query, including unsuccessful ones.
static BOOL FZWQCacheRestored(NSString *groupID, NSString **reason) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *group = [fm containerURLForSecurityApplicationGroupIdentifier:groupID];
    if (!group) {
        if (reason) *reason = @"Dedicated App Group unavailable after query";
        return NO;
    }
    NSURL *caches = [group URLByAppendingPathComponent:@"Library/Caches" isDirectory:YES];
    struct stat st = {0};
    if (lstat(caches.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) {
        if (reason) *reason = @"Dedicated App Group Caches was not restored to a real directory";
        return NO;
    }
    NSError *error = nil;
    NSArray *entries = [fm contentsOfDirectoryAtPath:caches.path error:&error];
    if (!entries || entries.count != 0) {
        if (reason) *reason = error.localizedDescription ?:
            @"Dedicated App Group Caches was unexpectedly populated after query";
        return NO;
    }
    return YES;
}

static NSString *FZWQErrorForCode(int64_t code) {
    switch (code) {
        case -1: return @"Signed App Group unavailable";
        case -2: return @"ContainerManager / sandbox symbols unavailable";
        case -3: return @"Container query creation failed";
        case -4: return @"App Group symlink preparation failed";
        case -5: return @"ContainerManager rejected the extension query";
        case -6: return @"Sandbox refused to issue an extension";
        case -255: return @"Target absent or lstat denied";
        default: return [NSString stringWithFormat:@"worse_query error=%lld", code];
    }
}

NSString *FZWorseQueryGrantDirectory(NSString *path) {
    @synchronized (FZWQLock()) {
        NSInteger major = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
        if (major != 26 && major != 27) {
            FZWQReport(@"Upstream worse_query is not claimed for this iOS version");
            return nil;
        }
        if ([NSUserDefaults.standardUserDefaults boolForKey:kFZWQCacheRestoreStop]) {
            FZWQReport(@"worse_query SAFETY STOP: dedicated App Group Caches restoration was not verified; recover the App Group before another request");
            return nil;
        }
        // Airlift remote-folder recovery is independent of this local
        // App Group sandbox-extension path. Never let a pending remote
        // restoration incident disable otherwise valid worse_query grants.
        // Airlift itself must still refuse all remote reads/writes until
        // its original object is independently confirmed restored.
        NSString *target = FZWQNormalized(path, major);
        if (!target) {
            FZWQReport(@"Path outside upstream supported container scopes");
            return nil;
        }
        NSString *groupID = FZWQInstalledGroup();
        if (!groupID) {
            FZWQReport([NSString stringWithFormat:
                @"Missing or ambiguous SideStore-provisioned App Group based on %@", kFZWQGroupBase]);
            return nil;
        }
        if (gHandles[target]) return target;

        NSString *reason = nil;
        if (!FZWQDedicatedEmptyCaches(groupID, &reason)) {
            FZWQReport(reason ?: @"Dedicated App Group preflight failed");
            return nil;
        }
        BOOL alternateFlags = major == 26 &&
            [target hasPrefix:@"/private/var/mobile/Containers/Shared/AppGroup/"];
        // The unchanged upstream implementation performs the real container
        // class-7 query and consumes its returned sandbox extension.
        int64_t handle = worse_query(target, groupID, alternateFlags, false);
        NSString *restoreReason = nil;
        if (!FZWQCacheRestored(groupID, &restoreReason)) {
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:kFZWQCacheRestoreStop];
            if (handle >= 0) worse_query_release(handle);
            FZWQReport([NSString stringWithFormat:
                @"SAFETY STOP: %@. No further worse_query requests will be made in this installation until inspected and recovered.",
                restoreReason ?: @"Dedicated App Group cache restoration failed"]);
            return nil;
        }
        // sandbox_extension_consume returns a NONNEGATIVE handle on success.
        // Handle zero is legitimate and must not be mistaken for denial.
        if (handle < 0) {
            FZWQReport(FZWQErrorForCode(handle));
            return nil;
        }

        // Issued token != proven access. Read only after realpath and open.
        char resolved[PATH_MAX] = {0};
        if (!realpath(target.fileSystemRepresentation, resolved)) {
            worse_query_release(handle);
            FZWQReport(@"Extension issued but target realpath failed");
            return nil;
        }
        NSString *canonical = [NSString stringWithUTF8String:resolved];
        if (!FZWQAllowed(canonical, major)) {
            worse_query_release(handle);
            FZWQReport(@"Resolved path escaped supported container scope");
            return nil;
        }
        int fd = open(canonical.fileSystemRepresentation,
                      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (fd < 0) {
            int saved = errno;
            worse_query_release(handle);
            FZWQReport([NSString stringWithFormat:
                @"Extension issued but directory open failed errno=%d", saved]);
            return nil;
        }
        close(fd);
        gHandles[target] = @(handle);
        gHandles[canonical] = @(handle);
        FZWQReport([NSString stringWithFormat:@"Confirmed live directory: %@", canonical]);
        return canonical;
    }
}


// Filza's original file-operation guards previously only recognized MCM
// leases. A sandbox extension successfully consumed by worse_query is a
// separate grant and must be recognized for the *verified* live directory.
// Resolve symlinks before testing containment: aliases must never extend a
// sandbox extension outside its actual granted directory.
BOOL FZWorseQueryPathHasActiveGrant(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath) return NO;
    char resolved[PATH_MAX] = {0};
    if (!realpath(path.fileSystemRepresentation, resolved)) return NO;
    NSString *canonical = [NSString stringWithUTF8String:resolved];
    if (!canonical.length) return NO;
    @synchronized (FZWQLock()) {
        for (NSString *grantedRoot in gHandles) {
            if ([canonical isEqualToString:grantedRoot] ||
                [canonical hasPrefix:[grantedRoot stringByAppendingString:@"/"]]) {
                return YES;
            }
        }
    }
    return NO;
}

NSString *FZWorseQueryResolveAppDataContainer(NSString *bundleID) {
    if (![bundleID isKindOfClass:NSString.class] || !bundleID.length ||
        [bundleID containsString:@"/"]) return nil;
    Class cls = NSClassFromString(@"LSApplicationProxy");
    SEL query = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!cls || ![cls respondsToSelector:query]) return nil;
    id proxy = ((id(*)(id,SEL,id))objc_msgSend)(cls, query, bundleID);
    SEL selector = NSSelectorFromString(@"dataContainerURL");
    if (!proxy || ![proxy respondsToSelector:selector]) return nil;
    id url = ((id(*)(id,SEL))objc_msgSend)(proxy, selector);
    if (![url isKindOfClass:NSURL.class] || ![url isFileURL]) return nil;
    return FZWorseQueryGrantDirectory([url path]);
}
