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
static NSString *const FZAirliftServiceProxyName = @"com.apple.atc.xpc.service";
static NSString *const FZAirliftFrameworkPath = @"/System/Library/PrivateFrameworks/AirTraffic.framework/AirTraffic";

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
    __block BOOL replyReceived = NO;
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
                replyReceived = YES;
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
    result[@"CompletionReceived"] = @(replyReceived);
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

static NSDictionary *FZAirliftDescribeMessageLink(id link)
{
    NSMutableDictionary *description = [@{
        @"Class": link ? NSStringFromClass([link class]) : @"",
        @"Description": link ? [link description] ?: @"" : @""
    } mutableCopy];

    SEL identifierSelector = NSSelectorFromString(@"identifier");
    if (link && [link respondsToSelector:identifierSelector]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(link, identifierSelector);
        if (value) description[@"Identifier"] = [value description] ?: @"";
    }
    SEL openSelector = NSSelectorFromString(@"isOpen");
    if (link && [link respondsToSelector:openSelector]) {
        description[@"Open"] = @(((BOOL (*)(id, SEL))objc_msgSend)(link, openSelector));
    }
    SEL initializedSelector = NSSelectorFromString(@"isInitialized");
    if (link && [link respondsToSelector:initializedSelector]) {
        description[@"Initialized"] = @(((BOOL (*)(id, SEL))objc_msgSend)(link, initializedSelector));
    }
    SEL endpointTypeSelector = NSSelectorFromString(@"endpointType");
    if (link && [link respondsToSelector:endpointTypeSelector]) {
        description[@"EndpointType"] = @(((NSInteger (*)(id, SEL))objc_msgSend)(link, endpointTypeSelector));
    }
    return description;
}

// Uses Apple's ATServiceProxy client exactly for the operation it is designed
// to expose: fetch existing daemon-owned message-link endpoints. This function
// never invokes sendRequest:, sendResponse:, requestSyncForLibrary:, or any
// asset method. A bounded outer wait prevents the diagnostics writer itself
// from hanging if the private service is unavailable to the Filza sandbox.
static NSDictionary *FZAirliftProbeServiceProxy(void)
{
    NSMutableDictionary *result = [@{
        @"Service": FZAirliftServiceProxyName,
        @"Attempted": @NO,
        @"ClassPresent": @NO,
        @"ProxyCreated": @NO,
        @"Completed": @NO,
        @"TimedOut": @NO,
        @"MessageLinkCount": @0
    } mutableCopy];

    dlerror();
    void *airTrafficHandle = dlopen(FZAirliftFrameworkPath.fileSystemRepresentation,
                                    RTLD_LAZY | RTLD_LOCAL);
    const char *loadError = dlerror();
    result[@"AirTrafficLoaded"] = @(airTrafficHandle != NULL);
    if (loadError) {
        result[@"AirTrafficLoadError"] = [NSString stringWithUTF8String:loadError] ?: @"unknown";
    }

    Class proxyClass = NSClassFromString(@"ATServiceProxy");
    result[@"ClassPresent"] = @(proxyClass != Nil);
    if (!proxyClass) {
        if (airTrafficHandle) dlclose(airTrafficHandle);
        return result;
    }

    SEL initSelector = NSSelectorFromString(@"initWithConnection:");
    SEL linksSelector = NSSelectorFromString(@"messageLinks");
    if (![proxyClass instancesRespondToSelector:initSelector] ||
        ![proxyClass instancesRespondToSelector:linksSelector]) {
        result[@"ExpectedSelectorsPresent"] = @NO;
        if (airTrafficHandle) dlclose(airTrafficHandle);
        return result;
    }
    result[@"ExpectedSelectorsPresent"] = @YES;
    result[@"Attempted"] = @YES;

    id allocated = ((id (*)(id, SEL))objc_msgSend)((id)proxyClass, sel_registerName("alloc"));
    id serviceProxy = ((id (*)(id, SEL, id))objc_msgSend)(allocated, initSelector, nil);
    result[@"ProxyCreated"] = @(serviceProxy != nil);
    if (!serviceProxy) {
        if (airTrafficHandle) dlclose(airTrafficHandle);
        return result;
    }

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block id links = nil;
    __block BOOL completed = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            links = ((id (*)(id, SEL))objc_msgSend)(serviceProxy, linksSelector);
            completed = YES;
            dispatch_semaphore_signal(done);
        }
    });

    long waitResult = dispatch_semaphore_wait(
        done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
    if (waitResult != 0) {
        result[@"TimedOut"] = @YES;
    } else {
        result[@"Completed"] = @(completed);
        NSArray *objects = nil;
        if ([links isKindOfClass:NSSet.class]) {
            objects = [(NSSet *)links allObjects];
        } else if ([links isKindOfClass:NSArray.class]) {
            objects = links;
        }
        if (objects) {
            result[@"ResultClass"] = NSStringFromClass([links class]) ?: @"";
            result[@"MessageLinkCount"] = @(objects.count);
            NSMutableArray *descriptions = [NSMutableArray arrayWithCapacity:objects.count];
            for (id link in objects) {
                [descriptions addObject:FZAirliftDescribeMessageLink(link)];
            }
            result[@"MessageLinks"] = descriptions;
        } else if (links) {
            result[@"ResultClass"] = NSStringFromClass([links class]) ?: @"";
            result[@"UnexpectedResult"] = [links description] ?: @"";
        }
    }

    // ATServiceProxy owns the private XPC connection. Do not explicitly tear
    // it down on the timeout path because the worker may still be inside the
    // synchronous messageLinks call. Process teardown will reclaim it safely.
    if (waitResult == 0 && airTrafficHandle) dlclose(airTrafficHandle);
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
        FZAirliftProbeMachService(@"com.apple.atc.xpc.service"),
        FZAirliftProbeMachService(@"com.apple.atc.xpc.sessions")
    ];

    NSArray *images = @[
        FZAirliftProbeImage(FZAirliftFrameworkPath),
        FZAirliftProbeImage(@"/System/Library/PrivateFrameworks/ATFoundation.framework/ATFoundation"),
        FZAirliftProbeImage(@"/System/Library/PrivateFrameworks/AirTrafficDevice.framework/AirTrafficDevice"),
        FZAirliftProbeImage(@"/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost")
    ];

    NSArray *classes = @[
        FZAirliftProbeClass(@"ATConnection"),
        FZAirliftProbeClass(@"ATServiceProxy"),
        FZAirliftProbeClass(@"ATMessageLinkProxy"),
        FZAirliftProbeClass(@"ATDeviceService"),
        FZAirliftProbeClass(@"ATXPCListener"),
        FZAirliftProbeClass(@"AirTrafficDevice"),
        FZAirliftProbeClass(@"ATDevice"),
        FZAirliftProbeClass(@"ATAirlock"),
        FZAirliftProbeClass(@"ATLegacyAssetLink")
    ];

    NSDictionary *report = @{
        @"SchemaVersion": @3,
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
        @"ServiceProxyEnumeration": FZAirliftProbeServiceProxy(),
        @"Interpretation": @"com.apple.atc.xpc answers sync-state queries through ATDeviceService. com.apple.atc.xpc.service is Apple's service-proxy channel for enumerating daemon-owned ATMessageLink endpoints. MessageLinkCount > 0 proves those endpoints are exposed to this process, but this probe never sends FileComplete or any crafted AirTraffic message and therefore does not claim an Airlift write primitive."
    };

    NSString *plistPath = [directory stringByAppendingPathComponent:@"Airlift On-Device Probe.plist"];
    BOOL wrote = [report writeToFile:plistPath atomically:YES];

    NSString *readme =
        @"Airlift experimental integration\n\n"
         "This probe checks whether the current Filza process can reach the iOS-side AirTraffic/ATC machinery used by Airlift. It does not claim a sandbox escape.\n\n"
         "Probe 1: com.apple.atc.xpc receives one read-only getSyncStateWithCompletion: request. No sync is requested and no asset state is changed.\n\n"
         "Probe 2: com.apple.atc.xpc.service uses Apple's ATServiceProxy to enumerate existing daemon-owned message-link endpoints. It does not call sendRequest:, sendResponse:, requestSyncForLibrary:, prioritizeAsset:, or any FileComplete path.\n\n"
         "If ReadOnlyXPCHandshake -> SyncStateReceived is true and ServiceProxyEnumeration -> MessageLinkCount is greater than zero, the next engineering step is a separately gated message-format experiment against an existing daemon link. That still would not imply full filesystem access.\n\n"
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
