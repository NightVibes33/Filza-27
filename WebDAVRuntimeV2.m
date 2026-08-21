@import Foundation;
@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>
#import <stdint.h>
#import <string.h>
#import <CommonCrypto/CommonDigest.h>
#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

#import "FilzaDiagnostics.h"
#import "GCDWebDAVServer.h"
#import "GCDWebServerConnection.h"
#import "GCDWebServerRequest.h"
#import "GCDWebServerResponse.h"

static NSString * const FilzaWebDAVEnabledKey = @"air-browser";
static NSString * const FilzaWebDAVServiceKey = @"air-browser-service";
static NSString * const FilzaWebDAVPortKey = @"air-port";
static NSString * const FilzaWebDAVBonjourKey = @"air-browser-bonjour";
static NSString * const FilzaWebDAVSecurityKey = @"air-browser-security";

static GCDWebDAVServer *FilzaWebDAVServer = nil;
static NSString *FilzaWebDAVAuthenticationUsername = nil;
static NSString *FilzaWebDAVAuthenticationPasswordMD5 = nil;
static BOOL FilzaWebDAVAuthenticationRequired = NO;
static BOOL FilzaWebDAVInstalled = NO;
static BOOL FilzaWebDAVStartInFlight = NO;
static uint64_t FilzaWebDAVGeneration = 1;
static SEL FilzaWebDAVStartSelector;
static SEL FilzaWebDAVStopSelector;

@interface FilzaWebDAVConnectionV2 : GCDWebServerConnection
@end

static NSString *FilzaWebDAVMD5(NSString *value)
{
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);
#pragma clang diagnostic pop
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static BOOL FilzaWebDAVConstantTimeEqual(NSString *left, NSString *right)
{
    NSData *a = [[left lowercaseString] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *b = [[right lowercaseString] dataUsingEncoding:NSUTF8StringEncoding];
    if (!a || !b || a.length != b.length) return NO;
    const uint8_t *ab = a.bytes, *bb = b.bytes;
    uint8_t difference = 0;
    for (NSUInteger i = 0; i < a.length; i++) difference |= ab[i] ^ bb[i];
    return difference == 0;
}

@implementation FilzaWebDAVConnectionV2
- (GCDWebServerResponse *)preflightRequest:(GCDWebServerRequest *)request
{
    GCDWebServerResponse *upstream = [super preflightRequest:request];
    if (upstream || !FilzaWebDAVAuthenticationRequired) return upstream;

    BOOL authenticated = NO;
    NSString *authorization = request.headers[@"Authorization"];
    if ([authorization hasPrefix:@"Basic "]) {
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:[authorization substringFromIndex:6] options:0];
        NSString *credential = [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding];
        NSRange separator = [credential rangeOfString:@":"];
        if (separator.location != NSNotFound) {
            NSString *username = [credential substringToIndex:separator.location];
            NSString *password = [credential substringFromIndex:separator.location + 1];
            authenticated = [username isEqualToString:FilzaWebDAVAuthenticationUsername] &&
                FilzaWebDAVConstantTimeEqual(FilzaWebDAVMD5(password), FilzaWebDAVAuthenticationPasswordMD5);
        }
    }
    if (authenticated) return nil;

    GCDWebServerResponse *response = [GCDWebServerResponse responseWithStatusCode:401];
    [response setValue:@"Basic realm=\"Filza 27 WebDAV\"" forAdditionalHeader:@"WWW-Authenticate"];
    return response;
}
@end

static id FilzaWebDAVSharedPreferences(void)
{
    Class cls = NSClassFromString(@"TGPreferences");
    SEL selector = NSSelectorFromString(@"sharedInstance");
    if (!cls || ![cls respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, selector);
}

static id FilzaWebDAVCallObject(id target, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static id FilzaWebDAVPreference(id preferences, NSString *key)
{
    SEL selector = NSSelectorFromString(@"objectForPreferenceKey:");
    if (!preferences || ![preferences respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(preferences, selector, key);
}

static id FilzaWebDAVSecurePreference(id preferences, NSString *key)
{
    SEL selector = NSSelectorFromString(@"objectForSecurePreferenceKey:");
    if (preferences && [preferences respondsToSelector:selector]) {
        id value = ((id (*)(id, SEL, id))objc_msgSend)(preferences, selector, key);
        if (value) return value;
    }
    return FilzaWebDAVPreference(preferences, key);
}

static BOOL FilzaWebDAVBoolPreference(id preferences, NSString *key)
{
    id value = FilzaWebDAVPreference(preferences, key);
    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

static const char *FilzaWebDAVUnqualifiedType(const char *type)
{
    while (type && strchr("rnNoORV", type[0])) type++;
    return type;
}

static BOOL FilzaWebDAVSetPreference(id preferences, NSString *key, id value)
{
    SEL selector = NSSelectorFromString(@"setObject:forPreferenceKey:notification:");
    NSMethodSignature *signature = [preferences methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments < 5) return NO;

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = preferences;
    invocation.selector = selector;
    __unsafe_unretained id valueArgument = value;
    __unsafe_unretained id keyArgument = key;
    [invocation setArgument:&valueArgument atIndex:2];
    [invocation setArgument:&keyArgument atIndex:3];

    const char *type = FilzaWebDAVUnqualifiedType([signature getArgumentTypeAtIndex:4]);
    if (type && type[0] == '@') {
        __unsafe_unretained id notification = nil;
        [invocation setArgument:&notification atIndex:4];
    } else if (type && (type[0] == 'B' || type[0] == 'c')) {
        BOOL notification = NO;
        [invocation setArgument:&notification atIndex:4];
    } else {
        NSUInteger zero = 0;
        [invocation setArgument:&zero atIndex:4];
    }
    @try { [invocation invoke]; return YES; }
    @catch (NSException *exception) {
        FilzaDiagnosticsAppend(@"WebDAV", [NSString stringWithFormat:@"preference write %@ failed: %@", key, exception.reason ?: exception.name]);
        return NO;
    }
}

static void FilzaWebDAVAssignServer(id preferences, id server)
{
    SEL selector = NSSelectorFromString(@"setHttpServer:");
    if (preferences && [preferences respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(preferences, selector, server);
}

static void FilzaWebDAVWriteStatus(NSString *message)
{
    NSString *path = [FilzaDiagnosticsDirectory() stringByAppendingPathComponent:@"WebDAVStatus.txt"];
    NSString *timestamp = [NSISO8601DateFormatter.new stringFromDate:NSDate.date] ?: NSDate.date.description;
    [[NSString stringWithFormat:@"%@\n%@\n", timestamp, message ?: @"unknown"]
        writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSInteger FilzaWebDAVConfiguredPort(id preferences)
{
    NSInteger port = [FilzaWebDAVPreference(preferences, FilzaWebDAVPortKey) integerValue];
    if (port < 1 || port > 65535) {
        port = 11111;
        FilzaWebDAVSetPreference(preferences, FilzaWebDAVPortKey, @(port));
    }
    return port;
}

static NSString *FilzaWebDAVRoot(id preferences)
{
    NSString *root = FilzaWebDAVCallObject(preferences, @"uploaderPath");
    BOOL isDirectory = NO;
    if ([root isKindOfClass:NSString.class] &&
        [NSFileManager.defaultManager fileExistsAtPath:root isDirectory:&isDirectory] && isDirectory) return root;

    root = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (root.length && [NSFileManager.defaultManager fileExistsAtPath:root isDirectory:&isDirectory] && isDirectory) return root;
    return NSHomeDirectory();
}

static void FilzaWebDAVStopServerObject(id preferences)
{
    id old = FilzaWebDAVCallObject(preferences, @"httpServer");
    if (old && old != FilzaWebDAVServer && [old respondsToSelector:@selector(stop)]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(old, @selector(stop)); }
        @catch (__unused NSException *exception) {}
    }
    [FilzaWebDAVServer stop];
    FilzaWebDAVServer = nil;
    FilzaWebDAVAssignServer(preferences, nil);
}

static BOOL FilzaWebDAVLoopbackProbe(NSInteger port, BOOL authRequired, NSString **result)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (result) *result = [NSString stringWithFormat:@"socket() failed: %s", strerror(errno)];
        return NO;
    }
    struct timeval timeout = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        int saved = errno; close(fd);
        if (result) *result = [NSString stringWithFormat:@"loopback connect failed: %s", strerror(saved)];
        return NO;
    }

    const char *request = "PROPFIND / HTTP/1.1\r\nHost: 127.0.0.1\r\nDepth: 0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    size_t total = strlen(request), sent = 0;
    while (sent < total) {
        ssize_t written = send(fd, request + sent, total - sent, 0);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            int saved = errno; close(fd);
            if (result) *result = [NSString stringWithFormat:@"loopback send failed: %s", strerror(saved)];
            return NO;
        }
        sent += (size_t)written;
    }

    char buffer[2048] = {0};
    ssize_t count = recv(fd, buffer, sizeof(buffer) - 1, 0);
    int saved = errno;
    close(fd);
    if (count <= 0) {
        if (result) *result = [NSString stringWithFormat:@"loopback response missing: %s", strerror(saved)];
        return NO;
    }
    buffer[count] = '\0';
    NSString *response = [NSString stringWithUTF8String:buffer] ?: @"";
    NSRange lineEnd = [response rangeOfString:@"\r\n"];
    NSString *statusLine = lineEnd.location == NSNotFound ? response : [response substringToIndex:lineEnd.location];
    BOOL healthy = authRequired ? [statusLine containsString:@" 401 "]
                                : ([statusLine containsString:@" 207 "] || [statusLine containsString:@" 200 "]);
    if (result) *result = [NSString stringWithFormat:@"%@ (%@)", statusLine, authRequired ? @"authentication challenge expected" : @"DAV PROPFIND expected"];
    return healthy;
}

static void FilzaWebDAVScheduleProbe(id preferences, NSInteger port, BOOL authRequired, uint64_t generation, NSInteger attempt)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *probe = nil;
        BOOL healthy = FilzaWebDAVLoopbackProbe(port, authRequired, &probe);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != FilzaWebDAVGeneration || !FilzaWebDAVServer.isRunning) return;
            if (healthy) {
                NSString *summary = [NSString stringWithFormat:@"protocol self-test passed port=%ld result=%@ root=%@ url=%@",
                                     (long)port, probe ?: @"ok", FilzaWebDAVRoot(preferences), FilzaWebDAVServer.serverURL ?: @"unavailable"];
                FilzaDiagnosticsAppend(@"WebDAV", summary);
                FilzaWebDAVWriteStatus(summary);
                [NSNotificationCenter.defaultCenter postNotificationName:@"AirBrowserChanged" object:preferences];
                return;
            }
            if (attempt < 1) {
                FilzaDiagnosticsAppend(@"WebDAV", [NSString stringWithFormat:@"protocol self-test retry after failure: %@", probe ?: @"unknown"]);
                FilzaWebDAVScheduleProbe(preferences, port, authRequired, generation, attempt + 1);
                return;
            }

            NSString *failure = [NSString stringWithFormat:@"listener bound but WebDAV protocol self-test failed twice: %@", probe ?: @"unknown"];
            FilzaDiagnosticsAppend(@"WebDAV", failure);
            FilzaWebDAVWriteStatus(failure);
            FilzaWebDAVStopServerObject(preferences);
            FilzaWebDAVSetPreference(preferences, FilzaWebDAVEnabledKey, @NO);
            [NSNotificationCenter.defaultCenter postNotificationName:@"AirBrowserChanged" object:preferences];
        });
    });
}

static BOOL FilzaWebDAVStartServer(id preferences)
{
    if (!preferences) return NO;
    if (FilzaWebDAVStartInFlight) return FilzaWebDAVServer.isRunning;
    FilzaWebDAVStartInFlight = YES;

    // The jailed build must never select Filza's launchd helper mode.
    FilzaWebDAVSetPreference(preferences, FilzaWebDAVServiceKey, @NO);
    NSInteger port = FilzaWebDAVConfiguredPort(preferences);
    NSString *root = FilzaWebDAVRoot(preferences);
    BOOL bonjour = FilzaWebDAVBoolPreference(preferences, FilzaWebDAVBonjourKey);
    BOOL security = FilzaWebDAVBoolPreference(preferences, FilzaWebDAVSecurityKey);

    NSString *username = FilzaWebDAVSecurePreference(preferences, @"air-username");
    NSString *passwordMD5 = FilzaWebDAVSecurePreference(preferences, @"air-password-md5");
    if (security && (!username.length || passwordMD5.length != 32)) {
        NSString *failure = @"WebDAV authentication is enabled but the saved username/password hash is incomplete. Configure WebDAV credentials or turn authentication off.";
        FilzaDiagnosticsAppend(@"WebDAV", failure);
        FilzaWebDAVWriteStatus(failure);
        FilzaWebDAVStartInFlight = NO;
        return NO;
    }

    FilzaWebDAVAuthenticationRequired = security;
    FilzaWebDAVAuthenticationUsername = security ? [username copy] : nil;
    FilzaWebDAVAuthenticationPasswordMD5 = security ? [[passwordMD5 lowercaseString] copy] : nil;

    // Never reuse an old Filza server object: it may have been configured for
    // the launchd helper or with a different connection class/root/options.
    FilzaWebDAVStopServerObject(preferences);
    GCDWebDAVServer *server = [[GCDWebDAVServer alloc] initWithUploadDirectory:root];
    server.allowHiddenItems = YES;

    NSMutableDictionary *options = [@{
        GCDWebServerOption_Port: @(port),
        GCDWebServerOption_ServerName: @"Filza 27 WebDAV",
        GCDWebServerOption_BindToLocalhost: @NO,
        GCDWebServerOption_AutomaticallySuspendInBackground: @NO,
        GCDWebServerOption_ConnectionClass: FilzaWebDAVConnectionV2.class,
        GCDWebServerOption_MaxPendingConnections: @32
    } mutableCopy];
    if (bonjour) {
        options[GCDWebServerOption_BonjourName] = @"Filza 27 WebDAV";
        options[GCDWebServerOption_BonjourType] = @"_http._tcp.";
    }

    NSError *error = nil;
    BOOL started = [server startWithOptions:options error:&error];
    if (!started || !server.isRunning) {
        NSString *failure = [NSString stringWithFormat:@"WebDAV failed to listen on port %ld: %@",
                             (long)port, error.localizedDescription ?: @"server did not enter running state"];
        [server stop];
        FilzaDiagnosticsAppend(@"WebDAV", failure);
        FilzaWebDAVWriteStatus(failure);
        FilzaWebDAVStartInFlight = NO;
        return NO;
    }

    FilzaWebDAVServer = server;
    FilzaWebDAVAssignServer(preferences, server);
    FilzaWebDAVGeneration += 1;
    uint64_t generation = FilzaWebDAVGeneration;

    SEL disableIdle = NSSelectorFromString(@"disableIdleTimer");
    if ([preferences respondsToSelector:disableIdle]) ((void (*)(id, SEL))objc_msgSend)(preferences, disableIdle);

    NSString *summary = [NSString stringWithFormat:@"in-process WebDAV listener started port=%ld root=%@ auth=%@ bonjour=%@ url=%@; protocol verification pending",
                         (long)port, root, security ? @"YES" : @"NO", bonjour ? @"YES" : @"NO", server.serverURL ?: @"unavailable"];
    FilzaDiagnosticsAppend(@"WebDAV", summary);
    FilzaWebDAVWriteStatus(summary);
    FilzaWebDAVStartInFlight = NO;
    FilzaWebDAVScheduleProbe(preferences, port, security, generation, 0);
    return YES;
}

static void FilzaWebDAVStopServer(id preferences)
{
    FilzaWebDAVGeneration += 1;
    FilzaWebDAVStopServerObject(preferences);
    FilzaWebDAVAuthenticationRequired = NO;
    FilzaWebDAVAuthenticationUsername = nil;
    FilzaWebDAVAuthenticationPasswordMD5 = nil;

    SEL enableIdle = NSSelectorFromString(@"enableIdleTimer");
    if ([preferences respondsToSelector:enableIdle]) ((void (*)(id, SEL))objc_msgSend)(preferences, enableIdle);

    FilzaDiagnosticsAppend(@"WebDAV", @"in-process WebDAV listener stopped");
    FilzaWebDAVWriteStatus(@"WebDAV server stopped");
    [NSNotificationCenter.defaultCenter postNotificationName:@"AirBrowserChanged" object:preferences];
}

static void FilzaWebDAVStartAirBrowser(id preferences, __unused SEL selector)
{
    BOOL started = FilzaWebDAVStartServer(preferences);
    if (started) {
        [NSNotificationCenter.defaultCenter postNotificationName:@"AirBrowserChanged" object:preferences];
    } else {
        // A failed start must never leave a fake ON state behind.
        FilzaWebDAVSetPreference(preferences, FilzaWebDAVEnabledKey, @NO);
        [NSNotificationCenter.defaultCenter postNotificationName:@"AirBrowserChanged" object:preferences];
    }
}

static void FilzaWebDAVStopAirBrowser(id preferences, __unused SEL selector)
{
    FilzaWebDAVStopServer(preferences);
}

static void FilzaWebDAVResumeIfNeeded(NSString *reason)
{
    id preferences = FilzaWebDAVSharedPreferences();
    if (!preferences) {
        FilzaDiagnosticsAppend(@"WebDAV", [NSString stringWithFormat:@"%@; TGPreferences unavailable", reason]);
        return;
    }
    FilzaWebDAVSetPreference(preferences, FilzaWebDAVServiceKey, @NO);
    BOOL enabled = FilzaWebDAVBoolPreference(preferences, FilzaWebDAVEnabledKey);
    BOOL running = FilzaWebDAVServer.isRunning;
    if (enabled && !running) {
        FilzaDiagnosticsAppend(@"WebDAV", [NSString stringWithFormat:@"%@; restoring saved WebDAV listener", reason]);
        FilzaWebDAVStartServer(preferences);
    } else {
        FilzaDiagnosticsAppend(@"WebDAV", [NSString stringWithFormat:@"%@; enabled=%@ running=%@",
                               reason, enabled ? @"YES" : @"NO", running ? @"YES" : @"NO"]);
    }
}

static void FilzaWebDAVInstall(void)
{
    if (FilzaWebDAVInstalled) return;
    Class preferencesClass = NSClassFromString(@"TGPreferences");
    if (!preferencesClass) {
        FilzaDiagnosticsAppend(@"WebDAV", @"WebDAV v2 install deferred: TGPreferences unavailable");
        return;
    }

    FilzaWebDAVStartSelector = NSSelectorFromString(@"startAirBrowser");
    FilzaWebDAVStopSelector = NSSelectorFromString(@"stopAirBrowser");
    Method start = class_getInstanceMethod(preferencesClass, FilzaWebDAVStartSelector);
    Method stop = class_getInstanceMethod(preferencesClass, FilzaWebDAVStopSelector);
    if (!start || !stop) {
        FilzaDiagnosticsAppend(@"WebDAV", @"WebDAV v2 install failed: Filza lifecycle selectors missing");
        return;
    }

    method_setImplementation(start, (IMP)FilzaWebDAVStartAirBrowser);
    method_setImplementation(stop, (IMP)FilzaWebDAVStopAirBrowser);
    FilzaWebDAVInstalled = YES;
    FilzaDiagnosticsAppend(@"WebDAV", @"WebDAV v2 authoritative in-process lifecycle installed; launchd path disabled");
    FilzaWebDAVResumeIfNeeded(@"runtime installed");
}

__attribute__((constructor)) static void FilzaWebDAVRuntimeV2Init(void)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            FilzaWebDAVInstall();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!FilzaWebDAVInstalled) FilzaWebDAVInstall();
            });
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                if (!FilzaWebDAVInstalled) FilzaWebDAVInstall();
                FilzaWebDAVResumeIfNeeded(@"application launched");
            }];
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                if (!FilzaWebDAVInstalled) FilzaWebDAVInstall();
                FilzaWebDAVResumeIfNeeded(@"application active");
            }];
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                if (FilzaWebDAVServer.isRunning)
                    FilzaDiagnosticsAppend(@"WebDAV", @"application backgrounded; jailed iOS may suspend the listener until the app resumes");
            }];
        });
    }
}
