#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <stdbool.h>
#import <sys/socket.h>
#import <unistd.h>
#import "idevice.h"
#import "MCMFilzaIntegration.h"

// Sixth-stage Airlift diagnostic.
//
// The previous on-device probe physically proved:
//   * RP pairing material can be consumed by Filza.
//   * a same-device RP tunnel can be created.
//   * RSD lockdown can be reached.
//
// It then failed when lockdownd_start_service("com.apple.atc") closed the
// lockdown channel. Before changing AirTraffic protocol code, enumerate the
// RSD handshake's already-advertised service table. If com.apple.atc or
// com.apple.atc2 is advertised directly, attempt only a raw TCP connect to
// that advertised port and immediately tear it down.
//
// No bytes are written to any discovered service. This is route discovery,
// not an AirTraffic protocol or filesystem-mutation stage.

static NSString *const FZAirliftRSDPairingGroup =
    @"group.com.edualexxis.MusicManager";
static const uint16_t FZAirliftRSDPairingPort = 49152;

static NSString *FZAirliftRSDString(const char *value)
{
    if (!value) return @"";
    return [NSString stringWithUTF8String:value] ?: @"<invalid-utf8>";
}

static NSDictionary *FZAirliftRSDConsumeError(IdeviceFfiError *error)
{
    if (!error) return @{ @"Success": @YES };

    int code = error->code;
    int subcode = error->sub_code;
    NSString *message = FZAirliftRSDString(error->message);
    idevice_error_free(error);
    return @{
        @"Success": @NO,
        @"Code": @(code),
        @"Subcode": @(subcode),
        @"Message": message
    };
}

static NSURL *FZAirliftRSDPairingFileURL(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *base =
        [fm containerURLForSecurityApplicationGroupIdentifier:
            FZAirliftRSDPairingGroup];
    if (!base) {
        base =
            [fm URLsForDirectory:NSDocumentDirectory
                       inDomains:NSUserDomainMask].firstObject;
    }
    if (!base) return nil;

    return [[base URLByAppendingPathComponent:@"pairing file" isDirectory:YES]
        URLByAppendingPathComponent:@"rpPairingFile.plist" isDirectory:NO];
}

static NSURL *FZAirliftRSDReportURL(void)
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
        NSLog(@"[AirliftRSDProbe] diagnostics directory failed: %@", error);
        return nil;
    }

    return [directory
        URLByAppendingPathComponent:@"Airlift RSD Service Discovery.plist"
                        isDirectory:NO];
}

static void FZAirliftRSDWriteProgress(
    NSString *stage,
    NSDictionary *state)
{
    NSURL *output = FZAirliftRSDReportURL();
    if (!output) return;

    NSDictionary *report = @{
        @"SchemaVersion": @1,
        @"GeneratedAt": [NSDate date],
        @"Process": NSProcessInfo.processInfo.processName ?: @"",
        @"PID": @(getpid()),
        @"SystemVersion":
            NSProcessInfo.processInfo.operatingSystemVersionString ?: @"",
        @"State": @"Running",
        @"LastReachedStage": stage ?: @"unknown",
        @"RSDServiceDiscovery": state ?: @{},
        @"SafetyBoundary":
            @"Read-only route discovery. Enumerates the RSD handshake service "
             @"table and may open/close a TCP stream only for an explicitly "
             @"advertised com.apple.atc or com.apple.atc2 port. "
             @"PayloadBytesSent is always zero. No HostInfo, SyncRequest, "
             @"AssetManifest, FileComplete, ATAirlock, AFC request, or "
             @"filesystem mutation is attempted."
    };

    BOOL wrote = [report writeToURL:output atomically:YES];
    NSLog(@"[AirliftRSDProbe] progress stage=%@ %@ at %@",
          stage ?: @"unknown",
          wrote ? @"written" : @"failed",
          output.path);
}

static NSArray<NSString *> *FZAirliftRSDFeatures(
    const struct CRsdService *service)
{
    if (!service || !service->features ||
        service->features_count == 0) {
        return @[];
    }

    NSMutableArray<NSString *> *features =
        [NSMutableArray arrayWithCapacity:service->features_count];
    for (size_t index = 0;
         index < service->features_count;
         index++) {
        const char *feature = service->features[index];
        if (feature) {
            [features addObject:FZAirliftRSDString(feature)];
        }
    }
    return features;
}

static NSDictionary *FZAirliftRSDDescriptor(
    const struct CRsdService *service)
{
    if (!service) return @{};

    return @{
        @"Name": FZAirliftRSDString(service->name),
        @"Entitlement": FZAirliftRSDString(service->entitlement),
        @"Port": @(service->port),
        @"UsesRemoteXPC": @(service->uses_remote_xpc),
        @"ServiceVersion": @(service->service_version),
        @"Features": FZAirliftRSDFeatures(service)
    };
}

static BOOL FZAirliftRSDNameIsInteresting(NSString *name)
{
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"atc"] ||
           [lower containsString:@"airtraffic"] ||
           [lower containsString:@"lockdown"] ||
           [lower containsString:@"sync"];
}

static NSDictionary *FZAirliftProbeRSDServices(void)
{
    NSMutableDictionary *result = [@{
        @"Attempted": @YES,
        @"PairingFilePresent": @NO,
        @"RPTunnelCreated": @NO,
        @"RSDEnumerationAttempted": @NO,
        @"RSDEnumerationSucceeded": @NO,
        @"RSDServiceCount": @0,
        @"ATCAdvertisedByRSD": @NO,
        @"ATC2AdvertisedByRSD": @NO,
        @"DirectConnectAttempted": @NO,
        @"DirectConnectSucceeded": @NO,
        @"PayloadBytesSent": @0,
        @"AdapterStackClosed": @NO,
        @"TemporaryTunnelDestroyed": @NO
    } mutableCopy];

    struct RpPairingFileHandle *pairing = NULL;
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;
    struct CRsdServiceArray *services = NULL;

    NSURL *pairingURL = FZAirliftRSDPairingFileURL();
    result[@"PairingFilePath"] = pairingURL.path ?: @"";
    FZAirliftRSDWriteProgress(@"pairing-file", result);

    if (!pairingURL ||
        ![NSFileManager.defaultManager
            fileExistsAtPath:pairingURL.path]) {
        result[@"FailureStage"] = @"pairing-file";
        result[@"Interpretation"] =
            @"RP pairing material is unavailable; RSD discovery was not run.";
        goto cleanup;
    }
    result[@"PairingFilePresent"] = @YES;

    FZAirliftRSDWriteProgress(@"pairing-read", result);
    IdeviceFfiError *error =
        rp_pairing_file_read(pairingURL.fileSystemRepresentation, &pairing);
    if (error || !pairing) {
        result[@"PairingRead"] = error
            ? FZAirliftRSDConsumeError(error)
            : @{ @"Success": @NO,
                 @"Message": @"rp_pairing_file_read returned a null handle" };
        result[@"FailureStage"] = @"pairing-read";
        goto cleanup;
    }
    result[@"PairingRead"] = @{ @"Success": @YES };

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(FZAirliftRSDPairingPort);
    if (inet_pton(AF_INET, "10.7.0.1", &address.sin_addr) != 1) {
        result[@"FailureStage"] = @"address";
        result[@"AddressError"] = @"inet_pton failed for 10.7.0.1";
        goto cleanup;
    }

    FZAirliftRSDWriteProgress(@"rp-tunnel", result);
    error = tunnel_create_rppairing(
        (const idevice_sockaddr *)&address,
        (idevice_socklen_t)sizeof(address),
        "Filza-Airlift-RSD-Discovery",
        pairing,
        NULL,
        NULL,
        &adapter,
        &handshake);
    if (error || !adapter || !handshake) {
        result[@"RPTunnel"] = error
            ? FZAirliftRSDConsumeError(error)
            : @{ @"Success": @NO,
                 @"Message":
                     @"tunnel_create_rppairing returned a null handle" };
        result[@"FailureStage"] = @"rp-tunnel";
        goto cleanup;
    }
    result[@"RPTunnelCreated"] = @YES;
    result[@"RPTunnel"] = @{ @"Success": @YES };

    size_t protocolVersion = 0;
    IdeviceFfiError *versionError =
        rsd_get_protocol_version(handshake, &protocolVersion);
    if (!versionError) {
        result[@"RSDProtocolVersion"] = @(protocolVersion);
    } else {
        result[@"RSDProtocolVersionError"] =
            FZAirliftRSDConsumeError(versionError);
    }

    char *uuid = NULL;
    IdeviceFfiError *uuidError = rsd_get_uuid(handshake, &uuid);
    if (!uuidError && uuid) {
        result[@"RSDUUID"] = FZAirliftRSDString(uuid);
        rsd_free_string(uuid);
        uuid = NULL;
    } else if (uuidError) {
        result[@"RSDUUIDError"] = FZAirliftRSDConsumeError(uuidError);
    }

    result[@"RSDEnumerationAttempted"] = @YES;
    FZAirliftRSDWriteProgress(@"rsd-enumeration", result);
    error = rsd_get_services(handshake, &services);
    if (error || !services) {
        result[@"RSDEnumeration"] = error
            ? FZAirliftRSDConsumeError(error)
            : @{ @"Success": @NO,
                 @"Message": @"rsd_get_services returned a null array" };
        result[@"FailureStage"] = @"rsd-enumeration";
        goto cleanup;
    }

    result[@"RSDEnumerationSucceeded"] = @YES;
    result[@"RSDEnumeration"] = @{ @"Success": @YES };
    result[@"RSDServiceCount"] = @(services->count);

    NSMutableArray<NSString *> *names =
        [NSMutableArray arrayWithCapacity:services->count];
    NSMutableArray<NSDictionary *> *interesting =
        [NSMutableArray array];

    for (size_t index = 0; index < services->count; index++) {
        struct CRsdService *service = &services->services[index];
        NSString *name = FZAirliftRSDString(service->name);
        if (name.length) [names addObject:name];

        if (FZAirliftRSDNameIsInteresting(name)) {
            [interesting addObject:FZAirliftRSDDescriptor(service)];
        }

        if ([name isEqualToString:@"com.apple.atc"]) {
            result[@"ATCAdvertisedByRSD"] = @YES;
            result[@"ATCService"] = FZAirliftRSDDescriptor(service);
        } else if ([name isEqualToString:@"com.apple.atc2"]) {
            result[@"ATC2AdvertisedByRSD"] = @YES;
            result[@"ATC2Service"] = FZAirliftRSDDescriptor(service);
        }
    }

    [names sortUsingSelector:@selector(compare:)];
    result[@"AdvertisedServiceNames"] = names;
    result[@"InterestingServices"] = interesting;

    // Connect only to the two historically documented AirTraffic service
    // identifiers, and only if the RSD handshake itself advertised them.
    // The stream is immediately destroyed without a read or write.
    NSMutableArray<NSDictionary *> *connectResults =
        [NSMutableArray array];

    for (size_t index = 0; index < services->count; index++) {
        struct CRsdService *service = &services->services[index];
        NSString *name = FZAirliftRSDString(service->name);
        if (![name isEqualToString:@"com.apple.atc"] &&
            ![name isEqualToString:@"com.apple.atc2"]) {
            continue;
        }

        result[@"DirectConnectAttempted"] = @YES;
        FZAirliftRSDWriteProgress(
            [NSString stringWithFormat:@"direct-connect-%@", name],
            result);

        struct ReadWriteOpaque *stream = NULL;
        IdeviceFfiError *connectError =
            adapter_connect(adapter, service->port, &stream);

        NSMutableDictionary *connectResult =
            [@{
                @"Service": name,
                @"Port": @(service->port),
                @"UsesRemoteXPC": @(service->uses_remote_xpc),
                @"PayloadBytesSent": @0
            } mutableCopy];

        if (connectError || !stream) {
            connectResult[@"Connect"] = connectError
                ? FZAirliftRSDConsumeError(connectError)
                : @{ @"Success": @NO,
                     @"Message":
                         @"adapter_connect returned a null stream" };
            connectResult[@"Connected"] = @NO;
        } else {
            connectResult[@"Connect"] = @{ @"Success": @YES };
            connectResult[@"Connected"] = @YES;
            result[@"DirectConnectSucceeded"] = @YES;
            idevice_stream_free(stream);
            stream = NULL;
            connectResult[@"StreamReleased"] = @YES;
        }

        [connectResults addObject:connectResult];
    }

    result[@"DirectConnectResults"] = connectResults;

    if ([result[@"DirectConnectSucceeded"] boolValue]) {
        result[@"Interpretation"] =
            @"At least one AirTraffic service was directly advertised by "
             @"RSD and its advertised port accepted a same-device adapter "
             @"connection. No service payload bytes were sent.";
    } else if ([result[@"ATCAdvertisedByRSD"] boolValue] ||
               [result[@"ATC2AdvertisedByRSD"] boolValue]) {
        result[@"Interpretation"] =
            @"RSD advertises an AirTraffic service, but a direct same-device "
             @"adapter connection to its advertised port failed. No service "
             @"payload bytes were sent.";
    } else {
        result[@"Interpretation"] =
            @"The same-device RSD handshake succeeded, but neither "
             @"com.apple.atc nor com.apple.atc2 was directly advertised. "
             @"The prior lockdownd StartService failure therefore remains a "
             @"separate route/context question.";
    }

cleanup:
    FZAirliftRSDWriteProgress(@"cleanup", result);

    if (services) {
        rsd_free_services(services);
        services = NULL;
    }
    if (handshake) {
        rsd_handshake_free(handshake);
        handshake = NULL;
    }
    if (adapter) {
        IdeviceFfiError *closeError = adapter_close(adapter);
        if (closeError) {
            result[@"AdapterClose"] =
                FZAirliftRSDConsumeError(closeError);
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
                @"RSD service discovery was not completed; failure stage: "
                 @"%@. No service payload bytes were sent.",
                stage];
    }

    return result;
}

static void FZAirliftWriteRSDServiceDiscovery(void)
{
    NSURL *output = FZAirliftRSDReportURL();
    if (!output) return;

    FZAirliftRSDWriteProgress(
        @"probe-started",
        @{ @"Attempted": @YES,
           @"PayloadBytesSent": @0 });

    NSDictionary *discovery = FZAirliftProbeRSDServices();
    NSDictionary *report = @{
        @"SchemaVersion": @1,
        @"GeneratedAt": [NSDate date],
        @"Process": NSProcessInfo.processInfo.processName ?: @"",
        @"PID": @(getpid()),
        @"SystemVersion":
            NSProcessInfo.processInfo.operatingSystemVersionString ?: @"",
        @"State": @"Completed",
        @"LastReachedStage": @"completed",
        @"RSDServiceDiscovery": discovery,
        @"SafetyBoundary":
            @"Read-only route discovery. Enumerates the RSD handshake service "
             @"table and may open/close a TCP stream only for an explicitly "
             @"advertised com.apple.atc or com.apple.atc2 port. "
             @"PayloadBytesSent is always zero. No HostInfo, SyncRequest, "
             @"AssetManifest, FileComplete, ATAirlock, AFC request, or "
             @"filesystem mutation is attempted except writing this plist "
             @"inside Filza's visible Airlift diagnostics directory."
    };

    BOOL wrote = [report writeToURL:output atomically:YES];
    NSLog(@"[AirliftRSDProbe] final report %@ at %@",
          wrote ? @"written" : @"failed",
          output.path);
}

__attribute__((constructor))
static void FZAirliftRSDServiceDiscoveryInit(void)
{
    // Run after the existing 14-second lockdown transport probe so the two
    // disposable RP tunnels never intentionally overlap.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 24 * NSEC_PER_SEC),
        dispatch_get_main_queue(),
        ^{
            [NSThread detachNewThreadWithBlock:^{
                @autoreleasepool {
                    FZAirliftWriteRSDServiceDiscovery();
                }
            }];
        });
}
