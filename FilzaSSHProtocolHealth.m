@import Foundation;
@import UIKit;

#define LIBSSH_STATIC 1
#import <libssh/libssh.h>

#import "FilzaDiagnostics.h"
#import "FilzaSSHServer.h"

static BOOL FilzaSSHHealthProbeScheduled = NO;

// Use libssh as the loopback client instead of a raw banner socket. ssh_connect()
// completes version exchange and key exchange but does not authenticate, so this
// proves the embedded server is actually servicing the SSH protocol without
// needing to retain or recover the user's password.
static BOOL FilzaSSHProbeProtocol(NSInteger configuredPort, NSString **result)
{
    ssh_session client = ssh_new();
    if (!client) {
        if (result) *result = @"ssh_new() failed";
        return NO;
    }

    const char *host = "127.0.0.1";
    unsigned int port = (unsigned int)configuredPort;
    long timeout = 2;
    int verbosity = SSH_LOG_NOLOG;
    int optionsOK = SSH_OK;
    if (ssh_options_set(client, SSH_OPTIONS_HOST, host) != SSH_OK) optionsOK = SSH_ERROR;
    if (ssh_options_set(client, SSH_OPTIONS_PORT, &port) != SSH_OK) optionsOK = SSH_ERROR;
    if (ssh_options_set(client, SSH_OPTIONS_TIMEOUT, &timeout) != SSH_OK) optionsOK = SSH_ERROR;
    (void)ssh_options_set(client, SSH_OPTIONS_LOG_VERBOSITY, &verbosity);

    if (optionsOK != SSH_OK) {
        NSString *message = [NSString stringWithFormat:@"libssh client options failed: %s", ssh_get_error(client) ?: "unknown"];
        if (result) *result = message;
        ssh_free(client);
        return NO;
    }

    int rc = ssh_connect(client);
    const char *bannerCString = rc == SSH_OK ? ssh_get_serverbanner(client) : NULL;
    const char *kexCString = rc == SSH_OK ? ssh_get_kex_algo(client) : NULL;
    NSString *banner = bannerCString ? [NSString stringWithUTF8String:bannerCString] : nil;
    NSString *kex = kexCString ? [NSString stringWithUTF8String:kexCString] : nil;

    BOOL healthy = rc == SSH_OK &&
        ([banner hasPrefix:@"SSH-2.0-"] || [banner hasPrefix:@"SSH-1.99-"]) &&
        kex.length > 0;

    if (healthy) {
        if (result) *result = [NSString stringWithFormat:@"%@ kex=%@", banner, kex];
        ssh_disconnect(client);
    } else {
        if (result) *result = [NSString stringWithFormat:@"ssh_connect rc=%d error=%s banner=%@ kex=%@",
                               rc, ssh_get_error(client) ?: "unknown", banner ?: @"none", kex ?: @"none"];
        if (ssh_is_connected(client)) ssh_disconnect(client);
    }
    ssh_free(client);
    return healthy;
}

void FilzaSSHProtocolHealthSchedule(NSString *reason)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (FilzaSSHHealthProbeScheduled) return;
        if (![NSUserDefaults.standardUserDefaults boolForKey:FilzaSSHEnabledKey] || !FilzaSSHServerIsRunning()) return;

        FilzaSSHHealthProbeScheduled = YES;
        NSInteger port = FilzaSSHConfiguredPort();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSString *probe = nil;
            BOOL healthy = FilzaSSHProbeProtocol(port, &probe);
            dispatch_async(dispatch_get_main_queue(), ^{
                FilzaSSHHealthProbeScheduled = NO;
                if (![NSUserDefaults.standardUserDefaults boolForKey:FilzaSSHEnabledKey] || !FilzaSSHServerIsRunning()) return;

                if (healthy) {
                    FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"protocol self-test passed reason=%@ port=%ld %@",
                                                    reason ?: @"unknown", (long)port, probe ?: @"SSH-2.0"]);
                    return;
                }

                FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"protocol self-test FAILED reason=%@ port=%ld result=%@; stopping listener",
                                                reason ?: @"unknown", (long)port, probe ?: @"unknown"]);
                [NSUserDefaults.standardUserDefaults setBool:NO forKey:FilzaSSHEnabledKey];
                FilzaSSHServerStop();
            });
        });
    });
}

__attribute__((constructor)) static void FilzaSSHProtocolHealthInit(void)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(__unused NSNotification *note) {
                FilzaSSHProtocolHealthSchedule(@"application active");
            }];
            FilzaSSHProtocolHealthSchedule(@"runtime initialized");
        });
    }
}
