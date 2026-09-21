#import "ByeTunesNodeRuntime.h"
@import UIKit;
#import <NodeMobile/NodeMobile.h>

static const NSInteger kByeTunesYoinkPort = 41337;
static dispatch_queue_t ByeTunesNodeQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.nightvibes33.filza.byetunes-node", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString *ByeTunesDiagnosticsPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"ByeTunesYoinkDiagnostics.json"];
}

static void WriteDiagnostics(NSDictionary *value) {
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithDictionary:value ?: @{}];
    out[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    NSData *data = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:nil];
    if (data) [data writeToFile:ByeTunesDiagnosticsPath() atomically:YES];
}

static void RunProbe(NSString *method, NSString *path, NSDictionary *body, void (^completion)(NSDictionary *)) {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld%@", (long)kByeTunesYoinkPort, path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    request.timeoutInterval = 20.0;
    if (body) {
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    [[[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration]
      dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
        completion(@{
            @"status": @(http.statusCode),
            @"body": text ?: @"",
            @"error": error.localizedDescription ?: @""
        });
    }] resume];
}

static void RunSelfTest(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2500 * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __block NSMutableDictionary *report = [@{
            @"server": @"http://127.0.0.1:41337",
            @"uiConnected": @NO,
            @"youtube": @NO,
            @"tests": [NSMutableDictionary dictionary]
        } mutableCopy];
        NSMutableDictionary *tests = report[@"tests"];
        dispatch_group_t group = dispatch_group_create();

        dispatch_group_enter(group);
        RunProbe(@"GET", @"/health", nil, ^(NSDictionary *result) {
            @synchronized (tests) { tests[@"health"] = result; }
            dispatch_group_leave(group);
        });

        dispatch_group_enter(group);
        RunProbe(@"POST", @"/api/metadata", @{}, ^(NSDictionary *result) {
            @synchronized (tests) { tests[@"metadataMissingURL"] = result; }
            dispatch_group_leave(group);
        });

        dispatch_group_enter(group);
        RunProbe(@"POST", @"/api/metadata", @{@"url": @"https://example.com/not-a-track"}, ^(NSDictionary *result) {
            @synchronized (tests) { tests[@"metadataUnsupportedURL"] = result; }
            dispatch_group_leave(group);
        });

        dispatch_group_enter(group);
        RunProbe(@"POST", @"/api/metadata", @{@"url": @"https://www.deezer.com/track/0"}, ^(NSDictionary *result) {
            @synchronized (tests) { tests[@"metadataDeezerDeadTrack"] = result; }
            dispatch_group_leave(group);
        });

        dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            report[@"complete"] = @YES;
            WriteDiagnostics(report);
            NSLog(@"[ByeTunesLocal] hidden NodeMobile self-test written to %@", ByeTunesDiagnosticsPath());
        });
    });
}

static void StartNodeRuntime(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *bundlePath = [NSBundle.mainBundle pathForResource:@"ByeTunesYoink" ofType:@"bundle"];
        NSString *serverPath = [bundlePath stringByAppendingPathComponent:@"server.js"];
        if (!bundlePath.length || ![NSFileManager.defaultManager fileExistsAtPath:serverPath]) {
            WriteDiagnostics(@{@"complete": @YES, @"startupError": @"ByeTunesYoink.bundle/server.js missing"});
            NSLog(@"[ByeTunesLocal] server resource missing");
            return;
        }

        setenv("BYETUNES_YOINK_PORT", "41337", 1);
        setenv("NODE_ENV", "production", 1);
        RunSelfTest();

        dispatch_async(ByeTunesNodeQueue(), ^{
            @autoreleasepool {
                NSArray<NSString *> *arguments = @[@"node", serverPath];
                size_t argumentBytes = 0;
                for (NSString *argument in arguments)
                    argumentBytes += strlen(argument.UTF8String) + 1;

                char *argumentBuffer = (char *)calloc(argumentBytes, 1);
                char **argv = (char **)calloc(arguments.count, sizeof(char *));
                if (!argumentBuffer || !argv) {
                    free(argumentBuffer);
                    free(argv);
                    WriteDiagnostics(@{@"complete": @YES, @"startupError": @"NodeMobile argv allocation failed"});
                    return;
                }

                char *cursor = argumentBuffer;
                for (NSUInteger index = 0; index < arguments.count; index++) {
                    const char *value = arguments[index].UTF8String;
                    size_t length = strlen(value);
                    memcpy(cursor, value, length);
                    argv[index] = cursor;
                    cursor += length + 1;
                }

                NSLog(@"[ByeTunesLocal] starting embedded NodeMobile runtime");
                int rc = node_start((int)arguments.count, argv);
                free(argv);
                free(argumentBuffer);
                WriteDiagnostics(@{@"complete": @YES, @"nodeExited": @(rc)});
                NSLog(@"[ByeTunesLocal] NodeMobile exited rc=%d", rc);
            }
        });
    });
}

void ByeTunesNodeRuntimeInstall(void) {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
        object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(__unused NSNotification *note) {
            StartNodeRuntime();
        }];

    if (UIApplication.sharedApplication.applicationState != UIApplicationStateInactive) {
        dispatch_async(dispatch_get_main_queue(), ^{ StartNodeRuntime(); });
    }
}
