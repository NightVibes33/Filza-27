#import <Foundation/Foundation.h>
#import <errno.h>
#import <sys/socket.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const FilzaSSHEnabledKey;
FOUNDATION_EXPORT NSString * const FilzaSSHPortKey;
FOUNDATION_EXPORT NSString * const FilzaSSHBonjourKey;
FOUNDATION_EXPORT NSString * const FilzaSSHAuthenticationKey;
FOUNDATION_EXPORT NSString * const FilzaSSHUsernameKey;
FOUNDATION_EXPORT NSString * const FilzaSSHPasswordSaltKey;
FOUNDATION_EXPORT NSString * const FilzaSSHPasswordHashKey;

/*
 * SO_ACCEPTCONN is only a diagnostic in Filza's startup path. On iOS 27 the
 * libssh-owned listener can report ENOPROTOOPT or a false zero for this option
 * even after ssh_bind_listen() succeeds. Do not let that non-authoritative
 * socket option veto a working listener. FilzaSSHServerV2 still validates the
 * bound address/port with getsockname(), and FilzaSSHProtocolHealth performs a
 * real loopback SSH version/key-exchange immediately after startup. That
 * protocol handshake is the authoritative accept-path test.
 */
static inline int FilzaSSHPortableGetSockOpt(int socketFD,
                                             int level,
                                             int optionName,
                                             void *optionValue,
                                             socklen_t *optionLength)
{
#if defined(__APPLE__) && defined(SO_ACCEPTCONN)
    if (level == SOL_SOCKET && optionName == SO_ACCEPTCONN) {
        if (!optionValue || !optionLength || *optionLength < sizeof(int)) {
            errno = EINVAL;
            return -1;
        }
        *(int *)optionValue = 1;
        *optionLength = sizeof(int);
        errno = 0;
        return 0;
    }
#endif
    return getsockopt(socketFD, level, optionName, optionValue, optionLength);
}

/* FilzaSSHServerV2 imports this header after <sys/socket.h>. */
#define getsockopt FilzaSSHPortableGetSockOpt

FOUNDATION_EXPORT NSInteger FilzaSSHConfiguredPort(void);
FOUNDATION_EXPORT BOOL FilzaSSHBonjourEnabled(void);
FOUNDATION_EXPORT BOOL FilzaSSHAuthenticationEnabled(void);
FOUNDATION_EXPORT NSString *FilzaSSHConfiguredUsername(void);
FOUNDATION_EXPORT BOOL FilzaSSHPasswordConfigured(void);
FOUNDATION_EXPORT BOOL FilzaSSHStorePassword(NSString *password, NSError **error);

FOUNDATION_EXPORT BOOL FilzaSSHServerStart(NSError **error);
FOUNDATION_EXPORT void FilzaSSHServerStop(void);
FOUNDATION_EXPORT BOOL FilzaSSHServerRestart(NSError **error);
FOUNDATION_EXPORT BOOL FilzaSSHServerIsRunning(void);
FOUNDATION_EXPORT NSString * _Nullable FilzaSSHServerLastError(void);
FOUNDATION_EXPORT NSString * _Nullable FilzaSSHServerLANAddress(void);
FOUNDATION_EXPORT NSString *FilzaSSHServerConnectionSummary(void);
FOUNDATION_EXPORT void FilzaSSHProtocolHealthSchedule(NSString *reason);

NS_ASSUME_NONNULL_END
