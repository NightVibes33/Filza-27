@import Foundation;
@import UIKit;

#import <arpa/inet.h>
#import <net/route.h>
#import <netinet/in.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <sys/sysctl.h>
#import <unistd.h>

#import "FilzaDiagnostics.h"
#import "FilzaSSHServer.h"

// Direct public SSH exposure without a VPN/overlay network.
//
// The device already owns a real TCP listener. This module asks the local
// gateway to publish that listener using standardized router protocols:
//   1. NAT-PMP (RFC 6886)
//   2. UPnP IGD WANIPConnection / WANPPPConnection fallback
//
// No address is advertised as public until the gateway confirms a mapping
// and reports a globally-routable IPv4 address. CGNAT/double-NAT is reported
// explicitly instead of manufacturing an unreachable endpoint.

static NSString * const FilzaSSHPublicStatusDidChangeNotification = @"FilzaSSHPublicStatusDidChangeNotification";
static const uint32_t FilzaSSHPublicLeaseSeconds = 3600;

static dispatch_queue_t FilzaSSHPublicQueue;
static dispatch_once_t FilzaSSHPublicOnce;
static BOOL FilzaSSHPublicAttemptRunning = NO;
static BOOL FilzaSSHPublicMappingActive = NO;
static NSInteger FilzaSSHPublicInternalPort = 0;
static NSInteger FilzaSSHPublicExternalPort = 0;
static NSString *FilzaSSHPublicAddress = nil;
static NSString *FilzaSSHPublicBackend = nil;
static NSString *FilzaSSHPublicGateway = nil;
static NSURL *FilzaSSHPublicUPnPControlURL = nil;
static NSString *FilzaSSHPublicUPnPServiceType = nil;
static NSDate *FilzaSSHPublicLastSuccess = nil;
static dispatch_source_t FilzaSSHPublicRenewTimer = nil;
static NSString *FilzaSSHPublicStatus = @"Public mapping not started.";

static NSString *(*FilzaSSHPublicOriginalFooter)(id, SEL, UITableView *, NSInteger) = NULL;
static BOOL FilzaSSHPublicFooterInstalled = NO;

static NSObject *FilzaSSHPublicLock(void)
{
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = NSObject.new; });
    return lock;
}

static void FilzaSSHPublicInitialize(void)
{
    dispatch_once(&FilzaSSHPublicOnce, ^{
        FilzaSSHPublicQueue = dispatch_queue_create("com.nightvibes33.filza.ssh.public", DISPATCH_QUEUE_SERIAL);
    });
}

static void FilzaSSHPublicReloadVisiblePreferences(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
        UIViewController *root = window.rootViewController;
        NSMutableArray<UIViewController *> *stack = NSMutableArray.new;
        if (root) [stack addObject:root];
        while (stack.count) {
            UIViewController *controller = stack.lastObject;
            [stack removeLastObject];
            if ([NSStringFromClass(controller.class) isEqualToString:@"TGPreferencesTableViewController"] &&
                [controller respondsToSelector:@selector(tableView)]) {
                UITableView *table = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(tableView));
                [table reloadData];
            }
            if ([controller isKindOfClass:UINavigationController.class]) {
                [stack addObjectsFromArray:((UINavigationController *)controller).viewControllers];
            }
            if ([controller isKindOfClass:UITabBarController.class]) {
                [stack addObjectsFromArray:((UITabBarController *)controller).viewControllers ?: @[]];
            }
            if (controller.presentedViewController) [stack addObject:controller.presentedViewController];
            [stack addObjectsFromArray:controller.childViewControllers ?: @[]];
        }
    });
}

static void FilzaSSHPublicSetStatus(NSString *status)
{
    if (!status.length) return;
    @synchronized (FilzaSSHPublicLock()) { FilzaSSHPublicStatus = [status copy]; }
    FilzaDiagnosticsAppend(@"SSH", [@"public access: " stringByAppendingString:status]);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:FilzaSSHPublicStatusDidChangeNotification object:nil];
        FilzaSSHPublicReloadVisiblePreferences();
    });
}

static NSString *FilzaSSHPublicStatusSnapshot(void)
{
    @synchronized (FilzaSSHPublicLock()) { return [FilzaSSHPublicStatus copy] ?: @"Public mapping unavailable."; }
}

static NSUInteger FilzaSockaddrSize(const struct sockaddr *sa)
{
    if (!sa) return sizeof(long);
    NSUInteger len = sa->sa_len;
    if (len == 0) return sizeof(long);
    return 1 + ((len - 1) | (sizeof(long) - 1));
}

static NSString *FilzaSSHPublicDefaultIPv4Gateway(void)
{
    int mib[] = { CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY };
    size_t length = 0;
    if (sysctl(mib, 6, NULL, &length, NULL, 0) != 0 || length == 0) return nil;

    NSMutableData *data = [NSMutableData dataWithLength:length];
    if (sysctl(mib, 6, data.mutableBytes, &length, NULL, 0) != 0) return nil;

    char *cursor = data.mutableBytes;
    char *limit = cursor + length;
    while (cursor + sizeof(struct rt_msghdr) <= limit) {
        struct rt_msghdr *rtm = (struct rt_msghdr *)cursor;
        if (rtm->rtm_msglen == 0 || cursor + rtm->rtm_msglen > limit) break;

        if ((rtm->rtm_flags & RTF_UP) && (rtm->rtm_flags & RTF_GATEWAY)) {
            struct sockaddr *sa = (struct sockaddr *)(rtm + 1);
            struct sockaddr_in *destination = NULL;
            struct sockaddr_in *gateway = NULL;

            for (int index = 0; index < RTAX_MAX && (char *)sa < cursor + rtm->rtm_msglen; index++) {
                if (!(rtm->rtm_addrs & (1 << index))) continue;
                if (index == RTAX_DST && sa->sa_family == AF_INET) destination = (struct sockaddr_in *)sa;
                if (index == RTAX_GATEWAY && sa->sa_family == AF_INET) gateway = (struct sockaddr_in *)sa;
                sa = (struct sockaddr *)((char *)sa + FilzaSockaddrSize(sa));
            }

            if (destination && gateway && destination->sin_addr.s_addr == INADDR_ANY) {
                char buffer[INET_ADDRSTRLEN] = {0};
                if (inet_ntop(AF_INET, &gateway->sin_addr, buffer, sizeof(buffer))) {
                    return [NSString stringWithUTF8String:buffer];
                }
            }
        }
        cursor += rtm->rtm_msglen;
    }
    return nil;
}

static BOOL FilzaSSHPublicIPv4IsGlobal(NSString *address)
{
    struct in_addr raw = {0};
    if (inet_pton(AF_INET, address.UTF8String, &raw) != 1) return NO;
    uint32_t value = ntohl(raw.s_addr);
    uint8_t a = (value >> 24) & 0xff;
    uint8_t b = (value >> 16) & 0xff;

    if (a == 0 || a == 10 || a == 127 || a >= 224) return NO;
    if (a == 100 && b >= 64 && b <= 127) return NO;       // RFC 6598 CGNAT
    if (a == 169 && b == 254) return NO;
    if (a == 172 && b >= 16 && b <= 31) return NO;
    if (a == 192 && b == 168) return NO;
    if (a == 198 && (b == 18 || b == 19)) return NO;
    if (a == 192 && b == 0) return NO;
    if (a == 198 && b == 51) return NO;
    if (a == 203 && b == 0) return NO;
    return YES;
}

static uint16_t FilzaReadBE16(const uint8_t *bytes)
{
    return (uint16_t)(((uint16_t)bytes[0] << 8) | bytes[1]);
}

static uint32_t FilzaReadBE32(const uint8_t *bytes)
{
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3];
}

static void FilzaWriteBE16(uint8_t *bytes, uint16_t value)
{
    bytes[0] = (uint8_t)(value >> 8);
    bytes[1] = (uint8_t)(value & 0xff);
}

static void FilzaWriteBE32(uint8_t *bytes, uint32_t value)
{
    bytes[0] = (uint8_t)(value >> 24);
    bytes[1] = (uint8_t)((value >> 16) & 0xff);
    bytes[2] = (uint8_t)((value >> 8) & 0xff);
    bytes[3] = (uint8_t)(value & 0xff);
}

static NSData *FilzaSSHPublicNATPMPRequest(NSString *gateway, NSData *request, NSUInteger minimumLength, uint8_t expectedOpcode, NSString **failure)
{
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        if (failure) *failure = [NSString stringWithFormat:@"NAT-PMP socket failed: %s", strerror(errno)];
        return nil;
    }

    struct sockaddr_in target = {0};
    target.sin_len = sizeof(target);
    target.sin_family = AF_INET;
    target.sin_port = htons(5351);
    if (inet_pton(AF_INET, gateway.UTF8String, &target.sin_addr) != 1) {
        close(fd);
        if (failure) *failure = @"NAT-PMP gateway address is invalid.";
        return nil;
    }

    if (connect(fd, (struct sockaddr *)&target, sizeof(target)) != 0) {
        if (failure) *failure = [NSString stringWithFormat:@"NAT-PMP connect failed: %s", strerror(errno)];
        close(fd);
        return nil;
    }

    const NSTimeInterval waits[] = {0.30, 0.60, 1.20, 2.40};
    for (NSUInteger attempt = 0; attempt < sizeof(waits) / sizeof(waits[0]); attempt++) {
        ssize_t sent = send(fd, request.bytes, request.length, 0);
        if (sent != (ssize_t)request.length) continue;

        fd_set readSet;
        FD_ZERO(&readSet);
        FD_SET(fd, &readSet);
        struct timeval timeout = {0};
        timeout.tv_sec = (int)waits[attempt];
        timeout.tv_usec = (int)((waits[attempt] - timeout.tv_sec) * 1000000.0);
        int ready = select(fd + 1, &readSet, NULL, NULL, &timeout);
        if (ready <= 0) continue;

        uint8_t buffer[64] = {0};
        ssize_t received = recv(fd, buffer, sizeof(buffer), 0);
        if (received < (ssize_t)minimumLength) continue;
        if (buffer[0] != 0 || buffer[1] != expectedOpcode) continue;
        uint16_t result = FilzaReadBE16(buffer + 2);
        if (result != 0) {
            if (failure) *failure = [NSString stringWithFormat:@"NAT-PMP gateway returned result %u.", result];
            close(fd);
            return nil;
        }
        close(fd);
        return [NSData dataWithBytes:buffer length:(NSUInteger)received];
    }

    close(fd);
    if (failure) *failure = @"NAT-PMP gateway did not answer.";
    return nil;
}

static BOOL FilzaSSHPublicTryNATPMP(NSInteger internalPort, NSInteger suggestedExternalPort, NSString **publicAddress, NSInteger *externalPort, NSString **failure)
{
    NSString *gateway = FilzaSSHPublicDefaultIPv4Gateway();
    if (!gateway.length) {
        if (failure) *failure = @"Could not determine the Wi-Fi default gateway.";
        return NO;
    }

    uint8_t externalRequestBytes[2] = {0, 0};
    NSString *requestFailure = nil;
    NSData *externalResponse = FilzaSSHPublicNATPMPRequest(gateway,
                                                           [NSData dataWithBytes:externalRequestBytes length:sizeof(externalRequestBytes)],
                                                           12,
                                                           128,
                                                           &requestFailure);
    if (!externalResponse) {
        if (failure) *failure = requestFailure;
        return NO;
    }

    const uint8_t *externalBytes = externalResponse.bytes;
    struct in_addr externalRaw = {0};
    memcpy(&externalRaw.s_addr, externalBytes + 8, 4);
    char addressBuffer[INET_ADDRSTRLEN] = {0};
    if (!inet_ntop(AF_INET, &externalRaw, addressBuffer, sizeof(addressBuffer))) {
        if (failure) *failure = @"NAT-PMP returned an invalid external address.";
        return NO;
    }
    NSString *address = [NSString stringWithUTF8String:addressBuffer];

    uint8_t mappingBytes[12] = {0};
    mappingBytes[0] = 0;
    mappingBytes[1] = 2; // TCP
    FilzaWriteBE16(mappingBytes + 4, (uint16_t)internalPort);
    FilzaWriteBE16(mappingBytes + 6, (uint16_t)suggestedExternalPort);
    FilzaWriteBE32(mappingBytes + 8, FilzaSSHPublicLeaseSeconds);

    NSData *mappingResponse = FilzaSSHPublicNATPMPRequest(gateway,
                                                          [NSData dataWithBytes:mappingBytes length:sizeof(mappingBytes)],
                                                          16,
                                                          130,
                                                          &requestFailure);
    if (!mappingResponse) {
        if (failure) *failure = requestFailure;
        return NO;
    }

    const uint8_t *mapping = mappingResponse.bytes;
    uint16_t returnedInternal = FilzaReadBE16(mapping + 8);
    uint16_t returnedExternal = FilzaReadBE16(mapping + 10);
    uint32_t returnedLifetime = FilzaReadBE32(mapping + 12);
    if (returnedInternal != (uint16_t)internalPort || returnedExternal == 0 || returnedLifetime == 0) {
        if (failure) *failure = @"NAT-PMP response did not contain a usable TCP mapping.";
        return NO;
    }

    FilzaSSHPublicGateway = gateway;
    if (publicAddress) *publicAddress = address;
    if (externalPort) *externalPort = returnedExternal;
    return YES;
}

static void FilzaSSHPublicDeleteNATPMP(void)
{
    if (!FilzaSSHPublicGateway.length || FilzaSSHPublicInternalPort <= 0) return;
    uint8_t mappingBytes[12] = {0};
    mappingBytes[0] = 0;
    mappingBytes[1] = 2;
    FilzaWriteBE16(mappingBytes + 4, (uint16_t)FilzaSSHPublicInternalPort);
    FilzaWriteBE16(mappingBytes + 6, (uint16_t)FilzaSSHPublicExternalPort);
    FilzaWriteBE32(mappingBytes + 8, 0);
    FilzaSSHPublicNATPMPRequest(FilzaSSHPublicGateway,
                                [NSData dataWithBytes:mappingBytes length:sizeof(mappingBytes)],
                                16,
                                130,
                                NULL);
}

static NSData *FilzaSSHPublicSynchronousRequest(NSURLRequest *request, NSHTTPURLResponse **outResponse, NSError **outError)
{
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSData *responseData = nil;
    __block NSURLResponse *response = nil;
    __block NSError *requestError = nil;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *urlResponse, NSError *error) {
        responseData = data;
        response = urlResponse;
        requestError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    long timedOut = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)));
    if (timedOut != 0) {
        [task cancel];
        requestError = [NSError errorWithDomain:@"FilzaSSHPublic" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Request timed out."}];
    }
    if (outResponse && [response isKindOfClass:NSHTTPURLResponse.class]) *outResponse = (NSHTTPURLResponse *)response;
    if (outError) *outError = requestError;
    return responseData;
}

static NSArray<NSURL *> *FilzaSSHPublicUPnPLocations(void)
{
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) return @[];

    int ttl = 2;
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl));

    struct sockaddr_in target = {0};
    target.sin_len = sizeof(target);
    target.sin_family = AF_INET;
    target.sin_port = htons(1900);
    inet_pton(AF_INET, "239.255.255.250", &target.sin_addr);

    NSString *message = @"M-SEARCH * HTTP/1.1\r\n"
                         "HOST: 239.255.255.250:1900\r\n"
                         "MAN: \"ssdp:discover\"\r\n"
                         "MX: 2\r\n"
                         "ST: ssdp:all\r\n\r\n";
    NSData *payload = [message dataUsingEncoding:NSUTF8StringEncoding];
    sendto(fd, payload.bytes, payload.length, 0, (struct sockaddr *)&target, sizeof(target));

    struct timeval timeout = {.tv_sec = 2, .tv_usec = 500000};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

    NSMutableOrderedSet<NSURL *> *locations = NSMutableOrderedSet.new;
    for (NSUInteger count = 0; count < 24; count++) {
        uint8_t buffer[8192] = {0};
        ssize_t received = recv(fd, buffer, sizeof(buffer) - 1, 0);
        if (received <= 0) break;
        NSString *response = [[NSString alloc] initWithBytes:buffer length:(NSUInteger)received encoding:NSUTF8StringEncoding];
        if (!response.length) continue;
        for (NSString *line in [response componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSRange colon = [trimmed rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            NSString *name = [[trimmed substringToIndex:colon.location] lowercaseString];
            if (![name isEqualToString:@"location"]) continue;
            NSString *value = [[trimmed substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSURL *url = [NSURL URLWithString:value];
            if (url) [locations addObject:url];
        }
    }
    close(fd);
    return locations.array;
}

static BOOL FilzaSSHPublicFindUPnPService(NSURL *location, NSURL **controlURL, NSString **serviceType)
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:location cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5.0];
    request.HTTPMethod = @"GET";
    NSHTTPURLResponse *response = nil;
    NSError *error = nil;
    NSData *data = FilzaSSHPublicSynchronousRequest(request, &response, &error);
    if (!data.length || response.statusCode < 200 || response.statusCode >= 300) return NO;

    NSString *xml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!xml.length) return NO;
    NSString *pattern = @"<service>.*?<serviceType>\\s*(urn:schemas-upnp-org:service:(?:WANIPConnection|WANPPPConnection):[0-9]+)\\s*</serviceType>.*?<controlURL>\\s*([^<]+)\\s*</controlURL>.*?</service>";
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
    if (!match || match.numberOfRanges < 3) return NO;

    NSString *type = [xml substringWithRange:[match rangeAtIndex:1]];
    NSString *control = [xml substringWithRange:[match rangeAtIndex:2]];
    control = [control stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    NSURL *resolved = [NSURL URLWithString:control relativeToURL:location].absoluteURL;
    if (!resolved || !type.length) return NO;
    if (controlURL) *controlURL = resolved;
    if (serviceType) *serviceType = type;
    return YES;
}

static NSString *FilzaSSHPublicXMLEscape(NSString *value)
{
    value = [value stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    value = [value stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    value = [value stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    value = [value stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    return value;
}

static NSData *FilzaSSHPublicUPnPSOAP(NSURL *controlURL, NSString *serviceType, NSString *action, NSString *arguments, NSInteger *statusCode)
{
    NSString *body = [NSString stringWithFormat:
        @"<?xml version=\"1.0\"?>"
         "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
         "<s:Body><u:%@ xmlns:u=\"%@\">%@</u:%@></s:Body></s:Envelope>",
         action, serviceType, arguments ?: @"", action];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:controlURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5.0];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"text/xml; charset=\"utf-8\"" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"\"%@#%@\"", serviceType, action] forHTTPHeaderField:@"SOAPAction"];
    NSHTTPURLResponse *response = nil;
    NSError *error = nil;
    NSData *data = FilzaSSHPublicSynchronousRequest(request, &response, &error);
    if (statusCode) *statusCode = response.statusCode;
    return data;
}

static NSString *FilzaSSHPublicUPnPExternalAddress(NSURL *controlURL, NSString *serviceType)
{
    NSInteger status = 0;
    NSData *data = FilzaSSHPublicUPnPSOAP(controlURL, serviceType, @"GetExternalIPAddress", @"", &status);
    if (!data.length || status < 200 || status >= 300) return nil;
    NSString *xml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<NewExternalIPAddress>\\s*([^<]+)\\s*</NewExternalIPAddress>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
    if (!match || match.numberOfRanges < 2) return nil;
    return [[xml substringWithRange:[match rangeAtIndex:1]] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL FilzaSSHPublicUPnPAddMapping(NSURL *controlURL, NSString *serviceType, NSString *localAddress, NSInteger internalPort, NSInteger externalPort, uint32_t lease)
{
    NSString *args = [NSString stringWithFormat:
        @"<NewRemoteHost></NewRemoteHost>"
         "<NewExternalPort>%ld</NewExternalPort>"
         "<NewProtocol>TCP</NewProtocol>"
         "<NewInternalPort>%ld</NewInternalPort>"
         "<NewInternalClient>%@</NewInternalClient>"
         "<NewEnabled>1</NewEnabled>"
         "<NewPortMappingDescription>Filza SSH</NewPortMappingDescription>"
         "<NewLeaseDuration>%u</NewLeaseDuration>",
         (long)externalPort,
         (long)internalPort,
         FilzaSSHPublicXMLEscape(localAddress),
         lease];
    NSInteger status = 0;
    FilzaSSHPublicUPnPSOAP(controlURL, serviceType, @"AddPortMapping", args, &status);
    return status >= 200 && status < 300;
}

static void FilzaSSHPublicUPnPDeleteMapping(NSURL *controlURL, NSString *serviceType, NSInteger externalPort)
{
    if (!controlURL || !serviceType.length || externalPort <= 0) return;
    NSString *args = [NSString stringWithFormat:
        @"<NewRemoteHost></NewRemoteHost>"
         "<NewExternalPort>%ld</NewExternalPort>"
         "<NewProtocol>TCP</NewProtocol>", (long)externalPort];
    FilzaSSHPublicUPnPSOAP(controlURL, serviceType, @"DeletePortMapping", args, NULL);
}

static BOOL FilzaSSHPublicTryUPnP(NSInteger internalPort, NSString **publicAddress, NSInteger *externalPort, NSString **failure)
{
    NSString *localAddress = FilzaSSHServerLANAddress();
    if (!localAddress.length) {
        if (failure) *failure = @"No Wi-Fi IPv4 address is available for UPnP.";
        return NO;
    }

    NSArray<NSURL *> *locations = FilzaSSHPublicUPnPLocations();
    if (!locations.count) {
        if (failure) *failure = @"No UPnP Internet Gateway Device answered discovery.";
        return NO;
    }

    for (NSURL *location in locations) {
        NSURL *controlURL = nil;
        NSString *serviceType = nil;
        if (!FilzaSSHPublicFindUPnPService(location, &controlURL, &serviceType)) continue;

        NSInteger candidates[] = { internalPort, 40000 + (NSInteger)arc4random_uniform(20000) };
        for (NSUInteger index = 0; index < 2; index++) {
            NSInteger candidate = candidates[index];
            BOOL added = FilzaSSHPublicUPnPAddMapping(controlURL, serviceType, localAddress, internalPort, candidate, FilzaSSHPublicLeaseSeconds);
            if (!added) {
                // A small number of IGDv1 routers only accept lease 0.
                added = FilzaSSHPublicUPnPAddMapping(controlURL, serviceType, localAddress, internalPort, candidate, 0);
            }
            if (!added) continue;

            NSString *address = FilzaSSHPublicUPnPExternalAddress(controlURL, serviceType);
            if (!address.length) {
                FilzaSSHPublicUPnPDeleteMapping(controlURL, serviceType, candidate);
                continue;
            }
            FilzaSSHPublicUPnPControlURL = controlURL;
            FilzaSSHPublicUPnPServiceType = serviceType;
            if (publicAddress) *publicAddress = address;
            if (externalPort) *externalPort = candidate;
            return YES;
        }
    }

    if (failure) *failure = @"UPnP gateway was found but rejected the TCP port mapping.";
    return NO;
}

static void FilzaSSHPublicCancelRenewal(void)
{
    if (FilzaSSHPublicRenewTimer) {
        dispatch_source_cancel(FilzaSSHPublicRenewTimer);
        FilzaSSHPublicRenewTimer = nil;
    }
}

static void FilzaSSHPublicRemoveMapping(void)
{
    FilzaSSHPublicCancelRenewal();
    if (FilzaSSHPublicMappingActive) {
        if ([FilzaSSHPublicBackend isEqualToString:@"NAT-PMP"]) FilzaSSHPublicDeleteNATPMP();
        else if ([FilzaSSHPublicBackend isEqualToString:@"UPnP"]) FilzaSSHPublicUPnPDeleteMapping(FilzaSSHPublicUPnPControlURL, FilzaSSHPublicUPnPServiceType, FilzaSSHPublicExternalPort);
    }
    FilzaSSHPublicMappingActive = NO;
    FilzaSSHPublicInternalPort = 0;
    FilzaSSHPublicExternalPort = 0;
    FilzaSSHPublicAddress = nil;
    FilzaSSHPublicBackend = nil;
    FilzaSSHPublicGateway = nil;
    FilzaSSHPublicUPnPControlURL = nil;
    FilzaSSHPublicUPnPServiceType = nil;
    FilzaSSHPublicLastSuccess = nil;
}

static BOOL FilzaSSHPublicRequirementsSatisfied(NSString **failure)
{
    if (!FilzaSSHServerIsRunning()) {
        if (failure) *failure = @"SSH listener is not running.";
        return NO;
    }
    if (!FilzaSSHAuthenticationEnabled()) {
        if (failure) *failure = @"Public exposure requires SSH authentication to be enabled.";
        return NO;
    }
    if (!FilzaSSHPasswordConfigured()) {
        if (failure) *failure = @"Set an SSH password before enabling public exposure.";
        return NO;
    }
    if (!FilzaSSHServerLANAddress().length) {
        if (failure) *failure = @"Public direct mapping requires a Wi-Fi/LAN IPv4 connection.";
        return NO;
    }
    return YES;
}

static void FilzaSSHPublicAttemptMapping(void);

static void FilzaSSHPublicScheduleRenewal(void)
{
    FilzaSSHPublicCancelRenewal();
    FilzaSSHPublicRenewTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, FilzaSSHPublicQueue);
    dispatch_source_set_timer(FilzaSSHPublicRenewTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * 60 * NSEC_PER_SEC)),
                              (uint64_t)(25 * 60 * NSEC_PER_SEC),
                              (uint64_t)(15 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(FilzaSSHPublicRenewTimer, ^{
        if (!FilzaSSHServerIsRunning()) {
            FilzaSSHPublicRemoveMapping();
            return;
        }
        // Re-request the mapping. Router protocols treat the same mapping as
        // a lease renewal; this also repairs mappings after a gateway reboot.
        FilzaSSHPublicMappingActive = NO;
        FilzaSSHPublicAttemptMapping();
    });
    dispatch_resume(FilzaSSHPublicRenewTimer);
}

static void FilzaSSHPublicAttemptMapping(void)
{
    if (FilzaSSHPublicAttemptRunning) return;
    FilzaSSHPublicAttemptRunning = YES;

    NSString *requirementFailure = nil;
    if (!FilzaSSHPublicRequirementsSatisfied(&requirementFailure)) {
        FilzaSSHPublicRemoveMapping();
        FilzaSSHPublicSetStatus(requirementFailure);
        FilzaSSHPublicAttemptRunning = NO;
        return;
    }

    NSInteger internalPort = FilzaSSHConfiguredPort();
    if (FilzaSSHPublicMappingActive && FilzaSSHPublicInternalPort == internalPort &&
        FilzaSSHPublicLastSuccess && -[FilzaSSHPublicLastSuccess timeIntervalSinceNow] < 20 * 60) {
        FilzaSSHPublicAttemptRunning = NO;
        return;
    }

    if (FilzaSSHPublicMappingActive) FilzaSSHPublicRemoveMapping();
    FilzaSSHPublicSetStatus(@"Requesting a public TCP mapping from the router…");

    NSString *address = nil;
    NSInteger mappedPort = 0;
    NSString *natFailure = nil;
    BOOL mapped = FilzaSSHPublicTryNATPMP(internalPort, internalPort, &address, &mappedPort, &natFailure);
    NSString *backend = mapped ? @"NAT-PMP" : nil;

    NSString *upnpFailure = nil;
    if (!mapped) {
        mapped = FilzaSSHPublicTryUPnP(internalPort, &address, &mappedPort, &upnpFailure);
        if (mapped) backend = @"UPnP";
    }

    if (!mapped) {
        NSString *failure = [NSString stringWithFormat:@"Direct public mapping unavailable. NAT-PMP: %@ UPnP: %@",
                             natFailure ?: @"not available.", upnpFailure ?: @"not available."];
        FilzaSSHPublicSetStatus(failure);
        FilzaSSHPublicAttemptRunning = NO;
        return;
    }

    if (!FilzaSSHPublicIPv4IsGlobal(address)) {
        if ([backend isEqualToString:@"NAT-PMP"]) {
            FilzaSSHPublicInternalPort = internalPort;
            FilzaSSHPublicExternalPort = mappedPort;
            FilzaSSHPublicDeleteNATPMP();
        } else if ([backend isEqualToString:@"UPnP"]) {
            FilzaSSHPublicUPnPDeleteMapping(FilzaSSHPublicUPnPControlURL, FilzaSSHPublicUPnPServiceType, mappedPort);
        }
        FilzaSSHPublicSetStatus([NSString stringWithFormat:@"Router mapping succeeded, but its WAN address %@ is private/CGNAT. A direct Internet SSH endpoint cannot exist on this connection without an upstream port mapping or relay.", address ?: @"unknown"]);
        FilzaSSHPublicAttemptRunning = NO;
        return;
    }

    FilzaSSHPublicMappingActive = YES;
    FilzaSSHPublicInternalPort = internalPort;
    FilzaSSHPublicExternalPort = mappedPort;
    FilzaSSHPublicAddress = address;
    FilzaSSHPublicBackend = backend;
    FilzaSSHPublicLastSuccess = NSDate.date;

    NSString *username = FilzaSSHConfiguredUsername();
    FilzaSSHPublicSetStatus([NSString stringWithFormat:@"PUBLIC via %@ — ssh %@@%@ -p %ld",
                             backend, username, address, (long)mappedPort]);
    FilzaSSHPublicScheduleRenewal();
    FilzaSSHPublicAttemptRunning = NO;
}

static void FilzaSSHPublicReconcile(void)
{
    FilzaSSHPublicInitialize();
    dispatch_async(FilzaSSHPublicQueue, ^{
        if (!FilzaSSHServerIsRunning()) {
            if (FilzaSSHPublicMappingActive) FilzaSSHPublicRemoveMapping();
            FilzaSSHPublicSetStatus(@"SSH listener is not running.");
            return;
        }
        if (FilzaSSHPublicInternalPort != 0 && FilzaSSHPublicInternalPort != FilzaSSHConfiguredPort()) {
            FilzaSSHPublicRemoveMapping();
        }
        FilzaSSHPublicAttemptMapping();
    });
}

static NSString *FilzaSSHPublicFooter(id controller, SEL selector, UITableView *table, NSInteger section)
{
    NSString *base = FilzaSSHPublicOriginalFooter ? FilzaSSHPublicOriginalFooter(controller, selector, table, section) : nil;
    NSString *header = nil;
    if ([controller respondsToSelector:@selector(tableView:titleForHeaderInSection:)]) {
        header = ((id (*)(id, SEL, id, NSInteger))objc_msgSend)(controller, @selector(tableView:titleForHeaderInSection:), table, section);
    }
    NSString *normalized = [header stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].uppercaseString;
    if (![normalized isEqualToString:@"SSH SERVER"]) return base;
    NSString *publicStatus = FilzaSSHPublicStatusSnapshot();
    if (!base.length) return publicStatus;
    return [NSString stringWithFormat:@"%@\n%@", base, publicStatus];
}

static void FilzaSSHPublicInstallFooterHook(void)
{
    if (FilzaSSHPublicFooterInstalled) return;
    Class cls = NSClassFromString(@"TGPreferencesTableViewController");
    SEL selector = @selector(tableView:titleForFooterInSection:);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (current == (IMP)FilzaSSHPublicFooter) {
        FilzaSSHPublicFooterInstalled = YES;
        return;
    }
    FilzaSSHPublicOriginalFooter = (void *)current;
    method_setImplementation(method, (IMP)FilzaSSHPublicFooter);
    FilzaSSHPublicFooterInstalled = YES;
    FilzaDiagnosticsAppend(@"SSH", @"public Internet SSH status appended to SSH SERVER preferences footer");
}

__attribute__((constructor)) static void FilzaSSHPublicAccessInit(void)
{
    @autoreleasepool {
        FilzaSSHPublicInitialize();
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.90 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                FilzaSSHPublicInstallFooterHook();
                FilzaSSHPublicReconcile();
            });

            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                FilzaSSHPublicInstallFooterHook();
                FilzaSSHPublicReconcile();
            }];

            [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                FilzaSSHPublicReconcile();
            }];
        });
    }
}
