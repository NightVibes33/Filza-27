#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <sys/sysctl.h>
#include <sys/stat.h>
#include <unistd.h>

#import "MCMFilzaIntegration.h"
#import "GestaltManager.h"

static IMP gCDOriginalTableDidMoveToWindow = NULL;
static BOOL gCDTableLifecycleHookInstalled = NO;

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
            @"TGMusicLibraryViewController": CDClassStatus(@"TGMusicLibraryViewController",
                @[@"viewDidLoad"]),
            @"TGMainView": CDClassStatus(@"TGMainView",
                @[@"openMusicLib", @"createMainToolBar"]),
            @"ByeTunesEmbeddedHostFactory": CDClassStatus(@"ByeTunesEmbeddedHostFactory",
                @[@"makeViewController", @"makeLibraryViewController"]),
            @"MondGestaltHostFactory": CDClassStatus(@"MondGestaltHostFactory",
                @[@"makeViewControllerWithPath:"]),
            @"GCDWebDAVServer": CDClassStatus(@"GCDWebDAVServer",
                @[@"initWithUploadDirectory:", @"startWithOptions:error:"]),
            @"GestaltManagerController": CDClassStatus(@"GestaltManagerController", @[@"viewDidLoad"]),
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
            @"byeTunesStage": CDPathStatus([[documents stringByAppendingPathComponent:@"FilzaSlop Logs"]
                stringByAppendingPathComponent:@"ByeTunesEmbedStage.txt"]),
            @"webDAVStatus": CDPathStatus([[documents stringByAppendingPathComponent:@"FilzaSlop Logs"]
                stringByAppendingPathComponent:@"WebDAVStatus.txt"]),
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

static void CDTableDidMoveToWindow(UITableView *tableView, SEL selector) {
    if (gCDOriginalTableDidMoveToWindow)
        ((void (*)(id, SEL))gCDOriginalTableDidMoveToWindow)(tableView, selector);
    if (!tableView.window) return;

    // The managers screen may not exist during launch. Re-run discovery when
    // any table actually becomes visible, then again after Filza populates it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 75 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        FilzaGestaltManagerInstall();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 450 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        FilzaGestaltManagerInstall();
    });
}

static void CDInstallTableLifecycleHook(void) {
    if (gCDTableLifecycleHookInstalled) return;
    Method method = class_getInstanceMethod(UITableView.class, @selector(didMoveToWindow));
    if (!method) return;
    gCDOriginalTableDidMoveToWindow = method_getImplementation(method);
    method_setImplementation(method, (IMP)CDTableDidMoveToWindow);
    gCDTableLifecycleHookInstalled = YES;
    NSLog(@"[CompatibilityDiagnostics] late manager discovery hook installed");
}

__attribute__((constructor)) static void CDCompatibilityDiagnosticsInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CDInstallTableLifecycleHook();
        FilzaGestaltManagerInstall();
    });

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *note) {
                    CDInstallTableLifecycleHook();
                    FilzaGestaltManagerInstall();
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        CDWriteCompatibilityReport();
                    });
                }];
}
