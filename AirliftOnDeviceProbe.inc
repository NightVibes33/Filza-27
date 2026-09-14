#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_init.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>

#if __has_include(<sandbox.h>)
#import <sandbox.h>
#define FZ_AIRLIFT_HAS_SANDBOX 1
#else
#define FZ_AIRLIFT_HAS_SANDBOX 0
#endif

#if __has_include(<servers/bootstrap.h>)
#import <servers/bootstrap.h>
#define FZ_AIRLIFT_HAS_BOOTSTRAP 1
#else
#define FZ_AIRLIFT_HAS_BOOTSTRAP 0
#endif

#import "MCMFilzaIntegration.h"

static NSString *const FZAirliftPinnedRevision = @"bcd220412fd71b66c2a1459f1a49e255a08aea01";
static NSString *const FZAirliftPrimaryXPCService = @"com.apple.atc.xpc";

// Read-only subset of ATXPCInterfaceProtocol. On the device side this method
// simply returns the legacy sync manager's currentSyncState and an NSError.
// It does not request a sync, transfer an asset, mutate Books state, or invoke
// the Airlift file primitive.
@protocol FZAirliftReadOnlyXPCProtocol
- (void)getSyncStateWithCompletion:(void (^)(NSError *error, NSDictionary *state))completion;
@end

static NSDictionary *FZAirliftProbeMachService(NSString *name)
{
    NSMutableDictionary *result = [@{ @"Name": name ?: @"" } mutableCopy];

#if FZ_AIRLIFT_HAS_SANDBOX
    int sandboxResult = sandbox_check(getpid(), "mach-lookup", SANDBOX_FILTER_GLOBAL_NAME,
                                      name.UTF8String);
    result[@"SandboxCheckResult"] = @(sandboxResult);
    result[@"SandboxAllowsLookup"] = @(sandboxResult == 0);
#else
    result[@"SandboxCheckAvailable"] = @NO;
#endif

#if FZ_AIRLIFT_HAS_BOOTSTRAP
    mach_port_t servicePort = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, name.UTF8String, &servicePort);
    BOOL reachable = (kr == KERN_SUCCESS && servicePort != MACH_PORT_NULL);
    result[@"BootstrapLookupResult"] = @(kr);
    result[@"BootstrapReachable"] = @(reachable);
    if (servicePort != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), servicePort);
    }
#else
    result[@"BootstrapLookupAvailable"] = @NO;
#endif

    return result;
}

static NSDictionary *FZAirliftProbeImage(NSString *path)
{
    NSMutableDictionary *result = [@{ @"Path": path ?: @"" } mutableCopy];
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    result[@"Exists"] = @(exists);

    dlerror();
    void *handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
    const char *errorText = dlerror();
    result[@"DlopenSucceeded"] = @(handle != NULL);
    if (errorText) {
        result[@"DlopenError"] = [NSString stringWithUTF8String:errorText] ?: @"unknown";
    }
    if (handle) dlclose(handle);
    return result;
}

static NSDictionary *FZAirliftProbeClass(NSString *name)
{
    Class cls = NSClassFromString(name);
    return @{
        @"Name": name ?: @"",
        @"Present": @(cls != Nil),
        @"RuntimeName": cls ? NSStringFromClass(cls) : @""
    };
}

static void FZAirliftSetObjectHandler(id object, NSString *selectorName, id block)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (object && [object respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(object, selector, block);
    }
}

static NSDictionary *FZAirliftProbeReadOnlyXPC(void)
{
    NSMutableDictionary *result = [@{
        @"Service": FZAirliftPrimaryXPCService,
        @"Attempted": @NO,
        @"ConnectionCreated": @NO,
        @"ProxyCreated": @NO,
        @"CompletionReceived": @NO,
        @"TimedOut": @NO
    } mutableCopy];

    Class connectionClass = NSClassFromString(@"NSXPCConnection");
    Class interfaceClass = NSClassFromString(@"NSXPCInterface");
    result[@"NSXPCConnectionClassPresent"] = @(connectionClass != Nil);
    result[@"NSXPCInterfaceClassPresent"] = @(interfaceClass != Nil);
    if (!connectionClass || !interfaceClass) return result;

    SEL initSelector = NSSelectorFromString(@"initWithMachServiceName:options:");
    if (![connectionClass instancesRespondToSelector:initSelector]) {
        result[@"InitializerPresent"] = @NO;
        return result;
    }
    result[@"InitializerPresent"] = @YES;
    result[@"Attempted"] = @YES;

    id allocated = ((id (*)(id, SEL))objc_msgSend)((id)connectionClass, sel_registerName("alloc"));
    id connection = ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(
        allocated, initSelector, FZAirliftPrimaryXPCService, (NSUInteger)0);
    if (!connection) return result;
    result[@"ConnectionCreated"] = @YES;

    dispatch_semaphore_t terminal = dispatch_semaphore_create(0);
    __block BOOL finished = NO;
    __block BOOL interrupted = NO;
    __block BOOL invalidated = NO;
    __block NSError *proxyError = nil;
    __block NSError *replyError = nil;
    __block NSDictionary *syncState = nil;

    void (^signalOnce)(void) = ^{
        @synchronized (result) {
            if (!finished) {
                finished = YES;
                dispatch_semaphore_signal(terminal);
            }
        }
    };

    FZAirliftSetObjectHandler(connection, @"setInterruptionHandler:", ^{
        interrupted = YES;
        signalOnce();
    });
    FZAirliftSetObjectHandler(connection, @"setInvalidationHandler:", ^{
        invalidated = YES;
        signalOnce();
    });

    SEL interfaceSelector = NSSelectorFromString(@"interfaceWithProtocol:");
    id interface = nil;
    if ([interfaceClass respondsToSelector:interfaceSelector]) {
        interface = ((id (*)(id, SEL, Protocol *))objc_msgSend)(
            (id)interfaceClass, interfaceSelector, @protocol(FZAirliftReadOnlyXPCProtocol));
    }
    result[@"RemoteInterfaceCreated"] = @(interface != nil);
    if (interface && [connection respondsToSelector:NSSelectorFromString(@"setRemoteObjectInterface:")]) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            connection, NSSelectorFromString(@"setRemoteObjectInterface:"), interface);
    }

    if ([connection respondsToSelector:NSSelectorFromString(@"resume")]) {
        ((void (*)(id, SEL))objc_msgSend)(connection, NSSelectorFromString(@"resume"));
    }

    id proxy = nil;
    SEL proxySelector = NSSelectorFromString(@"remoteObjectProxyWithErrorHandler:");
    if ([connection respondsToSelector:proxySelector]) {
        proxy = ((id (*)(id, SEL, id))objc_msgSend)(connection, proxySelector, ^(NSError *error) {
            proxyError = error;
            signalOnce();
        });
    }
    result[@"ProxyCreated"] = @(proxy != nil);

    SEL syncSelector = NSSelectorFromString(@"getSyncStateWithCompletion:");
    if (proxy && [proxy respondsToSelector:syncSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(proxy, syncSelector,
            ^(NSError *error, NSDictionary *state) {
                replyError = error;
                if ([state isKindOfClass:NSDictionary.class]) syncState = state;
                signalOnce();
            });
    } else {
        result[@"SyncSelectorAvailable"] = @NO;
        signalOnce();
    }

    long waitResult = dispatch_semaphore_wait(
        terminal, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
    if (waitResult != 0) result[@"TimedOut"] = @YES;

    result[@"Interrupted"] = @(interrupted);
    result[@"Invalidated"] = @(invalidated);
    result[@"CompletionReceived"] = @(syncState != nil || replyError != nil);
    if (proxyError) {
        result[@"ProxyErrorDomain"] = proxyError.domain ?: @"";
        result[@"ProxyErrorCode"] = @(proxyError.code);
        result[@"ProxyErrorDescription"] = proxyError.localizedDescription ?: @"";
    }
    if (replyError) {
        result[@"ReplyErrorDomain"] = replyError.domain ?: @"";
        result[@"ReplyErrorCode"] = @(replyError.code);
        result[@"ReplyErrorDescription"] = replyError.localizedDescription ?: @"";
    }
    if (syncState) {
        result[@"SyncStateReceived"] = @YES;
        result[@"SyncStateClass"] = NSStringFromClass(syncState.class) ?: @"";
        result[@"SyncStateKeyCount"] = @(syncState.count);
        result[@"SyncStateKeys"] = [[syncState.allKeys valueForKey:@"description"] sortedArrayUsingSelector:@selector(compare:)];
    } else {
        result[@"SyncStateReceived"] = @NO;
    }

    if ([connection respondsToSelector:NSSelectorFromString(@"invalidate")]) {
        ((void (*)(id, SEL))objc_msgSend)(connection, NSSelectorFromString(@"invalidate"));
    }
    return result;
}

static void FZAirliftWriteProbe(void)
{
    NSString *virtualRoot = MCMFilzaVirtualRoot();
    if (!virtualRoot.length) {
        NSLog(@"[AirliftProbe] no Filza virtual root available");
        return;
    }

    NSString *directory = [virtualRoot stringByAppendingPathComponent:@"Airlift - Experimental"];
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&directoryError]) {
        NSLog(@"[AirliftProbe] cannot create diagnostics directory: %@", directoryError);
        return;
    }

    NSArray *services = @[
        FZAirliftProbeMachService(@"com.apple.atc"),
        FZAirliftProbeMachService(@"com.apple.atc.xpc"),
        FZAirliftProbeMachService(@"com.apple.atc.xpc.sessions")
    ];

    NSArray *images = @[
        FZAirliftProbeImage(@"/System/Library/PrivateFrameworks/AirTraffic.framework/AirTraffic"),
        FZAirliftProbeImage(@"/System/Library/PrivateFrameworks/AirTrafficDevice.framework/AirTrafficDevice"),
        FZAirliftProbeImage(@"/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost")
    ];

    NSArray *classes = @[
        FZAirliftProbeClass(@"ATDeviceService"),
        FZAirliftProbeClass(@"ATXPCListener"),
        FZAirliftProbeClass(@"AirTrafficDevice"),
        FZAirliftProbeClass(@"ATDevice"),
        FZAirliftProbeClass(@"ATAirlock"),
        FZAirliftProbeClass(@"ATLegacyAssetLink")
    ];

    NSDictionary *report = @{
        @"SchemaVersion": @2,
        @"PinnedAirliftRevision": FZAirliftPinnedRevision,
        @"GeneratedAt": [NSDate date],
        @"Process": NSProcessInfo.processInfo.processName ?: @"",
        @"PID": @(getpid()),
        @"SystemVersion": UIDevice.currentDevice.systemVersion ?: @"",
        @"Model": UIDevice.currentDevice.model ?: @"",
        @"MachServices": services,
        @"PrivateFrameworks": images,
        @"RuntimeClasses": classes,
        @"ReadOnlyXPCHandshake": FZAirliftProbeReadOnlyXPC(),
        @"Interpretation": @"com.apple.atc.xpc BootstrapReachable=true proves only mach lookup. ReadOnlyXPCHandshake.SyncStateReceived=true additionally proves ATDeviceService accepted the Filza XPC connection and answered getSyncStateWithCompletion:. Neither result invokes the Airlift file primitive."
    };

    NSString *plistPath = [directory stringByAppendingPathComponent:@"Airlift On-Device Probe.plist"];
    BOOL wrote = [report writeToFile:plistPath atomically:YES];

    NSString *readme =
        @"Airlift experimental integration\n\n"
         "This probe checks whether the current Filza process can reach the iOS-side AirTraffic/ATC machinery used by Airlift. It does not claim a sandbox escape.\n\n"
         "Primary service: com.apple.atc.xpc. The probe first checks sandbox/bootstrap visibility, then performs one read-only getSyncStateWithCompletion: XPC request. No sync is requested, no Books state is modified, and no Airlift file operation is attempted.\n\n"
         "If ReadOnlyXPCHandshake -> SyncStateReceived is true, the next engineering step is mapping the Books/asset transport reachable over the accepted AT connection. If it is false, inspect ProxyError/ReplyError plus the mach lookup results.\n\n"
         "The public Airlift PoC remains host-assisted and is pinned by this branch to revision bcd220412fd71b66c2a1459f1a49e255a08aea01.\n";
    [readme writeToFile:[directory stringByAppendingPathComponent:@"README.txt"]
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:nil];

    NSLog(@"[AirliftProbe] report %@ at %@", wrote ? @"written" : @"failed", plistPath);
}

__attribute__((constructor)) static void FZAirliftProbeInit(void)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        FZAirliftWriteProbe();
    });
}
