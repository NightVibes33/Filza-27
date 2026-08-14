#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <dlfcn.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *RCSysctlString(const char *name) {
    size_t size = 0;
    if (sysctlbyname(name, NULL, &size, NULL, 0) != 0 || size == 0) return @"unknown";
    char *buffer = calloc(1, size + 1);
    if (!buffer) return @"unknown";
    NSString *value = @"unknown";
    if (sysctlbyname(name, buffer, &size, NULL, 0) == 0 && buffer[0])
        value = [NSString stringWithUTF8String:buffer] ?: @"unknown";
    free(buffer);
    return value;
}

static NSDictionary *RCPathStatus(NSString *path) {
    struct stat st = {0};
    BOOL exists = path.length && lstat(path.fileSystemRepresentation, &st) == 0;
    return @{
        @"path": path ?: @"",
        @"exists": @(exists),
        @"readable": @(exists && access(path.fileSystemRepresentation, R_OK) == 0),
        @"directory": @(exists && S_ISDIR(st.st_mode)),
    };
}

static NSDictionary *RCSymbolStatus(const char *symbol) {
    dlerror();
    void *address = dlsym(RTLD_DEFAULT, symbol);
    const char *error = dlerror();
    return @{
        @"symbol": [NSString stringWithUTF8String:symbol] ?: @"",
        @"present": @(address != NULL),
        @"address": address ? [NSString stringWithFormat:@"%p", address] : @"0x0",
        @"error": error ? ([NSString stringWithUTF8String:error] ?: @"") : @"",
    };
}

static void RCWriteReport(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *directory = [documents stringByAppendingPathComponent:@"Device Storage/Diagnostics"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];

    NSString *build = RCSysctlString("kern.osversion");
    NSString *machine = RCSysctlString("hw.machine");
    BOOL exactResearchBuild = [build isEqualToString:@"24A5380h"] &&
                              [machine isEqualToString:@"iPhone17,3"];

    NSArray *symbols = @[
        RCSymbolStatus("shared_region_check_np"),
        RCSymbolStatus("shared_region_map_and_slide_2_np"),
        RCSymbolStatus("_shared_region_check_np"),
        RCSymbolStatus("_shared_region_map_and_slide_2_np"),
    ];

    NSArray *cachePaths = @[
        RCPathStatus(@"/System/Library/dyld/dyld_shared_cache_arm64e"),
        RCPathStatus(@"/System/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e"),
        RCPathStatus(@"/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e"),
    ];

    NSDictionary *report = @{
        @"generatedAt": NSDate.date,
        @"cve": @"CVE-2026-43724",
        @"upstream": @"impost0r/Rie",
        @"upstreamValidatedTarget": @"macOS 26.5 (25F71), Apple M1 arm64e",
        @"device": @{
            @"systemVersion": UIDevice.currentDevice.systemVersion ?: @"unknown",
            @"build": build,
            @"machine": machine,
            @"exactResearchBuild": @(exactResearchBuild),
        },
        @"sharedRegionSymbols": symbols,
        @"dyldCachePaths": cachePaths,
        @"status": @"probe-only",
        @"triggerAttempted": @NO,
        @"kernelWriteClaimed": @NO,
        @"notes": @[
            @"Rie upstream is validated for macOS, not iOS.",
            @"This probe does not invoke shared_region_map_and_slide_2_np or syscall 536.",
            @"Presence of symbols or cache files does not prove CVE-2026-43724 is reachable on this iOS build.",
        ],
    };

    NSString *plistPath = [directory stringByAppendingPathComponent:@"CVE-2026-43724-Rie-Compatibility.plist"];
    NSString *textPath = [directory stringByAppendingPathComponent:@"CVE-2026-43724-Rie-Compatibility.txt"];
    [report writeToURL:[NSURL fileURLWithPath:plistPath] error:nil];

    NSMutableString *text = [NSMutableString string];
    [text appendString:@"CVE-2026-43724 / Rie iOS compatibility probe\n"];
    [text appendFormat:@"Generated: %@\n", report[@"generatedAt"]];
    [text appendFormat:@"Device: %@\n", machine];
    [text appendFormat:@"iOS: %@ (%@)\n", UIDevice.currentDevice.systemVersion, build];
    [text appendFormat:@"Exact research target: %@\n\n", exactResearchBuild ? @"YES" : @"NO"];
    [text appendString:@"Upstream validated target: macOS 26.5 (25F71), Apple M1 arm64e\n"];
    [text appendString:@"Trigger attempted: NO\nKernel write claimed: NO\n\n"];
    [text appendFormat:@"Shared-region symbols:\n%@\n\n", symbols];
    [text appendFormat:@"dyld cache paths:\n%@\n", cachePaths];
    [text writeToFile:textPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSLog(@"[CVE43724RieCompatibility] report written to %@", textPath);
}

__attribute__((constructor)) static void CVE43724RieCompatibilityInit(void) {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:nil
                usingBlock:^(__unused NSNotification *note) {
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        RCWriteReport();
                    });
                }];
}
