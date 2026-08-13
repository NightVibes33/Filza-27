@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

#import "FilzaDiagnostics.h"
#import "FilzaMondBridge.h"

static IMP gFMTOriginalCreateMainToolBar = NULL;
static IMP gFMTOriginalViewDidAppear = NULL;
static BOOL gFMTHooksInstalled = NO;

static NSString *const FMTGestaltIdentifier = @"com.nightvibes33.filzaslop.toolbar.gestalt";

static UIToolbar *FMTToolbar(id mainView)
{
    SEL selector = NSSelectorFromString(@"toolBar");
    if (![mainView respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(mainView, selector);
    return [value isKindOfClass:UIToolbar.class] ? value : nil;
}

static BOOL FMTIsGestaltItem(UIBarButtonItem *item)
{
    return [item.accessibilityIdentifier isEqualToString:FMTGestaltIdentifier] ||
           item.action == NSSelectorFromString(@"fz_openMondGestalt");
}

static void FMTOpenMond(id self, SEL _cmd)
{
    UIViewController *controller = [self isKindOfClass:UIViewController.class] ? self : nil;
    FilzaDiagnosticsAppend(@"Toolbar", @"Gestalt button tapped");
    FilzaMondPresentFromController(controller);
}

static void FMTEnsureGestaltItem(id mainView)
{
    UIToolbar *toolbar = FMTToolbar(mainView);
    if (!toolbar) return;

    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray arrayWithArray:toolbar.items ?: @[]];
    for (UIBarButtonItem *item in items) if (FMTIsGestaltItem(item)) return;

    NSInteger appsIndex = NSNotFound;
    NSInteger musicIndex = NSNotFound;
    for (NSInteger index = 0; index < (NSInteger)items.count; index++) {
        UIBarButtonItem *item = items[index];
        NSString *action = item.action ? NSStringFromSelector(item.action) : @"";
        NSString *title = item.title.lowercaseString ?: @"";
        NSString *label = item.accessibilityLabel.lowercaseString ?: @"";
        if ([action isEqualToString:@"openApps"] ||
            [title containsString:@"apps"] || [label containsString:@"apps"])
            appsIndex = index;
        if ([action isEqualToString:@"openMusicLib"] ||
            [title containsString:@"music"] || [label containsString:@"music"])
            musicIndex = index;
    }

    UIBarButtonItem *gestalt = [[UIBarButtonItem alloc]
        initWithTitle:@"Gestalt Editor"
        style:UIBarButtonItemStylePlain
        target:mainView
        action:NSSelectorFromString(@"fz_openMondGestalt")];
    gestalt.accessibilityIdentifier = FMTGestaltIdentifier;
    gestalt.accessibilityLabel = @"Gestalt Editor";

    NSInteger insertion = items.count;
    if (appsIndex != NSNotFound || musicIndex != NSNotFound) {
        NSInteger last = MAX(appsIndex == NSNotFound ? -1 : appsIndex,
                             musicIndex == NSNotFound ? -1 : musicIndex);
        insertion = MIN((NSInteger)items.count, last + 1);
    }
    [items insertObject:gestalt atIndex:(NSUInteger)insertion];
    [toolbar setItems:items animated:NO];

    FilzaDiagnosticsAppend(@"Toolbar",
        [NSString stringWithFormat:@"inserted Gestalt item appsIndex=%ld musicIndex=%ld insertion=%ld",
         (long)appsIndex, (long)musicIndex, (long)insertion]);
}

static void FMTCreateMainToolBar(id self, SEL _cmd)
{
    if (gFMTOriginalCreateMainToolBar)
        ((void (*)(id, SEL))gFMTOriginalCreateMainToolBar)(self, _cmd);
    FMTEnsureGestaltItem(self);
}

static void FMTViewDidAppear(id self, SEL _cmd, BOOL animated)
{
    if (gFMTOriginalViewDidAppear)
        ((void (*)(id, SEL, BOOL))gFMTOriginalViewDidAppear)(self, _cmd, animated);
    FMTEnsureGestaltItem(self);
}

static IMP FMTHook(Class cls, SEL selector, IMP replacement)
{
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NULL;
    IMP original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (class_addMethod(cls, selector, replacement, types)) return original;
    Method owned = class_getInstanceMethod(cls, selector);
    original = method_getImplementation(owned);
    if (original != replacement) method_setImplementation(owned, replacement);
    return original;
}

static void FMTInstallHooks(void)
{
    if (gFMTHooksInstalled) return;
    Class cls = NSClassFromString(@"TGMainView");
    if (!cls) return;

    class_addMethod(cls, NSSelectorFromString(@"fz_openMondGestalt"), (IMP)FMTOpenMond, "v@:");
    gFMTOriginalCreateMainToolBar = FMTHook(cls, NSSelectorFromString(@"createMainToolBar"), (IMP)FMTCreateMainToolBar);
    gFMTOriginalViewDidAppear = FMTHook(cls, @selector(viewDidAppear:), (IMP)FMTViewDidAppear);
    gFMTHooksInstalled = gFMTOriginalCreateMainToolBar || gFMTOriginalViewDidAppear;

    if (gFMTHooksInstalled)
        FilzaDiagnosticsAppend(@"Toolbar", @"TGMainView Gestalt Editor toolbar hooks installed");
}

__attribute__((constructor)) static void FilzaMainToolbarGestaltInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        FMTInstallHooks();
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) { FMTInstallHooks(); }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ FMTInstallHooks(); });
    });
}
