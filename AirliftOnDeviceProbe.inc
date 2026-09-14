#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_init.h>
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
        FZAirliftProbeMachService(@"com.apple.atc")
    ];

    NSArray *images = @[
        FZAirliftProbeImage(@"/System/Library/PrivateFrameworks/AirTraffic.framework/AirTraffic"),
        FZAirliftProbeImage(@"/System/Library/PrivateFrameworks/AirTrafficDevice.framework/AirTrafficDevice"),
        FZAirliftProbeImage(@"/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost")
    ];

    NSArray *classes = @[
        FZAirliftProbeClass(@"AirTrafficDevice"),
        FZAirliftProbeClass(@"ATDevice"),
        FZAirliftProbeClass(@"ATAirlock"),
        FZAirliftProbeClass(@"ATLegacyAssetLink")
    ];

    NSDictionary *report = @{
        @"SchemaVersion": @1,
        @"PinnedAirliftRevision": FZAirliftPinnedRevision,
        @"GeneratedAt": [NSDate date],
        @"Process": NSProcessInfo.processInfo.processName ?: @"",
        @"PID": @(getpid()),
        @"SystemVersion": UIDevice.currentDevice.systemVersion ?: @"",
        @"Model": UIDevice.currentDevice.model ?: @"",
        @"MachServices": services,
        @"PrivateFrameworks": images,
        @"RuntimeClasses": classes,
        @"Interpretation": @"BootstrapReachable=true means the Filza process can obtain the service port. It does not prove that AirTraffic accepts useful messages or that the Airlift primitive works on-device."
    };

    NSString *plistPath = [directory stringByAppendingPathComponent:@"Airlift On-Device Probe.plist"];
    BOOL wrote = [report writeToFile:plistPath atomically:YES];

    NSString *readme =
        @"Airlift experimental integration\n\n"
         "This probe checks whether the current Filza process can see the iOS-side AirTraffic/ATC pieces used by Airlift. It does not claim a sandbox escape.\n\n"
         "Key result: MachServices -> com.apple.atc -> BootstrapReachable. If true, the next research step is protocol discovery and a no-op handshake. If false, a direct in-app Airlift transport needs another reachable intermediary or additional privilege.\n\n"
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
                   dispatch_get_main_queue(), ^{
        FZAirliftWriteProbe();
    });
}
