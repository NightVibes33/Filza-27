#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Small compatibility guard for list reload races seen on newer iOS builds.
// It wraps the existing Filza app-list selection hook and only intercepts a
// stale NSIndexPath that no longer exists after the backing list reloads.

static IMP RSOriginalDidSelectItem = NULL;

static void RSReloadControllerIfPossible(id controller) {
    SEL reloadSelector = NSSelectorFromString(@"doLoadingPage");
    if ([controller respondsToSelector:reloadSelector])
        ((void (*)(id, SEL))objc_msgSend)(controller, reloadSelector);
}

static void RSHookDidSelectItem(id self, SEL _cmd, id browserView, id indexPath) {
    @try {
        SEL fileListSelector = NSSelectorFromString(@"fileList");
        if ([self respondsToSelector:fileListSelector] &&
            [indexPath respondsToSelector:@selector(row)]) {
            id fileList = ((id (*)(id, SEL))objc_msgSend)(self, fileListSelector);
            if ([fileList respondsToSelector:@selector(count)]) {
                NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(fileList, @selector(count));
                NSUInteger row = ((NSUInteger (*)(id, SEL))objc_msgSend)(indexPath, @selector(row));
                if (row >= count) {
                    NSLog(@"[RuntimeStability] ignored stale selection row=%lu count=%lu",
                        (unsigned long)row, (unsigned long)count);
                    RSReloadControllerIfPossible(self);
                    return;
                }
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"[RuntimeStability] selection validation failed: %@", exception);
        RSReloadControllerIfPossible(self);
        return;
    }

    if (RSOriginalDidSelectItem)
        ((void (*)(id, SEL, id, id))RSOriginalDidSelectItem)(self, _cmd, browserView, indexPath);
}

static void RSInstallHooks(void) {
    Class controller = NSClassFromString(@"TGApplicationsViewController");
    if (!controller) return;

    SEL selector = NSSelectorFromString(@"browserView:didSelectItemAtIndexPath:");
    Method method = class_getInstanceMethod(controller, selector);
    if (!method) return;

    IMP current = method_getImplementation(method);
    if (current == (IMP)RSHookDidSelectItem) return;
    RSOriginalDidSelectItem = current;
    method_setImplementation(method, (IMP)RSHookDidSelectItem);
    NSLog(@"[RuntimeStability] stale-selection guard installed");
}

__attribute__((constructor)) static void RSRuntimeStabilityInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        RSInstallHooks();
    });
}
