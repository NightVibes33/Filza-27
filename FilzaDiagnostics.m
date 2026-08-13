@import Foundation;
@import UIKit;

#import <fcntl.h>
#import <limits.h>
#import <signal.h>
#import <string.h>
#import <unistd.h>

#import "FilzaDiagnostics.h"

static char gFilzaSignalPath[PATH_MAX];
static NSUncaughtExceptionHandler *gPreviousExceptionHandler = NULL;

NSString *FilzaDiagnosticsDirectory(void)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                               NSUserDomainMask,
                                                               YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    NSString *directory = [documents stringByAppendingPathComponent:@"FilzaSlop Logs"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    return directory;
}

static void FilzaAppendTextToPath(NSString *path, NSString *text)
{
    if (!path.length || !text.length) return;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;

    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle synchronizeFile];
        [handle closeFile];
    } @catch (__unused NSException *exception) {
        @try { [handle closeFile]; } @catch (__unused NSException *ignored) {}
    }
}

void FilzaDiagnosticsAppend(NSString *component, NSString *message)
{
    NSString *directory = FilzaDiagnosticsDirectory();
    NSString *timestamp = [NSISO8601DateFormatter.new stringFromDate:NSDate.date];
    NSString *line = [NSString stringWithFormat:@"%@ | %@ | %@\n",
                      timestamp ?: NSDate.date.description,
                      component.length ? component : @"FilzaSlop",
                      message.length ? message : @"(empty)"];
    FilzaAppendTextToPath([directory stringByAppendingPathComponent:@"Runtime.log"], line);
}

void FilzaDiagnosticsWriteByeTunesStage(NSString *stage)
{
    NSString *directory = FilzaDiagnosticsDirectory();
    NSString *timestamp = [NSISO8601DateFormatter.new stringFromDate:NSDate.date];
    NSString *line = [NSString stringWithFormat:@"%@ | %@\n",
                      timestamp ?: NSDate.date.description,
                      stage.length ? stage : @"unknown"];
    FilzaAppendTextToPath([directory stringByAppendingPathComponent:@"ByeTunesEmbedStage.txt"], line);
    FilzaDiagnosticsAppend(@"ByeTunes", stage ?: @"unknown");
}

static void FilzaUncaughtExceptionHandler(NSException *exception)
{
    NSString *reason = [NSString stringWithFormat:@"%@ | %@\n%@",
                        exception.name ?: @"NSException",
                        exception.reason ?: @"no reason",
                        [exception.callStackSymbols componentsJoinedByString:@"\n"] ?: @""];
    FilzaDiagnosticsAppend(@"UncaughtException", reason);
    NSString *path = [FilzaDiagnosticsDirectory() stringByAppendingPathComponent:@"LastException.txt"];
    [reason writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (gPreviousExceptionHandler) gPreviousExceptionHandler(exception);
}

static void FilzaSignalHandler(int signalNumber)
{
    if (gFilzaSignalPath[0] == '\0') return;

    const char *message = "FilzaSlop terminated by a fatal signal. Check Runtime.log and ByeTunesEmbedStage.txt for the last completed stage.\n";
    size_t length = sizeof("FilzaSlop terminated by a fatal signal. Check Runtime.log and ByeTunesEmbedStage.txt for the last completed stage.\n") - 1;
    switch (signalNumber) {
        case SIGABRT:
            message = "FilzaSlop terminated by SIGABRT. Check Runtime.log and ByeTunesEmbedStage.txt for the last completed stage.\n";
            length = sizeof("FilzaSlop terminated by SIGABRT. Check Runtime.log and ByeTunesEmbedStage.txt for the last completed stage.\n") - 1;
            break;
        case SIGILL:
            message = "FilzaSlop terminated by SIGILL. Check Runtime.log and ByeTunesEmbedStage.txt for the last completed stage.\n";
            length = sizeof("FilzaSlop terminated by SIGILL. Check Runtime.log and ByeTunesEmbedStage.txt for the last completed stage.\n") - 1;
            break;
        case SIGTRAP:
            message = "FilzaSlop terminated by SIGTRAP. Check Runtime.log and ByeTunesEmbedStage.txt for the last completed stage.\n";
            length = sizeof("FilzaSlop terminated by SIGTRAP. Check Runtime.log and ByeTunesEmbedStage.txt for the last completed stage.\n") - 1;
            break;
        case SIGBUS:
            message = "FilzaSlop terminated by SIGBUS. Check Runtime.log and ByeTunesEmbedStage.txt for the last completed stage.\n";
            length = sizeof("FilzaSlop terminated by SIGBUS. Check Runtime.log and ByeTunesEmbedStage.txt for the last completed stage.\n") - 1;
            break;
        case SIGSEGV:
            message = "FilzaSlop terminated by SIGSEGV. Check Runtime.log and ByeTunesEmbedStage.txt for the last completed stage.\n";
            length = sizeof("FilzaSlop terminated by SIGSEGV. Check Runtime.log and ByeTunesEmbedStage.txt for the last completed stage.\n") - 1;
            break;
        case SIGFPE:
            message = "FilzaSlop terminated by SIGFPE. Check Runtime.log and ByeTunesEmbedStage.txt for the last completed stage.\n";
            length = sizeof("FilzaSlop terminated by SIGFPE. Check Runtime.log and ByeTunesEmbedStage.txt for the last completed stage.\n") - 1;
            break;
        default:
            break;
    }

    // Only async-signal-safe syscalls are used here. SA_RESETHAND restores the
    // default disposition before this handler executes, so returning preserves
    // the original fatal behavior while leaving a breadcrumb on disk.
    int fd = open(gFilzaSignalPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd >= 0) {
        (void)write(fd, message, length);
        (void)close(fd);
    }
}

static void FilzaInstallSignalHandler(int signalNumber)
{
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    action.sa_handler = FilzaSignalHandler;
    action.sa_flags = SA_RESETHAND;
    (void)sigaction(signalNumber, &action, NULL);
}

static void FilzaPrepareVisibleDiagnostics(void)
{
    NSString *directory = FilzaDiagnosticsDirectory();
    NSString *readmePath = [directory stringByAppendingPathComponent:@"README.txt"];
    if (![NSFileManager.defaultManager fileExistsAtPath:readmePath]) {
        NSString *readme = @"FilzaSlop diagnostics\n\n"
                            "This folder is intentionally stored inside the app Documents directory so it is visible through the iOS Files app when file sharing is enabled.\n\n"
                            "Runtime.log: launch/runtime breadcrumbs\n"
                            "ByeTunesEmbedStage.txt: persistent ByeTunes startup stages\n"
                            "WebDAVStatus.txt: latest listener, URL, port, authentication, and root status\n"
                            "LastException.txt: last uncaught Objective-C exception\n"
                            "LastSignal.txt: last fatal POSIX signal observed by the process\n";
        [readme writeToFile:readmePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    NSString *signalPath = [directory stringByAppendingPathComponent:@"LastSignal.txt"];
    const char *raw = signalPath.fileSystemRepresentation;
    if (raw) strlcpy(gFilzaSignalPath, raw, sizeof(gFilzaSignalPath));

    NSDictionary *bundle = NSBundle.mainBundle.infoDictionary ?: @{};
    NSString *launch = [NSString stringWithFormat:@"bundle=%@ version=%@ build=%@ os=%@ home=%@",
                        bundle[@"CFBundleIdentifier"] ?: @"unknown",
                        bundle[@"CFBundleShortVersionString"] ?: @"unknown",
                        bundle[@"CFBundleVersion"] ?: @"unknown",
                        UIDevice.currentDevice.systemVersion ?: @"unknown",
                        NSHomeDirectory() ?: @"unknown"];
    FilzaDiagnosticsAppend(@"Launch", launch);
}

__attribute__((constructor)) static void FilzaDiagnosticsInit(void)
{
    @autoreleasepool {
        FilzaPrepareVisibleDiagnostics();
        gPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(FilzaUncaughtExceptionHandler);
        FilzaInstallSignalHandler(SIGABRT);
        FilzaInstallSignalHandler(SIGILL);
        FilzaInstallSignalHandler(SIGTRAP);
        FilzaInstallSignalHandler(SIGBUS);
        FilzaInstallSignalHandler(SIGSEGV);
        FilzaInstallSignalHandler(SIGFPE);
    }
}
