// Third-stage Airlift diagnostic. This file is intentionally imported after
// AirliftOnDeviceProbe.inc into RuntimeStability.m so it can reuse the pinned
// framework/service constants without changing Filza's large Theos source list.
//
// Scope: obtain one daemon-owned ATMessageLinkProxy through ATServiceProxy,
// inspect the already-created NSXPCConnection, and issue only the endpoint's
// connectWithCompletion: handshake. No AirTraffic request/response, sync,
// asset, FileComplete, or filesystem operation is sent.

static NSDictionary *FZAirliftProbeEndpointAdmission(void)
{
    NSMutableDictionary *result = [@{
        @"Service": FZAirliftServiceProxyName,
        @"Attempted": @NO,
        @"MessageLinksFetched": @NO,
        @"MessageLinkCount": @0,
        @"ConnectionRecovered": @NO,
        @"RemoteProxyCreated": @NO,
        @"ConnectAttempted": @NO,
        @"CompletionReceived": @NO,
        @"TimedOut": @NO,
        @"EndpointAccepted": @NO
    } mutableCopy];

    // Ensure ATServiceProxy / ATMessageLinkProxy are registered in this process.
    dlerror();
    void *airTrafficHandle = dlopen(FZAirliftFrameworkPath.fileSystemRepresentation,
                                    RTLD_LAZY | RTLD_LOCAL);
    const char *loadError = dlerror();
    result[@"AirTrafficLoaded"] = @(airTrafficHandle != NULL);
    if (loadError) {
        result[@"AirTrafficLoadError"] = [NSString stringWithUTF8String:loadError] ?: @"unknown";
    }

    Class proxyClass = NSClassFromString(@"ATServiceProxy");
    result[@"ServiceProxyClassPresent"] = @(proxyClass != Nil);
    if (!proxyClass) return result;

    SEL initSelector = NSSelectorFromString(@"initWithConnection:");
    SEL linksSelector = NSSelectorFromString(@"messageLinks");
    if (![proxyClass instancesRespondToSelector:initSelector] ||
        ![proxyClass instancesRespondToSelector:linksSelector]) {
        result[@"ExpectedServiceProxySelectorsPresent"] = @NO;
        return result;
    }
    result[@"ExpectedServiceProxySelectorsPresent"] = @YES;
    result[@"Attempted"] = @YES;

    id allocated = ((id (*)(id, SEL))objc_msgSend)((id)proxyClass, sel_registerName("alloc"));
    id serviceProxy = ((id (*)(id, SEL, id))objc_msgSend)(allocated, initSelector, nil);
    if (!serviceProxy) {
        result[@"ServiceProxyCreated"] = @NO;
        return result;
    }
    result[@"ServiceProxyCreated"] = @YES;

    // Apple's -messageLinks wrapper waits synchronously for the service-proxy
    // reply. Bound that call externally so a sandbox denial cannot hang Filza.
    dispatch_semaphore_t linksDone = dispatch_semaphore_create(0);
    __block id links = nil;
    __block BOOL linksCompleted = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            links = ((id (*)(id, SEL))objc_msgSend)(serviceProxy, linksSelector);
            linksCompleted = YES;
            dispatch_semaphore_signal(linksDone);
        }
    });

    long linksWait = dispatch_semaphore_wait(
        linksDone, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
    if (linksWait != 0) {
        result[@"MessageLinksTimedOut"] = @YES;
        return result;
    }
    result[@"MessageLinksFetched"] = @(linksCompleted);

    NSArray *objects = nil;
    if ([links isKindOfClass:NSSet.class]) {
        objects = [(NSSet *)links allObjects];
    } else if ([links isKindOfClass:NSArray.class]) {
        objects = links;
    }
    if (!objects) {
        if (links) result[@"UnexpectedMessageLinksClass"] = NSStringFromClass([links class]) ?: @"";
        return result;
    }

    result[@"MessageLinkCount"] = @(objects.count);
    if (objects.count == 0) return result;

    id link = objects.firstObject;
    result[@"MessageLinkClass"] = NSStringFromClass([link class]) ?: @"";
    result[@"MessageLinkDescription"] = [link description] ?: @"";

    // ATMessageLinkProxy owns a resumed NSXPCConnection in its private
    // _connection ivar. KVC is used only to observe that existing connection;
    // this probe does not replace interfaces, handlers, or the endpoint.
    id connection = nil;
    @try {
        connection = [link valueForKey:@"_connection"];
    } @catch (NSException *exception) {
        result[@"ConnectionRecoveryException"] = exception.reason ?: exception.name ?: @"unknown";
    }
    if (!connection) {
        @try {
            connection = [link valueForKey:@"connection"];
        } @catch (__unused NSException *exception) {
        }
    }

    result[@"ConnectionRecovered"] = @(connection != nil);
    if (!connection) return result;
    result[@"ConnectionClass"] = NSStringFromClass([connection class]) ?: @"";
    result[@"ConnectionDescription"] = [connection description] ?: @"";

    SEL proxySelector = NSSelectorFromString(@"remoteObjectProxyWithErrorHandler:");
    if (![connection respondsToSelector:proxySelector]) {
        result[@"RemoteProxySelectorPresent"] = @NO;
        return result;
    }
    result[@"RemoteProxySelectorPresent"] = @YES;

    dispatch_semaphore_t terminal = dispatch_semaphore_create(0);
    __block BOOL finished = NO;
    __block BOOL completionReceived = NO;
    __block NSError *proxyError = nil;
    __block NSError *replyError = nil;

    void (^signalOnce)(void) = ^{
        @synchronized (result) {
            if (!finished) {
                finished = YES;
                dispatch_semaphore_signal(terminal);
            }
        }
    };

    id remoteProxy = ((id (*)(id, SEL, id))objc_msgSend)(
        connection, proxySelector, ^(NSError *error) {
            proxyError = error;
            signalOnce();
        });
    result[@"RemoteProxyCreated"] = @(remoteProxy != nil);
    if (!remoteProxy) return result;

    // ATMessageLinkProxy's own addObserver: implementation calls this exact
    // remote method. Calling it directly lets the diagnostic preserve the
    // returned NSError instead of having Apple's wrapper only log it.
    SEL connectSelector = NSSelectorFromString(@"connectWithCompletion:");
    result[@"ConnectSelector"] = NSStringFromSelector(connectSelector);
    result[@"ConnectAttempted"] = @YES;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(remoteProxy, connectSelector,
            ^(NSError *error) {
                completionReceived = YES;
                replyError = error;
                signalOnce();
            });
    } @catch (NSException *exception) {
        result[@"ConnectExceptionName"] = exception.name ?: @"";
        result[@"ConnectExceptionReason"] = exception.reason ?: @"";
        signalOnce();
    }

    long waitResult = dispatch_semaphore_wait(
        terminal, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
    if (waitResult != 0) result[@"TimedOut"] = @YES;

    result[@"CompletionReceived"] = @(completionReceived);
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

    BOOL accepted = completionReceived && !proxyError && !replyError && waitResult == 0;
    result[@"EndpointAccepted"] = @(accepted);
    result[@"Interpretation"] = accepted
        ? @"The daemon-owned ATMessageLink endpoint accepted a connectWithCompletion: RPC from this Filza process. This proves endpoint admission only; no AirTraffic message or Airlift file primitive was invoked."
        : @"Endpoint admission was not proven. Inspect timeout/proxy/reply error fields. No AirTraffic message or Airlift file primitive was invoked.";

    // Do not invalidate the recovered connection. It is owned by the
    // ATMessageLinkProxy instance returned by Apple's service-proxy machinery.
    return result;
}

static void FZAirliftWriteEndpointAdmissionProbe(void)
{
    NSString *virtualRoot = MCMFilzaVirtualRoot();
    if (!virtualRoot.length) {
        NSLog(@"[AirliftEndpointProbe] no Filza virtual root available");
        return;
    }

    NSString *directory = [virtualRoot stringByAppendingPathComponent:@"Airlift - Experimental"];
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&directoryError]) {
        NSLog(@"[AirliftEndpointProbe] cannot create diagnostics directory: %@", directoryError);
        return;
    }

    NSDictionary *report = @{
        @"SchemaVersion": @1,
        @"PinnedAirliftRevision": FZAirliftPinnedRevision,
        @"GeneratedAt": [NSDate date],
        @"Process": NSProcessInfo.processInfo.processName ?: @"",
        @"PID": @(getpid()),
        @"SystemVersion": UIDevice.currentDevice.systemVersion ?: @"",
        @"EndpointAdmission": FZAirliftProbeEndpointAdmission(),
        @"SafetyBoundary": @"Read-only transport admission diagnostic. It does not call sendRequest:, sendResponse:, requestSyncForLibrary:, prioritizeAsset:, AssetManifest, FileComplete, ATAirlock, or any filesystem mutation path."
    };

    NSString *plistPath = [directory stringByAppendingPathComponent:@"Airlift Endpoint Admission.plist"];
    BOOL wrote = [report writeToFile:plistPath atomically:YES];
    NSLog(@"[AirliftEndpointProbe] report %@ at %@", wrote ? @"written" : @"failed", plistPath);
}

__attribute__((constructor)) static void FZAirliftEndpointProbeInit(void)
{
    // Run after the base Airlift probe so the two diagnostics do not compete
    // for the private service during process startup.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        FZAirliftWriteEndpointAdmissionProbe();
    });
}
