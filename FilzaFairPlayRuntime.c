// Original in-process FairPlay mapping implementation for Filza.
// No second IPA, no copied FairPlayed code. The original executable must be
// legitimately licensed, readable, and accepted by Apple's FairPlay service.
#include <errno.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <libkern/OSByteOrder.h>
#include <mach/mach.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <math.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_ARCH 16
typedef struct {
    uint64_t offset, length, cryptid_pos;
    uint32_t cryptoff, cryptsize, cryptid;
    cpu_type_t cpu;
    cpu_subtype_t subtype;
    bool encrypted_command;
} FPArch;
static void err_msg(char *out, size_t size, const char *msg) {
    if(out && size) snprintf(out,size,"%s (errno %d)",msg,errno);
}
static bool read_all(int fd,void *dst,size_t n,uint64_t off) {
    if(off>INT64_MAX || n>(uint64_t)(INT64_MAX-off))return false;
    uint8_t *ptr=dst;
    while(n) {
        ssize_t amount=pread(fd,ptr,n,(off_t)off);
        if(amount<=0)return false;
        ptr+=amount;off+=(uint64_t)amount;n-=(size_t)amount;
    }
    return true;
}
static bool write_all(int fd,const void *src,size_t n,uint64_t off) {
    if(off>INT64_MAX || n>(uint64_t)(INT64_MAX-off))return false;
    const uint8_t *ptr=src;
    while(n) {
        ssize_t amount=pwrite(fd,ptr,n,(off_t)off);
        if(amount<=0)return false;
        ptr+=amount;off+=(uint64_t)amount;n-=(size_t)amount;
    }
    return true;
}
static bool parse_arch(int fd,uint64_t total,uint64_t offset,uint64_t length,FPArch *a) {
    if(offset>total || length>total-offset || length<sizeof(struct mach_header_64))return false;
    struct mach_header_64 h;
    if(!read_all(fd,&h,sizeof(h),offset) || h.magic!=MH_MAGIC_64 ||
       h.ncmds>8192 || h.sizeofcmds>16777216 ||
       h.sizeofcmds>length-sizeof(h))return false;
    uint8_t *cmds=malloc(h.sizeofcmds ? h.sizeofcmds : 1);
    if(!cmds)return false;
    bool ok=read_all(fd,cmds,h.sizeofcmds,offset+sizeof(h));
    memset(a,0,sizeof(*a));
    a->offset=offset;a->length=length;a->cpu=h.cputype;a->subtype=h.cpusubtype;
    uint32_t pos=0;
    for(uint32_t i=0;ok && i<h.ncmds;i++) {
        struct load_command cmd;
        if(pos>h.sizeofcmds || h.sizeofcmds-pos<sizeof(cmd)){ok=false;break;}
        memcpy(&cmd,cmds+pos,sizeof(cmd));
        if(cmd.cmdsize<sizeof(cmd) || cmd.cmdsize>h.sizeofcmds-pos){ok=false;break;}
        if(cmd.cmd==LC_ENCRYPTION_INFO_64 || cmd.cmd==LC_ENCRYPTION_INFO){
            struct encryption_info_command e;
            if(cmd.cmdsize<sizeof(e)){ok=false;break;}
            memcpy(&e,cmds+pos,sizeof(e));
            if((uint64_t)e.cryptoff>length || e.cryptsize>length-e.cryptoff){ok=false;break;}
            a->encrypted_command=true;a->cryptoff=e.cryptoff;
            a->cryptsize=e.cryptsize;a->cryptid=e.cryptid;
            a->cryptid_pos=offset+sizeof(h)+pos+offsetof(struct encryption_info_command,cryptid);
        }
        pos+=cmd.cmdsize;
    }
    free(cmds);return ok;
}
static int inspect_fd(int fd,FPArch slices[MAX_ARCH],int *count) {
    struct stat st;
    if(fstat(fd,&st)!=0 || st.st_size<4)return -1;
    const uint64_t total=(uint64_t)st.st_size;
    uint32_t magic=0;
    if(!read_all(fd,&magic,sizeof(magic),0))return -1;
    *count=0;
    if(magic==MH_MAGIC_64) {
        if(!parse_arch(fd,total,0,total,&slices[0]))return -1;
        *count=1;
    } else if(magic==FAT_CIGAM || magic==FAT_CIGAM_64){
        struct fat_header h;
        if(!read_all(fd,&h,sizeof(h),0))return -1;
        uint32_t n=OSSwapBigToHostInt32(h.nfat_arch);
        bool large=magic==FAT_CIGAM_64;
        size_t stride=large?sizeof(struct fat_arch_64):sizeof(struct fat_arch);
        if(n==0 || n>64 || (uint64_t)n*stride>total-sizeof(h))return -1;
        for(uint32_t i=0;i<n;i++) {
            uint64_t off,len,pos=sizeof(h)+(uint64_t)i*stride;
            uint32_t cpu;
            if(large) {
                struct fat_arch_64 a;
                if(!read_all(fd,&a,sizeof(a),pos))return -1;
                cpu=OSSwapBigToHostInt32(a.cputype);
                off=OSSwapBigToHostInt64(a.offset);len=OSSwapBigToHostInt64(a.size);
            } else {
                struct fat_arch a;
                if(!read_all(fd,&a,sizeof(a),pos))return -1;
                cpu=OSSwapBigToHostInt32(a.cputype);
                off=OSSwapBigToHostInt32(a.offset);len=OSSwapBigToHostInt32(a.size);
            }
            if(!(cpu & CPU_ARCH_ABI64))continue;
            if(*count>=MAX_ARCH || !parse_arch(fd,total,off,len,&slices[*count]))return -1;
            (*count)++;
        }
        if(*count==0)return -1;
    } else return -1;
    int encrypted=0;
    for(int i=0;i<*count;i++)if(slices[i].encrypted_command && slices[i].cryptid)encrypted++;
    return encrypted;
}
int FilzaFairPlayEncryptedSlices(const char *path) {
    if(!path)return -1;
    int fd=open(path,O_RDONLY);
    if(fd<0)return -1;
    FPArch slices[MAX_ARCH];int count=0;
    int result=inspect_fd(fd,slices,&count);
    close(fd);return result;
}
static int remap_apple(void *p,size_t n,cpu_type_t cpu,cpu_subtype_t sub) {
    typedef int(*Fn)(void *,size_t,uint32_t,uint32_t,uint32_t);
    Fn fn=(Fn)dlsym(RTLD_DEFAULT,"mremap_encrypted");
    if(fn)return fn(p,n,2,(uint32_t)cpu,(uint32_t)sub);
#if defined(__arm64__)
    register uint64_t x0 __asm__("x0")=(uint64_t)p;
    register uint64_t x1 __asm__("x1")=n;
    register uint64_t x2 __asm__("x2")=2;
    register uint64_t x3 __asm__("x3")=(uint32_t)cpu;
    register uint64_t x4 __asm__("x4")=(uint32_t)sub;
    register uint64_t x16 __asm__("x16")=489;
    uint64_t fail;
    __asm__ volatile("svc #0x80\n\tcset %[fail], cs"
        : "+r"(x0),"+r"(x1),[fail]"=r"(fail)
        : "r"(x2),"r"(x3),"r"(x4),"r"(x16):"memory","cc");
    if(fail){errno=(int)x0;return -1;}
    return (int)x0;
#else
    errno=ENOTSUP;return -1;
#endif
}
static double entropy(const uint8_t *p,size_t n) {
    if(!n)return 0;
    size_t counts[256]={0};double h=0;
    for(size_t i=0;i<n;i++)counts[p[i]]++;
    for(int i=0;i<256;i++)if(counts[i]){
        double q=(double)counts[i]/(double)n;h-=q*log2(q);
    }
    return h;
}
static bool decrypt_slice(int fd,int output,const FPArch *a,char *err,size_t cap) {
    size_t page=(size_t)getpagesize();
    if(!page || a->offset%page || a->cryptoff%page ||
       a->cryptsize==0 || a->cryptsize>(128U*1024U*1024U)){
        err_msg(err,cap,"Unsupported FairPlay mapping geometry");return false;
    }
    uint64_t end=(uint64_t)a->cryptoff+a->cryptsize;
    if(end>a->length || end>SIZE_MAX-page){
        err_msg(err,cap,"FairPlay mapping overflows slice");return false;
    }
    size_t span=((size_t)end+page-1)/page*page;
    if(span>a->length){err_msg(err,cap,"FairPlay mapping exceeds file length");return false;}
    uint8_t *mapped=mmap(NULL,span,PROT_READ,MAP_PRIVATE,fd,(off_t)a->offset);
    if(mapped==MAP_FAILED){
        err_msg(err,cap,"Installed executable is not accessible to FairPlay");return false;
    }
    size_t n=a->cryptsize;
    uint8_t *plain=malloc(n),*original=malloc(n);
    bool ok=plain && original && read_all(fd,original,n,a->offset+a->cryptoff);
    if(ok && remap_apple(mapped+a->cryptoff,n,a->cpu,a->subtype)!=0){
        err_msg(err,cap,"Apple FairPlay rejected the read-only mapping");ok=false;
    }
    for(size_t offset=0;ok && offset<n;offset+=page){
        vm_size_t size=(vm_size_t)((n-offset)<page?(n-offset):page),received=0;
        kern_return_t kr=vm_read_overwrite(mach_task_self(),
            (vm_address_t)(mapped+a->cryptoff+offset),size,
            (vm_address_t)(plain+offset),&received);
        if(kr!=KERN_SUCCESS || received!=size){
            err_msg(err,cap,"FairPlay page-in failed");ok=false;
        }
    }
    if(ok){
        size_t sample=n<16384?n:16384,diff=0;
        for(size_t i=0;i<sample;i++)if(plain[i]!=original[i])diff++;
        if(diff<sample/32 || entropy(plain,sample)+0.1>=entropy(original,sample)){
            err_msg(err,cap,"FairPlay plaintext validation failed");ok=false;
        }
    }
    if(ok){
        uint32_t zero=0;
        ok=write_all(output,plain,n,a->offset+a->cryptoff) &&
           write_all(output,&zero,sizeof(zero),a->cryptid_pos);
        if(!ok)err_msg(err,cap,"Could not write verified decrypted bytes");
    }
    free(plain);free(original);munmap(mapped,span);return ok;
}
static bool copy_binary(int from,int to){
    uint8_t *block=malloc(1024*1024);
    if(!block)return false;
    bool ok=true;uint64_t pos=0;
    while(ok){
        ssize_t n=pread(from,block,1024*1024,(off_t)pos);
        if(n<0){ok=false;break;}
        if(n==0)break;
        ok=write_all(to,block,(size_t)n,pos);
        pos+=(uint64_t)n;
    }
    free(block);return ok;
}
// Returns 0=verified decrypted, 1=already clear, -1=failed.
// Never modifies the installed app or exports a partially decrypted binary.
int FilzaFairPlayDecryptMachO(const char *source,const char *destination,
                              char *reason,size_t reason_size) {
    if(!source || !destination || !strcmp(source,destination)){
        err_msg(reason,reason_size,"Invalid FairPlay source or destination");return -1;
    }
    int input=open(source,O_RDONLY);
    if(input<0){err_msg(reason,reason_size,"Original installed executable not readable");return -1;}
    FPArch slices[MAX_ARCH];int count=0,encrypted=inspect_fd(input,slices,&count);
    if(encrypted<=0){
        if(encrypted<0)err_msg(reason,reason_size,"Unsupported Mach-O file");
        close(input);return encrypted==0?1:-1;
    }
    int output=open(destination,O_CREAT|O_TRUNC|O_RDWR,0700);
    if(output<0){err_msg(reason,reason_size,"Could not create destination");close(input);return -1;}
    bool ok=copy_binary(input,output);
    if(!ok)err_msg(reason,reason_size,"Could not copy original binary");
    for(int i=0;ok && i<count;i++){
        if(slices[i].encrypted_command && slices[i].cryptid)
            ok=decrypt_slice(input,output,&slices[i],reason,reason_size);
    }
    close(output);close(input);
    if(!ok || FilzaFairPlayEncryptedSlices(destination)!=0){
        if(ok)err_msg(reason,reason_size,"Decrypted output was not fully verified");
        unlink(destination);return -1;
    }
    return 0;
}
