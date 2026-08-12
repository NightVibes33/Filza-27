#import "MCMBridge.h"

#import <dlfcn.h>
#import <fcntl.h>
#import <stdlib.h>
#import <unistd.h>
#import <xpc/xpc.h>

typedef void *(*MCMQueryCreate)(void);
typedef void (*MCMQuerySetU64)(void *, uint64_t);
typedef void (*MCMQuerySetXPC)(void *, xpc_object_t);
typedef void (*MCMQuerySetCString)(void *, const char *);
typedef void *(*MCMQueryGetPointer)(void *);
typedef bool (*MCMQueryIterate)(void *, bool (^)(void *));
typedef void (*MCMQueryFree)(void *);
typedef const char *(*MCMObjectGetPath)(void *);
typedef const char *(*MCMObjectGetIdentifier)(void *);
typedef void *(*MCMObjectCopy)(void *);
typedef char *(*MCMObjectCopyToken)(void *);
typedef bool (*MCMObjectActivate)(void *, bool);
typedef void (*MCMObjectFree)(void *);
typedef int (*MCMErrorGetInt)(void *);
typedef const char *(*MCMErrorGetString)(void *);

typedef struct {
    void *handle;
    MCMQueryCreate queryCreate;
    MCMQuerySetU64 querySetClass;
    MCMQuerySetXPC querySetIdentifiers;
    MCMQuerySetXPC querySetGroupIdentifiers;
    MCMQuerySetU64 querySetFlags;
    MCMQuerySetU64 querySetPart;
    MCMQuerySetCString querySetPartDomain;
    MCMQueryGetPointer queryGetSingle;
    MCMQueryGetPointer queryGetLastError;
    MCMQueryIterate queryIterate;
    MCMQueryFree queryFree;
    MCMObjectGetPath objectGetPath;
    MCMObjectGetIdentifier objectGetIdentifier;
    MCMObjectCopy objectCopy;
    MCMObjectCopyToken objectCopyToken;
    MCMObjectActivate objectActivate;
    MCMObjectFree objectFree;
    MCMErrorGetInt errorGetPOSIX;
    MCMErrorGetString errorGetMessage;
} MCMAPI;

static const uint64_t kMCMDiscoveryLookupFlags = 0x900000000ULL;

static MCMAPI *MCMSharedAPI(void)
{
    static MCMAPI api;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        api.handle = dlopen("/usr/lib/system/libsystem_containermanager.dylib",
                            RTLD_NOW | RTLD_LOCAL);
        void *handle = api.handle != NULL ? api.handle : RTLD_DEFAULT;
#define LOAD(field, symbol) api.field = (__typeof(api.field))dlsym(handle, symbol)
        LOAD(queryCreate, "container_query_create");
        LOAD(querySetClass, "container_query_set_class");
        LOAD(querySetIdentifiers, "container_query_set_identifiers");
        LOAD(querySetGroupIdentifiers, "container_query_set_group_identifiers");
        LOAD(querySetFlags, "container_query_operation_set_flags");
        LOAD(querySetPart, "container_query_operation_set_part");
        LOAD(querySetPartDomain, "container_query_operation_set_part_domain");
        LOAD(queryGetSingle, "container_query_get_single_result");
        LOAD(queryGetLastError, "container_query_get_last_error");
        LOAD(queryIterate, "container_query_iterate_results_sync");
        LOAD(queryFree, "container_query_free");
        LOAD(objectGetPath, "container_object_get_path");
        LOAD(objectGetIdentifier, "container_object_get_identifier");
        LOAD(objectCopy, "container_object_copy");
        LOAD(objectCopyToken, "container_copy_sandbox_token");
        LOAD(objectActivate, "container_object_sandbox_extension_activate");
        LOAD(objectFree, "container_object_free");
        LOAD(errorGetPOSIX, "container_error_get_posix_errno");
        LOAD(errorGetMessage, "container_error_get_message");
#undef LOAD
    });
    return &api;
}

static NSInteger MCMOperatingSystemMajorVersion(void)
{
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
}

static BOOL MCMSafeDiscoveredIdentifier(NSString *identifier)
{
    if (identifier.length < 3 || identifier.length > 255) return NO;
    if (![identifier containsString:@"."] ||
        [identifier hasPrefix:@"."] || [identifier hasSuffix:@"."] ||
        [identifier containsString:@".."]) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static BOOL MCMLaunchServicesIdentifierByte(uint8_t value)
{
    return (value >= 'a' && value <= 'z') ||
        (value >= 'A' && value <= 'Z') ||
        (value >= '0' && value <= '9') ||
        value == '.' || value == '-' || value == '_';
}

static BOOL MCMRootDirectoryAlreadyAccessible(NSString *path)
{
    if (path.length == 0 || !path.isAbsolutePath) return NO;
    int descriptor = open(path.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) return NO;
    close(descriptor);
    return YES;
}

static void MCMCollectLaunchServicesStorePaths(NSFileManager *manager,
                                                NSString *directory,
                                                NSUInteger depth,
                                                NSMutableArray<NSString *> *paths)
{
    if (depth > 2 || paths.count >= 32) return;
    NSArray<NSString *> *children = [manager contentsOfDirectoryAtPath:directory
                                                                  error:nil];
    for (NSString *name in children ?: @[]) {
        if (paths.count >= 32) break;
        NSString *path = [directory stringByAppendingPathComponent:name];
        BOOL isDirectory = NO;
        if (![manager fileExistsAtPath:path isDirectory:&isDirectory]) continue;
        if (isDirectory) {
            if (depth < 2)
                MCMCollectLaunchServicesStorePaths(manager, path, depth + 1, paths);
            continue;
        }
        NSString *lower = name.lowercaseString;
        if ([lower rangeOfString:@"launchservices"].location == NSNotFound ||
            ![lower hasSuffix:@".csstore"]) continue;
        [paths addObject:path];
    }
}

static NSArray<NSString *> *MCMExtractLaunchServicesCandidates(NSString *libraryRoot,
                                                               NSUInteger requestedLimit,
                                                               NSString **error)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *stores = [NSMutableArray array];
    MCMCollectLaunchServicesStorePaths(manager, libraryRoot, 0, stores);
    if (stores.count == 0) {
        if (error) *error = @"no LaunchServices csstore found in lsd Library";
        return @[];
    }

    NSUInteger scaledLimit = requestedLimit > NSUIntegerMax / 16
        ? NSUIntegerMax : requestedLimit * 16;
    NSUInteger candidateLimit = MIN((NSUInteger)65536,
        MAX((NSUInteger)4096, scaledLimit));
    NSMutableOrderedSet<NSString *> *candidates = [NSMutableOrderedSet orderedSet];

    for (NSString *path in stores) {
        NSDictionary *attributes = [manager attributesOfItemAtPath:path error:nil];
        unsigned long long byteCount = [attributes[NSFileSize] unsignedLongLongValue];
        if (byteCount == 0 || byteCount > 128ULL * 1024ULL * 1024ULL) continue;

        NSError *readError = nil;
        NSData *data = [NSData dataWithContentsOfFile:path
            options:NSDataReadingMappedIfSafe error:&readError];
        if (!data) {
            NSLog(@"[MCMBridge] LaunchServices store read failed path=%@ error=%@",
                  path, readError);
            continue;
        }

        const uint8_t *bytes = data.bytes;
        NSUInteger start = NSNotFound;
        for (NSUInteger index = 0; index <= data.length; index++) {
            BOOL allowed = index < data.length &&
                MCMLaunchServicesIdentifierByte(bytes[index]);
            if (allowed) {
                if (start == NSNotFound) start = index;
                continue;
            }
            if (start == NSNotFound) continue;
            NSUInteger length = index - start;
            if (length >= 3 && length <= 255) {
                NSString *identifier = [[NSString alloc]
                    initWithBytes:bytes + start length:length
                    encoding:NSUTF8StringEncoding];
                if (MCMSafeDiscoveredIdentifier(identifier)) {
                    [candidates addObject:identifier];
                    if (candidates.count >= candidateLimit) break;
                }
            }
            start = NSNotFound;
        }
        NSLog(@"[MCMBridge] LaunchServices store os=%ld path=%@ bytes=%lu candidates=%lu",
              (long)MCMOperatingSystemMajorVersion(), path,
              (unsigned long)data.length, (unsigned long)candidates.count);
        if (candidates.count >= candidateLimit) break;
    }
    return candidates.array;
}

static BOOL MCMIdentifierHasClass2Container(NSString *identifier)
{
    NSString *detail = nil;
    MCMLease *lease = [MCMLease leaseForClass:2 identifier:identifier group:NO
        part:0 flags:kMCMDiscoveryLookupFlags error:&detail];
    BOOL exists = lease.rootPath.length > 0;
    [lease invalidate];
    return exists;
}

static NSArray<NSString *> *MCMVerifiedLaunchServicesAppIdentifiers(NSUInteger limit,
                                                                    NSString **error)
{
    if (limit == 0) return @[];
    NSString *leaseDetail = nil;
    MCMLease *lsdLease = [MCMLease leaseForClass:10 identifier:@"com.apple.lsd"
        group:NO part:0 flags:kMCMDiscoveryLookupFlags error:&leaseDetail];
    if (!lsdLease) {
        if (error) *error = leaseDetail ?: @"com.apple.lsd service container lookup failed";
        return @[];
    }

    NSString *activationDetail = nil;
    BOOL usable = [lsdLease activate:&activationDetail];
    if (!usable && !MCMRootDirectoryAlreadyAccessible(lsdLease.rootPath)) {
        if (error) *error = activationDetail ?: @"com.apple.lsd container unavailable";
        [lsdLease invalidate];
        return @[];
    }

    NSString *libraryRoot = [lsdLease.rootPath stringByAppendingPathComponent:@"Library"];
    NSString *scanDetail = nil;
    NSArray<NSString *> *candidates = MCMExtractLaunchServicesCandidates(
        libraryRoot, limit, &scanDetail);
    NSMutableOrderedSet<NSString *> *verified = [NSMutableOrderedSet orderedSet];
    NSUInteger probeBudget = MIN((NSUInteger)8192,
        MAX((NSUInteger)1024, limit > NSUIntegerMax / 8 ? NSUIntegerMax : limit * 8));
    NSUInteger probed = 0;
    for (NSString *identifier in candidates) {
        if (probed >= probeBudget || verified.count >= limit) break;
        probed++;
        if (MCMIdentifierHasClass2Container(identifier))
            [verified addObject:identifier];
    }

    NSLog(@"[MCMBridge] LaunchServices app discovery os=%ld storesCandidates=%lu probed=%lu verified=%lu",
          (long)MCMOperatingSystemMajorVersion(), (unsigned long)candidates.count,
          (unsigned long)probed, (unsigned long)verified.count);
    [lsdLease invalidate];

    if (verified.count == 0 && error)
        *error = scanDetail ?: @"LaunchServices store contained no verified class-2 identifiers";
    return verified.array;
}

NSArray<NSString *> *MCMEnumerateIdentifiersForClass(
    uint64_t containerClass, NSUInteger limit, NSString **error)
{
    MCMAPI *api = MCMSharedAPI();
    if (!MCMBridgeAvailable() || !api->queryIterate || !api->objectGetIdentifier || limit == 0) {
        if (error) *error = @"ContainerManager enumeration API unavailable";
        return @[];
    }
    void *query = api->queryCreate();
    if (!query) {
        if (error) *error = @"container_query_create returned NULL";
        return @[];
    }
    api->querySetClass(query, containerClass);
    // Metadata-only, no-create lookup. Extensions are requested individually
    // only after an identifier passes validation.
    api->querySetFlags(query, 0x100000000ULL);
    // iOS 18 does not export the part API. A new query already defaults to
    // part 0, so only set it when the newer API is present.
    if (api->querySetPart) api->querySetPart(query, 0);
    NSMutableOrderedSet<NSString *> *identifiers = [NSMutableOrderedSet orderedSet];
    BOOL iterated = api->queryIterate(query, ^bool(void *object) {
        const char *raw = object ? api->objectGetIdentifier(object) : NULL;
        NSString *identifier = raw ? [NSString stringWithUTF8String:raw] : nil;
        if (identifier.length) [identifiers addObject:identifier];
        return identifiers.count < limit;
    });

    NSString *iterationDetail = nil;
    if (!iterated && identifiers.count < limit) {
        void *queryError = api->queryGetLastError(query);
        int posix = queryError && api->errorGetPOSIX ? api->errorGetPOSIX(queryError) : 0;
        const char *message = queryError && api->errorGetMessage
            ? api->errorGetMessage(queryError) : NULL;
        iterationDetail = [NSString stringWithFormat:@"enumeration denied posix=%d message=%s",
            posix, message ?: "unknown"];
    }
    api->queryFree(query);

    // iOS 26 changed jailed ContainerManager enumeration so class-2 iteration
    // can be nearly empty while direct identifier lookups still work. Upstream
    // FilzaSlop now recovers identifiers from LaunchServices' lsd csstore.
    // Keep that behavior for iOS 26 and make it version-tolerant for iOS 27 by
    // accepting any LaunchServices*.csstore filename instead of only *-v2.
    NSInteger majorVersion = MCMOperatingSystemMajorVersion();
    if (containerClass == 2 && majorVersion >= 26 && identifiers.count < limit &&
        getenv("FILZA_MCM_DISABLE_LS_DISCOVERY") == NULL) {
        NSString *launchServicesDetail = nil;
        NSArray<NSString *> *fallback = MCMVerifiedLaunchServicesAppIdentifiers(
            limit - identifiers.count, &launchServicesDetail);
        NSUInteger before = identifiers.count;
        [identifiers addObjectsFromArray:fallback];
        NSUInteger added = identifiers.count - before;
        if (added > 0) {
            NSLog(@"[MCMBridge] iOS %ld LaunchServices fallback added %lu class-2 identifiers",
                  (long)majorVersion, (unsigned long)added);
            if (error) {
                *error = iterationDetail.length
                    ? [NSString stringWithFormat:@"%@; LaunchServices fallback added %lu",
                        iterationDetail, (unsigned long)added]
                    : [NSString stringWithFormat:@"LaunchServices fallback added %lu verified identifiers on iOS %ld",
                        (unsigned long)added, (long)majorVersion];
            }
        } else if (error) {
            if (iterationDetail.length && launchServicesDetail.length)
                *error = [NSString stringWithFormat:@"%@; LaunchServices fallback: %@",
                    iterationDetail, launchServicesDetail];
            else
                *error = iterationDetail ?: launchServicesDetail;
        }
    } else if (error && iterationDetail.length) {
        *error = iterationDetail;
    }

    return identifiers.array;
}

BOOL MCMBridgeAvailable(void)
{
    MCMAPI *api = MCMSharedAPI();
    return api->queryCreate != NULL && api->querySetClass != NULL &&
        api->querySetIdentifiers != NULL && api->querySetGroupIdentifiers != NULL &&
        api->querySetFlags != NULL &&
        api->queryGetSingle != NULL && api->queryGetLastError != NULL &&
        api->queryFree != NULL && api->objectGetPath != NULL &&
        api->objectCopy != NULL && api->objectCopyToken != NULL &&
        api->objectActivate != NULL && api->objectFree != NULL;
}

@interface MCMLease () {
    void *_query;
    void *_activation;
}
@property(nonatomic, readwrite) uint64_t containerClass;
@property(nonatomic, copy, readwrite) NSString *identifier;
@property(nonatomic, copy, readwrite) NSString *rootPath;
@property(nonatomic, readwrite) BOOL groupIdentifier;
@property(nonatomic, readwrite) BOOL tokenPresent;
@property(nonatomic, readwrite) BOOL activated;
@end

@implementation MCMLease

+ (instancetype)leaseForClass:(uint64_t)containerClass
                    identifier:(NSString *)identifier
                         group:(BOOL)group
                          part:(uint64_t)part
                         flags:(uint64_t)flags
                         error:(NSString **)error
{
    return [self leaseForClass:containerClass identifier:identifier group:group
                          part:part partDomain:nil flags:flags error:error];
}

+ (instancetype)leaseForClass:(uint64_t)containerClass
                    identifier:(NSString *)identifier
                         group:(BOOL)group
                          part:(uint64_t)part
                    partDomain:(NSString *)partDomain
                         flags:(uint64_t)flags
                         error:(NSString **)error
{
    if (!MCMBridgeAvailable() || identifier.length == 0) {
        if (error) *error = @"ContainerManager bridge unavailable or identifier empty";
        return nil;
    }
    MCMAPI *api = MCMSharedAPI();
    void *query = api->queryCreate();
    if (query == NULL) {
        if (error) *error = @"container_query_create returned NULL";
        return nil;
    }
    api->querySetClass(query, containerClass);
    xpc_object_t value = xpc_string_create(identifier.UTF8String);
    if (group) api->querySetGroupIdentifiers(query, value);
    else api->querySetIdentifiers(query, value);
#if !OS_OBJECT_USE_OBJC
    xpc_release(value);
#endif
    api->querySetFlags(query, flags);
    if (part != 0 && !api->querySetPart) {
        if (error) *error = @"part API unavailable on this OS";
        api->queryFree(query);
        return nil;
    }
    if (api->querySetPart) api->querySetPart(query, part);
    if (partDomain.length != 0) {
        if (!api->querySetPartDomain) {
            if (error) *error = @"part-domain API unavailable";
            api->queryFree(query);
            return nil;
        }
        api->querySetPartDomain(query, partDomain.fileSystemRepresentation);
    }
    void *object = api->queryGetSingle(query);
    if (object == NULL) {
        void *queryError = api->queryGetLastError(query);
        int posix = queryError && api->errorGetPOSIX ? api->errorGetPOSIX(queryError) : 0;
        const char *message = queryError && api->errorGetMessage
            ? api->errorGetMessage(queryError) : NULL;
        if (error) *error = [NSString stringWithFormat:@"lookup denied posix=%d message=%s",
            posix, message ?: "unknown"];
        api->queryFree(query);
        return nil;
    }
    const char *rawPath = api->objectGetPath(object);
    NSString *root = rawPath ? [NSString stringWithUTF8String:rawPath] : nil;
    if (root.length == 0 || !root.isAbsolutePath) {
        if (error) *error = @"MCM returned no absolute container path";
        api->queryFree(query);
        return nil;
    }
    if ([root isEqualToString:@"/var"] || [root hasPrefix:@"/var/"])
        root = [@"/private" stringByAppendingString:root];
    MCMLease *lease = [MCMLease new];
    lease->_query = query;
    lease.containerClass = containerClass;
    lease.identifier = identifier;
    lease.groupIdentifier = group;
    lease.rootPath = root;
    return lease;
}

- (BOOL)activate:(NSString **)error
{
    if (self.activated) return YES;
    if (!_query) {
        if (error) *error = @"lease invalidated";
        return NO;
    }
    MCMAPI *api = MCMSharedAPI();
    void *object = api->queryGetSingle(_query);
    _activation = object ? api->objectCopy(object) : NULL;
    char *token = _activation ? api->objectCopyToken(_activation) : NULL;
    self.tokenPresent = token && token[0] != '\0';
    free(token);
    self.activated = self.tokenPresent && api->objectActivate(_activation, false);
    if (self.activated) return YES;

    // iOS 26's containermanagerd may refuse the generic sandbox-extension
    // token even when this caller can already open the returned container root.
    // The new upstream FilzaSlop discovery path treats that openable path as
    // usable. Do the same on iOS 26+ (including iOS 27) without claiming that
    // a sandbox token was activated: self.activated deliberately remains NO.
    if (MCMOperatingSystemMajorVersion() >= 26 &&
        MCMRootDirectoryAlreadyAccessible(self.rootPath)) {
        if (error)
            *error = @"sandbox extension unavailable, but container root is directly accessible";
        return YES;
    }

    if (error)
        *error = self.tokenPresent ? @"sandbox extension activation failed"
                                   : @"MCM object contained no sandbox token";
    return NO;
}

- (void)invalidate
{
    MCMAPI *api = MCMSharedAPI();
    if (_activation) { api->objectFree(_activation); _activation = NULL; }
    if (_query) { api->queryFree(_query); _query = NULL; }
    self.activated = NO;
}

- (void)dealloc { [self invalidate]; }

@end
