#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <stdbool.h>
#import <sys/socket.h>
#import <unistd.h>
#import "idevice.h"
#import "MCMFilzaIntegration.h"

// Follow-on route probe for modern RSD lockdown-service shims.
//
// RSD handshakes on modern iOS expose classic lockdown services as
// *.shim.remote endpoints. Public RSD captures show:
//   com.apple.atc.shim.remote
//   com.apple.atc2.shim.remote
//
// This probe asks the already-created RSD handshake for those exact service
// descriptors, opens their advertised TCP ports if present, then immediately
// drops the streams. It sends no service bytes and performs no AirTraffic
// protocol messages or filesystem operations.

static NSString *const FZAirliftRSDShimPairingGroup =
    @"group.com.edualexxis.MusicManager";
static const uint16_t FZAirliftRSDShimPairingPort = 49152;

static NSString *FZAirliftRSDShimString(const char *value)
{
    if (!value) return @"";
    return [NSString stringWithUTF8String:value] ?: @"<invalid-utf8>";
}

static NSDictionary *FZAirliftRSDShimConsumeError(IdeviceFfiError *error)
{
    if (!error) return @{ @"Success": @YES };
    int code = error->code;
    int subcode = error->sub_code;
    NSString *message = FZAirliftRSDShimString(error->message);
    idevice_error_free(error);
    return @{
        @"Success": @NO,
        @"Code": @(code),
        @"Subcode": @(subcode),
        @"Message": message
    };
}

static NSURL *FZAirliftRSDShimPairingURL(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *base =
        [fm containerURLForSecurityApplicationGroupIdentifier:
            FZAirliftRSDShimPairingGroup];
    if (!base) {
        base =
            [fm URLsForDirectory:NSDocumentDirectory
                       inDomains:NSUserDomainMask].firstObject;
    }
    if (!base) return nil;
    return [[base URLByAppendingPathComponent:@"pairing file" isDirectory:YES]
        URLByAppendingPathComponent:@"rpPairingFile.plist" isDirectory:NO];
}

static NSURL *FZAirliftRSDShimReportURL(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *base = nil;
    NSString *virtualRoot = MCMFilzaVirtualRoot();
    if (virtualRoot.length) {
        base = [NSURL fileURLWithPath:virtualRoot isDirectory:YES];
    }
    if (!base) {
        base =
            [fm URLsForDirectory:NSDocumentDirectory
                       inDomains:NSUserDomainMask].firstObject;
    }
    if (!base) return nil;

    NSURL *directory =
        [base URLByAppendingPathComponent:@"Airlift - Experimental"
                              isDirectory:YES];
    NSError *error = nil;
    if (![fm createDirectoryAtURL:directory
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&error]) {
        NSLog(@"[AirliftRSDShim] diagnostics directory failed: %@", error);
        return nil;
    }
    return [directory
        URLByAppendingPathComponent:@"Airlift RSD AirTraffic Shim Connect.plist"
                        isDirectory:NO];
}

static void FZAirliftRSDShimWrite(
    NSString *stage,
    NSString *state,
    NSDictionary *result)
{
    NSURL *output = FZAirliftRSDShimReportURL();
    if (!output) return;

    NSDictionary *report = @{
        @"SchemaVersion": @1,
        @"GeneratedAt": [NSDate date],
        @"Process": NSProcessInfo.processInfo.processName ?: @"",
        @"PID": @(getpid()),
        @"SystemVersion":
            NSProcessInfo.processInfo.operatingSystemVersionString ?: @"",
        @"State": state ?: @"Running",
        @"LastReachedStage": stage ?: @"unknown",
        @"AirTrafficRSDShim": result ?: @{},
        @"SafetyBoundary":
            @"Route discovery only. Opens and closes an RSD-advertised "
             @"AirTraffic shim TCP port when present. PayloadBytesSent is "
             @"always zero. No HostInfo, SyncRequest, AssetManifest, "
             @"FileComplete, ATAirlock, AFC request, read, or filesystem "
             @"mutation is attempted."
    };
    [report writeToURL:output atomically:YES];
}

static NSArray<NSString *> *FZAirliftRSDShimFeatures(
    const struct CRsdService *service)
{
    if (!service || !service->features ||
        service->features_count == 0) {
        return @[];
    }

    NSMutableArray<NSString *> *features =
        [NSMutableArray arrayWithCapacity:service->features_count];
    for (size_t i = 0; i < service->features_count; i++) {
        if (service->features[i]) {
            [features addObject:
                FZAirliftRSDShimString(service->features[i])];
        }
    }
    return features;
}

static NSDictionary *FZAirliftRSDShimDescriptor(
    const struct CRsdService *service)
{
    if (!service) return @{};
    return @{
        @"Name": FZAirliftRSDShimString(service->name),
        @"Entitlement": FZAirliftRSDShimString(service->entitlement),
        @"Port": @(service->port),
        @"UsesRemoteXPC": @(service->uses_remote_xpc),
        @"ServiceVersion": @(service->service_version),
        @"Features": FZAirliftRSDShimFeatures(service)
    };
}

static NSDictionary *FZAirliftProbeRSDShimConnect(void)
{
    NSMutableDictionary *result = [@{
        @"Attempted": @YES,
        @"PairingFilePresent": @NO,
        @"RPTunnelCreated": @NO,
        @"PayloadBytesSent": @0,
        @"AnyAirTrafficShimAdvertised": @NO,
        @"AnyAirTrafficShimConnected": @NO,
        @"AdapterStackClosed": @NO,
        @"TemporaryTunnelDestroyed": @NO
    } mutableCopy];

    struct RpPairingFileHandle *pairing = NULL;
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;

    NSURL *pairingURL = FZAirliftRSDShimPairingURL();
    result[@"PairingFilePath"] = pairingURL.path ?: @"";
    FZAirliftRSDShimWrite(@"pairing-file", @"Running", result);

    if (!pairingURL ||
        ![NSFileManager.defaultManager
            fileExistsAtPath:pairingURL.path]) {
        result[@"FailureStage"] = @"pairing-file";
        goto cleanup;
    }
    result[@"PairingFilePresent"] = @YES;

    IdeviceFfiError *error =
        rp_pairing_file_read(pairingURL.fileSystemRepresentation, &pairing);
    if (error || !pairing) {
        result[@"PairingRead"] = error
            ? FZAirliftRSDShimConsumeError(error)
            : @{ @"Success": @NO,
                 @"Message": @"pairing read returned a null handle" };
        result[@"FailureStage"] = @"pairing-read";
        goto cleanup;
    }
    result[@"PairingRead"] = @{ @"Success": @YES };

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(FZAirliftRSDShimPairingPort);
    if (inet_pton(AF_INET, "10.7.0.1", &address.sin_addr) != 1) {
        result[@"FailureStage"] = @"address";
        goto cleanup;
    }

    FZAirliftRSDShimWrite(@"rp-tunnel", @"Running", result);
    error = tunnel_create_rppairing(
        (const idevice_sockaddr *)&address,
        (idevice_socklen_t)sizeof(address),
        "Filza-Airlift-RSD-Shim-Probe",
        pairing,
        NULL,
        NULL,
        &adapter,
        &handshake);
    if (error || !adapter || !handshake) {
        result[@"RPTunnel"] = error
            ? FZAirliftRSDShimConsumeError(error)
            : @{ @"Success": @NO,
                 @"Message": @"RSD tunnel returned a null handle" };
        result[@"FailureStage"] = @"rp-tunnel";
        goto cleanup;
    }
    result[@"RPTunnelCreated"] = @YES;
    result[@"RPTunnel"] = @{ @"Success": @YES };

    NSArray<NSString *> *candidates = @[
        @"com.apple.atc.shim.remote",
        @"com.apple.atc2.shim.remote",
        @"com.apple.atc",
        @"com.apple.atc2"
    ];
    NSMutableArray<NSDictionary *> *attempts = [NSMutableArray array];

    for (NSString *candidate in candidates) {
        struct CRsdService *service = NULL;
        IdeviceFfiError *infoError =
            rsd_get_service_info(
                handshake,
                candidate.UTF8String,
                &service);

        NSMutableDictionary *attempt =
            [@{
                @"RequestedService": candidate,
                @"Advertised": @NO,
                @"ConnectAttempted": @NO,
                @"Connected": @NO,
                @"PayloadBytesSent": @0
            } mutableCopy];

        if (infoError || !service) {
            attempt[@"Lookup"] = infoError
                ? FZAirliftRSDShimConsumeError(infoError)
                : @{ @"Success": @NO,
                     @"Message": @"service info returned null" };
            [attempts addObject:attempt];
            continue;
        }

        attempt[@"Lookup"] = @{ @"Success": @YES };
        attempt[@"Advertised"] = @YES;
        attempt[@"Descriptor"] =
            FZAirliftRSDShimDescriptor(service);
        result[@"AnyAirTrafficShimAdvertised"] = @YES;

        FZAirliftRSDShimWrite(
            [NSString stringWithFormat:@"connect-%@", candidate],
            @"Running",
            result);

        struct ReadWriteOpaque *stream = NULL;
        attempt[@"ConnectAttempted"] = @YES;
        IdeviceFfiError *connectError =
            adapter_connect(adapter, service->port, &stream);
        if (connectError || !stream) {
            attempt[@"Connect"] = connectError
                ? FZAirliftRSDShimConsumeError(connectError)
                : @{ @"Success": @NO,
                     @"Message": @"adapter_connect returned null" };
        } else {
            attempt[@"Connect"] = @{ @"Success": @YES };
            attempt[@"Connected"] = @YES;
            result[@"AnyAirTrafficShimConnected"] = @YES;

            // Exact matching destructor for ReadWriteOpaque.
            // No read/write call is made on the stream.
            idevice_stream_free(stream);
            stream = NULL;
            attempt[@"StreamReleased"] = @YES;
        }

        rsd_free_service(service);
        service = NULL;
        [attempts addObject:attempt];
    }

    result[@"Candidates"] = attempts;

    if ([result[@"AnyAirTrafficShimConnected"] boolValue]) {
        result[@"Interpretation"] =
            @"A modern AirTraffic RSD shim was advertised and its same-device "
             @"TCP port accepted a connection. This proves transport ingress "
             @"without using lockdownd StartService; zero service bytes were "
             @"sent.";
    } else if ([result[@"AnyAirTrafficShimAdvertised"] boolValue]) {
        result[@"Interpretation"] =
            @"An AirTraffic RSD shim was advertised, but its same-device TCP "
             @"port did not accept the adapter connection. Zero service bytes "
             @"were sent.";
    } else {
        result[@"Interpretation"] =
            @"None of the known AirTraffic RSD service or shim identifiers "
             @"were advertised by this device's handshake.";
    }

cleanup:
    FZAirliftRSDShimWrite(@"cleanup", @"Running", result);

    if (handshake) {
        rsd_handshake_free(handshake);
        handshake = NULL;
    }
    if (adapter) {
        IdeviceFfiError *closeError = adapter_close(adapter);
        if (closeError) {
            result[@"AdapterClose"] =
                FZAirliftRSDShimConsumeError(closeError);
        } else {
            result[@"AdapterClose"] = @{ @"Success": @YES };
            result[@"AdapterStackClosed"] = @YES;
        }
        adapter_free(adapter);
        adapter = NULL;
    }
    if (pairing) {
        rp_pairing_file_free(pairing);
        pairing = NULL;
    }

    result[@"TemporaryTunnelDestroyed"] = @YES;
    result[@"PayloadBytesSent"] = @0;

    if (!result[@"Interpretation"]) {
        NSString *stage = result[@"FailureStage"] ?: @"unknown";
        result[@"Interpretation"] =
            [NSString stringWithFormat:
                @"AirTraffic RSD shim route was not proven; failure stage: %@. "
                 @"No service bytes were sent.",
                stage];
    }

    return result;
}

static void FZAirliftWriteRSDShimConnectReport(void)
{
    NSURL *output = FZAirliftRSDShimReportURL();
    if (!output) return;

    FZAirliftRSDShimWrite(
        @"probe-started",
        @"Running",
        @{ @"Attempted": @YES, @"PayloadBytesSent": @0 });

    NSDictionary *result = FZAirliftProbeRSDShimConnect();

    FZAirliftRSDShimWrite(
        @"completed",
        @"Completed",
        result);
}

__attribute__((constructor))
static void FZAirliftRSDShimConnectInit(void)
{
    // Run after the 14-second lockdown probe and 24-second enumeration probe.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 34 * NSEC_PER_SEC),
        dispatch_get_main_queue(),
        ^{
            [NSThread detachNewThreadWithBlock:^{
                @autoreleasepool {
                    FZAirliftWriteRSDShimConnectReport();
                }
            }];
        });
}
