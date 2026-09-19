@import UIKit;
#import <objc/message.h>
#import "FilzaAirCardBridge.h"
#import "FilzaDiagnostics.h"
BOOL FilzaAirCardPresentFromController(UIViewController *source) {
    if (!source) return NO;
    Class f=NSClassFromString(@"AirCardEmbeddedHostFactory"); SEL s=NSSelectorFromString(@"makeViewController");
    if (!f || ![f respondsToSelector:s]) return NO;
    UIViewController *c=((UIViewController *(*)(id,SEL))objc_msgSend)(f,s); if(!c) return NO;
    UIViewController *t=source; while(t.presentedViewController) t=t.presentedViewController;
    c.modalPresentationStyle=UIModalPresentationFullScreen; [t presentViewController:c animated:YES completion:nil];
    FilzaDiagnosticsAppend(@"AirCard", @"presented full pinned AirCard root"); return YES;
}
