#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns the current on-device music library using the same AFC +
/// MediaLibrary.sqlitedb transport used by ByeTunes. Each dictionary contains
/// stable metadata plus a RemotePath under /iTunes_Control/Music.
FOUNDATION_EXPORT NSArray<NSDictionary *> * _Nullable BTMusicLoadLibrary(
    NSString * _Nullable * _Nullable error);

/// Materializes one AFC-backed track into Filza's private cache on demand.
/// Existing cache entries are reused.
FOUNDATION_EXPORT NSString * _Nullable BTMusicEnsureLocalFile(
    NSDictionary *song, NSString * _Nullable * _Nullable error);

/// Pairing file locations accepted by the bridge, in lookup order.
FOUNDATION_EXPORT NSArray<NSString *> *BTMusicPairingFileCandidates(void);

NS_ASSUME_NONNULL_END
