@import Foundation;
@import Security;
@import UIKit;

#import <CommonCrypto/CommonCrypto.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/utsname.h>
#import <unistd.h>

#include <wolfssl/options.h>
#include <wolfssl/wolfcrypt/asn.h>
#include <wolfssl/wolfcrypt/ecc.h>
#include <wolfssl/wolfcrypt/random.h>
#include <wolfssh/ssh.h>
#include <wolfssh/wolfsftp.h>

#import "FilzaDiagnostics.h"
#import "FilzaSSHServer.h"

NSString * const FilzaSSHEnabledKey = @"filza-ssh-enabled";
NSString * const FilzaSSHPortKey = @"filza-ssh-port";
NSString * const FilzaSSHBonjourKey = @"filza-ssh-bonjour";
NSString * const FilzaSSHAuthenticationKey = @"filza-ssh-authentication";
NSString * const FilzaSSHUsernameKey = @"filza-ssh-username";
NSString * const FilzaSSHPasswordSaltKey = @"filza-ssh-password-salt";
NSString * const FilzaSSHPasswordHashKey = @"filza-ssh-password-pbkdf2";

static NSString * const FilzaSSHErrorDomain = @"FilzaWolfSSH";
static dispatch_queue_t FilzaSSHListenerQueue;
static dispatch_queue_t FilzaSSHClientQueue;
static dispatch_source_t FilzaSSHAcceptSource;
static NSNetService *FilzaSSHBonjourService;
static _Atomic(bool) FilzaSSHRunning = false;
static int FilzaSSHListenFD = -1;
static dispatch_once_t FilzaSSHInitOnce;
static const void *FilzaSSHQueueKey = &FilzaSSHQueueKey;
static NSString *FilzaSSHFailure;
static AVAudioPlayer *FilzaSSHKeepAlivePlayer;
static id FilzaSSHInterruptionObserver;
static id FilzaSSHForegroundObserver;
static id FilzaSSHBackgroundObserver;
static _Atomic(bool) FilzaSSHKeepAliveActive = false;

typedef struct __attribute__((packed)) {
    char riff[4];
    uint32_t riffSize;
    char wave[4];
    char fmt[4];
    uint32_t fmtSize;
    uint16_t audioFormat;
    uint16_t channels;
    uint32_t sampleRate;
    uint32_t byteRate;
    uint16_t blockAlign;
    uint16_t bitsPerSample;
    char data[4];
    uint32_t dataSize;
} FilzaSSHSilentWAVHeader;

static NSData *FilzaSSHSilentAudioData(void)
{
    const uint32_t sampleRate = 8000;
    const uint16_t channels = 1;
    const uint16_t bits = 16;
    const uint32_t dataSize = sampleRate * channels * (bits / 8);
    FilzaSSHSilentWAVHeader header = {0};
    memcpy(header.riff, "RIFF", 4);
    header.riffSize = 36 + dataSize;
    memcpy(header.wave, "WAVE", 4);
    memcpy(header.fmt, "fmt ", 4);
    header.fmtSize = 16;
    header.audioFormat = 1;
    header.channels = channels;
    header.sampleRate = sampleRate;
    header.byteRate = sampleRate * channels * (bits / 8);
    header.blockAlign = channels * (bits / 8);
    header.bitsPerSample = bits;
    memcpy(header.data, "data", 4);
    header.dataSize = dataSize;
    NSMutableData *wav = [NSMutableData dataWithBytes:&header length:sizeof(header)];
    [wav increaseLengthBy:dataSize];
    return wav;
}

static BOOL FilzaSSHBackgroundKeepAliveStart(void)
{
    if (FilzaSSHKeepAlivePlayer.isPlaying) {
        atomic_store(&FilzaSSHKeepAliveActive, true);
        return YES;
    }

    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    if (![session setCategory:AVAudioSessionCategoryPlayback
                         mode:AVAudioSessionModeDefault
                      options:AVAudioSessionCategoryOptionMixWithOthers
                        error:&error] ||
        ![session setActive:YES error:&error]) {
        atomic_store(&FilzaSSHKeepAliveActive, false);
        FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"background keepalive audio session failed: %@", error.localizedDescription]);
        return NO;
    }

    FilzaSSHKeepAlivePlayer = [[AVAudioPlayer alloc] initWithData:FilzaSSHSilentAudioData() error:&error];
    FilzaSSHKeepAlivePlayer.numberOfLoops = -1;
    FilzaSSHKeepAlivePlayer.volume = 0.01f;
    [FilzaSSHKeepAlivePlayer prepareToPlay];
    BOOL started = [FilzaSSHKeepAlivePlayer play];
    atomic_store(&FilzaSSHKeepAliveActive, started);
    FilzaDiagnosticsAppend(@"SSH", started
        ? @"silent-audio background keepalive active for wolfSSH"
        : [NSString stringWithFormat:@"background keepalive player failed: %@", error.localizedDescription ?: @"play returned NO"]);
    return started;
}

static void FilzaSSHBackgroundKeepAliveStop(void)
{
    [FilzaSSHKeepAlivePlayer stop];
    FilzaSSHKeepAlivePlayer = nil;
    atomic_store(&FilzaSSHKeepAliveActive, false);
    FilzaDiagnosticsAppend(@"SSH", @"wolfSSH background keepalive stopped");
}

static NSObject *FilzaSSHLock(void)
{
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = NSObject.new; });
    return lock;
}

static void FilzaSSHWriteStatus(NSString *message)
{
    NSString *path = [FilzaDiagnosticsDirectory() stringByAppendingPathComponent:@"SSHStatus.txt"];
    NSString *timestamp = [NSISO8601DateFormatter.new stringFromDate:NSDate.date] ?: NSDate.date.description;
    [[NSString stringWithFormat:@"%@\n%@\n", timestamp, message ?: @"unknown"]
        writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void FilzaSSHSetFailure(NSString *message)
{
    @synchronized (FilzaSSHLock()) { FilzaSSHFailure = [message copy]; }
    if (!message.length) return;
    FilzaDiagnosticsAppend(@"SSH", message);
    FilzaSSHWriteStatus(message);
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
        FilzaSSHListenerQueue = dispatch_queue_create("com.nightvibes33.filza.wolfssh.listener", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(FilzaSSHListenerQueue, FilzaSSHQueueKey, (void *)FilzaSSHQueueKey, NULL);
        FilzaSSHClientQueue = dispatch_queue_create("com.nightvibes33.filza.wolfssh.clients", DISPATCH_QUEUE_CONCURRENT);
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        FilzaSSHInterruptionObserver = [center addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            AVAudioSessionInterruptionType type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
            if (type == AVAudioSessionInterruptionTypeEnded && atomic_load(&FilzaSSHRunning))
                dispatch_async(FilzaSSHListenerQueue, ^{ FilzaSSHBackgroundKeepAliveStart(); });
        }];
        FilzaSSHForegroundObserver = [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            if (atomic_load(&FilzaSSHRunning))
                dispatch_async(FilzaSSHListenerQueue, ^{ FilzaSSHBackgroundKeepAliveStart(); });
        }];
        FilzaSSHBackgroundObserver = [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            if (atomic_load(&FilzaSSHRunning))
                dispatch_async(FilzaSSHListenerQueue, ^{
                    BOOL active = FilzaSSHBackgroundKeepAliveStart();
                    FilzaDiagnosticsAppend(@"SSH", active ? @"wolfSSH entered background with keepalive active" : @"wolfSSH entered background without keepalive");
                });
        }];
        int rc = wolfSSH_Init();
        FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"wolfSSH initialized rc=%d backend=wolfSSH SFTP=enabled", rc]);
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
    FilzaDiagnosticsAppend(@"SSH", @"wolfSSH password verifier updated using PBKDF2-HMAC-SHA256");
    return YES;
}

static NSString *FilzaSSHHostKeyPath(void)
{
    NSString *root = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject.path;
    if (!root.length) root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    NSString *directory = [root stringByAppendingPathComponent:@"FilzaSSH"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
                                                  error:nil];
    return [directory stringByAppendingPathComponent:@"wolfssh_host_ecc.der"];
}

static NSData *FilzaSSHHostKey(NSError **error)
{
    NSString *path = FilzaSSHHostKeyPath();
    NSData *existing = [NSData dataWithContentsOfFile:path];
    if (existing.length > 32) return existing;

    WC_RNG rng;
    ecc_key key;
    XMEMSET(&rng, 0, sizeof(rng));
    XMEMSET(&key, 0, sizeof(key));
    int rc = wc_InitRng(&rng);
    if (rc == 0) rc = wc_ecc_init(&key);
    if (rc == 0) rc = wc_ecc_make_key(&rng, 32, &key);
    byte der[2048];
    int derSz = rc == 0 ? wc_EccKeyToDer(&key, der, (word32)sizeof(der)) : rc;
    wc_ecc_free(&key);
    wc_FreeRng(&rng);
    if (derSz <= 0) {
        if (error) *error = [NSError errorWithDomain:FilzaSSHErrorDomain code:20 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"wolfCrypt could not generate host key (%d).", derSz]}];
        return nil;
    }
    NSData *data = [NSData dataWithBytes:der length:(NSUInteger)derSz];
    if (![data writeToFile:path options:NSDataWritingAtomic error:error]) return nil;
    chmod(path.fileSystemRepresentation, S_IRUSR | S_IWUSR);
    FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"generated persistent wolfSSH ECDSA host key at %@", path]);
    return data;
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
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return documents.length ? documents : NSHomeDirectory();
}

static int FilzaWolfSSHUserAuth(byte authType, WS_UserAuthData *authData, void *ctx)
{
    (void)ctx;
    if (!authData) return WOLFSSH_USERAUTH_FAILURE;
    if (!FilzaSSHAuthenticationEnabled()) return WOLFSSH_USERAUTH_SUCCESS;
    if (authType != WOLFSSH_USERAUTH_PASSWORD) return WOLFSSH_USERAUTH_FAILURE;

    NSData *usernameData = [NSData dataWithBytes:authData->username length:authData->usernameSz];
    NSString *username = [[NSString alloc] initWithData:usernameData encoding:NSUTF8StringEncoding];
    if (![username isEqualToString:FilzaSSHConfiguredUsername()]) return WOLFSSH_USERAUTH_FAILURE;

    NSData *passwordData = [NSData dataWithBytes:authData->sf.password.password length:authData->sf.password.passwordSz];
    NSString *password = [[NSString alloc] initWithData:passwordData encoding:NSUTF8StringEncoding];
    NSData *salt = FilzaSSHDecodeDefault(FilzaSSHPasswordSaltKey);
    NSData *expected = FilzaSSHDecodeDefault(FilzaSSHPasswordHashKey);
    NSData *actual = password ? FilzaSSHDerivePassword(password, salt) : nil;
    return FilzaSSHConstantTimeEqual(actual, expected) ? WOLFSSH_USERAUTH_SUCCESS : WOLFSSH_USERAUTH_FAILURE;
}

static NSArray<NSString *> *FilzaSSHTokens(NSString *command)
{
    NSMutableArray<NSString *> *tokens = NSMutableArray.array;
    for (NSString *part in [command componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet])
        if (part.length) [tokens addObject:part];
    return tokens;
}

static NSString *FilzaSSHResolve(NSString *operand, NSString *cwd)
{
    if (!operand.length || [operand isEqualToString:@"."]) return cwd;
    if ([operand isEqualToString:@"~"]) return FilzaSSHInitialDirectory();
    if ([operand hasPrefix:@"~/"]) return [[FilzaSSHInitialDirectory() stringByAppendingPathComponent:[operand substringFromIndex:2]] stringByStandardizingPath];
    if ([operand hasPrefix:@"/"]) return operand.stringByStandardizingPath;
    return [[cwd stringByAppendingPathComponent:operand] stringByStandardizingPath];
}

static NSString *FilzaSSHExecute(NSString *command, NSString **cwd, BOOL *shouldClose)
{
    NSArray<NSString *> *args = FilzaSSHTokens(command ?: @"");
    if (!args.count) return @"";
    NSString *name = args[0];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *current = *cwd ?: FilzaSSHInitialDirectory();

    if ([name isEqualToString:@"help"]) return @"Commands: pwd cd ls cat mkdir touch cp mv rm whoami id uname echo help exit\r\nSFTP is provided by wolfSSH. Filesystem access equals the Filza process.\r\n";
    if ([name isEqualToString:@"exit"] || [name isEqualToString:@"logout"]) { if (shouldClose) *shouldClose = YES; return @"logout\r\n"; }
    if ([name isEqualToString:@"pwd"]) return [current stringByAppendingString:@"\r\n"];
    if ([name isEqualToString:@"whoami"]) return [FilzaSSHConfiguredUsername() stringByAppendingString:@"\r\n"];
    if ([name isEqualToString:@"id"]) return [NSString stringWithFormat:@"uid=%u gid=%u euid=%u egid=%u\r\n", getuid(), getgid(), geteuid(), getegid()];
    if ([name isEqualToString:@"uname"]) { struct utsname info = {0}; return uname(&info) == 0 ? [NSString stringWithFormat:@"%s %s %s %s %s\r\n", info.sysname, info.nodename, info.release, info.version, info.machine] : @"uname failed\r\n"; }
    if ([name isEqualToString:@"echo"]) return [NSString stringWithFormat:@"%@\r\n", args.count > 1 ? [[args subarrayWithRange:NSMakeRange(1, args.count - 1)] componentsJoinedByString:@" "] : @""];
    if ([name isEqualToString:@"cd"]) {
        NSString *path = FilzaSSHResolve(args.count > 1 ? args[1] : @"~", current); BOOL dir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&dir] || !dir) return [NSString stringWithFormat:@"cd: %@: inaccessible\r\n", path];
        *cwd = path; return @"";
    }
    if ([name isEqualToString:@"ls"]) {
        NSString *path = FilzaSSHResolve(args.count > 1 ? args[1] : @".", current); BOOL dir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&dir]) return [NSString stringWithFormat:@"ls: %@: inaccessible\r\n", path];
        NSArray *items = dir ? [fm contentsOfDirectoryAtPath:path error:nil] : @[path.lastPathComponent];
        return [[[items sortedArrayUsingSelector:@selector(localizedStandardCompare:)] componentsJoinedByString:@"\r\n"] stringByAppendingString:@"\r\n"];
    }
    if ([name isEqualToString:@"cat"] && args.count > 1) {
        NSString *path = FilzaSSHResolve(args[1], current);
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) return [NSString stringWithFormat:@"cat: %@: inaccessible\r\n", path];
        if (data.length > 16ULL * 1024ULL * 1024ULL) return @"cat: file exceeds 16 MiB limit\r\n";
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        return text ? [text stringByAppendingString:@"\r\n"] : @"cat: binary/non-UTF8 data\r\n";
    }
    if ([name isEqualToString:@"mkdir"] && args.count > 1) {
        NSString *path = FilzaSSHResolve(args[1], current); NSError *error = nil;
        return [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error] ? @"" : [NSString stringWithFormat:@"mkdir: %@\r\n", error.localizedDescription];
    }
    if ([name isEqualToString:@"touch"] && args.count > 1) {
        NSString *path = FilzaSSHResolve(args[1], current); int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT, 0644);
        if (fd < 0) return [NSString stringWithFormat:@"touch: %s\r\n", strerror(errno)]; close(fd); return @"";
    }
    if (([name isEqualToString:@"cp"] || [name isEqualToString:@"mv"]) && args.count > 2) {
        NSString *src = FilzaSSHResolve(args[1], current), *dst = FilzaSSHResolve(args[2], current); NSError *error = nil;
        BOOL ok = [name isEqualToString:@"cp"] ? [fm copyItemAtPath:src toPath:dst error:&error] : [fm moveItemAtPath:src toPath:dst error:&error];
        return ok ? @"" : [NSString stringWithFormat:@"%@: %@\r\n", name, error.localizedDescription];
    }
    if ([name isEqualToString:@"rm"] && args.count > 1) {
        NSString *path = FilzaSSHResolve(args.lastObject, current); NSError *error = nil;
        return [fm removeItemAtPath:path error:&error] ? @"" : [NSString stringWithFormat:@"rm: %@\r\n", error.localizedDescription];
    }
    return [NSString stringWithFormat:@"%@: command not found (type help)\r\n", name];
}

static void FilzaWolfSSHSend(WOLFSSH *ssh, NSString *text)
{
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    const byte *bytes = data.bytes;
    NSUInteger offset = 0;
    while (offset < data.length) {
        int sent = wolfSSH_stream_send(ssh, bytes + offset, (word32)MIN((NSUInteger)32768, data.length - offset));
        if (sent <= 0) break;
        offset += (NSUInteger)sent;
    }
}

static void FilzaWolfSSHServeSFTP(WOLFSSH *ssh)
{
    NSString *root = FilzaSSHInitialDirectory();
    int setup = wolfSSH_SFTP_SetDefaultPath(ssh, root.fileSystemRepresentation);
    if (setup != WS_SUCCESS) {
        FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"wolfSSH SFTP default path setup failed rc=%d", setup]);
        return;
    }
    FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"wolfSSH SFTP session active root=%@", root]);
    for (;;) {
        int rc = wolfSSH_SFTP_read(ssh);
        if (rc == WS_EOF) break;
        if (rc == WS_SUCCESS || rc == WS_WANT_READ || rc == WS_WANT_WRITE || rc == WS_CHAN_RXD || rc == WS_REKEYING) continue;
        if (rc < 0) {
            int error = wolfSSH_get_error(ssh);
            if (error == WS_WANT_READ || error == WS_WANT_WRITE || error == WS_CHAN_RXD || error == WS_REKEYING) continue;
            FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"wolfSSH SFTP loop ended rc=%d error=%d", rc, error]);
            break;
        }
    }
}

static void FilzaWolfSSHServeShell(WOLFSSH *ssh)
{
    __block NSString *cwd = FilzaSSHInitialDirectory();
    NSMutableData *line = NSMutableData.data;
    FilzaWolfSSHSend(ssh, @"Filza 27 wolfSSH\r\n");
    FilzaWolfSSHSend(ssh, [NSString stringWithFormat:@"filza:%@$ ", cwd]);
    byte buffer[4096];
    BOOL closeSession = NO;
    while (!closeSession && atomic_load(&FilzaSSHRunning)) {
        int rc = wolfSSH_stream_read(ssh, buffer, sizeof(buffer));
        if (rc <= 0) break;
        for (int i = 0; i < rc; i++) {
            byte ch = buffer[i];
            if (ch == '\r' || ch == '\n') {
                if (!line.length) continue;
                NSString *command = [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding] ?: @"";
                [line setLength:0];
                NSString *output = FilzaSSHExecute(command, &cwd, &closeSession);
                FilzaWolfSSHSend(ssh, @"\r\n");
                FilzaWolfSSHSend(ssh, output);
                if (!closeSession) FilzaWolfSSHSend(ssh, [NSString stringWithFormat:@"filza:%@$ ", cwd]);
            } else if (ch == 0x7f || ch == 0x08) {
                if (line.length) [line setLength:line.length - 1];
            } else if (ch >= 0x20 || ch == '\t') {
                [line appendBytes:&ch length:1];
            }
        }
    }
}

static void FilzaWolfSSHServeClient(int clientFD)
{
    @autoreleasepool {
        NSError *keyError = nil;
        NSData *hostKey = FilzaSSHHostKey(&keyError);
        if (!hostKey.length) {
            FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"wolfSSH client rejected: host key unavailable %@", keyError.localizedDescription]);
            close(clientFD); return;
        }

        WOLFSSH_CTX *ctx = wolfSSH_CTX_new(WOLFSSH_ENDPOINT_SERVER, NULL);
        if (!ctx) { FilzaDiagnosticsAppend(@"SSH", @"wolfSSH_CTX_new failed"); close(clientFD); return; }
        wolfSSH_SetUserAuth(ctx, FilzaWolfSSHUserAuth);
        wolfSSH_CTX_SetBanner(ctx, "Filza 27 wolfSSH server");
        if (wolfSSH_CTX_UsePrivateKey_buffer(ctx, hostKey.bytes, (word32)hostKey.length, WOLFSSH_FORMAT_ASN1) < 0) {
            FilzaDiagnosticsAppend(@"SSH", @"wolfSSH rejected persistent ECDSA host key");
            wolfSSH_CTX_free(ctx); close(clientFD); return;
        }

        WOLFSSH *ssh = wolfSSH_new(ctx);
        if (!ssh) { wolfSSH_CTX_free(ctx); close(clientFD); return; }
        wolfSSH_SetUserAuthCtx(ssh, NULL);
        wolfSSH_set_fd(ssh, clientFD);
        int rc = wolfSSH_accept(ssh);
        if (rc == WS_SUCCESS) {
            FilzaDiagnosticsAppend(@"SSH", @"wolfSSH authenticated shell session accepted");
            FilzaWolfSSHServeShell(ssh);
        } else if (rc == WS_SFTP_COMPLETE) {
            FilzaDiagnosticsAppend(@"SSH", @"wolfSSH authenticated SFTP subsystem accepted");
            FilzaWolfSSHServeSFTP(ssh);
        } else {
            FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"wolfSSH_accept failed rc=%d error=%d", rc, wolfSSH_get_error(ssh)]);
        }
        wolfSSH_shutdown(ssh);
        wolfSSH_free(ssh);
        wolfSSH_CTX_free(ctx);
        close(clientFD);
        FilzaDiagnosticsAppend(@"SSH", @"wolfSSH client session closed");
    }
}

static void FilzaWolfSSHAcceptAvailable(void)
{
    if (!atomic_load(&FilzaSSHRunning) || FilzaSSHListenFD < 0) return;
    for (;;) {
        struct sockaddr_storage peer = {0};
        socklen_t peerLen = sizeof(peer);
        int fd = accept(FilzaSSHListenFD, (struct sockaddr *)&peer, &peerLen);
        if (fd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"wolfSSH accept() failed: %s", strerror(errno)]);
            break;
        }
        int flags = fcntl(fd, F_GETFL, 0);
        if (flags >= 0) fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
#ifdef SO_NOSIGPIPE
        int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
        dispatch_async(FilzaSSHClientQueue, ^{ FilzaWolfSSHServeClient(fd); });
    }
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
        if (!FilzaSSHHostKey(&keyError).length) { failure = keyError; FilzaSSHSetFailure(failure.localizedDescription); return; }

        int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (fd < 0) {
            failure = [NSError errorWithDomain:FilzaSSHErrorDomain code:31 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"socket() failed: %s", strerror(errno)]}];
            FilzaSSHSetFailure(failure.localizedDescription); return;
        }
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
#ifdef SO_NOSIGPIPE
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
        struct sockaddr_in address = {0};
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_ANY);
        address.sin_port = htons((uint16_t)FilzaSSHConfiguredPort());
        if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 16) != 0) {
            failure = [NSError errorWithDomain:FilzaSSHErrorDomain code:32 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"wolfSSH listener failed on port %ld: %s", (long)FilzaSSHConfiguredPort(), strerror(errno)]}];
            close(fd); FilzaSSHSetFailure(failure.localizedDescription); return;
        }
        int flags = fcntl(fd, F_GETFL, 0);
        if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);

        struct sockaddr_in verified = {0}; socklen_t verifiedLen = sizeof(verified);
        if (getsockname(fd, (struct sockaddr *)&verified, &verifiedLen) != 0 || ntohs(verified.sin_port) != FilzaSSHConfiguredPort()) {
            failure = [NSError errorWithDomain:FilzaSSHErrorDomain code:33 userInfo:@{NSLocalizedDescriptionKey: @"wolfSSH listener could not verify its bound port."}];
            close(fd); FilzaSSHSetFailure(failure.localizedDescription); return;
        }

        FilzaSSHListenFD = fd;
        atomic_store(&FilzaSSHRunning, true);
        FilzaSSHAcceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, FilzaSSHListenerQueue);
        if (!FilzaSSHAcceptSource) {
            atomic_store(&FilzaSSHRunning, false); FilzaSSHListenFD = -1; close(fd);
            failure = [NSError errorWithDomain:FilzaSSHErrorDomain code:34 userInfo:@{NSLocalizedDescriptionKey: @"Could not create wolfSSH listener dispatch source."}];
            FilzaSSHSetFailure(failure.localizedDescription); return;
        }
        dispatch_source_set_event_handler(FilzaSSHAcceptSource, ^{ FilzaWolfSSHAcceptAvailable(); });
        dispatch_resume(FilzaSSHAcceptSource);

        if (FilzaSSHBonjourEnabled()) {
            FilzaSSHBonjourService = [[NSNetService alloc] initWithDomain:@"local." type:@"_ssh._tcp." name:@"Filza SSH" port:(int)FilzaSSHConfiguredPort()];
            [FilzaSSHBonjourService publish];
        }
        FilzaSSHClearFailure();
        FilzaSSHBackgroundKeepAliveStart();
        NSString *lan = FilzaSSHServerLANAddress() ?: @"0.0.0.0";
        NSString *summary = [NSString stringWithFormat:@"wolfSSH SSH/SFTP server listening address=%@ port=%ld auth=%@ backend=wolfSSH", lan, (long)FilzaSSHConfiguredPort(), FilzaSSHAuthenticationEnabled() ? @"YES" : @"NO"];
        FilzaDiagnosticsAppend(@"SSH", summary);
        FilzaSSHWriteStatus(summary);
        success = YES;
    });
    if (!success && error) *error = failure ?: [NSError errorWithDomain:FilzaSSHErrorDomain code:99 userInfo:@{NSLocalizedDescriptionKey: @"wolfSSH server failed to start."}];
    return success;
}

void FilzaSSHServerStop(void)
{
    FilzaSSHSync(^{
        atomic_store(&FilzaSSHRunning, false);
        if (FilzaSSHBonjourService) { [FilzaSSHBonjourService stop]; FilzaSSHBonjourService = nil; }
        if (FilzaSSHAcceptSource) { dispatch_source_cancel(FilzaSSHAcceptSource); FilzaSSHAcceptSource = nil; }
        if (FilzaSSHListenFD >= 0) { close(FilzaSSHListenFD); FilzaSSHListenFD = -1; }
        FilzaSSHBackgroundKeepAliveStop();
        FilzaDiagnosticsAppend(@"SSH", @"wolfSSH listener stopped");
    });
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
    NSInteger port = FilzaSSHConfiguredPort();
    NSString *user = FilzaSSHConfiguredUsername();
    return [NSString stringWithFormat:@"wolfSSH + SFTP listening — background=%@\nSame iPhone: ssh %@@127.0.0.1 -p %ld\nLAN: ssh %@@%@ -p %ld\nSFTP: sftp -P %ld %@@%@",
            atomic_load(&FilzaSSHKeepAliveActive) ? @"ON" : @"OFF", user, (long)port, user, address, (long)port, (long)port, user, address];
}
