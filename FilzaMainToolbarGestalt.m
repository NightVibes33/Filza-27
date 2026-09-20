@import UIKit;
#import <objc/message.h>
#import <objc/runtime.h>
#import "FilzaFeatureRouter.h"
#import "FilzaDiagnostics.h"

@interface FMTWeakMainView : NSObject
@property(nonatomic, weak) id owner;
@end
@implementation FMTWeakMainView @end

static IMP gCreate = NULL, gLoad = NULL, gWill = NULL, gDid = NULL, gSetItems = NULL;
static BOOL gHooks = NO, gSetter = NO, gMutating = NO;
static NSHashTable *gViews;
static char kOwner;

static NSString *const FMTAppsManager = @"com.nightvibes33.filzaslop.toolbar.apps-manager";
static NSString *const FMTMusic = @"com.nightvibes33.filzaslop.toolbar.music";
static NSString *const FMTGestalt = @"com.nightvibes33.filzaslop.toolbar.gestalt";
static NSString *const FMTAirCard = @"com.nightvibes33.filzaslop.toolbar.aircard";

static UIToolbar *FMTToolbar(id v) {
    SEL s=NSSelectorFromString(@"toolBar");
    if (![v respondsToSelector:s]) return nil;
    id x=((id(*)(id,SEL))objc_msgSend)(v,s);
    return [x isKindOfClass:UIToolbar.class]?x:nil;
}
static BOOL FMTMatches(UIBarButtonItem *i, NSString *action, NSString *word) {
    NSString *a=i.action?NSStringFromSelector(i.action):@"";
    NSString *t=i.title.lowercaseString?:@"", *l=i.accessibilityLabel.lowercaseString?:@"";
    return [a isEqualToString:action]||[t containsString:word]||[l containsString:word];
}
static BOOL FMTIsIntegration(UIBarButtonItem *i) {
    NSString *x=i.accessibilityIdentifier?:@"";
    if ([x isEqualToString:FMTAppsManager]||[x isEqualToString:FMTMusic]||[x isEqualToString:FMTGestalt]||[x isEqualToString:FMTAirCard]||
        [x isEqualToString:@"com.nightvibes33.filzaslop.toolbar.apps"]||[x isEqualToString:@"com.nightvibes33.filzaslop.toolbar.patches"]) return YES;
    return FMTMatches(i,@"openApps",@"apps")||FMTMatches(i,@"openMusicLib",@"music")||
           FMTMatches(i,@"fz_openAppsManagerApps",@"apps")||FMTMatches(i,@"fz_openAppsManagerPatches",@"patches")||
           FMTMatches(i,@"fz_openMondGestalt",@"gestalt")||FMTMatches(i,@"fz_openAirCard",@"aircard");
}
static UIBarButtonItem *FMTItem(NSString *symbol,NSString *title,NSString *ident,id target,SEL action) {
    UIImage *image=[UIImage systemImageNamed:symbol];
    UIBarButtonItem *i=image?[[UIBarButtonItem alloc]initWithImage:image style:UIBarButtonItemStylePlain target:target action:action]:
        [[UIBarButtonItem alloc]initWithTitle:title style:UIBarButtonItemStylePlain target:target action:action];
    i.accessibilityIdentifier=ident; i.accessibilityLabel=title; return i;
}
static void FMTOpen(id self, NSString *feature) {
    UIViewController *vc=[self isKindOfClass:UIViewController.class]?self:nil;
    FilzaPresentFeature(feature,vc);
}
static void OpenAppsManager(id s,SEL c){FMTOpen(s,FilzaFeatureAppsManager);}
static void OpenMusic(id s,SEL c){FMTOpen(s,FilzaFeatureMusic);}
static void OpenGestalt(id s,SEL c){FMTOpen(s,FilzaFeatureGestalt);}
static void OpenAirCard(id s,SEL c){FMTOpen(s,FilzaFeatureAirCard);}

static void FMTEnsure(id mainView) {
    UIToolbar *tb=FMTToolbar(mainView); if(!tb)return;
    FMTWeakMainView *box=objc_getAssociatedObject(tb,&kOwner);
    if(!box){box=[FMTWeakMainView new];objc_setAssociatedObject(tb,&kOwner,box,OBJC_ASSOCIATION_RETAIN_NONATOMIC);} box.owner=mainView;
    [gViews addObject:mainView];
    NSMutableArray *items=[NSMutableArray array];
    for(UIBarButtonItem *i in tb.items?:@[]) if(!FMTIsIntegration(i))[items addObject:i];
    [items addObject:FMTItem(@"square.grid.2x2",@"Apps Manager",FMTAppsManager,mainView,NSSelectorFromString(@"fz_openAppsManager"))];
    [items addObject:FMTItem(@"music.note",@"Music",FMTMusic,mainView,NSSelectorFromString(@"fz_openMusic"))];
    [items addObject:FMTItem(@"slider.horizontal.3",@"Gestalt",FMTGestalt,mainView,NSSelectorFromString(@"fz_openGestalt"))];
    [items addObject:FMTItem(@"network",@"AirCard",FMTAirCard,mainView,NSSelectorFromString(@"fz_openAirCard"))];
    gMutating=YES; [tb setItems:items animated:NO]; gMutating=NO;
    FilzaDiagnosticsAppend(@"Toolbar",@"canonical Apps Manager/Music/Gestalt/AirCard launchers installed; standalone Patches removed");
}
static void FMTSchedule(id v){FMTEnsure(v);__weak id w=v;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(),^{FMTEnsure(w);});dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC),dispatch_get_main_queue(),^{FMTEnsure(w);});}
static void Create(id s,SEL c){if(gCreate)((void(*)(id,SEL))gCreate)(s,c);FMTSchedule(s);}
static void Load(id s,SEL c){if(gLoad)((void(*)(id,SEL))gLoad)(s,c);FMTSchedule(s);}
static void Will(id s,SEL c,BOOL a){if(gWill)((void(*)(id,SEL,BOOL))gWill)(s,c,a);FMTSchedule(s);}
static void Did(id s,SEL c,BOOL a){if(gDid)((void(*)(id,SEL,BOOL))gDid)(s,c,a);FMTSchedule(s);}
static void SetItems(UIToolbar*s,SEL c,NSArray*i,BOOL a){if(gSetItems)((void(*)(id,SEL,id,BOOL))gSetItems)(s,c,i,a);if(gMutating)return;FMTWeakMainView*b=objc_getAssociatedObject(s,&kOwner);if(b.owner)dispatch_async(dispatch_get_main_queue(),^{FMTEnsure(b.owner);});}
static IMP Hook(Class cls,SEL s,IMP r){Method m=class_getInstanceMethod(cls,s);if(!m)return NULL;IMP o=method_getImplementation(m);const char*t=method_getTypeEncoding(m);if(class_addMethod(cls,s,r,t))return o;m=class_getInstanceMethod(cls,s);o=method_getImplementation(m);if(o!=r)method_setImplementation(m,r);return o;}
static void Install(void){
    if(!gSetter){Method m=class_getInstanceMethod(UIToolbar.class,@selector(setItems:animated:));if(m){gSetItems=method_getImplementation(m);if(gSetItems!=(IMP)SetItems)method_setImplementation(m,(IMP)SetItems);gSetter=YES;}}
    if(gHooks)return;Class cls=NSClassFromString(@"TGMainView");if(!cls)return;
    class_addMethod(cls,NSSelectorFromString(@"fz_openAppsManager"),(IMP)OpenAppsManager,"v@:");
    class_addMethod(cls,NSSelectorFromString(@"fz_openMusic"),(IMP)OpenMusic,"v@:");
    class_addMethod(cls,NSSelectorFromString(@"fz_openGestalt"),(IMP)OpenGestalt,"v@:");
    class_addMethod(cls,NSSelectorFromString(@"fz_openAirCard"),(IMP)OpenAirCard,"v@:");
    gCreate=Hook(cls,NSSelectorFromString(@"createMainToolBar"),(IMP)Create);gLoad=Hook(cls,@selector(viewDidLoad),(IMP)Load);
    gWill=Hook(cls,@selector(viewWillAppear:),(IMP)Will);gDid=Hook(cls,@selector(viewDidAppear:),(IMP)Did);
    gHooks=gCreate||gLoad||gWill||gDid;
}
static void Refresh(void){Install();for(id v in gViews.allObjects)FMTSchedule(v);}
__attribute__((constructor)) static void Init(void){dispatch_async(dispatch_get_main_queue(),^{gViews=[NSHashTable weakObjectsHashTable];Install();[NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification*n){Refresh();}];[NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification*n){Refresh();}];});}
