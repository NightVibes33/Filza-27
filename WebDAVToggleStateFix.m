@import Foundation;
@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

#import "FilzaDiagnostics.h"

// Filza's stock WebDAV settings row asks TGPreferences.isServerStarted to
// decide whether a tap means Start or Stop.  The jailed build uses an
// in-process GCDWebDAVServer rather than Filza's legacy helper/PID path, so the
// getter must observe that listener.  It must NOT mutate the air-browser
// preference: doing so from a state getter creates a feedback loop where an
// in-flight stop is observed as still-running and the preference is forced
// back to YES before the server has finished stopping.

static BOOL (*FilzaPreviousIsServerStarted)(id, SEL) = NULL;
static void (*FilzaPreviousWebDAVCheckbox)(id, SEL) = NULL;
static BOOL FilzaWebDAVToggleStateInstalled = NO;

static id FilzaWebDAVToggleSharedPreferences(void)
{
    Class cls = NSClassFromString(@"TGPreferences");
    SEL selector = NSSelectorFromString(@"sharedInstance");
    if (!cls || ![cls respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, selector);
}

static id FilzaWebDAVToggleHTTPServer(id preferences)
{
    SEL selector = NSSelectorFromString(@"httpServer");
    if (!preferences || ![preferences respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(preferences, selector);
}

static BOOL FilzaWebDAVToggleInProcessServerRunning(id preferences)
{
    id server = FilzaWebDAVToggleHTTPServer(preferences);
    SEL runningSelector = NSSelectorFromString(@"isRunning");
    if (!server || ![server respondsToSelector:runningSelector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(server, runningSelector);
}

static BOOL FilzaWebDAVToggleIsServerStarted(id preferences, SEL selector)
{
    id server = FilzaWebDAVToggleHTTPServer(preferences);
    if (server && [server respondsToSelector:NSSelectorFromString(@"isRunning")]) {
        // Observation only.  Never write UserDefaults from this getter.
        return FilzaWebDAVToggleInProcessServerRunning(preferences);
    }
    return FilzaPreviousIsServerStarted
        ? FilzaPreviousIsServerStarted(preferences, selector)
        : NO;
}

static void FilzaWebDAVToggleSetEnabledPreference(id preferences, BOOL enabled)
{
    SEL selector = NSSelectorFromString(@"setObject:forPreferenceKey:notification:");
    if (!preferences || ![preferences respondsToSelector:selector]) return;

    NSMethodSignature *signature = [preferences methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments < 5) return;

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = preferences;
    invocation.selector = selector;

    __unsafe_unretained id value = @(enabled);
    __unsafe_unretained id key = @"air-browser";
    [invocation setArgument:&value atIndex:2];
    [invocation setArgument:&key atIndex:3];

    const char *type = [signature getArgumentTypeAtIndex:4];
    while (type && strchr("rnNoORV", type[0])) type++;
    if (type && type[0] == '@') {
        __unsafe_unretained id notification = nil;
        [invocation setArgument:&notification atIndex:4];
    } else if (type && (type[0] == 'B' || type[0] == 'c')) {
        BOOL notification = NO;
        [invocation setArgument:&notification atIndex:4];
    } else {
        NSUInteger zero = 0;
        [invocation setArgument:&zero atIndex:4];
    }

    @try {
        [invocation invoke];
    } @catch (NSException *exception) {
        FilzaDiagnosticsAppend(@"WebDAV",
            [NSString stringWithFormat:@"toggle could not persist air-browser=%@: %@",
             enabled ? @"YES" : @"NO", exception.reason ?: exception.name]);
    }
}

static void FilzaWebDAVToggleCallLifecycle(id preferences, BOOL shouldRun)
{
    SEL selector = NSSelectorFromString(shouldRun ? @"startAirBrowser" : @"stopAirBrowser");
    if (!preferences || ![preferences respondsToSelector:selector]) return;
    ((void (*)(id, SEL))objc_msgSend)(preferences, selector);
}

static void FilzaWebDAVToggleFinishTransition(id preferences, BOOL shouldRun, NSInteger attempt)
{
    BOOL running = FilzaWebDAVToggleInProcessServerRunning(preferences);
    if (running != shouldRun && attempt == 0) {
        FilzaDiagnosticsAppend(@"WebDAV",
            [NSString stringWithFormat:@"toggle transition retry desired=%@ observed=%@",
             shouldRun ? @"ON" : @"OFF", running ? @"ON" : @"OFF"]);
        FilzaWebDAVToggleCallLifecycle(preferences, shouldRun);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            FilzaWebDAVToggleFinishTransition(preferences, shouldRun, 1);
        });
        return;
    }

    running = FilzaWebDAVToggleInProcessServerRunning(preferences);
    FilzaWebDAVToggleSetEnabledPreference(preferences, running);
    FilzaDiagnosticsAppend(@"WebDAV",
        [NSString stringWithFormat:@"toggle transition complete desired=%@ observed=%@ preference=%@",
         shouldRun ? @"ON" : @"OFF", running ? @"ON" : @"OFF",
         running ? @"YES" : @"NO"]);
}

static void FilzaWebDAVToggleCheckbox(id controller, SEL selector)
{
    id preferences = FilzaWebDAVToggleSharedPreferences();
    BOOL wasRunning = FilzaWebDAVToggleIsServerStarted(preferences,
                                                        NSSelectorFromString(@"isServerStarted"));
    BOOL shouldRun = !wasRunning;

    FilzaDiagnosticsAppend(@"WebDAV",
        [NSString stringWithFormat:@"settings toggle requested %@ -> %@",
         wasRunning ? @"ON" : @"OFF", shouldRun ? @"ON" : @"OFF"]);

    // Chain through WebDAVRuntimeFix and then Filza's original settings action.
    // The original action gets the corrected isServerStarted value and therefore
    // chooses the intended Start/Stop branch.
    if (FilzaPreviousWebDAVCheckbox)
        FilzaPreviousWebDAVCheckbox(controller, selector);

    // Give GCDWebServer one run-loop turn to bind/unbind.  If the listener did
    // not reach the state implied by the user's tap, call the already-hooked
    // TGPreferences lifecycle method once and verify again.  Preference state
    // is written only after this transition, never from the getter.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FilzaWebDAVToggleFinishTransition(preferences, shouldRun, 0);
    });
}

static void FilzaInstallWebDAVToggleStateFix(void)
{
    if (FilzaWebDAVToggleStateInstalled) return;

    Class preferencesClass = NSClassFromString(@"TGPreferences");
    Class controllerClass = NSClassFromString(@"TGPreferencesTableViewController");
    if (!preferencesClass || !controllerClass) {
        FilzaDiagnosticsAppend(@"WebDAV", @"toggle-state fix deferred; Filza preferences classes unavailable");
        return;
    }

    SEL startedSelector = NSSelectorFromString(@"isServerStarted");
    Method startedMethod = class_getInstanceMethod(preferencesClass, startedSelector);
    SEL checkboxSelector = NSSelectorFromString(@"swithAirBrowserCheckbox");
    Method checkboxMethod = class_getInstanceMethod(controllerClass, checkboxSelector);
    if (!startedMethod || !checkboxMethod) {
        FilzaDiagnosticsAppend(@"WebDAV", @"toggle-state fix unavailable; required Filza methods missing");
        return;
    }

    IMP currentStarted = method_getImplementation(startedMethod);
    if (currentStarted != (IMP)FilzaWebDAVToggleIsServerStarted) {
        FilzaPreviousIsServerStarted = (BOOL (*)(id, SEL))currentStarted;
        method_setImplementation(startedMethod, (IMP)FilzaWebDAVToggleIsServerStarted);
    }

    IMP currentCheckbox = method_getImplementation(checkboxMethod);
    if (currentCheckbox != (IMP)FilzaWebDAVToggleCheckbox) {
        FilzaPreviousWebDAVCheckbox = (void (*)(id, SEL))currentCheckbox;
        method_setImplementation(checkboxMethod, (IMP)FilzaWebDAVToggleCheckbox);
    }

    FilzaWebDAVToggleStateInstalled = YES;
    FilzaDiagnosticsAppend(@"WebDAV",
        @"toggle-state fix installed: listener getter is observation-only and OFF transitions are explicit");
}

__attribute__((constructor)) static void FilzaWebDAVToggleStateInit(void)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            // WebDAVRuntimeFix installs from the main queue as well.  Chain on
            // top after it so startAirBrowser/stopAirBrowser remain the real
            // in-process lifecycle implementation.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                FilzaInstallWebDAVToggleStateFix();
            });

            [NSNotificationCenter.defaultCenter
                addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *notification) {
                if (!FilzaWebDAVToggleStateInstalled)
                    FilzaInstallWebDAVToggleStateFix();
                // Intentionally do not synchronize air-browser here.  App
                // activation is an observation event, not a user toggle.
            }];
        });
    }
}
