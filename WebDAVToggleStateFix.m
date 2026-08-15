@import Foundation;
@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

#import "FilzaDiagnostics.h"

// Keep Filza's WebDAV switch tied to the real in-process listener. RuntimeFix
// already replaces startAirBrowser/stopAirBrowser with the jailed-safe
// GCDWebDAVServer lifecycle. This layer owns only the settings-row state.
//
// Do not chain the old checkbox implementation here. RuntimeFix also hooks that
// selector, and chaining both checkbox state machines can race an OFF request
// with a stale air-browser=YES write that immediately restarts the listener.

static BOOL (*FilzaPreviousIsServerStarted)(id, SEL) = NULL;
static BOOL FilzaWebDAVToggleStateInstalled = NO;

static id FilzaWebDAVToggleSharedPreferences(void)
{
    Class cls = NSClassFromString(@"TGPreferences");
    SEL selector = NSSelectorFromString(@"sharedInstance");
    if (!cls || ![cls respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, selector);
}

static id FilzaWebDAVTogglePreference(id preferences, NSString *key)
{
    SEL selector = NSSelectorFromString(@"objectForPreferenceKey:");
    if (!preferences || ![preferences respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(preferences, selector, key);
}

static BOOL FilzaWebDAVToggleStoredEnabled(id preferences)
{
    id value = FilzaWebDAVTogglePreference(preferences, @"air-browser");
    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
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
    if (server && [server respondsToSelector:NSSelectorFromString(@"isRunning")])
        return FilzaWebDAVToggleInProcessServerRunning(preferences);

    return FilzaPreviousIsServerStarted
        ? FilzaPreviousIsServerStarted(preferences, selector)
        : NO;
}

static BOOL FilzaWebDAVToggleSetEnabledPreference(id preferences, BOOL enabled)
{
    SEL selector = NSSelectorFromString(@"setObject:forPreferenceKey:notification:");
    if (!preferences || ![preferences respondsToSelector:selector]) return NO;

    NSMethodSignature *signature = [preferences methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments < 5) return NO;

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
        return YES;
    } @catch (NSException *exception) {
        FilzaDiagnosticsAppend(@"WebDAV",
            [NSString stringWithFormat:@"toggle could not persist air-browser=%@: %@",
             enabled ? @"YES" : @"NO", exception.reason ?: exception.name]);
        return NO;
    }
}

static void FilzaWebDAVToggleCallLifecycle(id preferences, BOOL shouldRun)
{
    SEL selector = NSSelectorFromString(shouldRun ? @"startAirBrowser" : @"stopAirBrowser");
    if (!preferences || ![preferences respondsToSelector:selector]) {
        FilzaDiagnosticsAppend(@"WebDAV",
            [NSString stringWithFormat:@"toggle lifecycle selector unavailable for %@",
             shouldRun ? @"START" : @"STOP"]);
        return;
    }

    @try {
        ((void (*)(id, SEL))objc_msgSend)(preferences, selector);
    } @catch (NSException *exception) {
        FilzaDiagnosticsAppend(@"WebDAV",
            [NSString stringWithFormat:@"toggle lifecycle %@ raised: %@",
             shouldRun ? @"START" : @"STOP", exception.reason ?: exception.name]);
    }
}

static void FilzaWebDAVToggleReloadSettings(id controller, BOOL running)
{
    if (!controller) return;

    UITableView *tableView = nil;
    if ([controller isKindOfClass:UITableViewController.class]) {
        tableView = ((UITableViewController *)controller).tableView;
    } else {
        SEL tableSelector = NSSelectorFromString(@"tableView");
        if ([controller respondsToSelector:tableSelector]) {
            id candidate = ((id (*)(id, SEL))objc_msgSend)(controller, tableSelector);
            if ([candidate isKindOfClass:UITableView.class]) tableView = candidate;
        }
    }

    if (!tableView) {
        SEL viewSelector = NSSelectorFromString(@"view");
        id view = [controller respondsToSelector:viewSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(controller, viewSelector)
            : nil;
        if ([view isKindOfClass:UITableView.class]) tableView = view;
    }

    if (!tableView) {
        FilzaDiagnosticsAppend(@"WebDAV",
            @"settings UI refresh skipped; preferences table unavailable");
        return;
    }

    [tableView reloadData];
    [tableView setNeedsLayout];
    [tableView layoutIfNeeded];

    BOOL stored = FilzaWebDAVToggleStoredEnabled(FilzaWebDAVToggleSharedPreferences());
    FilzaDiagnosticsAppend(@"WebDAV",
        [NSString stringWithFormat:@"settings table redrawn listener=%@ stored=%@",
         running ? @"ON" : @"OFF", stored ? @"ON" : @"OFF"]);
    FilzaDiagnosticsAppend(@"WebDAV",
        [NSString stringWithFormat:@"settings UI refreshed from listener state=%@",
         running ? @"ON" : @"OFF"]);
}

static void FilzaWebDAVTogglePostChanged(id preferences)
{
    [NSNotificationCenter.defaultCenter postNotificationName:@"AirBrowserChanged"
                                                      object:preferences];
}

static void FilzaWebDAVToggleFinishTransition(id controller,
                                               id preferences,
                                               BOOL shouldRun,
                                               NSInteger attempt)
{
    BOOL running = FilzaWebDAVToggleInProcessServerRunning(preferences);

    if (running != shouldRun && attempt < 2) {
        FilzaDiagnosticsAppend(@"WebDAV",
            [NSString stringWithFormat:@"toggle settle retry=%ld desired=%@ observed=%@",
             (long)attempt + 1,
             shouldRun ? @"ON" : @"OFF",
             running ? @"ON" : @"OFF"]);
        FilzaWebDAVToggleCallLifecycle(preferences, shouldRun);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            FilzaWebDAVToggleFinishTransition(controller, preferences, shouldRun, attempt + 1);
        });
        return;
    }

    running = FilzaWebDAVToggleInProcessServerRunning(preferences);
    if (shouldRun) {
        // Failed starts must not leave a fake enabled switch behind.
        FilzaWebDAVToggleSetEnabledPreference(preferences, running);
    } else {
        // OFF is authoritative. Never rewrite OFF to YES from a stale listener.
        FilzaWebDAVToggleSetEnabledPreference(preferences, NO);
    }

    FilzaWebDAVTogglePostChanged(preferences);
    FilzaWebDAVToggleReloadSettings(controller, running);
    BOOL stored = FilzaWebDAVToggleStoredEnabled(preferences);
    FilzaDiagnosticsAppend(@"WebDAV",
        [NSString stringWithFormat:@"toggle settled desired=%@ listener=%@ stored=%@",
         shouldRun ? @"ON" : @"OFF",
         running ? @"ON" : @"OFF",
         stored ? @"ON" : @"OFF"]);
    FilzaDiagnosticsAppend(@"WebDAV",
        [NSString stringWithFormat:@"toggle transition complete desired=%@ observed=%@ preference=%@",
         shouldRun ? @"ON" : @"OFF",
         running ? @"ON" : @"OFF",
         stored ? @"YES" : @"NO"]);
}

static void FilzaWebDAVToggleCheckbox(id controller, __unused SEL selector)
{
    id preferences = FilzaWebDAVToggleSharedPreferences();
    if (!preferences) {
        FilzaDiagnosticsAppend(@"WebDAV", @"settings toggle ignored: TGPreferences unavailable");
        return;
    }

    BOOL running = FilzaWebDAVToggleInProcessServerRunning(preferences);
    BOOL stored = FilzaWebDAVToggleStoredEnabled(preferences);
    BOOL wasEnabled = stored || running;
    BOOL shouldRun = !wasEnabled;

    FilzaDiagnosticsAppend(@"WebDAV",
        [NSString stringWithFormat:@"settings toggle direct request stored=%@ listener=%@ -> desired=%@",
         stored ? @"ON" : @"OFF",
         running ? @"ON" : @"OFF",
         shouldRun ? @"ON" : @"OFF"]);
    FilzaDiagnosticsAppend(@"WebDAV",
        [NSString stringWithFormat:@"settings toggle requested %@ -> %@",
         wasEnabled ? @"ON" : @"OFF",
         shouldRun ? @"ON" : @"OFF"]);

    // Persist user intent before lifecycle work. RuntimeFix sees OFF before the
    // listener starts unwinding, so queued stale state cannot restart it.
    FilzaWebDAVToggleSetEnabledPreference(preferences, shouldRun);
    FilzaWebDAVTogglePostChanged(preferences);
    FilzaWebDAVToggleReloadSettings(controller, running);
    FilzaWebDAVToggleCallLifecycle(preferences, shouldRun);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FilzaWebDAVToggleFinishTransition(controller, preferences, shouldRun, 0);
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

    // Replace RuntimeFix's checkbox state machine instead of chaining it. Its
    // startAirBrowser/stopAirBrowser hooks remain installed and are called above.
    IMP currentCheckbox = method_getImplementation(checkboxMethod);
    if (currentCheckbox != (IMP)FilzaWebDAVToggleCheckbox)
        method_setImplementation(checkboxMethod, (IMP)FilzaWebDAVToggleCheckbox);

    FilzaWebDAVToggleStateInstalled = YES;
    FilzaDiagnosticsAppend(@"WebDAV",
        @"toggle-state fix installed: direct intent owns checkbox and OFF is authoritative");
    FilzaDiagnosticsAppend(@"WebDAV",
        @"toggle-state fix installed: listener getter is observation-only and OFF transitions are explicit");
    FilzaDiagnosticsAppend(@"WebDAV",
        @"toggle-state fix installed: listener-backed state plus post-transition UI refresh");
}

__attribute__((constructor)) static void FilzaWebDAVToggleStateInit(void)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
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
            }];
        });
    }
}
