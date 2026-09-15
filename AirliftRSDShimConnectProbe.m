#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <stdbool.h>
#import <stdint.h>
#import <sys/socket.h>
#import <unistd.h>
#import "idevice.h"
#import "MCMFilzaIntegration.h"

// Protocol-admission probe for modern RSD lockdown-service shims.
//
// Physical-device testing on iOS 27.0 established that the RSD handshake
// advertises and accepts same-device connections to:
//   com.apple.atc.shim.remote
//   com.apple.atc2.shim.remote
// while the bare com.apple.atc/com.apple.atc2 identifiers are not advertised.
//
// This stage performs only the standard RSD shim check-in implemented by the
// pinned idevice library. If check-in succeeds it then performs one bounded,
// passive read. No AirTraffic HostInfo, SyncRequest, asset, FileComplete, AFC,
// ATAirlock, or filesystem request is sent.

static NSString *const FZAirliftRSDShimPairingGroup =
    @"group.com.edualexxis.MusicManager";
static const uint16_t FZAirliftRSDShimPairingPort = 49152;

static NSString *FZAirliftRSDShimString(const char *value)
{
    if (!value) return @"";
    return [NSString stringWithUTF8String:value] ?: @"<invalid-utf8>";
}

static NSString *FZAirliftRSDShimHex(const uint8_t *bytes, size_t length)
{
    if (!bytes || length == 0) return @"";
    size_t preview = MIN(length, (size_t)256);
    NSMutableString *hex =
        [NSMutableString stringWithCapacity:preview * 2];
    for (size_t i = 0; i < preview; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
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
        URLByAppendingPathComponent:@"Airlift RSD AirTraffic Shim Checkin.plist"
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
        @"SchemaVersion": @2,
        @"GeneratedAt": [NSDate date],
        @"Process": NSProcessInfo.processInfo.processName ?: @"",
        @"PID": @(getpid()),
        @"SystemVersion":
            NSProcessInfo.processInfo.operatingSystemVersionString ?: @"",
        @"State": state ?: @"Running",
        @"LastReachedStage": stage ?: @"unknown",
        @"AirTrafficRSDShim": result ?: @{},
        @"SafetyBoundary":
            @"Sends only the standard RSD shim check-in control plist and "
             @"performs one bounded passive post-checkin read. "
             @"AirTrafficPayloadBytesSent remains zero. No HostInfo, "
             @"SyncRequest, AssetManifest, FileComplete, ATAirlock, AFC "
             @"request, or filesystem mutation is attempted."
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
        @"AirTrafficPayloadBytesSent": @0,
        @"RSDControlTrafficAttempted": @NO,
        @"AnyAirTrafficShimAdvertised": @NO,
        @"AnyAirTrafficShimConnected": @NO,
        @"AnyAirTrafficShimCheckinSucceeded": @NO,
        @"AdapterStackClosed": @NO,
        @"TemporaryTunnelDestroyed": @NO
    } mutableCopy];

    // ARC forbids jumping over initialization of strong Objective-C locals.
    // Keep all strong locals that outlive failure branches above any goto.
    NSArray<NSString *> *candidates = @[
        @"com.apple.atc.shim.remote",
        @"com.apple.atc2.shim.remote",
        @"com.apple.atc",
        @"com.apple.atc2"
    ];
    NSMutableArray<NSDictionary *> *attempts = [NSMutableArray array];

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
                @"RSDCheckinAttempted": @NO,
                @"RSDCheckinSucceeded": @NO,
                @"RSDControlTrafficAttempted": @NO,
                @"PostCheckinReadAttempted": @NO,
                @"PostCheckinReadSucceeded": @NO,
                @"PostCheckinReadByteCount": @0,
                @"AirTrafficPayloadBytesSent": @0
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

            attempt[@"RSDCheckinAttempted"] = @YES;
            attempt[@"RSDControlTrafficAttempted"] = @YES;
            result[@"RSDControlTrafficAttempted"] = @YES;

            FZAirliftRSDShimWrite(
                [NSString stringWithFormat:@"rsd-checkin-%@", candidate],
                @"Running",
                result);

            IdeviceFfiError *checkinError =
                idevice_stream_rsd_checkin(stream);
            if (checkinError) {
                attempt[@"RSDCheckin"] =
                    FZAirliftRSDShimConsumeError(checkinError);
            } else {
                attempt[@"RSDCheckin"] = @{ @"Success": @YES };
                attempt[@"RSDCheckinSucceeded"] = @YES;
                result[@"AnyAirTrafficShimCheckinSucceeded"] = @YES;

                uint8_t buffer[4096] = {0};
                size_t count = 0;
                attempt[@"PostCheckinReadAttempted"] = @YES;

                IdeviceFfiError *readError =
                    idevice_stream_read_bounded(
                        stream,
                        buffer,
                        &count,
                        sizeof(buffer));
                if (readError) {
                    attempt[@"PostCheckinRead"] =
                        FZAirliftRSDShimConsumeError(readError);
                } else {
                    attempt[@"PostCheckinRead"] = @{ @"Success": @YES };
                    attempt[@"PostCheckinReadSucceeded"] = @YES;
                    attempt[@"PostCheckinReadByteCount"] = @(count);
                    if (count > 0) {
                        attempt[@"PostCheckinReadHexPreview"] =
                            FZAirliftRSDShimHex(buffer, count);
                    }
                }
            }

            // Exact matching destructor for ReadWriteOpaque. Any bytes sent by
            // this stage belong only to the standard RSD control transition;
            // AirTrafficPayloadBytesSent remains zero.
            idevice_stream_free(stream);
            stream = NULL;
            attempt[@"StreamReleased"] = @YES;
        }

        rsd_free_service(service);
        service = NULL;
        [attempts addObject:attempt];
    }

    result[@"Candidates"] = attempts;

    if ([result[@"AnyAirTrafficShimCheckinSucceeded"] boolValue]) {
        result[@"Interpretation"] =
            @"A modern AirTraffic RSD shim completed the standard RSDCheckin/"
             @"StartService transition into its legacy service protocol. No "
             @"AirTraffic host payload was sent; the post-checkin read was "
             @"passive and bounded.";
    } else if ([result[@"AnyAirTrafficShimConnected"] boolValue]) {
        result[@"Interpretation"] =
            @"A modern AirTraffic RSD shim accepted the same-device TCP "
             @"connection, but the standard RSD shim check-in did not "
             @"complete. No AirTraffic host payload was sent.";
    } else if ([result[@"AnyAirTrafficShimAdvertised"] boolValue]) {
        result[@"Interpretation"] =
            @"An AirTraffic RSD shim was advertised, but its same-device TCP "
             @"port did not accept the adapter connection. No AirTraffic host "
             @"payload was sent.";
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
    result[@"AirTrafficPayloadBytesSent"] = @0;

    if (!result[@"Interpretation"]) {
        NSString *stage = result[@"FailureStage"] ?: @"unknown";
        result[@"Interpretation"] =
            [NSString stringWithFormat:
                @"AirTraffic RSD shim protocol admission was not proven; "
                 @"failure stage: %@. No AirTraffic host payload was sent.",
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
        @{ @"Attempted": @YES,
           @"AirTrafficPayloadBytesSent": @0 });

    NSDictionary *result = FZAirliftProbeRSDShimConnect();

    FZAirliftRSDShimWrite(
        @"completed",
        @"Completed",
        result);
}

__attribute__((constructor))
static void FZAirliftRSDShimConnectInit(void)
{
    // Run after the existing 14-second lockdown probe. The broad RSD table
    // enumerator is intentionally not required for this focused shim test.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 26 * NSEC_PER_SEC),
        dispatch_get_main_queue(),
        ^{
            [NSThread detachNewThreadWithBlock:^{
                @autoreleasepool {
                    FZAirliftWriteRSDShimConnectReport();
                }
            }];
        });
}
