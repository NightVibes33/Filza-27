@import Foundation;
@import UIKit;

#import <dirent.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <unistd.h>
#import <xpc/xpc.h>

#import "GestaltManager.h"
#include "bad_query.h"

static NSString *const GMSystemGroupIdentifier = @"systemgroup.com.apple.mobilegestaltcache";
static NSString *const GMFallbackDirectory = @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches";
static NSString *const GMPlistName = @"com.apple.MobileGestalt.plist";
static NSString *const GMShortcutType = @"com.nightvibes33.filzaslop.gestalt-manager";

static NSString *gGMResolvedPath;
static int64_t gGMBadQueryHandle = -1;
static BOOL gGMMenuHooksInstalled = NO;
static BOOL gGMShortcutHookInstalled = NO;
static Class gGMMenuDataSourceClass = Nil;
static Class gGMMenuDelegateClass = Nil;
static NSInteger gGMMenuSection = NSNotFound;
static NSInteger gGMMenuRow = NSNotFound;

static IMP gGMOrigRows = NULL;
static IMP gGMOrigCell = NULL;
static IMP gGMOrigSelect = NULL;
static IMP gGMOrigShortcut = NULL;

#pragma mark - MobileGestalt access

typedef void *(*GMQueryCreate)(void);
typedef void (*GMQueryFree)(void *);
typedef void (*GMQuerySetU64)(void *, uint64_t);
typedef void (*GMQuerySetBool)(void *, bool);
typedef void (*GMQuerySetXPC)(void *, xpc_object_t);
typedef void *(*GMQueryGetSingle)(void *);
typedef bool (*GMObjectActivate)(void *, bool);
typedef const char *(*GMObjectGetPath)(void *);

static BOOL GMFileReadable(NSString *path)
{
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return NO;
    struct stat st = {0};
    BOOL ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0;
    close(fd);
    return ok;
}

static BOOL GMFileWritable(NSString *path)
{
    int fd = open(path.fileSystemRepresentation, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return NO;
    struct stat st = {0};
    BOOL ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode);
    close(fd);
    return ok;
}

static NSString *GMResolvePlistBelowRoot(NSString *root)
{
    if (!root.length) return nil;
    NSArray *candidates = @[
        [root stringByAppendingPathComponent:GMPlistName],
        [[root stringByAppendingPathComponent:@"Library/Caches"] stringByAppendingPathComponent:GMPlistName],
        [GMFallbackDirectory stringByAppendingPathComponent:GMPlistName],
    ];
    for (NSString *candidate in candidates) {
        if (GMFileReadable(candidate)) return candidate;
    }
    return nil;
}

static NSString *GMTryContainerManagerAccess(NSString **detail)
{
    void *lib = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    void *handle = lib ?: RTLD_DEFAULT;

#define GM_SYM(type, name) ((type)dlsym(handle, name))
    GMQueryCreate create = GM_SYM(GMQueryCreate, "container_query_create");
    GMQueryFree freeQuery = GM_SYM(GMQueryFree, "container_query_free");
    GMQuerySetU64 setClass = GM_SYM(GMQuerySetU64, "container_query_set_class");
    GMQuerySetBool setTransient = GM_SYM(GMQuerySetBool, "container_query_set_transient");
    GMQuerySetXPC setGroups = GM_SYM(GMQuerySetXPC, "container_query_set_group_identifiers");
    GMQuerySetU64 setPlatform = GM_SYM(GMQuerySetU64, "container_query_operation_set_platform");
    GMQuerySetU64 setFlags = GM_SYM(GMQuerySetU64, "container_query_operation_set_flags");
    GMQuerySetU64 setPart = GM_SYM(GMQuerySetU64, "container_query_operation_set_part");
    GMQueryGetSingle getSingle = GM_SYM(GMQueryGetSingle, "container_query_get_single_result");
    GMObjectActivate activate = GM_SYM(GMObjectActivate, "container_object_sandbox_extension_activate");
    GMObjectGetPath getPath = GM_SYM(GMObjectGetPath, "container_object_get_path");
#undef GM_SYM

    if (!create || !freeQuery || !setClass || !setGroups || !setPlatform ||
        !setFlags || !getSingle || !activate || !getPath) {
        if (detail) *detail = @"ContainerManager MobileGestalt query API unavailable";
        if (lib) dlclose(lib);
        return nil;
    }

    void *query = create();
    if (!query) {
        if (detail) *detail = @"container_query_create failed";
        if (lib) dlclose(lib);
        return nil;
    }

    setClass(query, 13);
    if (setTransient) setTransient(query, false);

    xpc_object_t groups = xpc_array_create(NULL, 0);
    xpc_array_set_string(groups, XPC_ARRAY_APPEND, GMSystemGroupIdentifier.UTF8String);
    setGroups(query, groups);
#if !OS_OBJECT_USE_OBJC
    xpc_release(groups);
#endif

    setPlatform(query, 2);
    setFlags(query, (1ULL << 32) | (1ULL << 39));
    if (setPart) setPart(query, 3);

    void *result = getSingle(query);
    if (!result) {
        freeQuery(query);
        if (detail) *detail = @"MobileGestalt system-group query returned no result";
        if (lib) dlclose(lib);
        return nil;
    }

    BOOL activated = activate(result, true);
    const char *raw = getPath(result);
    NSString *root = raw ? [NSString stringWithUTF8String:raw] : nil;
    NSString *resolved = GMResolvePlistBelowRoot(root);

    freeQuery(query);
    if (lib) dlclose(lib);

    if (resolved.length) {
        if (detail) *detail = [NSString stringWithFormat:
            @"ContainerManager access %@; plist %@",
            activated ? @"activated" : @"already usable", resolved];
        return resolved;
    }
    if (detail) *detail = [NSString stringWithFormat:
        @"ContainerManager returned %@ but MobileGestalt plist remained unreadable",
        root ?: @"no path"];
    return nil;
}

static NSString *GMTryBadQueryAccess(NSString **detail)
{
    NSString *file = [GMFallbackDirectory stringByAppendingPathComponent:GMPlistName];
    if (GMFileReadable(file)) {
        if (detail) *detail = @"MobileGestalt cache already readable";
        return file;
    }

    int64_t handle = bad_query((char *)GMFallbackDirectory.fileSystemRepresentation,
                               false, NULL, false);
    if (handle < 0) {
        handle = bad_query((char *)GMFallbackDirectory.fileSystemRepresentation,
                           true, NULL, false);
    }
    if (handle < 0) {
        if (detail) *detail = [NSString stringWithFormat:@"MobileGestalt access query failed: %lld", handle];
        return nil;
    }

    if (!GMFileReadable(file)) {
        bad_query_release(handle);
        if (detail) *detail = @"Access handle returned but MobileGestalt plist is still unreadable";
        return nil;
    }

    if (gGMBadQueryHandle >= 0) bad_query_release(gGMBadQueryHandle);
    gGMBadQueryHandle = handle;
    if (detail) *detail = [NSString stringWithFormat:@"MobileGestalt access active handle=%lld", handle];
    return file;
}

static NSString *GMEnsureAccess(NSString **detail)
{
    if (gGMResolvedPath.length && GMFileReadable(gGMResolvedPath)) {
        if (detail) *detail = GMFileWritable(gGMResolvedPath)
            ? @"MobileGestalt cache read/write access active"
            : @"MobileGestalt cache read-only access active";
        return gGMResolvedPath;
    }

    NSString *cmgDetail = nil;
    NSString *path = GMTryContainerManagerAccess(&cmgDetail);
    if (!path.length) {
        NSString *bqDetail = nil;
        path = GMTryBadQueryAccess(&bqDetail);
        if (detail) *detail = [NSString stringWithFormat:@"%@; %@",
            cmgDetail ?: @"ContainerManager path unavailable",
            bqDetail ?: @"fallback unavailable"];
    } else if (detail) {
        *detail = cmgDetail;
    }
    if (path.length) gGMResolvedPath = path;
    return path;
}

#pragma mark - CacheData support

static NSMutableDictionary<NSString *, NSNumber *> *GMOffsetCache(void)
{
    static NSMutableDictionary *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

static NSUInteger GMCacheDataOffsetForKey(NSString *key)
{
    NSNumber *cached = GMOffsetCache()[key];
    if (cached) return cached.unsignedIntegerValue;

    const char *imagePath = "/usr/lib/libMobileGestalt.dylib";
    void *lib = dlopen(imagePath, RTLD_NOW | RTLD_LOCAL);
    (void)lib;

    const struct mach_header_64 *header = NULL;
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index++) {
        const char *name = _dyld_get_image_name(index);
        if (name && !strcmp(name, imagePath)) {
            header = (const struct mach_header_64 *)_dyld_get_image_header(index);
            break;
        }
    }
    if (!header) {
        GMOffsetCache()[key] = @0;
        if (lib) dlclose(lib);
        return 0;
    }

    unsigned long cstringSize = 0;
    const uint8_t *cstring = getsectiondata(header, "__TEXT", "__cstring", &cstringSize);
    if (!cstring || cstringSize == 0) {
        GMOffsetCache()[key] = @0;
        if (lib) dlclose(lib);
        return 0;
    }

    const char *needle = NULL;
    NSUInteger position = 0;
    while (position < cstringSize) {
        const char *candidate = (const char *)(cstring + position);
        size_t remaining = cstringSize - position;
        size_t length = strnlen(candidate, remaining);
        if (length >= remaining) break;
        if ([key isEqualToString:[NSString stringWithUTF8String:candidate] ?: @""]) {
            needle = candidate;
            break;
        }
        position += length + 1;
    }

    unsigned long constSize = 0;
    const uint8_t *constBytes = getsectiondata(header, "__AUTH_CONST", "__const", &constSize);
    if (!constBytes)
        constBytes = getsectiondata(header, "__DATA_CONST", "__const", &constSize);

    NSUInteger result = 0;
    if (needle && constBytes && constSize >= sizeof(uintptr_t)) {
        NSUInteger count = constSize / sizeof(uintptr_t);
        const uintptr_t *slots = (const uintptr_t *)constBytes;
        uintptr_t target = (uintptr_t)needle;
        for (NSUInteger index = 0; index < count; index++) {
            if (slots[index] != target) continue;
            const uint8_t *entry = (const uint8_t *)&slots[index];
            const uint8_t *end = constBytes + constSize;
            if (entry + 0x9c > end) continue;
            uint16_t encoded = 0;
            memcpy(&encoded, entry + 0x9a, sizeof(encoded));
            result = ((NSUInteger)encoded) << 3;
            break;
        }
    }

    GMOffsetCache()[key] = @(result);
    if (lib) dlclose(lib);
    return result;
}

static NSMutableData *GMMutableCacheData(NSMutableDictionary *plist)
{
    id existing = plist[@"CacheData"];
    if ([existing isKindOfClass:NSMutableData.class]) return existing;
    if ([existing isKindOfClass:NSData.class]) {
        NSMutableData *mutable = [existing mutableCopy];
        plist[@"CacheData"] = mutable;
        return mutable;
    }
    return nil;
}

static BOOL GMReadCacheDataInt(NSMutableDictionary *plist, NSString *key, int64_t *value)
{
    NSMutableData *data = GMMutableCacheData(plist);
    NSUInteger offset = GMCacheDataOffsetForKey(key);
    if (!data || offset == 0 || offset + sizeof(int64_t) > data.length) return NO;
    int64_t current = 0;
    memcpy(&current, (const uint8_t *)data.bytes + offset, sizeof(current));
    if (value) *value = current;
    return YES;
}

static BOOL GMWriteCacheDataInt(NSMutableDictionary *plist, NSString *key, int64_t value)
{
    NSMutableData *data = GMMutableCacheData(plist);
    NSUInteger offset = GMCacheDataOffsetForKey(key);
    if (!data || offset == 0 || offset + sizeof(int64_t) > data.length) return NO;
    memcpy((uint8_t *)data.mutableBytes + offset, &value, sizeof(value));
    return YES;
}

#pragma mark - Safe plist persistence

static NSString *GMBackupDirectory(void)
{
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                          NSUserDomainMask, YES).firstObject;
    if (!base.length) base = NSTemporaryDirectory();
    NSString *directory = [base stringByAppendingPathComponent:@"GestaltManager"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}

static NSString *GMBackupPath(void)
{
    return [GMBackupDirectory() stringByAppendingPathComponent:@"SavedGestalt.plist"];
}

static NSMutableDictionary *GMLoadMutablePlist(NSString *path, NSError **error)
{
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data.length) return nil;
    NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
    id object = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListMutableContainersAndLeaves format:&format error:error];
    return [object isKindOfClass:NSMutableDictionary.class] ? object : nil;
}

static BOOL GMEnsureBackup(NSString *source, NSError **error)
{
    NSString *backup = GMBackupPath();
    if ([NSFileManager.defaultManager fileExistsAtPath:backup]) return YES;
    NSData *data = [NSData dataWithContentsOfFile:source options:0 error:error];
    if (!data.length) return NO;
    id parsed = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:error];
    if (![parsed isKindOfClass:NSDictionary.class]) return NO;
    return [data writeToFile:backup options:NSDataWritingAtomic error:error];
}

static BOOL GMWriteAll(int fd, NSData *data)
{
    const uint8_t *bytes = data.bytes;
    NSUInteger left = data.length;
    while (left > 0) {
        ssize_t written = write(fd, bytes, left);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return NO;
        bytes += written;
        left -= (NSUInteger)written;
    }
    return fsync(fd) == 0;
}

static BOOL GMDirectWrite(NSString *path, NSData *data, NSError **error)
{
    int fd = open(path.fileSystemRepresentation,
                  O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    BOOL ok = GMWriteAll(fd, data);
    int saved = errno;
    close(fd);
    if (!ok && error)
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:saved ?: EIO userInfo:nil];
    return ok;
}

static BOOL GMWriteValidatedPlist(NSString *path, NSMutableDictionary *plist, NSError **error)
{
    if (!GMEnsureBackup(path, error)) return NO;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
        format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    if (!data.length) return NO;

    id validation = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:error];
    if (![validation isKindOfClass:NSDictionary.class]) return NO;

    NSError *atomicError = nil;
    BOOL wrote = [data writeToFile:path options:NSDataWritingAtomic error:&atomicError];
    if (!wrote) wrote = GMDirectWrite(path, data, error);
    if (!wrote) {
        if (error && !*error) *error = atomicError;
        return NO;
    }

    NSError *verifyError = nil;
    NSMutableDictionary *roundTrip = GMLoadMutablePlist(path, &verifyError);
    if (roundTrip) return YES;

    NSData *backup = [NSData dataWithContentsOfFile:GMBackupPath()];
    if (backup.length) (void)GMDirectWrite(path, backup, nil);
    if (error) *error = verifyError ?: [NSError errorWithDomain:@"GestaltManager" code:2
        userInfo:@{NSLocalizedDescriptionKey: @"Written plist failed validation and backup was restored"}];
    return NO;
}

NSString *FilzaGestaltResolvePath(NSString **detail)
{
    NSString *path = GMEnsureAccess(detail);
    if (path.length) (void)GMEnsureBackup(path, nil);
    return path;
}

NSError *FilzaGestaltWritePlist(NSString *path, NSDictionary *plist)
{
    if (!path.length || ![plist isKindOfClass:NSDictionary.class]) {
        return [NSError errorWithDomain:@"GestaltManager" code:3 userInfo:@{
            NSLocalizedDescriptionKey: @"MobileGestalt path or property list is invalid"
        }];
    }
    NSError *error = nil;
    NSMutableDictionary *mutable = [plist mutableCopy];
    return GMWriteValidatedPlist(path, mutable, &error) ? nil : (error ?: [NSError
        errorWithDomain:@"GestaltManager" code:4 userInfo:@{
            NSLocalizedDescriptionKey: @"MobileGestalt write failed"
        }]);
}

NSError *FilzaGestaltRestoreBackup(NSString *path)
{
    NSError *error = nil;
    NSData *backup = [NSData dataWithContentsOfFile:GMBackupPath()
                                            options:0
                                              error:&error];
    if (!backup.length) return error ?: [NSError errorWithDomain:@"GestaltManager"
        code:5 userInfo:@{NSLocalizedDescriptionKey: @"No saved MobileGestalt backup exists"}];

    id parsed = [NSPropertyListSerialization propertyListWithData:backup
        options:0 format:nil error:&error];
    if (![parsed isKindOfClass:NSDictionary.class]) return error ?: [NSError
        errorWithDomain:@"GestaltManager" code:6 userInfo:@{
            NSLocalizedDescriptionKey: @"Saved MobileGestalt backup is invalid"
        }];
    if (!GMDirectWrite(path, backup, &error)) return error;
    if (!GMLoadMutablePlist(path, &error)) return error ?: [NSError
        errorWithDomain:@"GestaltManager" code:7 userInfo:@{
            NSLocalizedDescriptionKey: @"Restored MobileGestalt failed validation"
        }];
    return nil;
}

#pragma mark - Feature catalog

static NSArray<NSDictionary *> *GMSoftwareFeatures(void)
{
    return @[
        @{ @"name": @"Dynamic Island", @"kind": @"bool", @"keys": @[@"YlEtTtHlNesRBMal1CqRaA"] },
        @{ @"name": @"Always-On Display", @"kind": @"bool", @"keys": @[@"j8/Omm6s1lsmTDFsXjsBfA", @"2OOJf1VhaM7NxfRok3HbWQ"] },
        @{ @"name": @"AOD Vibrancy", @"kind": @"bool", @"keys": @[@"ykpu7qyhqFweVMKtxNylWA"] },
        @{ @"name": @"Charge Limit", @"kind": @"bool", @"keys": @[@"37NVydb//GP/GrhuTN+exg"] },
        @{ @"name": @"Boot Chime", @"kind": @"bool", @"keys": @[@"QHxt+hGLaBPbQJbXiUJX3w"] },
        @{ @"name": @"Liquid Glass in Low Power Mode", @"kind": @"bool", @"keys": @[@"SAGvsp6O6kAQ4fEfDJpC4Q"] },
    ];
}

static NSArray<NSDictionary *> *GMHardwareFeatures(void)
{
    return @[
        @{ @"name": @"Camera Control", @"kind": @"bool", @"keys": @[@"CwvKxM2cEogD3p+HYgaW0Q", @"oOV1jhJbdV3AddkcCg0AEA"] },
        @{ @"name": @"Action Button", @"kind": @"bool", @"keys": @[@"cT44WE1EohiwRzhsZ8xEsw"] },
        @{ @"name": @"Crash Detection", @"kind": @"bool", @"keys": @[@"HCzWusHQwZDea6nNhaKndw"] },
        @{ @"name": @"Tap to Wake", @"kind": @"bool", @"keys": @[@"yZf3GTRMGTuwSV/lD7Cagw"] },
        @{ @"name": @"Pulse Width Modulation", @"kind": @"bool", @"keys": @[@"6IejgN+1Fmu5/QrZFOIeNw"] },
        @{ @"name": @"Security Research Device UI", @"kind": @"bool", @"keys": @[@"XYlJKKkj2hztRP1NWWnhlw"] },
        @{ @"name": @"Apple Intelligence Eligibility", @"kind": @"bool", @"keys": @[@"A62OafQ85EJAiiqKn4agtg"] },
        @{ @"name": @"Allow Installing iPadOS Apps", @"kind": @"ipadapps", @"keys": @[@"9MZ5AdH43csAUajl/dU+IQ"] },
        @{ @"name": @"Apple Pencil Settings", @"kind": @"bool", @"keys": @[@"yhHcB0iH0d1XzPO/CFd3ow"] },
        @{ @"name": @"Stage Manager", @"kind": @"bool", @"keys": @[@"qeaj75wk3HF4DwQ8qbIi7g"] },
        @{ @"name": @"Internal Storage", @"kind": @"bool", @"keys": @[@"LBJfwOEzExRxzlAnSuI7eg"] },
        @{ @"name": @"Internal Features", @"kind": @"internal", @"keys": @[] },
        @{ @"name": @"Metal HUD in All Apps", @"kind": @"bool", @"keys": @[@"EqrsVvjcYDdxHBiQmGhAWw"] },
        @{ @"name": @"iPadOS UI / Multitasking", @"kind": @"medusa", @"keys": @[] },
    ];
}

static NSArray<NSDictionary *> *GMIOS27Keys(void)
{
    return @[
        @{ @"key": @"7brdL5xrEUWnlF9C0kdg5A", @"name": @"DeviceSupportsHighLuminanceAlwaysOnDisplay" },
        @{ @"key": @"A/74xUbqJwBsaWTjSDd0fQ", @"name": @"ChassisSlotFunctionNumber" },
        @{ @"key": @"a3n5T9sFtlyQ74NEp9ESxg", @"name": @"SiriMode" },
        @{ @"key": @"HBG+hj/Oz89PjVgn93Jd8A", @"name": @"Image4SecureBootKeyScheme" },
        @{ @"key": @"ikn/KMyeztXJhAj/dqBjBg", @"name": @"LowPowerRendererCapability" },
        @{ @"key": @"J2+oJRiGdbAzTi6U5nhqdQ", @"name": @"PostQuantumCryptographyEnforced" },
        @{ @"key": @"Kpfa0nb8nn8EVzI/UgcMfQ", @"name": @"CoalescedSubTargetID" },
        @{ @"key": @"lyJZrSDc8J8eQ5b7A1Rvw", @"name": @"DeviceSupportsTouchSensitiveCameraControl" },
        @{ @"key": @"m4xs4mhvxnAopYrApoLDMw", @"name": @"DeviceSupportsInstructionFollowingPruningModels" },
        @{ @"key": @"mnPU37/y4i0TJFnJc+r4lA", @"name": @"DeviceSupportsLowPowerWake" },
        @{ @"key": @"odI0U9Etrx7hObzvJ9xJ8Q", @"name": @"DeviceSupportsSandcat" },
        @{ @"key": @"P4ZJVy/zYuLy4ejRKP+0DA", @"name": @"DeviceSupportsRegionalCameraShutterRelaxation" },
        @{ @"key": @"qqrspu7CpuPdZwSDxNY+Fg", @"name": @"MaximumFlipbookCount" },
        @{ @"key": @"s1ZXqZtUSpr+BjUgZXZ/2g", @"name": @"ChassisSlotInstanceNumber" },
        @{ @"key": @"TusANsf9Lfe3P/9fIXXSrQ", @"name": @"DeviceSupportsAlwaysListeningHeySiri" },
        @{ @"key": @"VXc3L66nqQ6bn4z60ChX+A", @"name": @"ResponsiveAirPlayAudioCapability" },
        @{ @"key": @"ym8C/Ut5YcBnqAdm4NEDLQ", @"name": @"Image4SecureBootCertificateFormat" },
    ];
}

static NSString *GMValueDescription(id value)
{
    if (!value || value == NSNull.null) return @"Not set";
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) {
        const char *type = [value objCType];
        if (type && (!strcmp(type, @encode(BOOL)) || !strcmp(type, "B")))
            return [value boolValue] ? @"true" : @"false";
        return [value stringValue];
    }
    if ([NSJSONSerialization isValidJSONObject:value]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
        NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (text.length) return text;
    }
    return [value description];
}

#pragma mark - Manager controller

@interface GMSwitch : UISwitch
@property(nonatomic, strong) NSDictionary *feature;
@end
@implementation GMSwitch
@end

@interface GestaltManagerController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, strong) NSMutableDictionary *plist;
@property(nonatomic, strong) NSMutableDictionary *cacheExtra;
@property(nonatomic, copy) NSString *plistPath;
@property(nonatomic, copy) NSString *accessDetail;
@property(nonatomic, copy) NSArray<NSString *> *rawKeys;
@property(nonatomic, copy) NSArray<NSString *> *filteredKeys;
@property(nonatomic, assign) BOOL loading;
@property(nonatomic, assign) BOOL dirty;
@property(nonatomic, strong) UISearchController *searchController;
@end

@implementation GestaltManagerController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Gestalt Manager";
    self.loading = YES;
    self.accessDetail = @"Requesting MobileGestalt access…";

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadFromDisk)];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search Gestalt keys";
    self.navigationItem.searchController = self.searchController;
    self.definesPresentationContext = YES;

    [self reloadFromDisk];
}

- (void)reloadFromDisk
{
    self.loading = YES;
    self.dirty = NO;
    self.accessDetail = @"Requesting MobileGestalt access…";
    [self.tableView reloadData];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *detail = nil;
        NSString *path = GMEnsureAccess(&detail);
        NSError *error = nil;
        NSMutableDictionary *plist = path.length ? GMLoadMutablePlist(path, &error) : nil;
        if (plist && path.length) (void)GMEnsureBackup(path, nil);

        dispatch_async(dispatch_get_main_queue(), ^{
            self.plistPath = path;
            self.plist = plist;
            id extra = plist[@"CacheExtra"];
            if ([extra isKindOfClass:NSMutableDictionary.class]) {
                self.cacheExtra = extra;
            } else if ([extra isKindOfClass:NSDictionary.class]) {
                self.cacheExtra = [extra mutableCopy];
                self.plist[@"CacheExtra"] = self.cacheExtra;
            } else if (plist) {
                self.cacheExtra = [NSMutableDictionary dictionary];
                self.plist[@"CacheExtra"] = self.cacheExtra;
            } else {
                self.cacheExtra = nil;
            }
            self.rawKeys = [[self.cacheExtra.allKeys filteredArrayUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(id key, NSDictionary *_) {
                    return [key isKindOfClass:NSString.class];
                }]] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
            self.filteredKeys = self.rawKeys;
            self.accessDetail = path.length
                ? [NSString stringWithFormat:@"%@\n%@\n%@",
                    detail ?: @"Access active", path,
                    GMFileWritable(path) ? @"Read/write verified" : @"Read-only"]
                : [NSString stringWithFormat:@"Access unavailable\n%@%@",
                    detail ?: @"No detail", error ? [@"\n" stringByAppendingString:error.localizedDescription] : @""];
            self.loading = NO;
            [self updateSearchResultsForSearchController:self.searchController];
            [self.tableView reloadData];
        });
    });
}

- (NSMutableDictionary *)mutableArtworkDictionary
{
    if (!self.cacheExtra) return nil;
    NSString *key = @"oPeik/9e8lQWMszEjbPzng";
    id existing = self.cacheExtra[key];
    NSMutableDictionary *artwork = nil;
    if ([existing isKindOfClass:NSMutableDictionary.class]) artwork = existing;
    else if ([existing isKindOfClass:NSDictionary.class]) artwork = [existing mutableCopy];
    else artwork = [NSMutableDictionary dictionary];
    self.cacheExtra[key] = artwork;
    return artwork;
}

- (BOOL)featureEnabled:(NSDictionary *)feature
{
    NSString *kind = feature[@"kind"];
    NSArray *keys = feature[@"keys"];
    if ([kind isEqualToString:@"bool"]) {
        if (!keys.count) return NO;
        for (NSString *key in keys) if (![self.cacheExtra[key] boolValue]) return NO;
        return YES;
    }
    if ([kind isEqualToString:@"ipadapps"]) {
        NSArray *value = self.cacheExtra[keys.firstObject];
        return [value isKindOfClass:NSArray.class] && [value containsObject:@2];
    }
    if ([kind isEqualToString:@"internal"]) {
        int64_t a = 0, b = 0, c = 0;
        return GMReadCacheDataInt(self.plist, @"EqrsVvjcYDdxHBiQmGhAWw", &a) &&
               GMReadCacheDataInt(self.plist, @"Oji6HRoPi7rH7HPdWVakuw", &b) &&
               GMReadCacheDataInt(self.plist, @"LBJfwOEzExRxzlAnSuI7eg", &c) &&
               a == 1 && b == 1 && c == 1;
    }
    if ([kind isEqualToString:@"medusa"]) {
        NSArray *medusaKeys = @[@"mG0AnH/Vy1veoqoLRAIgTA", @"UCG5MkVahJxG1YULbbd5Bg",
                                @"ZYqko/XM5zD3XBfN5RmaXA", @"nVh/gwNpy7Jv1NOk00CMrw",
                                @"uKc7FPnEO++lVhHWHFlGbQ"];
        for (NSString *key in medusaKeys) if ([self.cacheExtra[key] integerValue] != 1) return NO;
        int64_t value = 0;
        return GMReadCacheDataInt(self.plist, @"mtrAoWJ3gsq+I90ZnQ0vQw", &value) && value == 3;
    }
    return NO;
}

- (void)setFeature:(NSDictionary *)feature enabled:(BOOL)enabled
{
    NSString *kind = feature[@"kind"];
    NSArray *keys = feature[@"keys"];
    if ([kind isEqualToString:@"bool"]) {
        for (NSString *key in keys) {
            if (enabled) self.cacheExtra[key] = @1;
            else [self.cacheExtra removeObjectForKey:key];
        }
    } else if ([kind isEqualToString:@"ipadapps"]) {
        NSString *key = keys.firstObject;
        if (enabled) self.cacheExtra[key] = @[@1, @2];
        else self.cacheExtra[key] = @[@1];
    } else if ([kind isEqualToString:@"internal"]) {
        BOOL a = GMWriteCacheDataInt(self.plist, @"EqrsVvjcYDdxHBiQmGhAWw", enabled ? 1 : 0);
        BOOL b = GMWriteCacheDataInt(self.plist, @"Oji6HRoPi7rH7HPdWVakuw", enabled ? 1 : 0);
        BOOL c = GMWriteCacheDataInt(self.plist, @"LBJfwOEzExRxzlAnSuI7eg", enabled ? 1 : 0);
        if (!(a && b && c)) [self showMessage:@"CacheData mapping unavailable" body:@"The required MobileGestalt CacheData offsets could not be resolved on this build."];
    } else if ([kind isEqualToString:@"medusa"]) {
        NSArray *medusaKeys = @[@"mG0AnH/Vy1veoqoLRAIgTA", @"UCG5MkVahJxG1YULbbd5Bg",
                                @"ZYqko/XM5zD3XBfN5RmaXA", @"nVh/gwNpy7Jv1NOk00CMrw",
                                @"uKc7FPnEO++lVhHWHFlGbQ"];
        (void)GMWriteCacheDataInt(self.plist, @"mtrAoWJ3gsq+I90ZnQ0vQw", enabled ? 3 : 1);
        for (NSString *key in medusaKeys) {
            if (enabled) self.cacheExtra[key] = @1;
            else [self.cacheExtra removeObjectForKey:key];
        }
    }
    self.dirty = YES;
    self.rawKeys = [[self.cacheExtra.allKeys filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(id key, NSDictionary *_) { return [key isKindOfClass:NSString.class]; }]]
        sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (void)featureSwitchChanged:(GMSwitch *)sender
{
    NSDictionary *feature = sender.feature;
    if ([feature[@"kind"] isEqualToString:@"medusa"] && sender.on) {
        UIAlertController *warning = [UIAlertController alertControllerWithTitle:@"Enable iPadOS UI / Multitasking?"
            message:@"This changes low-level MobileGestalt capability data. A bad value can make SpringBoard unstable."
            preferredStyle:UIAlertControllerStyleAlert];
        [warning addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) {
            sender.on = NO;
        }]];
        [warning addAction:[UIAlertAction actionWithTitle:@"Enable" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
            [self setFeature:feature enabled:YES];
            [self.tableView reloadData];
        }]];
        [self presentViewController:warning animated:YES completion:nil];
        return;
    }
    [self setFeature:feature enabled:sender.on];
    [self.tableView reloadData];
}

- (void)showMessage:(NSString *)title body:(NSString *)body
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:body
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)saveChanges
{
    if (!self.plist || !self.plistPath.length) return;
    NSError *error = nil;
    if (GMWriteValidatedPlist(self.plistPath, self.plist, &error)) {
        self.dirty = NO;
        [self showMessage:@"Gestalt saved" body:@"Changes were written and the resulting plist passed a read-back validation check."];
    } else {
        [self showMessage:@"Save failed" body:error.localizedDescription ?: @"Unknown write error"];
    }
    [self.tableView reloadData];
}

- (void)revertBackup
{
    NSData *backup = [NSData dataWithContentsOfFile:GMBackupPath()];
    if (!backup.length || !self.plistPath.length) {
        [self showMessage:@"No backup" body:@"A valid saved Gestalt backup is not available yet."];
        return;
    }
    NSError *error = nil;
    id parsed = [NSPropertyListSerialization propertyListWithData:backup options:0 format:nil error:&error];
    if (![parsed isKindOfClass:NSDictionary.class] || !GMDirectWrite(self.plistPath, backup, &error)) {
        [self showMessage:@"Revert failed" body:error.localizedDescription ?: @"Could not restore backup"];
        return;
    }
    [self showMessage:@"Gestalt restored" body:@"The saved original MobileGestalt plist was restored."];
    [self reloadFromDisk];
}

- (void)editIdentity
{
    NSMutableDictionary *artwork = [self mutableArtworkDictionary];
    NSString *subtype = [artwork[@"ArtworkDeviceSubType"] description] ?: @"";
    NSString *deviceName = artwork[@"ArtworkDeviceProductDescription"] ?: @"";
    NSString *productType = self.cacheExtra[@"h9jDsbgj7xIVeIQ8S3/X3Q"] ?: @"";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Device Identity"
        message:@"Edit only the fields you want to override." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"ArtworkDeviceSubType"; field.text = subtype; field.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Artwork device name"; field.text = deviceName;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Product type (for example iPhone17,3)"; field.text = productType;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Apply to editor" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *sub = alert.textFields[0].text;
        NSString *name = alert.textFields[1].text;
        NSString *product = alert.textFields[2].text;
        if (sub.length) artwork[@"ArtworkDeviceSubType"] = @([sub longLongValue]);
        else [artwork removeObjectForKey:@"ArtworkDeviceSubType"];
        if (name.length) artwork[@"ArtworkDeviceProductDescription"] = name;
        else [artwork removeObjectForKey:@"ArtworkDeviceProductDescription"];
        if (product.length) self.cacheExtra[@"h9jDsbgj7xIVeIQ8S3/X3Q"] = product;
        else [self.cacheExtra removeObjectForKey:@"h9jDsbgj7xIVeIQ8S3/X3Q"];
        self.dirty = YES;
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editRegion
{
    NSString *region = self.cacheExtra[@"h63QSdBCiT/z0WU6rdQv6Q"] ?: @"";
    NSString *model = self.cacheExtra[@"zHeENZu+wbg7PUprwNwBWg"] ?: @"";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Region Configuration"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Region code"; field.text = region; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Model region suffix"; field.text = model; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        [self.cacheExtra removeObjectForKey:@"h63QSdBCiT/z0WU6rdQv6Q"];
        [self.cacheExtra removeObjectForKey:@"zHeENZu+wbg7PUprwNwBWg"];
        self.dirty = YES; [self.tableView reloadData];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Apply to editor" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *r = alert.textFields[0].text; NSString *m = alert.textFields[1].text;
        if (r.length) self.cacheExtra[@"h63QSdBCiT/z0WU6rdQv6Q"] = r;
        if (m.length) self.cacheExtra[@"zHeENZu+wbg7PUprwNwBWg"] = m;
        self.dirty = YES; [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editKey:(NSString *)key displayName:(NSString *)displayName
{
    if (!key.length || !self.cacheExtra) return;
    id current = self.cacheExtra[key];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:displayName ?: key
        message:key preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current ? GMValueDescription(current) : @"";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        [self.cacheExtra removeObjectForKey:key]; self.dirty = YES; [self reloadKeyLists];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"false" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        self.cacheExtra[key] = @0; self.dirty = YES; [self reloadKeyLists];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"true" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        self.cacheExtra[key] = @1; self.dirty = YES; [self reloadKeyLists];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save value" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *text = alert.textFields.firstObject.text ?: @"";
        id value = text;
        if ([current isKindOfClass:NSNumber.class]) {
            NSScanner *scanner = [NSScanner scannerWithString:text];
            long long integer = 0;
            if ([scanner scanLongLong:&integer] && scanner.isAtEnd) value = @(integer);
            else value = @([text doubleValue]);
        } else if ([current isKindOfClass:NSArray.class] || [current isKindOfClass:NSDictionary.class] ||
                   [text hasPrefix:@"["] || [text hasPrefix:@"{"]) {
            NSData *jsonData = [text dataUsingEncoding:NSUTF8StringEncoding];
            id json = jsonData ? [NSJSONSerialization JSONObjectWithData:jsonData options:NSJSONReadingMutableContainers error:nil] : nil;
            if (json) value = json;
        } else if (!current) {
            NSString *lower = text.lowercaseString;
            if ([lower isEqualToString:@"true"]) value = @1;
            else if ([lower isEqualToString:@"false"]) value = @0;
            else {
                NSScanner *scanner = [NSScanner scannerWithString:text]; long long integer = 0;
                if ([scanner scanLongLong:&integer] && scanner.isAtEnd) value = @(integer);
            }
        }
        self.cacheExtra[key] = value ?: @""; self.dirty = YES; [self reloadKeyLists];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)reloadKeyLists
{
    self.rawKeys = [[self.cacheExtra.allKeys filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(id key, NSDictionary *_) { return [key isKindOfClass:NSString.class]; }]]
        sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [self updateSearchResultsForSearchController:self.searchController];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *term = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!term.length) {
        self.filteredKeys = self.rawKeys ?: @[];
        [self.tableView reloadData];
        return;
    }
    NSString *needle = term.lowercaseString;
    NSMutableArray *matches = [NSMutableArray array];
    for (NSString *key in self.rawKeys ?: @[]) {
        BOOL match = [key.lowercaseString containsString:needle];
        if (!match) {
            for (NSDictionary *record in GMIOS27Keys()) {
                if ([record[@"key"] isEqualToString:key] && [record[@"name"] lowercaseString] &&
                    [[record[@"name"] lowercaseString] containsString:needle]) { match = YES; break; }
            }
        }
        if (match) [matches addObject:key];
    }
    for (NSDictionary *record in GMIOS27Keys()) {
        NSString *key = record[@"key"];
        if ([matches containsObject:key]) continue;
        if ([key.lowercaseString containsString:needle] || [[record[@"name"] lowercaseString] containsString:needle])
            [matches addObject:key];
    }
    self.filteredKeys = matches;
    [self.tableView reloadData];
}

- (BOOL)isSearching
{
    return self.searchController.isActive && self.searchController.searchBar.text.length > 0;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return [self isSearching] ? 1 : 6;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if ([self isSearching]) return self.filteredKeys.count;
    switch (section) {
        case 0: return 3;
        case 1: return GMSoftwareFeatures().count;
        case 2: return GMHardwareFeatures().count;
        case 3: return 2;
        case 4: return GMIOS27Keys().count;
        case 5: return self.rawKeys.count;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if ([self isSearching]) return @"Matching Gestalt Keys";
    return @[@"Access & Actions", @"Software Features", @"Hardware / Eligibility / Internal",
             @"Device Identity", @"iOS 27 Key Catalog", @"CacheExtra Raw Keys"][section];
}

- (UITableViewCell *)valueCellForKey:(NSString *)key name:(NSString *)name
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = name ?: key;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  •  %@", key, GMValueDescription(self.cacheExtra[key])];
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (UITableViewCell *)featureCell:(NSDictionary *)feature
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = feature[@"name"];
    GMSwitch *toggle = [GMSwitch new];
    toggle.feature = feature;
    toggle.on = [self featureEnabled:feature];
    toggle.enabled = self.plist != nil && !self.loading;
    [toggle addTarget:self action:@selector(featureSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self isSearching]) {
        NSString *key = self.filteredKeys[indexPath.row];
        NSString *name = nil;
        for (NSDictionary *record in GMIOS27Keys()) if ([record[@"key"] isEqualToString:key]) { name = record[@"name"]; break; }
        return [self valueCellForKey:key name:name];
    }

    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        if (indexPath.row == 0) {
            cell.textLabel.text = self.loading ? @"Loading…" : (self.plist ? @"MobileGestalt Access Active" : @"MobileGestalt Access Unavailable");
            cell.detailTextLabel.text = self.accessDetail;
            cell.detailTextLabel.numberOfLines = 4;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = self.dirty ? @"Save Changes • Unsaved" : @"Save Changes";
            cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.down"];
            cell.textLabel.enabled = self.plist != nil;
        } else {
            cell.textLabel.text = @"Revert to Saved Original";
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.uturn.backward"];
            cell.textLabel.textColor = UIColor.systemOrangeColor;
        }
        return cell;
    }
    if (indexPath.section == 1) return [self featureCell:GMSoftwareFeatures()[indexPath.row]];
    if (indexPath.section == 2) return [self featureCell:GMHardwareFeatures()[indexPath.row]];
    if (indexPath.section == 3) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (indexPath.row == 0) {
            NSMutableDictionary *artwork = [self mutableArtworkDictionary];
            cell.textLabel.text = @"Artwork / Device Model";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"subtype=%@ • name=%@ • product=%@",
                artwork[@"ArtworkDeviceSubType"] ?: @"—", artwork[@"ArtworkDeviceProductDescription"] ?: @"—",
                self.cacheExtra[@"h9jDsbgj7xIVeIQ8S3/X3Q"] ?: @"—"];
        } else {
            cell.textLabel.text = @"Region Configuration";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@",
                self.cacheExtra[@"h63QSdBCiT/z0WU6rdQv6Q"] ?: @"—",
                self.cacheExtra[@"zHeENZu+wbg7PUprwNwBWg"] ?: @"—"];
        }
        return cell;
    }
    if (indexPath.section == 4) {
        NSDictionary *record = GMIOS27Keys()[indexPath.row];
        return [self valueCellForKey:record[@"key"] name:record[@"name"]];
    }
    NSString *key = self.rawKeys[indexPath.row];
    return [self valueCellForKey:key name:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self isSearching]) {
        NSString *key = self.filteredKeys[indexPath.row];
        NSString *name = nil;
        for (NSDictionary *record in GMIOS27Keys()) if ([record[@"key"] isEqualToString:key]) { name = record[@"name"]; break; }
        [self editKey:key displayName:name];
        return;
    }
    if (indexPath.section == 0) {
        if (indexPath.row == 1) [self saveChanges];
        else if (indexPath.row == 2) [self revertBackup];
        return;
    }
    if (indexPath.section == 3) {
        if (indexPath.row == 0) [self editIdentity]; else [self editRegion];
        return;
    }
    if (indexPath.section == 4) {
        NSDictionary *record = GMIOS27Keys()[indexPath.row];
        [self editKey:record[@"key"] displayName:record[@"name"]];
        return;
    }
    if (indexPath.section == 5) [self editKey:self.rawKeys[indexPath.row] displayName:nil];
}

@end

#pragma mark - Presentation

static UIViewController *GMActiveController(void)
{
    UIWindow *window = nil;
    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
        if (candidate.isKeyWindow) { window = candidate; break; }
        if (!window && !candidate.hidden) window = candidate;
    }
    UIViewController *controller = window.rootViewController;
    while (controller) {
        UIViewController *next = controller.presentedViewController;
        if (!next && [controller isKindOfClass:UINavigationController.class])
            next = ((UINavigationController *)controller).visibleViewController;
        if (!next && [controller isKindOfClass:UITabBarController.class])
            next = ((UITabBarController *)controller).selectedViewController;
        if (!next && [controller isKindOfClass:UISplitViewController.class])
            next = ((UISplitViewController *)controller).viewControllers.lastObject;
        if (!next || next == controller) break;
        controller = next;
    }
    return controller;
}

void FilzaGestaltManagerPresentFromController(UIViewController *source)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = source ?: GMActiveController();
        GestaltManagerController *manager = [GestaltManagerController new];
        if (presenter.navigationController && !presenter.presentedViewController) {
            [presenter.navigationController pushViewController:manager animated:YES];
        } else {
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:manager];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [presenter presentViewController:nav animated:YES completion:nil];
        }
    });
}

void FilzaGestaltManagerPresent(void)
{
    FilzaGestaltManagerPresentFromController(GMActiveController());
}

#pragma mark - Filza manager-menu insertion

static NSString *GMCellText(UITableViewCell *cell)
{
    if (cell.textLabel.text.length) return cell.textLabel.text;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:cell.contentView];
    while (stack.count) {
        UIView *view = stack.lastObject; [stack removeLastObject];
        if ([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length)
            return ((UILabel *)view).text;
        [stack addObjectsFromArray:view.subviews];
    }
    return @"";
}

static UIViewController *GMControllerForView(UIView *view)
{
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:UIViewController.class]) return (UIViewController *)responder;
        responder = responder.nextResponder;
    }
    return nil;
}

static NSIndexPath *GMOriginalIndexPath(NSIndexPath *requested)
{
    if (requested.section != gGMMenuSection || requested.row <= gGMMenuRow) return requested;
    return [NSIndexPath indexPathForRow:requested.row - 1 inSection:requested.section];
}

static NSInteger GMMenuRows(id self, SEL _cmd, UITableView *tableView, NSInteger section)
{
    NSInteger original = gGMOrigRows
        ? ((NSInteger (*)(id, SEL, id, NSInteger))gGMOrigRows)(self, _cmd, tableView, section) : 0;
    return section == gGMMenuSection ? original + 1 : original;
}

static UITableViewCell *GMMenuCell(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath)
{
    if (indexPath.section == gGMMenuSection && indexPath.row == gGMMenuRow) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = @"Gestalt Manager";
        cell.imageView.image = [UIImage systemImageNamed:@"slider.horizontal.3"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    NSIndexPath *mapped = GMOriginalIndexPath(indexPath);
    return gGMOrigCell ? ((id (*)(id, SEL, id, id))gGMOrigCell)(self, _cmd, tableView, mapped) : [UITableViewCell new];
}

static void GMMenuSelected(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath)
{
    if (indexPath.section == gGMMenuSection && indexPath.row == gGMMenuRow) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        FilzaGestaltManagerPresentFromController(GMControllerForView(tableView));
        return;
    }
    NSIndexPath *mapped = GMOriginalIndexPath(indexPath);
    if (gGMOrigSelect) ((void (*)(id, SEL, id, id))gGMOrigSelect)(self, _cmd, tableView, mapped);
}

static BOOL GMInstallMenuHooksForTable(UITableView *tableView)
{
    if (gGMMenuHooksInstalled || !tableView.dataSource) return gGMMenuHooksInstalled;
    id dataSource = tableView.dataSource;
    id delegate = tableView.delegate;
    NSInteger appsSection = NSNotFound, appsRow = NSNotFound;
    NSInteger musicSection = NSNotFound, musicRow = NSNotFound;

    NSInteger sections = [dataSource respondsToSelector:@selector(numberOfSectionsInTableView:)]
        ? [dataSource numberOfSectionsInTableView:tableView] : 1;
    sections = MIN(sections, 16);
    for (NSInteger section = 0; section < sections; section++) {
        NSInteger rows = [dataSource tableView:tableView numberOfRowsInSection:section];
        rows = MIN(rows, 64);
        for (NSInteger row = 0; row < rows; row++) {
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:section];
            UITableViewCell *cell = [dataSource tableView:tableView cellForRowAtIndexPath:indexPath];
            NSString *text = GMCellText(cell).lowercaseString;
            if ([text containsString:@"apps manager"] || [text containsString:@"appsmanager"]) {
                appsSection = section; appsRow = row;
            }
            if ([text containsString:@"music library"] || [text containsString:@"musiclibrary"]) {
                musicSection = section; musicRow = row;
            }
        }
    }

    if (musicSection == NSNotFound || appsSection == NSNotFound) return NO;
    gGMMenuSection = musicSection;
    gGMMenuRow = musicRow + 1;
    if (appsSection == musicSection) gGMMenuRow = MAX(appsRow, musicRow) + 1;

    Class dsClass = object_getClass(dataSource);
    Class delegateClass = delegate ? object_getClass(delegate) : Nil;
    SEL rowsSel = @selector(tableView:numberOfRowsInSection:);
    SEL cellSel = @selector(tableView:cellForRowAtIndexPath:);
    Method rowsMethod = class_getInstanceMethod(dsClass, rowsSel);
    Method cellMethod = class_getInstanceMethod(dsClass, cellSel);
    if (!rowsMethod || !cellMethod) return NO;

    gGMOrigRows = method_getImplementation(rowsMethod);
    gGMOrigCell = method_getImplementation(cellMethod);
    class_addMethod(dsClass, rowsSel, (IMP)GMMenuRows, method_getTypeEncoding(rowsMethod)) ||
        (method_setImplementation(class_getInstanceMethod(dsClass, rowsSel), (IMP)GMMenuRows), YES);
    class_addMethod(dsClass, cellSel, (IMP)GMMenuCell, method_getTypeEncoding(cellMethod)) ||
        (method_setImplementation(class_getInstanceMethod(dsClass, cellSel), (IMP)GMMenuCell), YES);

    if (delegateClass) {
        SEL selectSel = @selector(tableView:didSelectRowAtIndexPath:);
        Method selectMethod = class_getInstanceMethod(delegateClass, selectSel);
        if (selectMethod) {
            gGMOrigSelect = method_getImplementation(selectMethod);
            class_addMethod(delegateClass, selectSel, (IMP)GMMenuSelected, method_getTypeEncoding(selectMethod)) ||
                (method_setImplementation(class_getInstanceMethod(delegateClass, selectSel), (IMP)GMMenuSelected), YES);
        }
    }

    gGMMenuDataSourceClass = dsClass;
    gGMMenuDelegateClass = delegateClass;
    gGMMenuHooksInstalled = YES;
    NSLog(@"[GestaltManager] inserted manager menu section=%ld row=%ld dataSource=%@ delegate=%@",
          (long)gGMMenuSection, (long)gGMMenuRow, NSStringFromClass(dsClass), NSStringFromClass(delegateClass));
    [tableView reloadData];
    return YES;
}

static void GMScanViewsForMenu(UIView *view)
{
    if (gGMMenuHooksInstalled || !view) return;
    if ([view isKindOfClass:UITableView.class] && GMInstallMenuHooksForTable((UITableView *)view)) return;
    for (UIView *child in view.subviews) {
        GMScanViewsForMenu(child);
        if (gGMMenuHooksInstalled) return;
    }
}

static void GMScheduleMenuScan(NSUInteger attempts)
{
    if (attempts == 0 || gGMMenuHooksInstalled) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            GMScanViewsForMenu(window);
            if (gGMMenuHooksInstalled) break;
        }
        if (!gGMMenuHooksInstalled) GMScheduleMenuScan(attempts - 1);
    });
}

#pragma mark - Home Screen quick action

static void GMInstallShortcutItem(void)
{
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableArray *items = [NSMutableArray arrayWithArray:application.shortcutItems ?: @[]];
    for (UIApplicationShortcutItem *item in items) if ([item.type isEqualToString:GMShortcutType]) return;

    UIApplicationShortcutIcon *icon = nil;
    if (@available(iOS 13.0, *)) icon = [UIApplicationShortcutIcon iconWithSystemImageName:@"slider.horizontal.3"];
    UIApplicationShortcutItem *item = [[UIApplicationShortcutItem alloc]
        initWithType:GMShortcutType localizedTitle:@"Gestalt Manager"
        localizedSubtitle:@"Edit MobileGestalt" icon:icon userInfo:nil];
    [items addObject:item];
    application.shortcutItems = items;
    NSLog(@"[GestaltManager] Home Screen shortcut installed");
}

static void GMShortcutAction(id self, SEL _cmd, UIApplication *application,
                             UIApplicationShortcutItem *item,
                             void (^completion)(BOOL))
{
    if ([item.type isEqualToString:GMShortcutType]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            FilzaGestaltManagerPresent();
        });
        if (completion) completion(YES);
        return;
    }
    if (gGMOrigShortcut)
        ((void (*)(id, SEL, id, id, id))gGMOrigShortcut)(self, _cmd, application, item, completion);
    else if (completion) completion(NO);
}

static void GMInstallShortcutDelegateHook(void)
{
    if (gGMShortcutHookInstalled) return;
    id delegate = UIApplication.sharedApplication.delegate;
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    SEL selector = @selector(application:performActionForShortcutItem:completionHandler:);
    Method resolved = class_getInstanceMethod(cls, selector);
    if (resolved) {
        gGMOrigShortcut = method_getImplementation(resolved);
        if (!class_addMethod(cls, selector, (IMP)GMShortcutAction, method_getTypeEncoding(resolved)))
            method_setImplementation(class_getInstanceMethod(cls, selector), (IMP)GMShortcutAction);
    } else {
        class_addMethod(cls, selector, (IMP)GMShortcutAction, "v@:@@@?");
    }
    gGMShortcutHookInstalled = YES;
    NSLog(@"[GestaltManager] quick-action delegate hook installed on %@", NSStringFromClass(cls));
}

void FilzaGestaltManagerInstall(void)
{
    // Presentation is owned by the linked Mond surface and the unified
    // three-action router. Keep this controller as the verified access and
    // persistence provider without installing a second menu or shortcut.
    NSLog(@"[GestaltManager] verified access provider ready");
}

__attribute__((constructor)) static void GestaltManagerInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        FilzaGestaltManagerInstall();
    });
}
