@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

static const void *kByeTunesFullPresentedKey = &kByeTunesFullPresentedKey;
static IMP gByeTunesOriginalMusicViewDidAppear = NULL;
static IMP gByeTunesOriginalShortcutHandler = NULL;

typedef void (*ByeTunesShortcutIMP)(id, SEL, UIApplication *, UIApplicationShortcutItem *, void (^)(BOOL));

static UIViewController *ByeTunesTopController(void)
{
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
            if (!window && !candidate.hidden) window = candidate;
        }
        if (window) break;
    }
    if (!window) window = UIApplication.sharedApplication.windows.firstObject;

    UIViewController *controller = window.rootViewController;
    while (controller) {
        UIViewController *next = controller.presentedViewController;
        if (!next && [controller isKindOfClass:UINavigationController.class])
            next = ((UINavigationController *)controller).visibleViewController;
        if (!next && [controller isKindOfClass:UITabBarController.class])
            next = ((UITabBarController *)controller).selectedViewController;
        if (!next && [controller isKindOfClass:UISplitViewController.class])
            next = ((UISplitViewController *)controller).viewControllers.lastObject;
        if (!next || next == controller) break;
        controller = next;
    }
    return controller;
}

static UIViewController *ByeTunesMakeFullController(void)
{
    Class factory = NSClassFromString(@"ByeTunesEmbeddedHostFactory");
    SEL selector = NSSelectorFromString(@"makeViewController");
    if (!factory || ![factory respondsToSelector:selector]) {
        NSLog(@"[ByeTunesFull] Swift host factory unavailable");
        return nil;
    }
    return ((UIViewController *(*)(id, SEL))objc_msgSend)(factory, selector);
}

static BOOL ByeTunesPresentFullApp(UIViewController *presenter)
{
    UIViewController *host = presenter ?: ByeTunesTopController();
    if (!host) return NO;

    UIViewController *full = ByeTunesMakeFullController();
    if (!full) return NO;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *target = host;
        while (target.presentedViewController) target = target.presentedViewController;
        [target presentViewController:full animated:YES completion:nil];
        NSLog(@"[ByeTunesFull] presented complete ByeTunes ContentView inside Filza");
    });
    return YES;
}

static void ByeTunesMusicViewDidAppear(id self, SEL _cmd, BOOL animated)
{
    if (gByeTunesOriginalMusicViewDidAppear)
        ((void (*)(id, SEL, BOOL))gByeTunesOriginalMusicViewDidAppear)(self, _cmd, animated);

    if (objc_getAssociatedObject(self, kByeTunesFullPresentedKey)) return;
    objc_setAssociatedObject(self, kByeTunesFullPresentedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ByeTunesPresentFullApp((UIViewController *)self);
}

static BOOL ByeTunesShortcutIsMusic(UIApplicationShortcutItem *item)
{
    if (![item isKindOfClass:UIApplicationShortcutItem.class]) return NO;
    if ([item.localizedTitle caseInsensitiveCompare:@"Music Library"] == NSOrderedSame) return YES;
    if ([item.localizedTitle rangeOfString:@"ByeTunes" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return [item.type rangeOfString:@"music" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static void ByeTunesFullShortcutHandler(id self, SEL _cmd, UIApplication *application,
                                        UIApplicationShortcutItem *item, void (^completion)(BOOL))
{
    if (ByeTunesShortcutIsMusic(item) && ByeTunesPresentFullApp(nil)) {
        if (completion) completion(YES);
        return;
    }

    if (gByeTunesOriginalShortcutHandler)
        ((ByeTunesShortcutIMP)gByeTunesOriginalShortcutHandler)(self, _cmd, application, item, completion);
    else if (completion)
        completion(NO);
}

static void ByeTunesInstallFullAppHooks(void)
{
    Class musicClass = NSClassFromString(@"TGMusicLibraryViewController");
    SEL appear = @selector(viewDidAppear:);
    Method appearMethod = musicClass ? class_getInstanceMethod(musicClass, appear) : NULL;
    if (appearMethod && method_getImplementation(appearMethod) != (IMP)ByeTunesMusicViewDidAppear) {
        gByeTunesOriginalMusicViewDidAppear = method_getImplementation(appearMethod);
        method_setImplementation(appearMethod, (IMP)ByeTunesMusicViewDidAppear);
    }

    id delegate = UIApplication.sharedApplication.delegate;
    Class delegateClass = delegate ? [delegate class] : Nil;
    SEL shortcut = @selector(application:performActionForShortcutItem:completionHandler:);
    Method shortcutMethod = delegateClass ? class_getInstanceMethod(delegateClass, shortcut) : NULL;
    if (shortcutMethod && method_getImplementation(shortcutMethod) != (IMP)ByeTunesFullShortcutHandler) {
        gByeTunesOriginalShortcutHandler = method_getImplementation(shortcutMethod);
        method_setImplementation(shortcutMethod, (IMP)ByeTunesFullShortcutHandler);
    }

    NSLog(@"[ByeTunesFull] complete app hooks installed");
}

__attribute__((constructor)) static void ByeTunesFullAppInit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) {
                // FilzaByeTunesUI installs its compatibility hook at launch.
                // Install the complete-app route immediately afterwards so it
                // owns the Music Library shortcut while preserving the old
                // implementation as a fallback for unrelated shortcuts.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{ ByeTunesInstallFullAppHooks(); });
            }];

        if (UIApplication.sharedApplication.delegate) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{ ByeTunesInstallFullAppHooks(); });
        }
    });
}
