@import Foundation;
#import <objc/runtime.h>
#include <AirliftFFI/airlift.h>

#import "FilzaDiagnostics.h"

// Transparent AirCard/Airlift fallback for Filza's normal /var/mobile/Media
// namespace. There is deliberately no synthetic mount/mirror directory.
// Local filesystem operations win whenever they work; paired AFC is consulted
// only after the normal jailed operation fails.

static IMP gOrigContents = NULL;
static IMP gOrigAttributes = NULL;
static IMP gOrigDataInit = NULL;
static NSString *gPairing = nil;

static NSString *FZPairingPath(void) {
    if (gPairing.length) return gPairing;
    NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    for(NSString *n in @[@"aircard_pairing.plist",@"airlift_pairing.plist"]) {
        NSString *p=[docs stringByAppendingPathComponent:n];
        if ([[NSFileManager.defaultManager attributesOfItemAtPath:p error:nil][NSFileSize] unsignedLongLongValue]>0) {
            gPairing=p; return p;
        }
    }
    return nil;
}

static NSString *FZAFCPath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath) return nil;
    NSString *p=path.stringByStandardizingPath;
    NSArray<NSString *> *roots=@[@"/var/mobile/Media",@"/private/var/mobile/Media"];
    for(NSString *root in roots) {
        if ([p isEqualToString:root]) return @"";
        NSString *prefix=[root stringByAppendingString:@"/"];
        if ([p hasPrefix:prefix]) return [p substringFromIndex:prefix.length];
    }
    return nil;
}

static NSArray<NSDictionary *> *FZList(NSString *remote) {
    NSString *pairing=FZPairingPath(); if(!pairing) return nil;
    char *json=NULL,*error=NULL;
    int32_t rc=al_filza_fs_list(pairing.UTF8String,remote.UTF8String,&json,&error);
    if(error) al_string_free(error);
    if(rc!=0||!json) { if(json) al_string_free(json); return nil; }
    NSData *d=[NSData dataWithBytes:json length:strlen(json)]; al_string_free(json);
    id obj=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    return [obj isKindOfClass:NSArray.class]?obj:nil;
}

static NSDictionary *FZRemoteInfo(NSString *path) {
    NSString *remote=FZAFCPath(path); if(!remote) return nil;
    NSString *parent=[remote stringByDeletingLastPathComponent];
    NSString *leaf=remote.lastPathComponent;
    if(!leaf.length) return @{NSFileType:NSFileTypeDirectory,NSFileSize:@0};
    for(NSDictionary *row in FZList(parent)) {
        if(![row[@"name"] isEqual:leaf]) continue;
        NSString *kind=[row[@"kind"] lowercaseString]?:@"";
        BOOL dir=[kind containsString:@"dir"]||[kind containsString:@"s_ifdir"];
        NSMutableDictionary *a=[NSMutableDictionary dictionary];
        a[NSFileType]=dir?NSFileTypeDirectory:NSFileTypeRegular;
        a[NSFileSize]=row[@"size"]?:@0;
        NSNumber *modified=row[@"modified"];
        if(modified.longLongValue>0) a[NSFileModificationDate]=[NSDate dateWithTimeIntervalSince1970:modified.doubleValue];
        return a;
    }
    return nil;
}

static NSArray *FZContents(id self,SEL cmd,NSString *path,NSError **error) {
    NSArray *local=((NSArray *(*)(id,SEL,id,id*))gOrigContents)(self,cmd,path,error);
    if(local) return local;
    NSString *remote=FZAFCPath(path); if(!remote) return nil;
    NSArray *rows=FZList(remote); if(!rows) return nil;
    NSMutableArray *names=[NSMutableArray arrayWithCapacity:rows.count];
    for(NSDictionary *r in rows) if([r[@"name"] isKindOfClass:NSString.class]) [names addObject:r[@"name"]];
    if(error) *error=nil;
    FilzaDiagnosticsAppend(@"AirCardFS",[NSString stringWithFormat:@"transparent AFC list %@ count=%lu",path,(unsigned long)names.count]);
    return names;
}

static NSDictionary *FZAttributes(id self,SEL cmd,NSString *path,NSError **error) {
    NSDictionary *local=((NSDictionary *(*)(id,SEL,id,id*))gOrigAttributes)(self,cmd,path,error);
    if(local) return local;
    NSDictionary *remote=FZRemoteInfo(path);
    if(remote&&error) *error=nil;
    return remote;
}

static id FZDataInit(id self,SEL cmd,NSString *path,NSUInteger options,NSError **error) {
    id local=((id(*)(id,SEL,id,NSUInteger,id*))gOrigDataInit)(self,cmd,path,options,error);
    if(local) return local;
    NSString *remote=FZAFCPath(path),*pairing=FZPairingPath(); if(!remote||!pairing||!remote.length) return nil;
    uint8_t *bytes=NULL; size_t len=0; char *err=NULL;
    int32_t rc=al_filza_fs_read(pairing.UTF8String,remote.UTF8String,&bytes,&len,&err);
    if(err) al_string_free(err);
    if(rc!=0||!bytes) { if(bytes) al_filza_fs_bytes_free(bytes,len); return nil; }
    NSData *d=[NSData dataWithBytes:bytes length:len]; al_filza_fs_bytes_free(bytes,len);
    if(error) *error=nil;
    FilzaDiagnosticsAppend(@"AirCardFS",[NSString stringWithFormat:@"transparent AFC read %@ bytes=%lu",path,(unsigned long)len]);
    return [self initWithData:d];
}

static void FZInstallAirCardDirectBackend(void) {
    Class fm=NSFileManager.class;
    Method m=class_getInstanceMethod(fm,@selector(contentsOfDirectoryAtPath:error:));
    if(m){gOrigContents=method_getImplementation(m);method_setImplementation(m,(IMP)FZContents);}
    m=class_getInstanceMethod(fm,@selector(attributesOfItemAtPath:error:));
    if(m){gOrigAttributes=method_getImplementation(m);method_setImplementation(m,(IMP)FZAttributes);}

    Class data=NSMutableData.class;
    SEL sel=@selector(initWithContentsOfFile:options:error:);
    m=class_getInstanceMethod(data,sel);
    if(m){gOrigDataInit=method_getImplementation(m);method_setImplementation(m,(IMP)FZDataInit);}

    FilzaDiagnosticsAppend(@"AirCardFS",@"direct normal-path AFC fallback installed; no mirror");
}

__attribute__((constructor)) static void FZAirCardDirectInit(void) {
    dispatch_async(dispatch_get_main_queue(),^{ FZInstallAirCardDirectBackend(); });
}
