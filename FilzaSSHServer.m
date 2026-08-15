@import Foundation;
@import Security;
@import UIKit;

#define LIBSSH_STATIC 1
#import <libssh/callbacks.h>
#import <libssh/libssh.h>
#import <libssh/server.h>

#import <CommonCrypto/CommonKeyDerivation.h>
#import <CommonCrypto/CommonCryptoError.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <sys/stat.h>
#import <sys/utsname.h>
#import <unistd.h>

#import "FilzaDiagnostics.h"
#import "FilzaSSHServer.h"

NSString * const FilzaSSHEnabledKey = @"filza-ssh-enabled";
NSString * const FilzaSSHPortKey = @"filza-ssh-port";
NSString * const FilzaSSHBonjourKey = @"filza-ssh-bonjour";
NSString * const FilzaSSHAuthenticationKey = @"filza-ssh-authentication";
NSString * const FilzaSSHUsernameKey = @"filza-ssh-username";
NSString * const FilzaSSHPasswordSaltKey = @"filza-ssh-password-salt";
NSString * const FilzaSSHPasswordHashKey = @"filza-ssh-password-pbkdf2";

static NSString * const FilzaSSHErrorDomain = @"FilzaSSH";
static dispatch_queue_t FilzaSSHListenerQueue;
static dispatch_queue_t FilzaSSHClientQueue;
static dispatch_source_t FilzaSSHAcceptSource;
static ssh_bind FilzaSSHBind = NULL;
static NSNetService *FilzaSSHBonjourService;
static _Atomic(bool) FilzaSSHRunning = false;
static _Atomic(uint_fast64_t) FilzaSSHGeneration = 1;
static dispatch_once_t FilzaSSHInitOnce;
static const void *FilzaSSHQueueKey = &FilzaSSHQueueKey;
static NSString *FilzaSSHFailure;

@interface FilzaSSHClientContext : NSObject {
@public
    ssh_session session;
    ssh_channel channel;
    struct ssh_server_callbacks_struct serverCallbacks;
    struct ssh_channel_callbacks_struct channelCallbacks;
}
@property(nonatomic) BOOL authenticated;
@property(nonatomic) BOOL interactive;
@property(nonatomic) BOOL shouldClose;
@property(nonatomic) BOOL lastWasCR;
@property(nonatomic) BOOL authenticationRequired;
@property(nonatomic, copy) NSString *username;
@property(nonatomic, copy) NSData *passwordSalt;
@property(nonatomic, copy) NSData *passwordHash;
@property(nonatomic, copy) NSString *currentDirectory;
@property(nonatomic, strong) NSMutableData *lineBuffer;
@end
@implementation FilzaSSHClientContext @end

static NSObject *FilzaSSHLock(void)
{
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = NSObject.new; });
    return lock;
}

static void FilzaSSHSetFailure(NSString *message)
{
    @synchronized (FilzaSSHLock()) { FilzaSSHFailure = [message copy]; }
    if (!message.length) return;
    FilzaDiagnosticsAppend(@"SSH", message);
    NSString *path = [FilzaDiagnosticsDirectory() stringByAppendingPathComponent:@"SSHStatus.txt"];
    NSString *timestamp = [NSISO8601DateFormatter.new stringFromDate:NSDate.date] ?: NSDate.date.description;
    [[NSString stringWithFormat:@"%@\n%@\n", timestamp, message]
        writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void FilzaSSHClearFailure(void)
{
    @synchronized (FilzaSSHLock()) { FilzaSSHFailure = nil; }
}

static void FilzaSSHInitialize(void)
{
    dispatch_once(&FilzaSSHInitOnce, ^{
        [NSUserDefaults.standardUserDefaults registerDefaults:@{
            FilzaSSHEnabledKey: @NO,
            FilzaSSHPortKey: @2222,
            FilzaSSHBonjourKey: @YES,
            FilzaSSHAuthenticationKey: @YES,
            FilzaSSHUsernameKey: @"filza"
        }];
        FilzaSSHListenerQueue = dispatch_queue_create("com.nightvibes33.filza.ssh.listener", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(FilzaSSHListenerQueue, FilzaSSHQueueKey, (void *)FilzaSSHQueueKey, NULL);
        FilzaSSHClientQueue = dispatch_queue_create("com.nightvibes33.filza.ssh.clients", DISPATCH_QUEUE_CONCURRENT);
        int rc = ssh_init();
        FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"libssh initialized rc=%d version=%s", rc, ssh_version(0) ?: "unknown"]);
    });
}

static void FilzaSSHSync(dispatch_block_t block)
{
    FilzaSSHInitialize();
    if (dispatch_get_specific(FilzaSSHQueueKey)) block();
    else dispatch_sync(FilzaSSHListenerQueue, block);
}

NSInteger FilzaSSHConfiguredPort(void)
{
    FilzaSSHInitialize();
    NSInteger port = [NSUserDefaults.standardUserDefaults integerForKey:FilzaSSHPortKey];
    return (port >= 1 && port <= 65535) ? port : 2222;
}

BOOL FilzaSSHBonjourEnabled(void)
{
    FilzaSSHInitialize();
    return [NSUserDefaults.standardUserDefaults boolForKey:FilzaSSHBonjourKey];
}

BOOL FilzaSSHAuthenticationEnabled(void)
{
    FilzaSSHInitialize();
    return [NSUserDefaults.standardUserDefaults boolForKey:FilzaSSHAuthenticationKey];
}

NSString *FilzaSSHConfiguredUsername(void)
{
    FilzaSSHInitialize();
    NSString *name = [NSUserDefaults.standardUserDefaults stringForKey:FilzaSSHUsernameKey];
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return name.length ? name : @"filza";
}

static NSData *FilzaSSHDecodeDefault(NSString *key)
{
    NSString *text = [NSUserDefaults.standardUserDefaults stringForKey:key];
    return text.length ? [[NSData alloc] initWithBase64EncodedString:text options:0] : nil;
}

static NSData *FilzaSSHDerivePassword(NSString *password, NSData *salt)
{
    if (!password || salt.length < 16) return nil;
    NSMutableData *derived = [NSMutableData dataWithLength:32];
    int rc = CCKeyDerivationPBKDF(kCCPBKDF2,
                                  password.UTF8String,
                                  [password lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                                  salt.bytes,
                                  salt.length,
                                  kCCPRFHmacAlgSHA256,
                                  120000,
                                  derived.mutableBytes,
                                  derived.length);
    return rc == kCCSuccess ? derived : nil;
}

static BOOL FilzaSSHConstantTimeEqual(NSData *left, NSData *right)
{
    if (!left || !right || left.length != right.length) return NO;
    const uint8_t *a = left.bytes, *b = right.bytes;
    uint8_t difference = 0;
    for (NSUInteger i = 0; i < left.length; i++) difference |= a[i] ^ b[i];
    return difference == 0;
}

BOOL FilzaSSHPasswordConfigured(void)
{
    return FilzaSSHDecodeDefault(FilzaSSHPasswordSaltKey).length >= 16 &&
           FilzaSSHDecodeDefault(FilzaSSHPasswordHashKey).length == 32;
}

BOOL FilzaSSHStorePassword(NSString *password, NSError **error)
{
    FilzaSSHInitialize();
    if (password.length < 6) {
        if (error) *error = [NSError errorWithDomain:FilzaSSHErrorDomain code:10 userInfo:@{NSLocalizedDescriptionKey: @"SSH password must contain at least 6 characters."}];
        return NO;
    }
    uint8_t saltBytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(saltBytes), saltBytes) != errSecSuccess) {
        if (error) *error = [NSError errorWithDomain:FilzaSSHErrorDomain code:11 userInfo:@{NSLocalizedDescriptionKey: @"Could not generate a secure password salt."}];
        return NO;
    }
    NSData *salt = [NSData dataWithBytes:saltBytes length:sizeof(saltBytes)];
    NSData *hash = FilzaSSHDerivePassword(password, salt);
    if (!hash) {
        if (error) *error = [NSError errorWithDomain:FilzaSSHErrorDomain code:12 userInfo:@{NSLocalizedDescriptionKey: @"Could not derive the SSH password verifier."}];
        return NO;
    }
    [NSUserDefaults.standardUserDefaults setObject:[salt base64EncodedStringWithOptions:0] forKey:FilzaSSHPasswordSaltKey];
    [NSUserDefaults.standardUserDefaults setObject:[hash base64EncodedStringWithOptions:0] forKey:FilzaSSHPasswordHashKey];
    FilzaDiagnosticsAppend(@"SSH", @"password verifier updated using PBKDF2-HMAC-SHA256");
    return YES;
}

static NSString *FilzaSSHHostKeyPath(NSError **error)
{
    NSString *root = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject.path;
    if (!root.length) root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    NSString *directory = [root stringByAppendingPathComponent:@"FilzaSSH"];
    NSError *mkdirError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                                 withIntermediateDirectories:YES
                                                  attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
                                                       error:&mkdirError]) {
        if (error) *error = mkdirError;
        return nil;
    }
    NSString *path = [directory stringByAppendingPathComponent:@"ssh_host_ed25519_key"];
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) return path;

    ssh_key key = NULL;
    if (ssh_pki_generate(SSH_KEYTYPE_ED25519, 0, &key) != SSH_OK || !key) {
        if (error) *error = [NSError errorWithDomain:FilzaSSHErrorDomain code:20 userInfo:@{NSLocalizedDescriptionKey: @"libssh could not generate an Ed25519 host key."}];
        if (key) ssh_key_free(key);
        return nil;
    }
    int rc = ssh_pki_export_privkey_file(key, NULL, NULL, NULL, path.fileSystemRepresentation);
    ssh_key_free(key);
    if (rc != SSH_OK) {
        if (error) *error = [NSError errorWithDomain:FilzaSSHErrorDomain code:21 userInfo:@{NSLocalizedDescriptionKey: @"libssh could not save the Ed25519 host key."}];
        return nil;
    }
    chmod(path.fileSystemRepresentation, S_IRUSR | S_IWUSR);
    FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"generated persistent Ed25519 host key at %@", path]);
    return path;
}

NSString *FilzaSSHServerLANAddress(void)
{
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0 || !list) return nil;
    NSString *fallback = nil, *preferred = nil;
    for (struct ifaddrs *cursor = list; cursor; cursor = cursor->ifa_next) {
        if (!cursor->ifa_addr || cursor->ifa_addr->sa_family != AF_INET) continue;
        if (!(cursor->ifa_flags & IFF_UP) || (cursor->ifa_flags & IFF_LOOPBACK)) continue;
        char buffer[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *address = (struct sockaddr_in *)cursor->ifa_addr;
        if (!inet_ntop(AF_INET, &address->sin_addr, buffer, sizeof(buffer))) continue;
        NSString *value = [NSString stringWithUTF8String:buffer];
        if (!fallback) fallback = value;
        if (cursor->ifa_name && strcmp(cursor->ifa_name, "en0") == 0) { preferred = value; break; }
    }
    freeifaddrs(list);
    return preferred ?: fallback;
}

static NSString *FilzaSSHInitialDirectory(void)
{
    Class cls = NSClassFromString(@"TGPreferences");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    id prefs = (cls && [cls respondsToSelector:shared]) ? ((id (*)(id, SEL))objc_msgSend)(cls, shared) : nil;
    SEL uploader = NSSelectorFromString(@"uploaderPath");
    NSString *candidate = (prefs && [prefs respondsToSelector:uploader]) ? ((id (*)(id, SEL))objc_msgSend)(prefs, uploader) : nil;
    BOOL directory = NO;
    if ([candidate isKindOfClass:NSString.class] && [NSFileManager.defaultManager fileExistsAtPath:candidate isDirectory:&directory] && directory)
        return candidate;
    return NSHomeDirectory();
}

static NSArray<NSString *> *FilzaSSHTokens(NSString *command)
{
    NSMutableArray<NSString *> *tokens = NSMutableArray.array;
    NSMutableString *current = NSMutableString.string;
    unichar quote = 0;
    BOOL escape = NO;
    for (NSUInteger i = 0; i < command.length; i++) {
        unichar ch = [command characterAtIndex:i];
        if (escape) { [current appendFormat:@"%C", ch]; escape = NO; continue; }
        if (ch == '\\') { escape = YES; continue; }
        if (quote) {
            if (ch == quote) quote = 0; else [current appendFormat:@"%C", ch];
            continue;
        }
        if (ch == '\'' || ch == '"') { quote = ch; continue; }
        if ([NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:ch]) {
            if (current.length) { [tokens addObject:current.copy]; [current setString:@""]; }
        } else [current appendFormat:@"%C", ch];
    }
    if (current.length) [tokens addObject:current.copy];
    return tokens;
}

static NSString *FilzaSSHResolve(NSString *operand, NSString *cwd)
{
    if (!operand.length || [operand isEqualToString:@"."]) return cwd;
    if ([operand isEqualToString:@"~"]) return NSHomeDirectory();
    if ([operand hasPrefix:@"~/"]) return [[NSHomeDirectory() stringByAppendingPathComponent:[operand substringFromIndex:2]] stringByStandardizingPath];
    if ([operand hasPrefix:@"/"]) return operand.stringByStandardizingPath;
    return [[cwd stringByAppendingPathComponent:operand] stringByStandardizingPath];
}

static NSString *FilzaSSHMode(mode_t mode)
{
    char text[11] = "----------";
    text[0] = S_ISDIR(mode) ? 'd' : S_ISLNK(mode) ? 'l' : '-';
    const mode_t bits[] = {S_IRUSR,S_IWUSR,S_IXUSR,S_IRGRP,S_IWGRP,S_IXGRP,S_IROTH,S_IWOTH,S_IXOTH};
    const char chars[] = {'r','w','x','r','w','x','r','w','x'};
    for (int i = 0; i < 9; i++) if (mode & bits[i]) text[i + 1] = chars[i];
    return [NSString stringWithUTF8String:text];
}

static NSString *FilzaSSHExecute(NSString *command, FilzaSSHClientContext *context, int *status, BOOL *closeSession)
{
    NSArray<NSString *> *args = FilzaSSHTokens(command ?: @"");
    if (!args.count) { if (status) *status = 0; return @""; }
    NSString *name = args[0];
    NSString *cwd = context.currentDirectory ?: NSHomeDirectory();
    NSFileManager *fm = NSFileManager.defaultManager;
    if (status) *status = 0;

    if ([name isEqualToString:@"help"]) return @"Commands: pwd cd ls cat stat mkdir touch cp mv rm chmod readlink df whoami id uname echo clear help exit\nThis is an in-process Filza shell. Filesystem access is exactly the access of the Filza process.\n";
    if ([name isEqualToString:@"exit"] || [name isEqualToString:@"logout"]) { if (closeSession) *closeSession = YES; return @"logout\n"; }
    if ([name isEqualToString:@"clear"]) return @"\033[2J\033[H";
    if ([name isEqualToString:@"pwd"]) return [cwd stringByAppendingString:@"\n"];
    if ([name isEqualToString:@"whoami"]) return [FilzaSSHConfiguredUsername() stringByAppendingString:@"\n"];
    if ([name isEqualToString:@"id"]) return [NSString stringWithFormat:@"uid=%u gid=%u euid=%u egid=%u\n", getuid(), getgid(), geteuid(), getegid()];
    if ([name isEqualToString:@"echo"]) return [NSString stringWithFormat:@"%@\n", args.count > 1 ? [[args subarrayWithRange:NSMakeRange(1, args.count - 1)] componentsJoinedByString:@" "] : @""];
    if ([name isEqualToString:@"uname"]) {
        struct utsname info = {0};
        if (uname(&info) != 0) { if (status) *status = 1; return [NSString stringWithFormat:@"uname: %s\n", strerror(errno)]; }
        return [NSString stringWithFormat:@"%s %s %s %s %s\n", info.sysname, info.nodename, info.release, info.version, info.machine];
    }
    if ([name isEqualToString:@"cd"]) {
        NSString *path = FilzaSSHResolve(args.count > 1 ? args[1] : @"~", cwd); BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) { if (status) *status = 1; return [NSString stringWithFormat:@"cd: %@: not a directory or inaccessible\n", path]; }
        context.currentDirectory = path; return @"";
    }
    if ([name isEqualToString:@"ls"]) {
        BOOL longForm = [args containsObject:@"-l"] || [args containsObject:@"-la"] || [args containsObject:@"-al"];
        BOOL hidden = [args containsObject:@"-a"] || [args containsObject:@"-la"] || [args containsObject:@"-al"];
        NSString *operand = nil;
        for (NSUInteger i = 1; i < args.count; i++) if (![args[i] hasPrefix:@"-"]) { operand = args[i]; break; }
        NSString *path = FilzaSSHResolve(operand ?: @".", cwd); BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir]) { if (status) *status = 1; return [NSString stringWithFormat:@"ls: %@: no such file or inaccessible\n", path]; }
        NSArray<NSString *> *items = isDir ? [fm contentsOfDirectoryAtPath:path error:nil] : @[path.lastPathComponent];
        items = [items sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        NSMutableString *out = NSMutableString.string;
        for (NSString *item in items) {
            if (!hidden && [item hasPrefix:@"."]) continue;
            NSString *full = isDir ? [path stringByAppendingPathComponent:item] : path;
            if (!longForm) { [out appendFormat:@"%@\n", item]; continue; }
            struct stat st = {0};
            if (lstat(full.fileSystemRepresentation, &st) == 0) [out appendFormat:@"%@ %4u %4u %10lld %@\n", FilzaSSHMode(st.st_mode), st.st_uid, st.st_gid, (long long)st.st_size, item];
            else [out appendFormat:@"%@\n", item];
        }
        return out;
    }
    if ([name isEqualToString:@"cat"]) {
        if (args.count < 2) { if (status) *status = 2; return @"cat: missing file operand\n"; }
        NSString *path = FilzaSSHResolve(args[1], cwd); NSError *error = nil;
        NSDictionary *attributes = [fm attributesOfItemAtPath:path error:&error];
        if (!attributes) { if (status) *status = 1; return [NSString stringWithFormat:@"cat: %@: %@\n", path, error.localizedDescription]; }
        if ([attributes[NSFileSize] unsignedLongLongValue] > 16ULL * 1024ULL * 1024ULL) { if (status) *status = 1; return @"cat: file exceeds the 16 MiB interactive-output limit\n"; }
        NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&error];
        if (!data) { if (status) *status = 1; return [NSString stringWithFormat:@"cat: %@: %@\n", path, error.localizedDescription]; }
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        return text ?: @"cat: binary/non-UTF8 data is not printed by the embedded shell\n";
    }
    if ([name isEqualToString:@"stat"]) {
        if (args.count < 2) { if (status) *status = 2; return @"stat: missing operand\n"; }
        NSString *path = FilzaSSHResolve(args[1], cwd); struct stat st = {0};
        if (lstat(path.fileSystemRepresentation, &st) != 0) { if (status) *status = 1; return [NSString stringWithFormat:@"stat: %@: %s\n", path, strerror(errno)]; }
        return [NSString stringWithFormat:@"File: %@\nSize: %lld\tMode: %04o\tUid: %u\tGid: %u\n", path, (long long)st.st_size, st.st_mode & 07777, st.st_uid, st.st_gid];
    }
    if ([name isEqualToString:@"mkdir"]) {
        BOOL parents = [args containsObject:@"-p"]; NSString *operand = args.lastObject;
        if (args.count < 2 || [operand hasPrefix:@"-"]) { if (status) *status = 2; return @"mkdir: missing operand\n"; }
        NSString *path = FilzaSSHResolve(operand, cwd); NSError *error = nil;
        if (![fm createDirectoryAtPath:path withIntermediateDirectories:parents attributes:nil error:&error]) { if (status) *status = 1; return [NSString stringWithFormat:@"mkdir: %@: %@\n", path, error.localizedDescription]; }
        return @"";
    }
    if ([name isEqualToString:@"touch"]) {
        if (args.count < 2) { if (status) *status = 2; return @"touch: missing operand\n"; }
        NSString *path = FilzaSSHResolve(args[1], cwd); int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT, 0644);
        if (fd < 0) { if (status) *status = 1; return [NSString stringWithFormat:@"touch: %@: %s\n", path, strerror(errno)]; }
        close(fd); [fm setAttributes:@{NSFileModificationDate: NSDate.date} ofItemAtPath:path error:nil]; return @"";
    }
    if ([name isEqualToString:@"cp"] || [name isEqualToString:@"mv"]) {
        if (args.count < 3) { if (status) *status = 2; return [NSString stringWithFormat:@"%@: missing source/destination\n", name]; }
        NSString *source = FilzaSSHResolve(args[1], cwd), *dest = FilzaSSHResolve(args[2], cwd); NSError *error = nil;
        BOOL ok = [name isEqualToString:@"cp"] ? [fm copyItemAtPath:source toPath:dest error:&error] : [fm moveItemAtPath:source toPath:dest error:&error];
        if (!ok) { if (status) *status = 1; return [NSString stringWithFormat:@"%@: %@ -> %@: %@\n", name, source, dest, error.localizedDescription]; }
        return @"";
    }
    if ([name isEqualToString:@"rm"]) {
        BOOL recursive = [args containsObject:@"-r"] || [args containsObject:@"-rf"] || [args containsObject:@"-fr"];
        NSString *operand = nil; for (NSUInteger i = 1; i < args.count; i++) if (![args[i] hasPrefix:@"-"]) { operand = args[i]; break; }
        if (!operand) { if (status) *status = 2; return @"rm: missing operand\n"; }
        NSString *path = FilzaSSHResolve(operand, cwd); BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir]) { if (status) *status = 1; return [NSString stringWithFormat:@"rm: %@: no such file or inaccessible\n", path]; }
        if (isDir && !recursive) { if (status) *status = 1; return @"rm: directory requires -r\n"; }
        NSError *error = nil; if (![fm removeItemAtPath:path error:&error]) { if (status) *status = 1; return [NSString stringWithFormat:@"rm: %@: %@\n", path, error.localizedDescription]; }
        return @"";
    }
    if ([name isEqualToString:@"chmod"]) {
        if (args.count < 3) { if (status) *status = 2; return @"chmod: usage chmod OCTAL PATH\n"; }
        char *end = NULL; long mode = strtol(args[1].UTF8String, &end, 8); NSString *path = FilzaSSHResolve(args[2], cwd);
        if (!end || *end || mode < 0 || mode > 07777) { if (status) *status = 2; return @"chmod: invalid octal mode\n"; }
        if (chmod(path.fileSystemRepresentation, (mode_t)mode) != 0) { if (status) *status = 1; return [NSString stringWithFormat:@"chmod: %@: %s\n", path, strerror(errno)]; }
        return @"";
    }
    if ([name isEqualToString:@"readlink"]) {
        if (args.count < 2) { if (status) *status = 2; return @"readlink: missing operand\n"; }
        NSString *path = FilzaSSHResolve(args[1], cwd); char target[PATH_MAX] = {0}; ssize_t count = readlink(path.fileSystemRepresentation, target, sizeof(target) - 1);
        if (count < 0) { if (status) *status = 1; return [NSString stringWithFormat:@"readlink: %@: %s\n", path, strerror(errno)]; }
        return [NSString stringWithFormat:@"%s\n", target];
    }
    if ([name isEqualToString:@"df"]) {
        NSString *path = FilzaSSHResolve(args.count > 1 ? args[1] : @".", cwd); NSError *error = nil;
        NSDictionary *fs = [fm attributesOfFileSystemForPath:path error:&error];
        if (!fs) { if (status) *status = 1; return [NSString stringWithFormat:@"df: %@: %@\n", path, error.localizedDescription]; }
        unsigned long long total = [fs[NSFileSystemSize] unsignedLongLongValue], free = [fs[NSFileSystemFreeSize] unsignedLongLongValue];
        return [NSString stringWithFormat:@"Filesystem\tSize\tUsed\tAvail\n%@\t%llu\t%llu\t%llu\n", path, total, total - free, free];
    }
    if (status) *status = 127;
    return [NSString stringWithFormat:@"%@: command not found (type help)\n", name];
}

static void FilzaSSHWrite(ssh_channel channel, NSString *text)
{
    if (!channel || !text.length || !ssh_channel_is_open(channel)) return;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *bytes = data.bytes; NSUInteger offset = 0;
    while (offset < data.length && ssh_channel_is_open(channel)) {
        uint32_t amount = (uint32_t)MIN((NSUInteger)32768, data.length - offset);
        int written = ssh_channel_write(channel, bytes + offset, amount);
        if (written <= 0) break;
        offset += (NSUInteger)written;
    }
}

static NSString *FilzaSSHPrompt(FilzaSSHClientContext *context)
{
    return [NSString stringWithFormat:@"filza:%@$ ", context.currentDirectory ?: @"?"];
}

static int FilzaSSHAuthNone(ssh_session session, const char *user, void *userdata)
{
    FilzaSSHClientContext *context = (__bridge FilzaSSHClientContext *)userdata;
    if (!context.authenticationRequired) { context.authenticated = YES; return SSH_AUTH_SUCCESS; }
    ssh_set_auth_methods(session, SSH_AUTH_METHOD_PASSWORD);
    return SSH_AUTH_DENIED;
}

static int FilzaSSHAuthPassword(__unused ssh_session session, const char *user, const char *password, void *userdata)
{
    FilzaSSHClientContext *context = (__bridge FilzaSSHClientContext *)userdata;
    NSString *suppliedUser = user ? [NSString stringWithUTF8String:user] : @"";
    NSString *suppliedPassword = password ? [NSString stringWithUTF8String:password] : @"";
    NSData *derived = FilzaSSHDerivePassword(suppliedPassword, context.passwordSalt);
    BOOL accepted = [suppliedUser isEqualToString:context.username] && FilzaSSHConstantTimeEqual(derived, context.passwordHash);
    FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"password authentication user=%@ result=%@", suppliedUser, accepted ? @"accepted" : @"denied"]);
    if (accepted) { context.authenticated = YES; return SSH_AUTH_SUCCESS; }
    return SSH_AUTH_DENIED;
}

static int FilzaSSHPty(__unused ssh_session session, __unused ssh_channel channel, __unused const char *term,
                       __unused int width, __unused int height, __unused int pxwidth, __unused int pxheight, __unused void *userdata)
{ return 0; }

static int FilzaSSHShell(__unused ssh_session session, ssh_channel channel, void *userdata)
{
    FilzaSSHClientContext *context = (__bridge FilzaSSHClientContext *)userdata;
    if (!context.authenticated) return 1;
    context.interactive = YES;
    FilzaDiagnosticsAppend(@"SSH", @"interactive embedded Filza shell opened");
    FilzaSSHWrite(channel, [NSString stringWithFormat:@"Filza embedded SSH shell (%s)\r\nNot a root shell; access equals the Filza process. Type help.\r\n%@", ssh_version(0) ?: "libssh", FilzaSSHPrompt(context)]);
    return 0;
}

static int FilzaSSHExec(__unused ssh_session session, ssh_channel channel, const char *command, void *userdata)
{
    FilzaSSHClientContext *context = (__bridge FilzaSSHClientContext *)userdata;
    if (!context.authenticated || !command) return 1;
    int status = 0; BOOL closeSession = NO;
    NSString *text = [NSString stringWithUTF8String:command] ?: @"";
    FilzaSSHWrite(channel, FilzaSSHExecute(text, context, &status, &closeSession));
    ssh_channel_request_send_exit_status(channel, status);
    ssh_channel_send_eof(channel);
    context.shouldClose = YES;
    return 0;
}

static int FilzaSSHSubsystem(__unused ssh_session session, __unused ssh_channel channel, const char *subsystem, __unused void *userdata)
{
    FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"subsystem rejected because it is not implemented yet: %s", subsystem ?: "unknown"]);
    return 1;
}

static void FilzaSSHProcessInteractiveLine(FilzaSSHClientContext *context, ssh_channel channel)
{
    NSString *command = [[NSString alloc] initWithData:context.lineBuffer encoding:NSUTF8StringEncoding] ?: @"";
    [context.lineBuffer setLength:0];
    int status = 0; BOOL closeSession = NO;
    NSString *output = FilzaSSHExecute(command, context, &status, &closeSession);
    FilzaSSHWrite(channel, [[output stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\n" withString:@"\r\n"]);
    if (closeSession) {
        ssh_channel_request_send_exit_status(channel, status);
        ssh_channel_send_eof(channel);
        context.shouldClose = YES;
    } else FilzaSSHWrite(channel, FilzaSSHPrompt(context));
}

static int FilzaSSHChannelData(__unused ssh_session session, ssh_channel channel, void *data, uint32_t length, int isStderr, void *userdata)
{
    FilzaSSHClientContext *context = (__bridge FilzaSSHClientContext *)userdata;
    if (!context.interactive || isStderr || !data) return (int)length;
    const uint8_t *bytes = data;
    for (uint32_t i = 0; i < length; i++) {
        uint8_t byte = bytes[i];
        if (byte == 3) { [context.lineBuffer setLength:0]; FilzaSSHWrite(channel, @"^C\r\n"); FilzaSSHWrite(channel, FilzaSSHPrompt(context)); context.lastWasCR = NO; continue; }
        if (byte == 8 || byte == 127) { if (context.lineBuffer.length) { [context.lineBuffer setLength:context.lineBuffer.length - 1]; FilzaSSHWrite(channel, @"\b \b"); } context.lastWasCR = NO; continue; }
        if (byte == '\r') { FilzaSSHWrite(channel, @"\r\n"); FilzaSSHProcessInteractiveLine(context, channel); context.lastWasCR = YES; continue; }
        if (byte == '\n') { if (context.lastWasCR) { context.lastWasCR = NO; continue; } FilzaSSHWrite(channel, @"\r\n"); FilzaSSHProcessInteractiveLine(context, channel); continue; }
        context.lastWasCR = NO;
        [context.lineBuffer appendBytes:&byte length:1];
        FilzaSSHWrite(channel, [[NSString alloc] initWithBytes:&byte length:1 encoding:NSUTF8StringEncoding] ?: @"");
    }
    return (int)length;
}

static void FilzaSSHChannelClose(__unused ssh_session session, __unused ssh_channel channel, void *userdata)
{
    ((__bridge FilzaSSHClientContext *)userdata).shouldClose = YES;
}

static ssh_channel FilzaSSHOpenSessionChannel(ssh_session session, void *userdata)
{
    FilzaSSHClientContext *context = (__bridge FilzaSSHClientContext *)userdata;
    if (!context.authenticated || context->channel) return NULL;
    ssh_channel channel = ssh_channel_new(session);
    if (!channel) return NULL;
    context->channel = channel;
    memset(&context->channelCallbacks, 0, sizeof(context->channelCallbacks));
    context->channelCallbacks.userdata = (__bridge void *)context;
    context->channelCallbacks.channel_data_function = FilzaSSHChannelData;
    context->channelCallbacks.channel_close_function = FilzaSSHChannelClose;
    context->channelCallbacks.channel_pty_request_function = FilzaSSHPty;
    context->channelCallbacks.channel_shell_request_function = FilzaSSHShell;
    context->channelCallbacks.channel_exec_request_function = FilzaSSHExec;
    context->channelCallbacks.channel_subsystem_request_function = FilzaSSHSubsystem;
    ssh_callbacks_init(&context->channelCallbacks);
    ssh_set_channel_callbacks(channel, &context->channelCallbacks);
    return channel;
}

static void FilzaSSHServeSession(ssh_session session, uint64_t generation)
{
    @autoreleasepool {
        FilzaSSHClientContext *context = FilzaSSHClientContext.new;
        context->session = session;
        context.currentDirectory = FilzaSSHInitialDirectory();
        context.lineBuffer = NSMutableData.data;
        context.username = FilzaSSHConfiguredUsername();
        context.authenticationRequired = FilzaSSHAuthenticationEnabled();
        context.passwordSalt = FilzaSSHDecodeDefault(FilzaSSHPasswordSaltKey);
        context.passwordHash = FilzaSSHDecodeDefault(FilzaSSHPasswordHashKey);

        memset(&context->serverCallbacks, 0, sizeof(context->serverCallbacks));
        context->serverCallbacks.userdata = (__bridge void *)context;
        context->serverCallbacks.auth_none_function = FilzaSSHAuthNone;
        context->serverCallbacks.auth_password_function = FilzaSSHAuthPassword;
        context->serverCallbacks.channel_open_request_session_function = FilzaSSHOpenSessionChannel;
        ssh_callbacks_init(&context->serverCallbacks);
        ssh_set_server_callbacks(session, &context->serverCallbacks);
        if (context.authenticationRequired) ssh_set_auth_methods(session, SSH_AUTH_METHOD_PASSWORD);

        if (ssh_handle_key_exchange(session) != SSH_OK) {
            FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"key exchange failed: %s", ssh_get_error(session)]);
            ssh_disconnect(session); ssh_free(session); return;
        }

        ssh_event event = ssh_event_new();
        if (!event || ssh_event_add_session(event, session) != SSH_OK) {
            FilzaDiagnosticsAppend(@"SSH", @"could not create libssh session event loop");
            if (event) ssh_event_free(event);
            ssh_disconnect(session); ssh_free(session); return;
        }

        FilzaDiagnosticsAppend(@"SSH", @"incoming SSH connection entered authenticated event loop");
        while (atomic_load(&FilzaSSHRunning) && atomic_load(&FilzaSSHGeneration) == generation &&
               ssh_is_connected(session) && !context.shouldClose) {
            int rc = ssh_event_dopoll(event, 250);
            if (rc == SSH_ERROR) {
                FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"session event loop failed: %s", ssh_get_error(session)]);
                break;
            }
        }

        if (context->channel) {
            if (ssh_channel_is_open(context->channel)) ssh_channel_close(context->channel);
            ssh_channel_free(context->channel);
            context->channel = NULL;
        }
        ssh_event_remove_session(event, session);
        ssh_event_free(event);
        ssh_disconnect(session);
        ssh_free(session);
        FilzaDiagnosticsAppend(@"SSH", @"SSH client session closed");
    }
}

static void FilzaSSHAcceptAvailable(void)
{
    if (!atomic_load(&FilzaSSHRunning) || !FilzaSSHBind) return;
    ssh_session session = ssh_new();
    if (!session) return;
    int rc = ssh_bind_accept(FilzaSSHBind, session);
    if (rc != SSH_OK) {
        FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"accept failed: %s", ssh_get_error(FilzaSSHBind)]);
        ssh_free(session);
        return;
    }
    uint64_t generation = atomic_load(&FilzaSSHGeneration);
    dispatch_async(FilzaSSHClientQueue, ^{ FilzaSSHServeSession(session, generation); });
}

static void FilzaSSHStopLocked(void)
{
    atomic_store(&FilzaSSHRunning, false);
    atomic_fetch_add(&FilzaSSHGeneration, 1);
    if (FilzaSSHBonjourService) { [FilzaSSHBonjourService stop]; FilzaSSHBonjourService = nil; }
    if (FilzaSSHAcceptSource) { dispatch_source_cancel(FilzaSSHAcceptSource); FilzaSSHAcceptSource = nil; }
    if (FilzaSSHBind) { ssh_bind_free(FilzaSSHBind); FilzaSSHBind = NULL; }
    FilzaDiagnosticsAppend(@"SSH", @"embedded SSH listener stopped");
}

BOOL FilzaSSHServerStart(NSError **error)
{
    __block BOOL success = NO;
    __block NSError *failure = nil;
    FilzaSSHSync(^{
        if (atomic_load(&FilzaSSHRunning)) { success = YES; return; }
        if (FilzaSSHAuthenticationEnabled() && !FilzaSSHPasswordConfigured()) {
            failure = [NSError errorWithDomain:FilzaSSHErrorDomain code:30 userInfo:@{NSLocalizedDescriptionKey: @"Authentication is enabled but no SSH password is configured."}];
            FilzaSSHSetFailure(failure.localizedDescription); return;
        }

        NSError *keyError = nil;
        NSString *hostKey = FilzaSSHHostKeyPath(&keyError);
        if (!hostKey.length) { failure = keyError; FilzaSSHSetFailure(failure.localizedDescription); return; }

        ssh_bind bind = ssh_bind_new();
        if (!bind) {
            failure = [NSError errorWithDomain:FilzaSSHErrorDomain code:31 userInfo:@{NSLocalizedDescriptionKey: @"libssh could not allocate a server bind."}];
            FilzaSSHSetFailure(failure.localizedDescription); return;
        }
        int port = (int)FilzaSSHConfiguredPort();
        const char *address = "0.0.0.0";
        const char *keyPath = hostKey.fileSystemRepresentation;
        if (ssh_bind_options_set(bind, SSH_BIND_OPTIONS_BINDADDR, address) != SSH_OK ||
            ssh_bind_options_set(bind, SSH_BIND_OPTIONS_BINDPORT, &port) != SSH_OK ||
            ssh_bind_options_set(bind, SSH_BIND_OPTIONS_HOSTKEY, keyPath) != SSH_OK ||
            ssh_bind_listen(bind) != SSH_OK) {
            NSString *message = [NSString stringWithFormat:@"libssh failed to listen on port %d: %s", port, ssh_get_error(bind) ?: "unknown error"];
            failure = [NSError errorWithDomain:FilzaSSHErrorDomain code:32 userInfo:@{NSLocalizedDescriptionKey: message}];
            ssh_bind_free(bind); FilzaSSHSetFailure(message); return;
        }

        socket_t fd = ssh_bind_get_fd(bind);
        if (fd < 0) {
            failure = [NSError errorWithDomain:FilzaSSHErrorDomain code:33 userInfo:@{NSLocalizedDescriptionKey: @"libssh listener has no usable socket."}];
            ssh_bind_free(bind); FilzaSSHSetFailure(failure.localizedDescription); return;
        }

        FilzaSSHBind = bind;
        atomic_store(&FilzaSSHRunning, true);
        FilzaSSHAcceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, FilzaSSHListenerQueue);
        dispatch_source_set_event_handler(FilzaSSHAcceptSource, ^{ FilzaSSHAcceptAvailable(); });
        dispatch_resume(FilzaSSHAcceptSource);

        if (FilzaSSHBonjourEnabled()) {
            FilzaSSHBonjourService = [[NSNetService alloc] initWithDomain:@"local." type:@"_ssh._tcp." name:@"Filza SSH" port:port];
            [FilzaSSHBonjourService publish];
        }
        FilzaSSHClearFailure();
        NSString *addressText = FilzaSSHServerLANAddress() ?: @"0.0.0.0";
        FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"embedded libssh server listening address=%@ port=%d auth=%@", addressText, port, FilzaSSHAuthenticationEnabled() ? @"YES" : @"NO"]);
        success = YES;
    });
    if (!success && error) *error = failure ?: [NSError errorWithDomain:FilzaSSHErrorDomain code:99 userInfo:@{NSLocalizedDescriptionKey: @"SSH server failed to start."}];
    return success;
}

void FilzaSSHServerStop(void)
{
    FilzaSSHSync(^{ FilzaSSHStopLocked(); });
}

BOOL FilzaSSHServerRestart(NSError **error)
{
    FilzaSSHServerStop();
    return FilzaSSHServerStart(error);
}

BOOL FilzaSSHServerIsRunning(void)
{
    FilzaSSHInitialize();
    return atomic_load(&FilzaSSHRunning);
}

NSString *FilzaSSHServerLastError(void)
{
    @synchronized (FilzaSSHLock()) { return [FilzaSSHFailure copy]; }
}

NSString *FilzaSSHServerConnectionSummary(void)
{
    if (!FilzaSSHServerIsRunning()) return FilzaSSHServerLastError() ?: @"Not listening";
    NSString *address = FilzaSSHServerLANAddress() ?: @"iPhone";
    return [NSString stringWithFormat:@"Listening at ssh://%@:%ld\nssh %@@%@ -p %ld", address, (long)FilzaSSHConfiguredPort(), FilzaSSHConfiguredUsername(), address, (long)FilzaSSHConfiguredPort()];
}
