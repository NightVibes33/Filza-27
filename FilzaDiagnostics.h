#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *FilzaDiagnosticsDirectory(void);
FOUNDATION_EXPORT void FilzaDiagnosticsAppend(NSString *component, NSString *message);
FOUNDATION_EXPORT void FilzaDiagnosticsWriteByeTunesStage(NSString *stage);
NS_ASSUME_NONNULL_END
