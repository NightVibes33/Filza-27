@import UIKit;
#import "FilzaFeatureRouter.h"
#import "Filza3105Bridge.h"
#import "ByeTunesFullAppLauncher.h"
#import "FilzaMondBridge.h"
#import "FilzaAirCardBridge.h"
#import "FilzaDiagnostics.h"

NSString *const FilzaFeatureAppsManager = @"com.nightvibes33.filzaslop.apps-manager";
NSString *const FilzaFeatureMusic = @"com.nightvibes33.filzaslop.music-library";
NSString *const FilzaFeatureGestalt = @"com.nightvibes33.filzaslop.gestalt-manager";
NSString *const FilzaFeatureAirCard = @"com.nightvibes33.filzaslop.aircard";

NSArray<NSString *> *FilzaCanonicalFeatureIdentifiers(void) {
    return @[FilzaFeatureAppsManager, FilzaFeatureMusic, FilzaFeatureGestalt, FilzaFeatureAirCard];
}

BOOL FilzaPresentFeature(NSString *feature, UIViewController *source) {
    BOOL opened = NO;
    if ([feature isEqualToString:FilzaFeatureAppsManager])
        opened = Filza3105PresentHomeFromController(source);
    else if ([feature isEqualToString:FilzaFeatureMusic])
        opened = FilzaByeTunesPresentFromController(source);
    else if ([feature isEqualToString:FilzaFeatureGestalt]) {
        if (source) { FilzaMondPresentFromController(source); opened = YES; }
    } else if ([feature isEqualToString:FilzaFeatureAirCard])
        opened = FilzaAirCardPresentFromController(source);
    FilzaDiagnosticsAppend(@"FeatureRouter", [NSString stringWithFormat:@"%@ %@", opened ? @"opened" : @"failed", feature ?: @"nil"]);
    return opened;
}
