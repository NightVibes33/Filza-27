@import Foundation;
@import UIKit;

#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

#import "FilzaDiagnostics.h"
#import "FilzaSSHServer.h"

static BOOL FilzaSSHHealthProbeScheduled = NO;

static BOOL FilzaSSHProbeBanner(NSInteger port, NSString **result)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (result) *result = [NSString stringWithFormat:@"socket() failed: %s", strerror(errno)];
        return NO;
    }

    struct timeval timeout = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        int saved = errno;
        close(fd);
        if (result) *result = [NSString stringWithFormat:@"loopback connect failed: %s", strerror(saved)];
        return NO;
    }

    char banner[512] = {0};
    ssize_t count = recv(fd, banner, sizeof(banner) - 1, 0);
    int saved = errno;
    if (count > 0) {
        banner[count] = '\0';
        // Complete identification exchange so libssh can cleanly identify this
        // as a health probe before we close without entering userauth.
        const char probeBanner[] = "SSH-2.0-Filza27HealthProbe\r\n";
        (void)send(fd, probeBanner, sizeof(probeBanner) - 1, 0);
    }
    close(fd);

    if (count <= 0) {
        if (result) *result = [NSString stringWithFormat:@"SSH banner missing: %s", strerror(saved)];
        return NO;
    }

    NSString *text = [[NSString alloc] initWithBytes:banner length:(NSUInteger)count encoding:NSUTF8StringEncoding] ?: @"";
    NSRange newline = [text rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet];
    NSString *line = newline.location == NSNotFound ? text : [text substringToIndex:newline.location];
    BOOL healthy = [line hasPrefix:@"SSH-2.0-"] || [line hasPrefix:@"SSH-1.99-"];
    if (result) *result = line.length ? line : @"empty SSH identification";
    return healthy;
}

static void FilzaSSHScheduleProtocolHealth(NSString *reason)
{
    if (FilzaSSHHealthProbeScheduled) return;
    if (![NSUserDefaults.standardUserDefaults boolForKey:FilzaSSHEnabledKey] || !FilzaSSHServerIsRunning()) return;

    FilzaSSHHealthProbeScheduled = YES;
    NSInteger port = FilzaSSHConfiguredPort();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *probe = nil;
        BOOL healthy = FilzaSSHProbeBanner(port, &probe);
        dispatch_async(dispatch_get_main_queue(), ^{
            FilzaSSHHealthProbeScheduled = NO;
            if (![NSUserDefaults.standardUserDefaults boolForKey:FilzaSSHEnabledKey] || !FilzaSSHServerIsRunning()) return;

            if (healthy) {
                FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"protocol self-test passed reason=%@ port=%ld banner=%@",
                                                reason ?: @"unknown", (long)port, probe ?: @"SSH-2.0"]);
                return;
            }

            FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"protocol self-test FAILED reason=%@ port=%ld result=%@; stopping listener",
                                            reason ?: @"unknown", (long)port, probe ?: @"unknown"]);
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:FilzaSSHEnabledKey];
            FilzaSSHServerStop();
        });
    });
}

__attribute__((constructor)) static void FilzaSSHProtocolHealthInit(void)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
                                                            object:NSUserDefaults.standardUserDefaults
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(__unused NSNotification *note) {
                FilzaSSHScheduleProtocolHealth(@"preferences changed");
            }];
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(__unused NSNotification *note) {
                FilzaSSHScheduleProtocolHealth(@"application active");
            }];
            FilzaSSHScheduleProtocolHealth(@"runtime initialized");
        });
    }
}
