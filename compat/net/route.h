#ifndef FILZA_COMPAT_NET_ROUTE_H
#define FILZA_COMPAT_NET_ROUTE_H

/*
 * Minimal user-space Darwin routing ABI used by FilzaSSHPublicAccess.m.
 *
 * The iPhoneOS SDK no longer ships <net/route.h>, but XNU still defines the
 * PF_ROUTE sysctl ABI. Keep only the declarations required to parse the
 * default IPv4 gateway; values/layout mirror Apple's XNU bsd/net/route.h.
 */

#include <stdint.h>
#include <sys/types.h>
#include <sys/socket.h>

#ifndef RTF_UP
#define RTF_UP          0x1
#endif
#ifndef RTF_GATEWAY
#define RTF_GATEWAY     0x2
#endif

struct rt_metrics {
    uint32_t rmx_locks;
    uint32_t rmx_mtu;
    uint32_t rmx_hopcount;
    int32_t  rmx_expire;
    uint32_t rmx_recvpipe;
    uint32_t rmx_sendpipe;
    uint32_t rmx_ssthresh;
    uint32_t rmx_rtt;
    uint32_t rmx_rttvar;
    uint32_t rmx_pksent;
    uint32_t rmx_filler[4];
};

struct rt_msghdr {
    u_short rtm_msglen;
    u_char  rtm_version;
    u_char  rtm_type;
    u_short rtm_index;
    int     rtm_flags;
    int     rtm_addrs;
    pid_t   rtm_pid;
    int     rtm_seq;
    int     rtm_errno;
    int     rtm_use;
    uint32_t rtm_inits;
    struct rt_metrics rtm_rmx;
};

#ifndef RTAX_DST
#define RTAX_DST        0
#endif
#ifndef RTAX_GATEWAY
#define RTAX_GATEWAY    1
#endif
#ifndef RTAX_NETMASK
#define RTAX_NETMASK    2
#endif
#ifndef RTAX_GENMASK
#define RTAX_GENMASK    3
#endif
#ifndef RTAX_IFP
#define RTAX_IFP        4
#endif
#ifndef RTAX_IFA
#define RTAX_IFA        5
#endif
#ifndef RTAX_AUTHOR
#define RTAX_AUTHOR     6
#endif
#ifndef RTAX_BRD
#define RTAX_BRD        7
#endif
#ifndef RTAX_MAX
#define RTAX_MAX        8
#endif

/* CTL_NET/PF_ROUTE sysctl operation selector from Darwin socket ABI. */
#ifndef NET_RT_FLAGS
#define NET_RT_FLAGS    2
#endif

#endif /* FILZA_COMPAT_NET_ROUTE_H */
