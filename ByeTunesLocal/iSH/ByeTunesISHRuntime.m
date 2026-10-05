#import "ByeTunesISHRuntime.h"

@import Foundation;
@import UIKit;

#import "GCDWebServer.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"

#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/init.h"
#include "kernel/signal.h"
#include "kernel/task.h"
#include "fs/fd.h"
#include "fs/path.h"
#include "fs/real.h"
#include "fs/devices.h"

static const NSUInteger kByeTunesISHPort = 41339;
static BOOL sISHReady = NO;
static NSString *sISHBootError = nil;
static NSString *sSharedHostRoot = nil;
static GCDWebServer *sISHServer = nil;
static dispatch_semaphore_t sCommandExitSemaphore = nil;
static pid_t_ sWaitingPID = 0;
static int sWaitingStatus = 0;

static dispatch_queue_t ISHCommandQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.nightvibes33.filza.byetunes-ish-command", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString *ByeTunesLibraryRoot(void) {
    NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    return [library stringByAppendingPathComponent:@"ByeTunesLocal"];
}

static NSDictionary *JSONResponse(BOOL ok, NSDictionary *extra) {
    NSMutableDictionary *value = [NSMutableDictionary dictionaryWithDictionary:extra ?: @{}];
    value[@"ok"] = @(ok);
    value[@"ish"] = @"official-ish-app/ish";
    value[@"ready"] = @(sISHReady);
    if (sISHBootError.length) value[@"bootError"] = sISHBootError;
    return value;
}

static GCDWebServerDataResponse *Response(NSInteger status, NSDictionary *json) {
    GCDWebServerDataResponse *response = [GCDWebServerDataResponse responseWithJSONObject:json ?: @{}];
    response.statusCode = status;
    [response setValue:@"no-store" forAdditionalHeader:@"Cache-Control"];
    return response;
}

static BOOL EnsureWritableRoot(NSString **rootOut, NSString **sharedOut, NSError **errorOut) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *bundle = [NSBundle.mainBundle pathForResource:@"ByeTunesISH" ofType:@"bundle"];
    if (!bundle.length) {
        if (errorOut) *errorOut = [NSError errorWithDomain:@"ByeTunesISH" code:1 userInfo:@{NSLocalizedDescriptionKey:@"ByeTunesISH.bundle missing"}];
        return NO;
    }

    NSString *sourceRoot = [bundle stringByAppendingPathComponent:@"rootfs"];
    NSString *sourceVersionPath = [bundle stringByAppendingPathComponent:@"rootfs.version"];
    NSString *sourceVersion = [NSString stringWithContentsOfFile:sourceVersionPath encoding:NSUTF8StringEncoding error:nil];
    if (![fm fileExistsAtPath:[sourceRoot stringByAppendingPathComponent:@"data"]] || !sourceVersion.length) {
        if (errorOut) *errorOut = [NSError errorWithDomain:@"ByeTunesISH" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Bundled iSH rootfs is incomplete"}];
        return NO;
    }

    NSString *base = ByeTunesLibraryRoot();
    NSString *root = [base stringByAppendingPathComponent:@"ish-root"];
    NSString *versionPath = [root stringByAppendingPathComponent:@"rootfs.version"];
    NSString *installedVersion = [NSString stringWithContentsOfFile:versionPath encoding:NSUTF8StringEncoding error:nil];

    [fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
    if (![installedVersion isEqualToString:sourceVersion]) {
        [fm removeItemAtPath:root error:nil];
        NSError *copyError = nil;
        if (![fm copyItemAtPath:sourceRoot toPath:root error:&copyError]) {
            if (errorOut) *errorOut = copyError;
            return NO;
        }
        [sourceVersion writeToFile:versionPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    NSString *shared = [base stringByAppendingPathComponent:@"jobs"];
    if (![fm createDirectoryAtPath:shared withIntermediateDirectories:YES attributes:nil error:errorOut])
        return NO;

    if (rootOut) *rootOut = root;
    if (sharedOut) *sharedOut = shared;
    return YES;
}

static struct fd *GuestFDFromHostFD(int hostFD) {
    struct fd *fd = adhoc_fd_create(&realfs_fdops);
    if (!fd) return NULL;
    fd->real_fd = hostFD;
    fd->dir = NULL;
    return fd;
}

static BOOL InstallGuestStdio(int stdinFD, int stdoutFD, int stderrFD) {
    struct fd *inFD = GuestFDFromHostFD(stdinFD);
    struct fd *outFD = GuestFDFromHostFD(stdoutFD);
    struct fd *errFD = GuestFDFromHostFD(stderrFD);
    if (!inFD || !outFD || !errFD) return NO;
    current->files->files[0] = inFD;
    current->files->files[1] = outFD;
    current->files->files[2] = errFD;
    return YES;
}

static NSData *ReadBounded(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path] ?: NSData.data;
    static const NSUInteger limit = 4 * 1024 * 1024;
    if (data.length <= limit) return data;
    return [data subdataWithRange:NSMakeRange(data.length - limit, limit)];
}

static NSString *UTF8File(NSString *path) {
    NSData *data = ReadBounded(path);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static NSData *PackedStrings(NSArray<NSString *> *strings) {
    NSMutableData *data = [NSMutableData data];
    for (NSString *string in strings) {
        NSData *part = [string dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data;
        [data appendData:part];
        uint8_t zero = 0;
        [data appendBytes:&zero length:1];
    }
    uint8_t zero = 0;
    [data appendBytes:&zero length:1];
    return data;
}

static void ISHExitHook(struct task *task, int code) {
    if (sWaitingPID != 0 && task->pid == sWaitingPID) {
        sWaitingStatus = code;
        dispatch_semaphore_t semaphore = sCommandExitSemaphore;
        if (semaphore) dispatch_semaphore_signal(semaphore);
    }
}

static int BootISH(NSString *root, NSString *shared) {
    NSString *dataRoot = [root stringByAppendingPathComponent:@"data"];
    int err = mount_root(&fakefs, dataRoot.fileSystemRepresentation);
    if (err < 0) return err;

    err = become_first_process();
    if (err < 0) return err;

    create_some_device_nodes();
    generic_mkdirat(AT_PWD, "/mnt", 0755);
    generic_mkdirat(AT_PWD, "/mnt/byetunes", 0755);
    generic_mkdirat(AT_PWD, "/tmp", 01777);
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);

    err = do_mount(&realfs, shared.fileSystemRepresentation, "/mnt/byetunes", "", 0);
    if (err < 0) return err;

    exit_hook = ISHExitHook;

    NSArray<NSString *> *argv = @[@"/bin/sh", @"-c", @"trap '' TERM INT; while :; do sleep 3600; done"];
    NSData *packedArgv = PackedStrings(argv);
    NSData *packedEnv = PackedStrings(@[
        @"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        @"HOME=/root",
        @"TMPDIR=/tmp",
        @"LANG=C.UTF-8",
        @"LC_ALL=C.UTF-8"
    ]);

    err = do_execve("/bin/sh", argv.count, (const char *)packedArgv.bytes, (const char *)packedEnv.bytes);
    if (err < 0) return err;

    int inFD = open("/dev/null", O_RDONLY);
    int outFD = open("/dev/null", O_WRONLY);
    int errFD = open("/dev/null", O_WRONLY);
    if (inFD < 0 || outFD < 0 || errFD < 0 || !InstallGuestStdio(inFD, outFD, errFD))
        return -1;

    task_start(current);
    return 0;
}

static NSDictionary *RunISHCommand(NSString *command, NSArray<NSString *> *args, NSString *cwd, NSInteger timeoutMs) {
    if (!sISHReady)
        return JSONResponse(NO, @{@"error": sISHBootError ?: @"iSH is not ready"});

    NSSet<NSString *> *allowed = [NSSet setWithArray:@[
        @"/usr/bin/ffmpeg", @"/usr/bin/ffprobe", @"/usr/bin/curl", @"/bin/sh", @"/bin/busybox"
    ]];
    if (![allowed containsObject:command])
        return JSONResponse(NO, @{@"error": @"command is not allowlisted"});

    NSString *bridgeDir = [sSharedHostRoot stringByAppendingPathComponent:@".bridge"];
    [NSFileManager.defaultManager createDirectoryAtPath:bridgeDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *token = NSUUID.UUID.UUIDString;
    NSString *stdoutPath = [bridgeDir stringByAppendingPathComponent:[token stringByAppendingString:@".stdout"]];
    NSString *stderrPath = [bridgeDir stringByAppendingPathComponent:[token stringByAppendingString:@".stderr"]];

    int stdinFD = open("/dev/null", O_RDONLY);
    int stdoutFD = open(stdoutPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    int stderrFD = open(stderrPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (stdinFD < 0 || stdoutFD < 0 || stderrFD < 0)
        return JSONResponse(NO, @{@"error": @"failed to allocate command stdio"});

    int err = become_new_init_child();
    if (err < 0) return JSONResponse(NO, @{@"error": [NSString stringWithFormat:@"become_new_init_child=%d", err]});

    NSMutableArray<NSString *> *argv = [NSMutableArray arrayWithObject:command];
    [argv addObjectsFromArray:args ?: @[]];
    NSData *packedArgv = PackedStrings(argv);
    NSData *packedEnv = PackedStrings(@[
        @"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        @"HOME=/root", @"TMPDIR=/tmp", @"LANG=C.UTF-8", @"LC_ALL=C.UTF-8"
    ]);

    err = do_execve(command.UTF8String, argv.count, (const char *)packedArgv.bytes, (const char *)packedEnv.bytes);
    if (err < 0) return JSONResponse(NO, @{@"error": [NSString stringWithFormat:@"exec=%d", err]});

    if (cwd.length) {
        struct fd *pwd = generic_open(cwd.UTF8String, O_RDONLY_, 0);
        if (!IS_ERR(pwd)) fs_chdir(current->fs, pwd);
    }

    if (!InstallGuestStdio(stdinFD, stdoutFD, stderrFD))
        return JSONResponse(NO, @{@"error": @"failed to attach iSH stdio"});

    sWaitingPID = current->pid;
    sWaitingStatus = 0;
    sCommandExitSemaphore = dispatch_semaphore_create(0);
    pid_t_ commandPID = sWaitingPID;
    task_start(current);

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, MAX((NSInteger)1000, timeoutMs) * NSEC_PER_MSEC);
    BOOL timedOut = dispatch_semaphore_wait(sCommandExitSemaphore, deadline) != 0;
    if (timedOut) {
        lock(&pids_lock);
        struct task *task = pid_get_task(commandPID);
        if (task) deliver_signal(task, SIGKILL_, SIGINFO_NIL);
        unlock(&pids_lock);
        dispatch_semaphore_wait(sCommandExitSemaphore, dispatch_time(DISPATCH_TIME_NOW, 3000 * NSEC_PER_MSEC));
    }

    int status = sWaitingStatus;
    sWaitingPID = 0;
    sCommandExitSemaphore = nil;

    NSString *stdoutText = UTF8File(stdoutPath);
    NSString *stderrText = UTF8File(stderrPath);
    [NSFileManager.defaultManager removeItemAtPath:stdoutPath error:nil];
    [NSFileManager.defaultManager removeItemAtPath:stderrPath error:nil];

    NSInteger exitCode = (status & 0xff) ? 128 + (status & 0x7f) : ((status >> 8) & 0xff);
    return JSONResponse(!timedOut && exitCode == 0, @{
        @"command": command, @"pid": @(commandPID), @"exitCode": @(exitCode), @"timedOut": @(timedOut),
        @"stdout": stdoutText ?: @"", @"stderr": stderrText ?: @""
    });
}

static void StartISHBridgeServer(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sISHServer.running) return;
        sISHServer = [GCDWebServer new];

        [sISHServer addHandlerForMethod:@"GET" path:@"/health"
                          requestClass:GCDWebServerRequest.class
                          processBlock:^GCDWebServerResponse *(__unused GCDWebServerRequest *request) {
            return Response(sISHReady ? 200 : 503, JSONResponse(sISHReady, @{
                @"port": @(kByeTunesISHPort), @"rootfs": @"Alpine i386", @"youtube": @NO
            }));
        }];

        [sISHServer addHandlerForMethod:@"POST" path:@"/exec"
                          requestClass:GCDWebServerDataRequest.class
                     asyncProcessBlock:^(GCDWebServerDataRequest *request, GCDWebServerCompletionBlock completion) {
            NSDictionary *body = [request.jsonObject isKindOfClass:NSDictionary.class] ? request.jsonObject : nil;
            NSString *command = [body[@"command"] isKindOfClass:NSString.class] ? body[@"command"] : nil;
            NSArray *args = [body[@"args"] isKindOfClass:NSArray.class] ? body[@"args"] : @[];
            NSString *cwd = [body[@"cwd"] isKindOfClass:NSString.class] ? body[@"cwd"] : @"/mnt/byetunes";
            NSInteger timeout = [body[@"timeoutMs"] respondsToSelector:@selector(integerValue)] ? [body[@"timeoutMs"] integerValue] : 120000;

            if (!command.length || args.count > 256) {
                completion(Response(400, JSONResponse(NO, @{@"error": @"invalid command request"})));
                return;
            }
            for (id item in args) {
                if (![item isKindOfClass:NSString.class]) {
                    completion(Response(400, JSONResponse(NO, @{@"error": @"args must be strings"})));
                    return;
                }
            }

            dispatch_async(ISHCommandQueue(), ^{
                NSDictionary *result = RunISHCommand(command, args, cwd, MIN(MAX(timeout, 1000), 180000));
                NSInteger status = [result[@"ok"] boolValue] ? 200 : ([result[@"ready"] boolValue] ? 500 : 503);
                completion(Response(status, result));
            });
        }];

        NSError *error = nil;
        BOOL started = [sISHServer startWithOptions:@{
            GCDWebServerOption_Port: @(kByeTunesISHPort),
            GCDWebServerOption_BindToLocalhost: @YES,
            GCDWebServerOption_AutomaticallySuspendInBackground: @NO,
            GCDWebServerOption_ServerName: @"ByeTunesISH"
        } error:&error];
        if (!started) {
            sISHBootError = [NSString stringWithFormat:@"iSH bridge HTTP failed: %@", error.localizedDescription ?: @"unknown"];
            NSLog(@"[ByeTunesISH] %@", sISHBootError);
        }
    });
}

static void StartISHRuntime(void) {
    StartISHBridgeServer();
    dispatch_async(ISHCommandQueue(), ^{
        @autoreleasepool {
            NSError *error = nil;
            NSString *root = nil;
            NSString *shared = nil;
            if (!EnsureWritableRoot(&root, &shared, &error)) {
                sISHBootError = error.localizedDescription ?: @"rootfs staging failed";
                return;
            }
            sSharedHostRoot = shared;
            int rc = BootISH(root, shared);
            if (rc < 0) {
                sISHBootError = [NSString stringWithFormat:@"official iSH boot rc=%d", rc];
                return;
            }
            sISHReady = YES;
            NSLog(@"[ByeTunesISH] official iSH ready root=%@ shared=%@", root, shared);
        }
    });
}

void ByeTunesISHRuntimeInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) { StartISHRuntime(); }];
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateInactive)
            StartISHRuntime();
    });
}

bool ByeTunesISHRuntimeIsReady(void) {
    return sISHReady;
}
