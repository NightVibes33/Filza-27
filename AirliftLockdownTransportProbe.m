#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <stdbool.h>
#import <sys/socket.h>
#import <unistd.h>
#import "idevice.h"

// Fourth-stage Airlift diagnostic.
//
// Goal: prove (or disprove) that Filza can use its existing iOS 27 RP pairing
// material to act as a host for the phone's own lockdown service
// "com.apple.atc". This probe creates a completely separate RP tunnel, asks
// lockdownd to start com.apple.atc, opens the returned TCP port, sends ZERO
// bytes, frees that exact raw stream wrapper through idevice_stream_free(),
// and then tears the entire temporary tunnel down.
//
// It does NOT send AssetManifest/FileComplete/AirTraffic messages and does not
// invoke ATAirlock or any Airlift filesystem primitive.

static NSString *const FZAirliftATCService = @"com.apple.atc";
static NSString *const FZAirliftPairingGroup = @"group.com.edualexxis.MusicManager";
static const uint16_t FZAirliftRPPairingPort = 49152;

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
    NSURL *documents = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    if (!documents) return nil;

    NSURL *directory = [documents URLByAppendingPathComponent:@"Airlift - Experimental" isDirectory:YES];
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
    if (!pairingURL || ![NSFileManager.defaultManager fileExistsAtPath:pairingURL.path]) {
        result[@"FailureStage"] = @"pairing-file";
        result[@"Interpretation"] = @"RP pairing file is unavailable, so self-hosted ATC transport was not attempted.";
        goto cleanup;
    }
    result[@"PairingFilePresent"] = @YES;

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

    // This is deliberately only a TCP-open reachability test. Do not send a
    // protocol preface, plist, AssetManifest, FileComplete, or any payload.
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
    result[@"PayloadBytesSent"] = @0;
    result[@"Interpretation"] = @"Filza successfully used a disposable iOS 27 RP tunnel to ask lockdownd to start com.apple.atc and open the returned service port. This proves self-hosted ATC transport reachability only; no AirTraffic protocol message or Airlift filesystem primitive was invoked.";

cleanup:
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
    NSURL *directory = FZAirliftDiagnosticsDirectoryURL();
    if (!directory) return;

    NSDictionary *report = @{
        @"SchemaVersion": @3,
        @"GeneratedAt": [NSDate date],
        @"Process": NSProcessInfo.processInfo.processName ?: @"",
        @"PID": @(getpid()),
        @"SystemVersion": NSProcessInfo.processInfo.operatingSystemVersionString ?: @"",
        @"ATCLockdownTransport": FZAirliftProbeATCLockdownTransport(),
        @"SafetyBoundary": @"Connect-and-teardown transport diagnostic only. PayloadBytesSent is always zero. No AssetManifest, FileComplete, ATAirlock, AFC, or filesystem mutation is attempted except writing this diagnostics plist inside Filza Documents. The ReadWriteOpaque returned by adapter_connect is freed only with idevice_stream_free, then the entire disposable RP adapter is closed and freed."
    };

    NSURL *output = [directory URLByAppendingPathComponent:@"Airlift ATC Lockdown Transport.plist"];
    BOOL wrote = [report writeToURL:output atomically:YES];
    NSLog(@"[AirliftATCProbe] report %@ at %@", wrote ? @"written" : @"failed", output.path);
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
