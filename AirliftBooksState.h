#import <Foundation/Foundation.h>
struct AfcClientHandle;
NS_ASSUME_NONNULL_BEGIN
NSDictionary *FZACSnapshotBooksState(struct AfcClientHandle *afc, NSString *root);
BOOL FZACBooksStateMatchesSnapshot(struct AfcClientHandle *afc, NSString *root, NSDictionary *snapshot);
NSDictionary *FZACRestoreBooksState(struct AfcClientHandle *afc, NSString *root);
NS_ASSUME_NONNULL_END
