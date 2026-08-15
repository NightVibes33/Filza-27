@import Foundation;
@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

#import "FilzaDiagnostics.h"

// The original Filza settings action decides whether the WebDAV switch is ON
// by calling TGPreferences.isServerStarted, then reloads the whole settings
// section. In the jailed build that method only checks the legacy root-helper
// process/PID-file path, so it always reports NO even while our in-process
// GCDWebDAVServer is listening. Every tap therefore becomes another "start"
// and the visible switch snaps back to OFF.
//
// Make the existing UI authoritative again by teaching isServerStarted about
// TGPreferences.httpServer.isRunning. Then mirror the resulting listener state
// into the existing air-browser preference so launch/resume persistence and the
// settings row remain synchronized.

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

static BOOL FilzaWebDAVToggleInProcessServerRunning(id preferences)
{
    SEL httpServerSelector = NSSelectorFromString(@"httpServer");
    if (!preferences || ![preferences respondsToSelector:httpServerSelector]) return NO;
    id server = ((id (*)(id, SEL))objc_msgSend)(preferences, httpServerSelector);
    if (!server) return NO;

    SEL runningSelector = NSSelectorFromString(@"isRunning");
    if (![server respondsToSelector:runningSelector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(server, runningSelector);
}

static BOOL FilzaWebDAVToggleIsServerStarted(id preferences, SEL selector)
{
    if (FilzaWebDAVToggleInProcessServerRunning(preferences)) return YES;
    return FilzaPreviousIsServerStarted
        ? FilzaPreviousIsServerStarted(preferences, selector)
        : NO;
}

static void FilzaWebDAVTogglePersistRunningState(void)
{
    id preferences = FilzaWebDAVToggleSharedPreferences();
    if (!preferences) return;

    BOOL running = FilzaWebDAVToggleIsServerStarted(preferences,
                                                     NSSelectorFromString(@"isServerStarted"));
    SEL getSelector = NSSelectorFromString(@"objectForPreferenceKey:");
    id current = [preferences respondsToSelector:getSelector]
        ? ((id (*)(id, SEL, id))objc_msgSend)(preferences, getSelector, @"air-browser")
        : nil;
    BOOL stored = [current respondsToSelector:@selector(boolValue)] && [current boolValue];

    if (stored != running) {
        SEL setSelector = NSSelectorFromString(@"setObject:forPreferenceKey:notification:");
        if ([preferences respondsToSelector:setSelector]) {
            ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                preferences, setSelector, @(running), @"air-browser", NO);
        }
    }

    FilzaDiagnosticsAppend(@"WebDAV",
        [NSString stringWithFormat:@"settings toggle synchronized visible-state=%@ preference=%@",
         running ? @"ON" : @"OFF", running ? @"YES" : @"NO"]);
}

static void FilzaWebDAVToggleCheckbox(id controller, SEL selector)
{
    if (FilzaPreviousWebDAVCheckbox)
        FilzaPreviousWebDAVCheckbox(controller, selector);

    // The original action reloads the section synchronously. Our
    // isServerStarted hook is already active during that reload. Persist the
    // final listener state on the next main-loop turn after start/stop settles.
    dispatch_async(dispatch_get_main_queue(), ^{
        FilzaWebDAVTogglePersistRunningState();
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
        // By installing after WebDAVRuntimeFix, this chains through its existing
        // start/stop wrapper rather than replacing it.
        FilzaPreviousWebDAVCheckbox = (void (*)(id, SEL))currentCheckbox;
        method_setImplementation(checkboxMethod, (IMP)FilzaWebDAVToggleCheckbox);
    }

    FilzaWebDAVToggleStateInstalled = YES;
    FilzaDiagnosticsAppend(@"WebDAV",
        @"toggle-state fix installed: isServerStarted now reflects in-process listener");
    FilzaWebDAVTogglePersistRunningState();
}

__attribute__((constructor)) static void FilzaWebDAVToggleStateInit(void)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            // WebDAVRuntimeFix also installs from the main queue. Delay one turn
            // so this wrapper chains on top of its lifecycle hooks deterministically.
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
                else
                    FilzaWebDAVTogglePersistRunningState();
            }];
        });
    }
}
