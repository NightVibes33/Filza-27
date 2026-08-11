#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <sys/sysctl.h>
#include <sys/stat.h>
#include <unistd.h>

#import "MCMFilzaIntegration.h"

static NSString *CDSysctlString(const char *name) {
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

static NSDictionary *CDClassStatus(NSString *className, NSArray<NSString *> *selectors) {
    Class cls = NSClassFromString(className);
    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    status[@"present"] = @(cls != Nil);
    if (cls && selectors.count) {
        NSMutableDictionary *selectorStatus = [NSMutableDictionary dictionary];
        for (NSString *selectorName in selectors) {
            SEL selector = NSSelectorFromString(selectorName);
            selectorStatus[selectorName] = @(class_getInstanceMethod(cls, selector) != NULL ||
                                             class_getClassMethod(cls, selector) != NULL);
        }
        status[@"selectors"] = selectorStatus;
    }
    return status;
}

static NSDictionary *CDPathStatus(NSString *path) {
    if (!path.length) return @{ @"path": @"", @"exists": @NO };
    struct stat st = {0};
    BOOL exists = lstat(path.fileSystemRepresentation, &st) == 0;
    return @{
        @"path": path,
        @"exists": @(exists),
        @"directory": @(exists && S_ISDIR(st.st_mode)),
        @"readable": @([NSFileManager.defaultManager isReadableFileAtPath:path]),
        @"writable": @([NSFileManager.defaultManager isWritableFileAtPath:path]),
    };
}

static void CDWriteCompatibilityReport(void) {
    NSString *virtualRoot = MCMFilzaVirtualRoot();
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *reportDirectory = [documents stringByAppendingPathComponent:@"Device Storage/Diagnostics"];
    [NSFileManager.defaultManager createDirectoryAtPath:reportDirectory
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];

    NSDictionary *report = @{
        @"generatedAt": NSDate.date,
        @"system": @{
            @"version": UIDevice.currentDevice.systemVersion ?: @"unknown",
            @"build": CDSysctlString("kern.osversion"),
            @"machine": CDSysctlString("hw.machine"),
            @"process": NSProcessInfo.processInfo.processName ?: @"unknown",
        },
        @"runtime": @{
            @"TGFileSystemListViewController": CDClassStatus(@"TGFileSystemListViewController",
                @[@"setCurrentPath:", @"doLoadingPage", @"updateEditableUI"]),
            @"TGApplicationsViewController": CDClassStatus(@"TGApplicationsViewController",
                @[@"browserView:didSelectItemAtIndexPath:"]),
            @"TGPageViewController": CDClassStatus(@"TGPageViewController",
                @[@"copyFilesAndDirectoryFromPasteboard"]),
            @"Zipper": CDClassStatus(@"Zipper",
                @[@"ZipFiles:toFilePath:currentDirectory:",
                  @"unZipFile:toPath:currentDirectory:outMessage:",
                  @"unZipFile:toPath:currentDirectory:withPassword:outMessage:"]),
        },
        @"paths": @{
            @"virtualRoot": CDPathStatus(virtualRoot),
            @"documents": CDPathStatus(documents),
        },
    };

    NSString *plistPath = [reportDirectory stringByAppendingPathComponent:@"CompatibilityReport.plist"];
    NSString *textPath = [reportDirectory stringByAppendingPathComponent:@"CompatibilityReport.txt"];
    NSError *error = nil;
    if (![report writeToURL:[NSURL fileURLWithPath:plistPath] error:&error])
        NSLog(@"[CompatibilityDiagnostics] plist write failed: %@", error);

    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"FilzaSlop compatibility report\nGenerated: %@\n", report[@"generatedAt"]];
    [text appendFormat:@"iOS: %@ (%@)\nDevice: %@\nProcess: %@\n\n",
        report[@"system"][@"version"], report[@"system"][@"build"],
        report[@"system"][@"machine"], report[@"system"][@"process"]];
    [text appendFormat:@"Virtual root: %@\nExists: %@  Readable: %@  Writable: %@\n\n",
        report[@"paths"][@"virtualRoot"][@"path"],
        report[@"paths"][@"virtualRoot"][@"exists"],
        report[@"paths"][@"virtualRoot"][@"readable"],
        report[@"paths"][@"virtualRoot"][@"writable"]];
    [text appendString:@"Runtime classes/selectors:\n"];
    [text appendFormat:@"%@\n", report[@"runtime"]];
    [text writeToFile:textPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSLog(@"[CompatibilityDiagnostics] report written to %@", reportDirectory);
}

__attribute__((constructor)) static void CDCompatibilityDiagnosticsInit(void) {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *note) {
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        CDWriteCompatibilityReport();
                    });
                }];
}
