@import Foundation;
@import UIKit;

#import <objc/runtime.h>
#import <stdint.h>
#import <string.h>
#import <CommonCrypto/CommonDigest.h>

#import "FilzaDiagnostics.h"
#import "GCDWebDAVServer.h"
#import "GCDWebServerConnection.h"
#import "GCDWebServerResponse.h"

// Filza still carries two WebDAV launch modes:
//
//  1. a jailbreak-only launchd service under /usr/libexec/filza; and
//  2. an in-process GCDWebDAVServer owned by TGPreferences.
//
// The MobileHouseArrest/sideloaded build cannot install or load the launchd
// service. Keep Filza's own server, UI, authentication, DAV implementation and
// root selection, but force launches through the in-process path.

static NSString * const FilzaWebDAVEnabledKey = @"air-browser";
static NSString * const FilzaWebDAVServiceKey = @"air-browser-service";
static NSString * const FilzaWebDAVPortKey = @"air-port";
static NSString * const FilzaWebDAVBonjourKey = @"air-browser-bonjour";
static NSString * const FilzaWebDAVSecurityKey = @"air-browser-security";

static void (*FilzaOriginalStartAirBrowser)(id, SEL) = NULL;
static void (*FilzaOriginalStopAirBrowser)(id, SEL) = NULL;
static void (*FilzaOriginalSetPreference)(id, SEL, id, id, uintptr_t) = NULL;
static void (*FilzaOriginalRemovePreference)(id, SEL, id, uintptr_t) = NULL;
static void (*FilzaOriginalSwitchAirBrowserCheckbox)(id, SEL) = NULL;
static SEL FilzaStartAirBrowserSelector;
static SEL FilzaStopAirBrowserSelector;
static BOOL FilzaWebDAVStartInFlight = NO;
static BOOL FilzaWebDAVPreferenceHooksInstalled = NO;
static GCDWebDAVServer *FilzaPinnedWebDAVServer = nil;
static NSString *FilzaWebDAVAuthenticationUsername = nil;
static NSString *FilzaWebDAVAuthenticationPasswordMD5 = nil;
static BOOL FilzaWebDAVAuthenticationRequired = NO;

static void FilzaWebDAVStartAirBrowser(id preferences, SEL selector);
static void FilzaWebDAVStopAirBrowser(id preferences, SEL selector);

@interface FilzaWebDAVConnection : GCDWebServerConnection
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
    for (NSUInteger index = 0; index < CC_MD5_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

static BOOL FilzaWebDAVConstantTimeEqual(NSString *left, NSString *right)
{
    NSData *leftData = [[left lowercaseString] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *rightData = [[right lowercaseString] dataUsingEncoding:NSUTF8StringEncoding];
    if (leftData.length != rightData.length) return NO;
    const uint8_t *leftBytes = leftData.bytes;
    const uint8_t *rightBytes = rightData.bytes;
    uint8_t difference = 0;
    for (NSUInteger index = 0; index < leftData.length; index++) {
        difference |= leftBytes[index] ^ rightBytes[index];
    }
    return difference == 0;
}

@implementation FilzaWebDAVConnection

- (GCDWebServerResponse *)preflightRequest:(GCDWebServerRequest *)request
{
    GCDWebServerResponse *upstreamResponse = [super preflightRequest:request];
    FilzaDiagnosticsAppend(@"WebDAV", [NSString stringWithFormat:@"request %@ %@ auth-required=%@",
        request.method ?: @"?", request.path ?: @"/",
        FilzaWebDAVAuthenticationRequired ? @"YES" : @"NO"]);
    if (upstreamResponse || !FilzaWebDAVAuthenticationRequired) return upstreamResponse;

    BOOL authenticated = NO;
    NSString *authorization = request.headers[@"Authorization"];
    if ([authorization hasPrefix:@"Basic "]) {
        NSData *credentialData = [[NSData alloc] initWithBase64EncodedString:[authorization substringFromIndex:6]
                                                                     options:0];
        NSString *credential = [[NSString alloc] initWithData:credentialData encoding:NSUTF8StringEncoding];
        NSRange separator = [credential rangeOfString:@":"];
        if (separator.location != NSNotFound) {
            NSString *username = [credential substringToIndex:separator.location];
            NSString *password = [credential substringFromIndex:separator.location + 1];
            authenticated = [username isEqualToString:FilzaWebDAVAuthenticationUsername] &&
                            FilzaWebDAVConstantTimeEqual(FilzaWebDAVMD5(password),
                                                        FilzaWebDAVAuthenticationPasswordMD5);
        }
    }

    if (authenticated) {
        FilzaDiagnosticsAppend(@"WebDAV", [NSString stringWithFormat:@"authenticated %@ %@",
            request.method ?: @"?", request.path ?: @"/"]);
        return nil;
    }
    FilzaDiagnosticsAppend(@"WebDAV", [NSString stringWithFormat:@"rejected unauthenticated %@ %@",
        request.method ?: @"?", request.path ?: @"/"]);
    GCDWebServerResponse *response = [GCDWebServerResponse responseWithStatusCode:401];
    [response setValue:@"Basic realm=\"FilzaSlop WebDAV\"" forAdditionalHeader:@"WWW-Authenticate"];
    return response;
}

@end

static id FilzaWebDAVCallObject(id target, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) return nil;
    IMP implementation = [target methodForSelector:selector];
    if (!implementation) return nil;
    return ((id (*)(id, SEL))implementation)(target, selector);
}

static BOOL FilzaWebDAVCallBool(id target, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:selector]) return NO;
    IMP implementation = [target methodForSelector:selector];
    if (!implementation) return NO;
    return ((BOOL (*)(id, SEL))implementation)(target, selector);
}

static id FilzaWebDAVPreference(id preferences, NSString *key)
{
    SEL selector = NSSelectorFromString(@"objectForPreferenceKey:");
    if (!preferences || ![preferences respondsToSelector:selector]) return nil;
    IMP implementation = [preferences methodForSelector:selector];
    if (!implementation) return nil;
    return ((id (*)(id, SEL, id))implementation)(preferences, selector, key);
}

static id FilzaWebDAVSecurePreference(id preferences, NSString *key)
{
    SEL selector = NSSelectorFromString(@"objectForSecurePreferenceKey:");
    if (!preferences || ![preferences respondsToSelector:selector]) return FilzaWebDAVPreference(preferences, key);
    IMP implementation = [preferences methodForSelector:selector];
    if (!implementation) return FilzaWebDAVPreference(preferences, key);
    id value = ((id (*)(id, SEL, id))implementation)(preferences, selector, key);
    return value ?: FilzaWebDAVPreference(preferences, key);
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

    const char *notificationType = FilzaWebDAVUnqualifiedType([signature getArgumentTypeAtIndex:4]);
    if (notificationType && notificationType[0] == '@') {
        __unsafe_unretained id notification = nil;
        [invocation setArgument:&notification atIndex:4];
    } else if (notificationType && (notificationType[0] == 'B' || notificationType[0] == 'c')) {
        BOOL notification = NO;
        [invocation setArgument:&notification atIndex:4];
    } else {
        NSUInteger zero = 0;
        [invocation setArgument:&zero atIndex:4];
    }

    @try {
        [invocation invoke];
        return YES;
    } @catch (NSException *exception) {
        FilzaDiagnosticsAppend(@"WebDAV",
                               [NSString stringWithFormat:@"could not update %@: %@",
                                key, exception.reason ?: exception.name]);
        return NO;
    }
}

static id FilzaWebDAVSharedPreferences(void)
{
    Class preferencesClass = NSClassFromString(@"TGPreferences");
    SEL selector = NSSelectorFromString(@"sharedInstance");
    if (!preferencesClass || ![preferencesClass respondsToSelector:selector]) return nil;
    IMP implementation = [preferencesClass methodForSelector:selector];
    if (!implementation) return nil;
    return ((id (*)(id, SEL))implementation)(preferencesClass, selector);
}

static void FilzaWebDAVWriteStatus(NSString *status)
{
    NSString *path = [FilzaDiagnosticsDirectory() stringByAppendingPathComponent:@"WebDAVStatus.txt"];
    NSString *timestamp = [NSISO8601DateFormatter.new stringFromDate:NSDate.date];
    NSString *contents = [NSString stringWithFormat:@"%@\n%@\n",
                          timestamp ?: NSDate.date.description,
                          status ?: @"unknown"];
    [contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void FilzaWebDAVForceInProcessSettings(id preferences)
{
    BOOL changed = FilzaWebDAVSetPreference(preferences, FilzaWebDAVServiceKey, @NO);

    id portValue = FilzaWebDAVPreference(preferences, FilzaWebDAVPortKey);
    NSInteger port = [portValue respondsToSelector:@selector(integerValue)] ? [portValue integerValue] : 0;
    if (port < 1 || port > 65535) {
        FilzaWebDAVSetPreference(preferences, FilzaWebDAVPortKey, @11111);
        port = 11111;
    }

    FilzaDiagnosticsAppend(@"WebDAV",
                           [NSString stringWithFormat:@"selected in-process server mode port=%ld setting-updated=%@",
                            (long)port, changed ? @"YES" : @"NO"]);
}

static NSString *FilzaWebDAVTrimmedLog(id value)
{
    if (!value) return @"";
    NSString *text = [value isKindOfClass:NSString.class] ? value : [value description];
    if (text.length > 1200) text = [text substringFromIndex:text.length - 1200];
    return [text stringByReplacingOccurrencesOfString:@"\n" withString:@" | "];
}

static void FilzaWebDAVAssignServer(id preferences, GCDWebDAVServer *server)
{
    SEL selector = NSSelectorFromString(@"setHttpServer:");
    if (![preferences respondsToSelector:selector]) return;
    IMP implementation = [preferences methodForSelector:selector];
    if (implementation) ((void (*)(id, SEL, id))implementation)(preferences, selector, server);
}

static BOOL FilzaWebDAVStartPinnedServer(id preferences)
{
    NSString *root = FilzaWebDAVCallObject(preferences, @"uploaderPath");
    BOOL isDirectory = NO;
    if (![root isKindOfClass:NSString.class] ||
        ![NSFileManager.defaultManager fileExistsAtPath:root isDirectory:&isDirectory] ||
        !isDirectory) {
        root = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    }
    if (!root.length) root = NSHomeDirectory();

    NSInteger port = [FilzaWebDAVPreference(preferences, FilzaWebDAVPortKey) integerValue];
    if (port < 1 || port > 65535) port = 11111;
    BOOL bonjour = FilzaWebDAVBoolPreference(preferences, FilzaWebDAVBonjourKey);
    BOOL security = FilzaWebDAVBoolPreference(preferences, FilzaWebDAVSecurityKey);

    NSString *username = FilzaWebDAVSecurePreference(preferences, @"air-username");
    NSString *passwordMD5 = FilzaWebDAVSecurePreference(preferences, @"air-password-md5");
    if (security && (!username.length || passwordMD5.length != 32)) {
        NSString *failure = @"authentication is enabled but Filza's saved username/password hash is incomplete; refusing to expose an unauthenticated server";
        FilzaDiagnosticsAppend(@"WebDAV", failure);
        FilzaWebDAVWriteStatus(failure);
        return NO;
    }

    FilzaWebDAVAuthenticationRequired = security;
    FilzaWebDAVAuthenticationUsername = security ? [username copy] : nil;
    FilzaWebDAVAuthenticationPasswordMD5 = security ? [[passwordMD5 lowercaseString] copy] : nil;

    GCDWebDAVServer *server = FilzaPinnedWebDAVServer;
    id filzaServer = FilzaWebDAVCallObject(preferences, @"httpServer");
    if ([filzaServer isKindOfClass:GCDWebDAVServer.class]) server = filzaServer;
    if (!server || ![server.uploadDirectory isEqualToString:root]) {
        [server stop];
        server = [[GCDWebDAVServer alloc] initWithUploadDirectory:root];
    }
    server.allowHiddenItems = YES;

    NSMutableDictionary<NSString *, id> *options = [@{
        GCDWebServerOption_Port: @(port),
        GCDWebServerOption_ServerName: @"FilzaSlop WebDAV",
        GCDWebServerOption_BindToLocalhost: @NO,
        GCDWebServerOption_AutomaticallySuspendInBackground: @NO,
        GCDWebServerOption_ConnectionClass: FilzaWebDAVConnection.class,
        GCDWebServerOption_MaxPendingConnections: @16
    } mutableCopy];
    if (bonjour) {
        options[GCDWebServerOption_BonjourName] = @"";
        options[GCDWebServerOption_BonjourType] = @"_http._tcp.";
    }

    NSError *error = nil;
    BOOL started = server.isRunning || [server startWithOptions:options error:&error];
    if (!started) {
        NSString *failure = [NSString stringWithFormat:@"pinned server failed to bind port %ld: %@",
                             (long)port, error.localizedDescription ?: @"unknown error"];
        FilzaDiagnosticsAppend(@"WebDAV", failure);
        FilzaWebDAVWriteStatus(failure);
        return NO;
    }

    FilzaPinnedWebDAVServer = server;
    FilzaWebDAVAssignServer(preferences, server);
    FilzaDiagnosticsAppend(@"WebDAV",
                           [NSString stringWithFormat:@"pinned complete WebDAV server listening root=%@ url=%@ auth=%@",
                            root, server.serverURL ?: @"unavailable", security ? @"YES" : @"NO"]);
    return YES;
}

static void FilzaWebDAVReport(id preferences, NSString *reason, BOOL permitRetry);

static void FilzaWebDAVRetry(id preferences, NSString *reason)
{
    if (!FilzaWebDAVBoolPreference(preferences, FilzaWebDAVEnabledKey)) return;

    FilzaDiagnosticsAppend(@"WebDAV", @"server did not report listening; rebuilding the in-process server once");
    FilzaWebDAVForceInProcessSettings(preferences);

    @try {
        if (!FilzaWebDAVCallBool(preferences, @"isServerStarted") && !FilzaPinnedWebDAVServer.isRunning) {
            FilzaWebDAVStartPinnedServer(preferences);
        }
    } @catch (NSException *exception) {
        FilzaDiagnosticsAppend(@"WebDAV",
                               [NSString stringWithFormat:@"retry exception: %@ | %@",
                                exception.name, exception.reason ?: @"no reason"]);
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FilzaWebDAVReport(preferences, [reason stringByAppendingString:@" retry"], NO);
    });
}

static void FilzaWebDAVReport(id preferences, NSString *reason, BOOL permitRetry)
{
    if (!preferences) return;

    BOOL enabled = FilzaWebDAVBoolPreference(preferences, FilzaWebDAVEnabledKey);
    BOOL started = FilzaWebDAVCallBool(preferences, @"isServerStarted") || FilzaPinnedWebDAVServer.isRunning;
    id server = FilzaWebDAVCallObject(preferences, @"httpServer") ?: FilzaPinnedWebDAVServer;
    id connectionURL = FilzaWebDAVCallObject(preferences, @"connectionUrl");
    id hostnameURL = FilzaWebDAVCallObject(preferences, @"connectionUrlWithHostname");
    id root = FilzaWebDAVCallObject(preferences, @"uploaderPath");
    id port = FilzaWebDAVPreference(preferences, FilzaWebDAVPortKey) ?: @11111;
    BOOL bonjour = FilzaWebDAVBoolPreference(preferences, FilzaWebDAVBonjourKey);
    BOOL security = FilzaWebDAVBoolPreference(preferences, FilzaWebDAVSecurityKey);

    NSString *summary = [NSString stringWithFormat:
                         @"%@ enabled=%@ listening=%@ mode=in-process server=%@ port=%@ bonjour=%@ auth=%@ root=%@ url=%@ hostname-url=%@",
                         reason ?: @"status",
                         enabled ? @"YES" : @"NO",
                         started ? @"YES" : @"NO",
                         server ? NSStringFromClass([server class]) : @"nil",
                         port,
                         bonjour ? @"YES" : @"NO",
                         security ? @"YES" : @"NO",
                         root ?: @"unknown",
                         connectionURL ?: @"unavailable",
                         hostnameURL ?: @"unavailable"];
    FilzaDiagnosticsAppend(@"WebDAV", summary);

    NSString *serverLog = FilzaWebDAVTrimmedLog(FilzaWebDAVCallObject(preferences, @"readLog"));
    if (!started && serverLog.length) {
        summary = [summary stringByAppendingFormat:@"\nFilza server log: %@", serverLog];
        FilzaDiagnosticsAppend(@"WebDAV", [@"Filza server log: " stringByAppendingString:serverLog]);
    }
    FilzaWebDAVWriteStatus(summary);

    if (enabled && !started && permitRetry) FilzaWebDAVRetry(preferences, reason ?: @"start");
}

static void FilzaWebDAVStopAirBrowser(id preferences, SEL selector)
{
    [FilzaPinnedWebDAVServer stop];
    FilzaPinnedWebDAVServer = nil;
    FilzaWebDAVAssignServer(preferences, nil);
    SEL enableIdleTimer = NSSelectorFromString(@"enableIdleTimer");
    if ([preferences respondsToSelector:enableIdleTimer]) {
        IMP implementation = [preferences methodForSelector:enableIdleTimer];
        if (implementation) ((void (*)(id, SEL))implementation)(preferences, enableIdleTimer);
    }
    FilzaWebDAVAuthenticationUsername = nil;
    FilzaWebDAVAuthenticationPasswordMD5 = nil;
    FilzaWebDAVAuthenticationRequired = NO;
    FilzaWebDAVWriteStatus(@"WebDAV server stopped");
    FilzaDiagnosticsAppend(@"WebDAV", @"in-process WebDAV server stopped");
    [NSNotificationCenter.defaultCenter postNotificationName:@"AirBrowserChanged" object:preferences];
}

static void FilzaWebDAVStartAirBrowser(id preferences, __unused SEL selector)
{
    if (FilzaWebDAVStartInFlight) {
        return;
    }

    FilzaWebDAVStartInFlight = YES;
    FilzaWebDAVForceInProcessSettings(preferences);
    FilzaDiagnosticsAppend(@"WebDAV", @"start requested; invoking pinned complete in-process WebDAV implementation");
    @try {
        BOOL started = FilzaWebDAVStartPinnedServer(preferences);
        if (started) {
            SEL disableIdleTimer = NSSelectorFromString(@"disableIdleTimer");
            if ([preferences respondsToSelector:disableIdleTimer]) {
                IMP implementation = [preferences methodForSelector:disableIdleTimer];
                if (implementation) ((void (*)(id, SEL))implementation)(preferences, disableIdleTimer);
            }
            [NSNotificationCenter.defaultCenter postNotificationName:@"AirBrowserChanged" object:preferences];
        }
    } @catch (NSException *exception) {
        FilzaDiagnosticsAppend(@"WebDAV",
                               [NSString stringWithFormat:@"start exception: %@ | %@",
                                exception.name, exception.reason ?: @"no reason"]);
    }
    FilzaWebDAVStartInFlight = NO;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FilzaWebDAVReport(preferences, @"after start", YES);
    });
}

static void FilzaWebDAVPreferenceChanged(id preferences, SEL selector,
                                         id value, id key, uintptr_t notification)
{
    if (FilzaOriginalSetPreference)
        FilzaOriginalSetPreference(preferences, selector, value, key, notification);
    if (![key isKindOfClass:NSString.class] ||
        ![(NSString *)key isEqualToString:FilzaWebDAVEnabledKey]) return;

    BOOL enabled = [value respondsToSelector:@selector(boolValue)] && [value boolValue];
    FilzaDiagnosticsAppend(@"WebDAV", [NSString stringWithFormat:
        @"WebDAV toggle preference observed enabled=%@", enabled ? @"YES" : @"NO"]);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (enabled)
            FilzaWebDAVStartAirBrowser(preferences, FilzaStartAirBrowserSelector);
        else
            FilzaWebDAVStopAirBrowser(preferences, FilzaStopAirBrowserSelector);
    });
}

static void FilzaWebDAVPreferenceRemoved(id preferences, SEL selector,
                                         id key, uintptr_t notification)
{
    if (FilzaOriginalRemovePreference)
        FilzaOriginalRemovePreference(preferences, selector, key, notification);
    if (![key isKindOfClass:NSString.class] ||
        ![(NSString *)key isEqualToString:FilzaWebDAVEnabledKey]) return;

    FilzaDiagnosticsAppend(@"WebDAV", @"WebDAV toggle preference removed; stopping listener");
    dispatch_async(dispatch_get_main_queue(), ^{
        FilzaWebDAVStopAirBrowser(preferences, FilzaStopAirBrowserSelector);
    });
}

static void FilzaWebDAVSwitchAirBrowserCheckbox(id controller, SEL selector)
{
    if (FilzaOriginalSwitchAirBrowserCheckbox)
        FilzaOriginalSwitchAirBrowserCheckbox(controller, selector);

    // Filza updates its preference during this action. Read it on the next run
    // loop so this also covers builds that bypass setObject:forPreferenceKey:.
    dispatch_async(dispatch_get_main_queue(), ^{
        id preferences = FilzaWebDAVSharedPreferences();
        BOOL enabled = FilzaWebDAVBoolPreference(preferences, FilzaWebDAVEnabledKey);
        FilzaDiagnosticsAppend(@"WebDAV", [NSString stringWithFormat:
            @"WebDAV checkbox action completed enabled=%@", enabled ? @"YES" : @"NO"]);
        if (enabled)
            FilzaWebDAVStartAirBrowser(preferences, FilzaStartAirBrowserSelector);
        else
            FilzaWebDAVStopAirBrowser(preferences, FilzaStopAirBrowserSelector);
    });
}

static void FilzaWebDAVInstallPreferenceHooks(Class preferencesClass)
{
    if (FilzaWebDAVPreferenceHooksInstalled || !preferencesClass) return;

    SEL setSelector = NSSelectorFromString(@"setObject:forPreferenceKey:notification:");
    Method setMethod = class_getInstanceMethod(preferencesClass, setSelector);
    if (setMethod) {
        FilzaOriginalSetPreference = (void (*)(id, SEL, id, id, uintptr_t))
            method_getImplementation(setMethod);
        method_setImplementation(setMethod, (IMP)FilzaWebDAVPreferenceChanged);
    }

    SEL removeSelector = NSSelectorFromString(@"removeObjectForPreferenceKey:notification:");
    Method removeMethod = class_getInstanceMethod(preferencesClass, removeSelector);
    if (removeMethod) {
        FilzaOriginalRemovePreference = (void (*)(id, SEL, id, uintptr_t))
            method_getImplementation(removeMethod);
        method_setImplementation(removeMethod, (IMP)FilzaWebDAVPreferenceRemoved);
    }

    Class controllerClass = NSClassFromString(@"TGPreferencesTableViewController");
    SEL checkboxSelector = NSSelectorFromString(@"swithAirBrowserCheckbox");
    Method checkboxMethod = controllerClass
        ? class_getInstanceMethod(controllerClass, checkboxSelector) : NULL;
    if (checkboxMethod) {
        FilzaOriginalSwitchAirBrowserCheckbox = (void (*)(id, SEL))
            method_getImplementation(checkboxMethod);
        method_setImplementation(checkboxMethod, (IMP)FilzaWebDAVSwitchAirBrowserCheckbox);
    }

    FilzaWebDAVPreferenceHooksInstalled = setMethod || removeMethod || checkboxMethod;
    FilzaDiagnosticsAppend(@"WebDAV", [NSString stringWithFormat:
        @"WebDAV toggle hooks installed preference-write=%@ preference-remove=%@ checkbox=%@",
        setMethod ? @"YES" : @"NO", removeMethod ? @"YES" : @"NO",
        checkboxMethod ? @"YES" : @"NO"]);
}

static void FilzaWebDAVResumeIfNeeded(NSString *reason)
{
    id preferences = FilzaWebDAVSharedPreferences();
    if (!preferences) {
        FilzaDiagnosticsAppend(@"WebDAV", @"TGPreferences is unavailable");
        return;
    }

    FilzaWebDAVForceInProcessSettings(preferences);
    BOOL enabled = FilzaWebDAVBoolPreference(preferences, FilzaWebDAVEnabledKey);
    BOOL started = FilzaWebDAVCallBool(preferences, @"isServerStarted");
    if (enabled && !started && [preferences respondsToSelector:FilzaStartAirBrowserSelector]) {
        IMP startImplementation = [preferences methodForSelector:FilzaStartAirBrowserSelector];
        if (startImplementation) {
            ((void (*)(id, SEL))startImplementation)(preferences, FilzaStartAirBrowserSelector);
            return;
        }
    }
    FilzaWebDAVReport(preferences, reason, NO);
}

static void FilzaWebDAVInstall(void)
{
    Class preferencesClass = NSClassFromString(@"TGPreferences");
    FilzaStartAirBrowserSelector = NSSelectorFromString(@"startAirBrowser");
    FilzaStopAirBrowserSelector = NSSelectorFromString(@"stopAirBrowser");
    Method startMethod = class_getInstanceMethod(preferencesClass, FilzaStartAirBrowserSelector);
    if (!preferencesClass || !startMethod) {
        FilzaDiagnosticsAppend(@"WebDAV", @"TGPreferences.startAirBrowser hook unavailable");
        return;
    }

    FilzaOriginalStartAirBrowser = (void (*)(id, SEL))method_getImplementation(startMethod);
    method_setImplementation(startMethod, (IMP)FilzaWebDAVStartAirBrowser);
    Method stopMethod = class_getInstanceMethod(preferencesClass, FilzaStopAirBrowserSelector);
    if (stopMethod) {
        FilzaOriginalStopAirBrowser = (void (*)(id, SEL))method_getImplementation(stopMethod);
        method_setImplementation(stopMethod, (IMP)FilzaWebDAVStopAirBrowser);
    }
    FilzaWebDAVInstallPreferenceHooks(preferencesClass);
    FilzaDiagnosticsAppend(@"WebDAV", @"jailed in-process WebDAV lifecycle hook installed");

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
        FilzaWebDAVResumeIfNeeded(@"application launched");
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
        FilzaWebDAVResumeIfNeeded(@"application active");
    }];
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
        FilzaWebDAVReport(FilzaWebDAVSharedPreferences(), @"application backgrounded; iOS may suspend the listener", NO);
    }];
}

__attribute__((constructor)) static void FilzaWebDAVRuntimeInit(void)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            FilzaWebDAVInstall();
        });
    }
}
