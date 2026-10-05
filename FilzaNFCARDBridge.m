@import UIKit;
#import <objc/message.h>

#import "FilzaNFCARDBridge.h"
#import "FilzaDiagnostics.h"

BOOL FilzaNFCARDPresentFromController(UIViewController *source)
{
    if (!source) return NO;

    Class factory = NSClassFromString(@"NFCARDEmbeddedHostFactory");
    SEL selector = NSSelectorFromString(@"makeViewController");
    if (!factory || ![factory respondsToSelector:selector]) {
        FilzaDiagnosticsAppend(@"NFCARD", @"embedded NFCARD host factory unavailable");
        return NO;
    }

    UIViewController *controller =
        ((UIViewController *(*)(id, SEL))objc_msgSend)(factory, selector);
    if (!controller) return NO;

    UIViewController *target = source;
    while (target.presentedViewController)
        target = target.presentedViewController;

    [target presentViewController:controller animated:YES completion:^{
        FilzaDiagnosticsAppend(@"NFCARD", @"presented embedded NFCARD");
    }];
    return YES;
}
