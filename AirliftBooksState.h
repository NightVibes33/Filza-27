#import <Foundation/Foundation.h>

struct AfcClientHandle;

NS_ASSUME_NONNULL_BEGIN

// Snapshots/restores the AFC-visible Books sync preimage used by the Airlift
// canary. Snapshot data lives in the app container, never in Media/AFC.
NSDictionary *FZACSnapshotBooksState(struct AfcClientHandle *afc, NSString *root);
BOOL FZACBooksStateMatchesSnapshot(struct AfcClientHandle *afc, NSString *root, NSDictionary *snapshot);
NSDictionary *FZACRestoreBooksState(struct AfcClientHandle *afc, NSString *root);

NS_ASSUME_NONNULL_END
