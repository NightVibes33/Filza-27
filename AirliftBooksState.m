#import "AirliftBooksState.h"
#import "idevice.h"

static const char *TrackedBooksFiles[] = {
    "Books/Books.plist",
    "Books/Sync/Books.plist",
    "Books/Sync/Upload.plist",
    "Books/Sync/Database/OutstandingAssets_4.sqlite",
    "Books/Sync/Database/OutstandingAssets_4.sqlite-shm",
    "Books/Sync/Database/OutstandingAssets_4.sqlite-wal",
};
static const char *TrackedBooksDirectories[] = { "Books", "Books/Sync", "Books/Sync/Database" };

static NSString *S(const char *p) { return [NSString stringWithUTF8String:p] ?: @""; }
static BOOL Exists(struct AfcClientHandle *afc, NSString *path) {
    struct AfcFileInfo info = {0};
    IdeviceFfiError *e = afc_get_file_info(afc, path.UTF8String, &info);
    if (e) { idevice_error_free(e); return NO; }
    afc_file_info_free(&info); return YES;
}
static NSData *Read(struct AfcClientHandle *afc, NSString *path, size_t limit) {
    struct AfcFileHandle *f = NULL; IdeviceFfiError *e = afc_file_open(afc, path.UTF8String, (AfcFopenMode)1, &f);
    if (e || !f) { if (e) idevice_error_free(e); return nil; }
    uint8_t *bytes = NULL; size_t length = 0; e = afc_file_read_entire(f, &bytes, &length);
    NSData *d = (!e && bytes && length <= limit) ? [NSData dataWithBytes:bytes length:length] : nil;
    if (e) idevice_error_free(e); if (bytes) idevice_data_free(bytes, length); e = afc_file_close(f); if (e) idevice_error_free(e); return d;
}
static BOOL EnsureDir(struct AfcClientHandle *afc, NSString *path) {
    if (Exists(afc,path)) return YES; IdeviceFfiError *e = afc_make_directory(afc,path.UTF8String); if(e){idevice_error_free(e);return NO;} return Exists(afc,path);
}
static BOOL Write(struct AfcClientHandle *afc, NSString *path, NSData *data) {
    struct AfcFileHandle *f=NULL; IdeviceFfiError *e=afc_file_open(afc,path.UTF8String,(AfcFopenMode)3,&f); if(e||!f){if(e)idevice_error_free(e);return NO;}
    BOOL ok=YES; if(data.length){e=afc_file_write(f,data.bytes,data.length);if(e){idevice_error_free(e);ok=NO;}} e=afc_file_close(f);if(e){idevice_error_free(e);ok=NO;} return ok;
}
static BOOL Remove(struct AfcClientHandle *afc, NSString *path) {
    if(!Exists(afc,path))return YES; IdeviceFfiError *e=afc_remove_path(afc,path.UTF8String);if(e){idevice_error_free(e);return NO;}return !Exists(afc,path);
}
static NSString *Manifest(NSString *root){return [root stringByAppendingPathComponent:@"manifest.plist"];}
static NSString *Local(NSUInteger i){return [NSString stringWithFormat:@"file-%lu.bin",(unsigned long)i];}
static NSDictionary *Load(NSString *root){NSData*d=[NSData dataWithContentsOfFile:Manifest(root)];id x=d?[NSPropertyListSerialization propertyListWithData:d options:0 format:nil error:nil]:nil;return [x isKindOfClass:NSDictionary.class]?x:nil;}

NSDictionary *FZACSnapshotBooksState(struct AfcClientHandle *afc, NSString *root) {
    NSFileManager *fm=NSFileManager.defaultManager; NSError *err=nil;
    if(![fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:&err] || [fm fileExistsAtPath:Manifest(root)]) return @{ @"ok":@NO, @"error":err.localizedDescription?:@"snapshot root not fresh" };
    NSMutableDictionary *files=[NSMutableDictionary dictionary],*dirs=[NSMutableDictionary dictionary]; NSMutableArray *present=[NSMutableArray array]; unsigned long long total=0;
    for(NSUInteger i=0;i<sizeof(TrackedBooksFiles)/sizeof(char*);i++){
        NSString*p=S(TrackedBooksFiles[i]);BOOL ex=Exists(afc,p);NSData*d=ex?Read(afc,p,128*1024*1024):nil;if(ex&&!d)return @{ @"ok":@NO,@"snapshotReadFailed":p };
        if(d){total+=d.length;if(total>256ULL*1024*1024)return @{ @"ok":@NO,@"snapshotTooLarge":@YES };NSString*l=[root stringByAppendingPathComponent:Local(i)];if(![d writeToFile:l options:NSDataWritingWithoutOverwriting error:&err])return @{ @"ok":@NO,@"snapshotWriteFailed":p };[present addObject:p];}
        files[p]=@{ @"exists":@(ex),@"localName":Local(i),@"size":@(d.length) };
    }
    for(NSUInteger i=0;i<sizeof(TrackedBooksDirectories)/sizeof(char*);i++){NSString*p=S(TrackedBooksDirectories[i]);dirs[p]=@(Exists(afc,p));}
    NSDictionary*m=@{ @"version":@1,@"files":files,@"directories":dirs };NSData*md=[NSPropertyListSerialization dataWithPropertyList:m format:NSPropertyListBinaryFormat_v1_0 options:0 error:&err];BOOL ok=md&&[md writeToFile:Manifest(root) options:NSDataWritingAtomic error:&err];
    return @{ @"ok":@(ok),@"presentPaths":present,@"snapshotBytes":@(total),@"root":root };
}

BOOL FZACBooksStateMatchesSnapshot(struct AfcClientHandle *afc, NSString *root, NSDictionary *snapshot) {
    NSDictionary*files=snapshot[@"files"],*dirs=snapshot[@"directories"];if(![files isKindOfClass:NSDictionary.class]||![dirs isKindOfClass:NSDictionary.class])return NO;
    for(NSUInteger i=0;i<sizeof(TrackedBooksFiles)/sizeof(char*);i++){NSString*p=S(TrackedBooksFiles[i]);NSDictionary*r=files[p];BOOL ex=[r[@"exists"] boolValue];if(Exists(afc,p)!=ex)return NO;if(ex){NSData*a=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:Local(i)]],*b=Read(afc,p,128*1024*1024);if(!a||!b||![a isEqualToData:b])return NO;}}
    for(NSUInteger i=0;i<sizeof(TrackedBooksDirectories)/sizeof(char*);i++){NSString*p=S(TrackedBooksDirectories[i]);if(Exists(afc,p)!=[dirs[p] boolValue])return NO;}return YES;
}

NSDictionary *FZACRestoreBooksState(struct AfcClientHandle *afc, NSString *root) {
    NSDictionary*snap=Load(root);if(!snap)return @{ @"ok":@NO,@"error":@"invalid snapshot" };NSMutableArray*fails=[NSMutableArray array];NSDictionary*files=snap[@"files"];
    for(NSUInteger i=0;i<sizeof(TrackedBooksFiles)/sizeof(char*);i++){NSString*p=S(TrackedBooksFiles[i]);NSDictionary*r=files[p];if([r[@"exists"] boolValue]){NSData*d=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:Local(i)]];if([p hasPrefix:@"Books/Sync/Database/"]&&!EnsureDir(afc,@"Books/Sync/Database")){[fails addObject:p];continue;}if([p hasPrefix:@"Books/Sync/"]&&!EnsureDir(afc,@"Books/Sync")){[fails addObject:p];continue;}if(!EnsureDir(afc,@"Books")||!d||!Write(afc,p,d))[fails addObject:p];}else if(!Remove(afc,p))[fails addObject:p];}
    NSDictionary*dirs=snap[@"directories"];for(NSInteger i=(NSInteger)(sizeof(TrackedBooksDirectories)/sizeof(char*))-1;i>=0;i--){NSString*p=S(TrackedBooksDirectories[i]);if(![dirs[p] boolValue]&&!Remove(afc,p))[fails addObject:p];}
    BOOL ok=fails.count==0&&FZACBooksStateMatchesSnapshot(afc,root,snap);return @{ @"ok":@(ok),@"failures":fails,@"preimageVerified":@(ok) };
}
