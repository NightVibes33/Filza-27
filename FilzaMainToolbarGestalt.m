@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

#import "Filza3105Bridge.h"
#import "FilzaDiagnostics.h"
#import "FilzaMondBridge.h"

@interface FMTWeakMainView : NSObject
@property(nonatomic, weak) id owner;
@end

@implementation FMTWeakMainView
@end

static IMP gFMTOriginalCreateMainToolBar = NULL;
static IMP gFMTOriginalViewDidLoad = NULL;
static IMP gFMTOriginalViewWillAppear = NULL;
static IMP gFMTOriginalViewDidAppear = NULL;
static IMP gFMTOriginalSetToolbarItems = NULL;
static BOOL gFMTMainHooksInstalled = NO;
static BOOL gFMTToolbarSetterInstalled = NO;
static BOOL gFMTMutatingToolbar = NO;
static NSHashTable *gFMTKnownMainViews;

static char kFMTToolbarOwnerKey;
static NSString *const FMTGestaltIdentifier =
    @"com.nightvibes33.filzaslop.toolbar.gestalt";
static NSString *const FMTPatchesIdentifier =
    @"com.nightvibes33.filzaslop.toolbar.patches";

static UIToolbar *FMTToolbar(id mainView)
{
    SEL selector = NSSelectorFromString(@"toolBar");
    if (![mainView respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(mainView, selector);
    return [value isKindOfClass:UIToolbar.class] ? value : nil;
}

static BOOL FMTIsUtilityItem(UIBarButtonItem *item)
{
    NSString *identifier = item.accessibilityIdentifier;
    return [identifier isEqualToString:FMTGestaltIdentifier] ||
        [identifier isEqualToString:FMTPatchesIdentifier] ||
        item.action == NSSelectorFromString(@"fz_openMondGestalt") ||
        item.action == NSSelectorFromString(@"fz_open3105Patches");
}

static BOOL FMTItemMatches(UIBarButtonItem *item, NSString *actionName,
                           NSString *word)
{
    NSString *action = item.action ? NSStringFromSelector(item.action) : @"";
    NSString *title = item.title.lowercaseString ?: @"";
    NSString *label = item.accessibilityLabel.lowercaseString ?: @"";
    return [action isEqualToString:actionName] ||
        [title containsString:word] || [label containsString:word];
}

static UIBarButtonItem *FMTImageItem(NSString *symbol, NSString *fallbackTitle,
                                     NSString *identifier, id target, SEL action)
{
    UIImage *image = [UIImage systemImageNamed:symbol];
    UIBarButtonItem *item = image
        ? [[UIBarButtonItem alloc] initWithImage:image
            style:UIBarButtonItemStylePlain target:target action:action]
        : [[UIBarButtonItem alloc] initWithTitle:fallbackTitle
            style:UIBarButtonItemStylePlain target:target action:action];
    item.accessibilityIdentifier = identifier;
    item.accessibilityLabel = fallbackTitle;
    return item;
}

static void FMTOpenMond(id self, SEL _cmd)
{
    UIViewController *controller = [self isKindOfClass:UIViewController.class]
        ? self : nil;
    FilzaDiagnosticsAppend(@"Toolbar", @"persistent Gestalt button tapped");
    FilzaMondPresentFromController(controller);
}

static void FMTOpenPatches(id self, SEL _cmd)
{
    UIViewController *controller = [self isKindOfClass:UIViewController.class]
        ? self : nil;
    FilzaDiagnosticsAppend(@"Toolbar", @"persistent Patches button tapped");
    Filza3105PresentPatchesFromController(controller);
}

static void FMTEnsureUtilityItems(id mainView)
{
    if (!mainView) return;
    UIToolbar *toolbar = FMTToolbar(mainView);
    if (!toolbar) return;

    FMTWeakMainView *ownerBox = objc_getAssociatedObject(toolbar,
        &kFMTToolbarOwnerKey);
    if (!ownerBox) {
        ownerBox = [FMTWeakMainView new];
        objc_setAssociatedObject(toolbar, &kFMTToolbarOwnerKey, ownerBox,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ownerBox.owner = mainView;
    [gFMTKnownMainViews addObject:mainView];

    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
    for (UIBarButtonItem *item in toolbar.items ?: @[])
        if (!FMTIsUtilityItem(item)) [items addObject:item];

    NSInteger appsIndex = NSNotFound;
    NSInteger musicIndex = NSNotFound;
    for (NSInteger index = 0; index < (NSInteger)items.count; index++) {
        UIBarButtonItem *item = items[(NSUInteger)index];
        if (FMTItemMatches(item, @"openApps", @"apps")) appsIndex = index;
        if (FMTItemMatches(item, @"openMusicLib", @"music")) musicIndex = index;
    }

    UIBarButtonItem *gestalt = FMTImageItem(@"slider.horizontal.3",
        @"Gestalt Editor", FMTGestaltIdentifier, mainView,
        NSSelectorFromString(@"fz_openMondGestalt"));
    UIBarButtonItem *patches = FMTImageItem(@"shippingbox",
        @"Patches", FMTPatchesIdentifier, mainView,
        NSSelectorFromString(@"fz_open3105Patches"));

    NSInteger insertion = items.count;
    if (appsIndex != NSNotFound || musicIndex != NSNotFound) {
        NSInteger last = MAX(appsIndex == NSNotFound ? -1 : appsIndex,
                             musicIndex == NSNotFound ? -1 : musicIndex);
        insertion = MIN((NSInteger)items.count, last + 1);
    }
    [items insertObject:gestalt atIndex:(NSUInteger)insertion];
    [items insertObject:patches atIndex:(NSUInteger)insertion + 1];

    gFMTMutatingToolbar = YES;
    [toolbar setItems:items animated:NO];
    gFMTMutatingToolbar = NO;
    FilzaDiagnosticsAppend(@"Toolbar", [NSString stringWithFormat:
        @"ensured persistent Apps/Music/Gestalt/Patches bottom toolbar apps=%ld music=%ld",
        (long)appsIndex, (long)musicIndex]);
}

static void FMTScheduleEnsure(id mainView)
{
    FMTEnsureUtilityItems(mainView);
    __weak id weakMainView = mainView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        FMTEnsureUtilityItems(weakMainView);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        FMTEnsureUtilityItems(weakMainView);
    });
}

static void FMTCreateMainToolBar(id self, SEL _cmd)
{
    if (gFMTOriginalCreateMainToolBar)
        ((void (*)(id, SEL))gFMTOriginalCreateMainToolBar)(self, _cmd);
    FMTScheduleEnsure(self);
}

static void FMTViewDidLoad(id self, SEL _cmd)
{
    if (gFMTOriginalViewDidLoad)
        ((void (*)(id, SEL))gFMTOriginalViewDidLoad)(self, _cmd);
    FMTScheduleEnsure(self);
}

static void FMTViewWillAppear(id self, SEL _cmd, BOOL animated)
{
    if (gFMTOriginalViewWillAppear)
        ((void (*)(id, SEL, BOOL))gFMTOriginalViewWillAppear)(self, _cmd, animated);
    FMTScheduleEnsure(self);
}

static void FMTViewDidAppear(id self, SEL _cmd, BOOL animated)
{
    if (gFMTOriginalViewDidAppear)
        ((void (*)(id, SEL, BOOL))gFMTOriginalViewDidAppear)(self, _cmd, animated);
    FMTScheduleEnsure(self);
}

static void FMTSetToolbarItems(UIToolbar *self, SEL _cmd, NSArray *items,
                               BOOL animated)
{
    if (gFMTOriginalSetToolbarItems)
        ((void (*)(id, SEL, id, BOOL))gFMTOriginalSetToolbarItems)(
            self, _cmd, items, animated);
    if (gFMTMutatingToolbar) return;

    FMTWeakMainView *ownerBox = objc_getAssociatedObject(self,
        &kFMTToolbarOwnerKey);
    id owner = ownerBox.owner;
    if (owner) dispatch_async(dispatch_get_main_queue(), ^{
        FMTEnsureUtilityItems(owner);
    });
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

static void FMTInstallToolbarSetter(void)
{
    if (gFMTToolbarSetterInstalled) return;
    Method method = class_getInstanceMethod(UIToolbar.class,
        @selector(setItems:animated:));
    if (!method) return;
    gFMTOriginalSetToolbarItems = method_getImplementation(method);
    if (gFMTOriginalSetToolbarItems != (IMP)FMTSetToolbarItems)
        method_setImplementation(method, (IMP)FMTSetToolbarItems);
    gFMTToolbarSetterInstalled = YES;
}

static void FMTInstallHooks(void)
{
    FMTInstallToolbarSetter();
    if (gFMTMainHooksInstalled) return;
    Class cls = NSClassFromString(@"TGMainView");
    if (!cls) return;

    class_addMethod(cls, NSSelectorFromString(@"fz_openMondGestalt"),
                    (IMP)FMTOpenMond, "v@:");
    class_addMethod(cls, NSSelectorFromString(@"fz_open3105Patches"),
                    (IMP)FMTOpenPatches, "v@:");
    gFMTOriginalCreateMainToolBar = FMTHook(cls,
        NSSelectorFromString(@"createMainToolBar"), (IMP)FMTCreateMainToolBar);
    gFMTOriginalViewDidLoad = FMTHook(cls, @selector(viewDidLoad),
                                      (IMP)FMTViewDidLoad);
    gFMTOriginalViewWillAppear = FMTHook(cls, @selector(viewWillAppear:),
                                         (IMP)FMTViewWillAppear);
    gFMTOriginalViewDidAppear = FMTHook(cls, @selector(viewDidAppear:),
                                        (IMP)FMTViewDidAppear);
    gFMTMainHooksInstalled = gFMTOriginalCreateMainToolBar ||
        gFMTOriginalViewDidLoad || gFMTOriginalViewWillAppear ||
        gFMTOriginalViewDidAppear;

    if (gFMTMainHooksInstalled)
        FilzaDiagnosticsAppend(@"Toolbar",
            @"TGMainView persistent Gestalt/Patches toolbar hooks installed");
}

static void FMTRefreshKnownMainViews(void)
{
    FMTInstallHooks();
    for (id mainView in gFMTKnownMainViews.allObjects)
        FMTScheduleEnsure(mainView);
}

__attribute__((constructor)) static void FilzaMainToolbarGestaltInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        gFMTKnownMainViews = [NSHashTable weakObjectsHashTable];
        FMTInstallHooks();
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) {
                FMTRefreshKnownMainViews();
            }];
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) {
                FMTRefreshKnownMainViews();
            }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ FMTRefreshKnownMainViews(); });
    });
}
