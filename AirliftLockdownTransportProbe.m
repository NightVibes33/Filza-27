#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <stdbool.h>
#import <sys/socket.h>
#import <unistd.h>
#import "idevice.h"
#import "MCMFilzaIntegration.h"

// Fifth-stage Airlift diagnostic.
//
// Goal: prove (or disprove) that Filza can use its existing iOS 27 RP pairing
// material to act as a host for the phone's own lockdown service
// "com.apple.atc". This probe creates a completely separate RP tunnel, asks
// lockdownd to start com.apple.atc, opens the returned TCP port, and—only when
// lockdownd marks the service as plaintext—performs one bounded RECEIVE from
// the exact ReadWriteOpaque returned by adapter_connect(). It sends ZERO bytes.
//
// It does NOT send HostInfo, SyncRequest, AssetManifest, FileComplete, or any
// other AirTraffic message. It does not invoke ATAirlock or an Airlift
// filesystem primitive.

static NSString *const FZAirliftATCService = @"com.apple.atc";
static NSString *const FZAirliftPairingGroup = @"group.com.edualexxis.MusicManager";
static const uint16_t FZAirliftRPPairingPort = 49152;
enum {
    FZAirliftInitialReadCapacity = 4096,
    FZAirliftInitialHexPreviewCapacity = 256
};

static NSDictionary *FZAirliftConsumeIdeviceError(IdeviceFfiError *error)
{
    if (!error) return @{ @"Success": @YES };

    int code = error->code;
    int subcode = error->sub_code;
    NSString *message = error->message
        ? ([NSString stringWithUTF8String:error->message] ?: @"invalid UTF-8 error")
        : @"";
    idevice_error_free(error);

    return @{
        @"Success": @NO,
        @"Code": @(code),
        @"Subcode": @(subcode),
        @"Message": message
    };
}

static NSString *FZAirliftHexPreview(const uint8_t *bytes, size_t length)
{
    if (!bytes || length == 0) return @"";
    size_t previewLength = MIN(length, FZAirliftInitialHexPreviewCapacity);
    NSMutableString *hex = [NSMutableString stringWithCapacity:previewLength * 2];
    for (size_t index = 0; index < previewLength; index++) {
        [hex appendFormat:@"%02x", bytes[index]];
    }
    return hex;
}

static NSURL *FZAirliftRPPairingFileURL(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *base = [fm containerURLForSecurityApplicationGroupIdentifier:FZAirliftPairingGroup];
    if (!base) {
        base = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    }
    if (!base) return nil;

    NSURL *pairingDirectory = [base URLByAppendingPathComponent:@"pairing file" isDirectory:YES];
    return [pairingDirectory URLByAppendingPathComponent:@"rpPairingFile.plist" isDirectory:NO];
}

static NSURL *FZAirliftDiagnosticsDirectoryURL(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;

    // Keep this probe beside the other Airlift diagnostics that the user is
    // already viewing in Filza. Fall back to the raw app Documents directory
    // only if the virtual root has not been initialized yet.
    NSURL *base = nil;
    NSString *virtualRoot = MCMFilzaVirtualRoot();
    if (virtualRoot.length) {
        base = [NSURL fileURLWithPath:virtualRoot isDirectory:YES];
    }
    if (!base) {
        base = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    }
    if (!base) return nil;

    NSURL *directory = [base URLByAppendingPathComponent:@"Airlift - Experimental" isDirectory:YES];
    NSError *error = nil;
    if (![fm createDirectoryAtURL:directory
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&error]) {
        NSLog(@"[AirliftATCProbe] diagnostics directory failed: %@", error);
        return nil;
    }
    return directory;
}

static NSURL *FZAirliftATCReportURL(void)
{
    NSURL *directory = FZAirliftDiagnosticsDirectoryURL();
    return [directory URLByAppendingPathComponent:@"Airlift ATC Lockdown Transport.plist"];
}

static void FZAirliftWriteATCProgress(NSString *stage, NSDictionary *transportState)
{
    NSURL *output = FZAirliftATCReportURL();
    if (!output) return;

    NSDictionary *report = @{
        @"SchemaVersion": @5,
        @"GeneratedAt": [NSDate date],
        @"Process": NSProcessInfo.processInfo.processName ?: @"",
        @"PID": @(getpid()),
        @"SystemVersion": NSProcessInfo.processInfo.operatingSystemVersionString ?: @"",
        @"State": @"Running",
        @"LastReachedStage": stage ?: @"unknown",
        @"ATCLockdownTransport": transportState ?: @{},
        @"SafetyBoundary": @"Passive transport diagnostic. PayloadBytesSent is always zero. The only service-I/O operation after connect is one bounded receive when lockdownd reports plaintext. No HostInfo, SyncRequest, AssetManifest, FileComplete, ATAirlock, AFC, or Airlift filesystem mutation is attempted."
    };

    BOOL wrote = [report writeToURL:output atomically:YES];
    NSLog(@"[AirliftATCProbe] progress stage=%@ %@ at %@",
          stage ?: @"unknown", wrote ? @"written" : @"failed", output.path);
}

static NSDictionary *FZAirliftProbeATCLockdownTransport(void)
{
    NSMutableDictionary *result = [@{
        @"Service": FZAirliftATCService,
        @"Attempted": @YES,
        @"PairingFilePresent": @NO,
        @"RPTunnelCreated": @NO,
        @"LockdownConnected": @NO,
        @"StartServiceSucceeded": @NO,
        @"ReturnedPort": @0,
        @"ReturnedSSL": @NO,
        @"PortConnected": @NO,
        @"InitialReadAttempted": @NO,
        @"InitialReadSucceeded": @NO,
        @"InitialReadByteCount": @0,
        @"InitialReadCapacity": @(FZAirliftInitialReadCapacity),
        @"InitialReadTimeoutSeconds": @5,
        @"PayloadBytesSent": @0,
        @"ReadWriteOpaqueWrapperFreed": @NO,
        @"AdapterStackClosed": @NO,
        @"TemporaryTunnelDestroyed": @NO
    } mutableCopy];

    struct RpPairingFileHandle *pairing = NULL;
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;
    struct LockdowndClientHandle *lockdown = NULL;
    struct ReadWriteOpaque *stream = NULL;

    NSURL *pairingURL = FZAirliftRPPairingFileURL();
    result[@"PairingFilePath"] = pairingURL.path ?: @"";
    FZAirliftWriteATCProgress(@"pairing-file", result);
    if (!pairingURL || ![NSFileManager.defaultManager fileExistsAtPath:pairingURL.path]) {
        result[@"FailureStage"] = @"pairing-file";
        result[@"Interpretation"] = @"RP pairing file is unavailable, so self-hosted ATC transport was not attempted.";
        goto cleanup;
    }
    result[@"PairingFilePresent"] = @YES;

    FZAirliftWriteATCProgress(@"pairing-read", result);
    IdeviceFfiError *error = rp_pairing_file_read(pairingURL.fileSystemRepresentation, &pairing);
    if (error) {
        result[@"PairingRead"] = FZAirliftConsumeIdeviceError(error);
        result[@"FailureStage"] = @"pairing-read";
        goto cleanup;
    }
    result[@"PairingRead"] = @{ @"Success": @YES };

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(FZAirliftRPPairingPort);
    if (inet_pton(AF_INET, "10.7.0.1", &address.sin_addr) != 1) {
        result[@"FailureStage"] = @"address";
        result[@"AddressError"] = @"inet_pton failed for 10.7.0.1";
        goto cleanup;
    }

    FZAirliftWriteATCProgress(@"rp-tunnel", result);
    error = tunnel_create_rppairing(
        (const idevice_sockaddr *)&address,
        (idevice_socklen_t)sizeof(address),
        "Filza-Airlift-ATC-Probe",
        pairing,
        NULL,
        NULL,
        &adapter,
        &handshake);
    if (error || !adapter || !handshake) {
        result[@"RPTunnel"] = error
            ? FZAirliftConsumeIdeviceError(error)
            : @{ @"Success": @NO, @"Message": @"tunnel_create_rppairing returned a null handle" };
        result[@"FailureStage"] = @"rp-tunnel";
        goto cleanup;
    }
    result[@"RPTunnelCreated"] = @YES;
    result[@"RPTunnel"] = @{ @"Success": @YES };

    FZAirliftWriteATCProgress(@"lockdown-connect", result);
    error = lockdownd_connect_rsd(adapter, handshake, &lockdown);
    if (error || !lockdown) {
        result[@"LockdownConnect"] = error
            ? FZAirliftConsumeIdeviceError(error)
            : @{ @"Success": @NO, @"Message": @"lockdownd_connect_rsd returned a null client" };
        result[@"FailureStage"] = @"lockdown-connect";
        goto cleanup;
    }
    result[@"LockdownConnected"] = @YES;
    result[@"LockdownConnect"] = @{ @"Success": @YES };

    uint16_t port = 0;
    bool ssl = false;
    FZAirliftWriteATCProgress(@"start-service", result);
    error = lockdownd_start_service(lockdown, FZAirliftATCService.UTF8String, &port, &ssl);
    if (error || port == 0) {
        result[@"StartService"] = error
            ? FZAirliftConsumeIdeviceError(error)
            : @{ @"Success": @NO, @"Message": @"lockdownd returned port 0" };
        result[@"FailureStage"] = @"start-service";
        goto cleanup;
    }

    result[@"StartServiceSucceeded"] = @YES;
    result[@"StartService"] = @{ @"Success": @YES };
    result[@"ReturnedPort"] = @(port);
    result[@"ReturnedSSL"] = @(ssl);

    FZAirliftWriteATCProgress(@"port-connect", result);
    error = adapter_connect(adapter, port, &stream);
    if (error || !stream) {
        result[@"PortConnect"] = error
            ? FZAirliftConsumeIdeviceError(error)
            : @{ @"Success": @NO, @"Message": @"adapter_connect returned a null stream" };
        result[@"FailureStage"] = @"port-connect";
        goto cleanup;
    }

    result[@"PortConnected"] = @YES;
    result[@"PortConnect"] = @{ @"Success": @YES };

    // Do not interpret TLS ciphertext as an AirTraffic frame. If lockdownd
    // marks this service SSL, stop at transport reachability until an exact
    // same-device SSL wrapping path is implemented and verified.
    if (ssl) {
        result[@"InitialReadSkippedReason"] = @"lockdownd marked com.apple.atc as SSL; raw read intentionally skipped";
        result[@"Interpretation"] = @"Self-hosted com.apple.atc transport is reachable, but lockdownd requires SSL. No service bytes were read or sent.";
    } else {
        uint8_t initialBytes[FZAirliftInitialReadCapacity];
        memset(initialBytes, 0, sizeof(initialBytes));
        size_t initialLength = 0;

        result[@"InitialReadAttempted"] = @YES;
        FZAirliftWriteATCProgress(@"atc-initial-read", result);
        error = idevice_stream_read_bounded(
            stream,
            initialBytes,
            &initialLength,
            sizeof(initialBytes));

        if (error) {
            result[@"InitialRead"] = FZAirliftConsumeIdeviceError(error);
            result[@"InitialReadByteCount"] = @0;
            result[@"Interpretation"] = @"Self-hosted com.apple.atc transport is reachable, but no plaintext initial service frame was captured within the bounded read. Zero payload bytes were sent.";
        } else {
            result[@"InitialRead"] = @{ @"Success": @YES };
            result[@"InitialReadSucceeded"] = @YES;
            result[@"InitialReadByteCount"] = @(initialLength);
            result[@"InitialReadHexPreview"] = FZAirliftHexPreview(initialBytes, initialLength);
            result[@"InitialReadHexPreviewByteCount"] = @(MIN(initialLength, FZAirliftInitialHexPreviewCapacity));
            if (initialLength > 0) {
                result[@"Interpretation"] = @"Self-hosted com.apple.atc transport is reachable and emitted plaintext bytes without Filza transmitting a service payload. Framing/message identity is intentionally not inferred from raw bytes yet.";
            } else {
                result[@"Interpretation"] = @"Self-hosted com.apple.atc transport is reachable and the bounded plaintext read completed with zero bytes. Zero payload bytes were sent.";
            }
        }
    }

    result[@"PayloadBytesSent"] = @0;

cleanup:
    FZAirliftWriteATCProgress(@"cleanup", result);
    if (stream) {
        // adapter_connect() returns ReadWriteOpaque. The pinned idevice ABI
        // provides the exact matching destructor idevice_stream_free(). Do
        // not use adapter_stream_close(): that API expects AdapterStreamHandle,
        // which is a different Rust wrapper/layout.
        idevice_stream_free(stream);
        stream = NULL;
        result[@"ReadWriteOpaqueWrapperFreed"] = @YES;
        result[@"StreamTeardown"] = @"Released with idevice_stream_free(ReadWriteOpaque *); never cast to AdapterStreamHandle.";
    }
    if (lockdown) {
        lockdownd_client_free(lockdown);
        lockdown = NULL;
    }
    if (handshake) {
        rsd_handshake_free(handshake);
        handshake = NULL;
    }
    if (adapter) {
        IdeviceFfiError *adapterCloseError = adapter_close(adapter);
        if (adapterCloseError) {
            result[@"AdapterClose"] = FZAirliftConsumeIdeviceError(adapterCloseError);
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

    if (!result[@"Interpretation"]) {
        NSString *stage = result[@"FailureStage"] ?: @"unknown";
        result[@"Interpretation"] = [NSString stringWithFormat:
            @"Self-hosted ATC transport was not proven; failure stage: %@. No AirTraffic payload bytes were sent.", stage];
    }
    return result;
}

static void FZAirliftWriteATCTransportProbe(void)
{
    NSURL *output = FZAirliftATCReportURL();
    if (!output) return;

    // Write immediately before doing any potentially blocking FFI work. If a
    // call stalls, the user still gets a visible report with LastReachedStage.
    FZAirliftWriteATCProgress(@"probe-started", @{
        @"Service": FZAirliftATCService,
        @"Attempted": @YES,
        @"PayloadBytesSent": @0
    });

    NSDictionary *transport = FZAirliftProbeATCLockdownTransport();
    NSDictionary *report = @{
        @"SchemaVersion": @5,
        @"GeneratedAt": [NSDate date],
        @"Process": NSProcessInfo.processInfo.processName ?: @"",
        @"PID": @(getpid()),
        @"SystemVersion": NSProcessInfo.processInfo.operatingSystemVersionString ?: @"",
        @"State": @"Completed",
        @"LastReachedStage": @"completed",
        @"ATCLockdownTransport": transport,
        @"SafetyBoundary": @"Passive connect/read/teardown diagnostic only. PayloadBytesSent is always zero. At most one 4096-byte plaintext read is attempted with a five-second bound, and it is skipped when lockdownd marks the service SSL. No HostInfo, SyncRequest, AssetManifest, FileComplete, ATAirlock, AFC, or Airlift filesystem mutation is attempted except writing this diagnostics plist inside Filza's visible Airlift diagnostics directory."
    };

    BOOL wrote = [report writeToURL:output atomically:YES];
    NSLog(@"[AirliftATCProbe] final report %@ at %@", wrote ? @"written" : @"failed", output.path);
}

__attribute__((constructor)) static void FZAirliftATCTransportProbeInit(void)
{
    // Keep this after the XPC/service-proxy diagnostics. A dedicated NSThread
    // also guarantees the disposable adapter and its stream are created and
    // used on the same native thread as required by idevice's adapter FFI.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 14 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        [NSThread detachNewThreadWithBlock:^{
            @autoreleasepool {
                FZAirliftWriteATCTransportProbe();
            }
        }];
    });
}