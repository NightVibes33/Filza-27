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
 * Darwin/iOS can return ENOPROTOOPT for SO_ACCEPTCONN on a valid libssh-owned
 * listening descriptor. ssh_bind_listen() has already succeeded at that point,
 * and FilzaSSHServerV2 immediately follows this probe with getsockname() plus a
 * real libssh loopback protocol health check after startup. Treat only that
 * specific unsupported diagnostic option as "accepting" instead of turning a
 * working listener into a false startup failure.
 */
static inline int FilzaSSHPortableGetSockOpt(int socketFD,
                                             int level,
                                             int optionName,
                                             void *optionValue,
                                             socklen_t *optionLength)
{
    int rc = getsockopt(socketFD, level, optionName, optionValue, optionLength);
#if defined(__APPLE__) && defined(SO_ACCEPTCONN)
    if (rc != 0 && errno == ENOPROTOOPT &&
        level == SOL_SOCKET && optionName == SO_ACCEPTCONN &&
        optionValue && optionLength && *optionLength >= sizeof(int)) {
        *(int *)optionValue = 1;
        *optionLength = sizeof(int);
        errno = 0;
        return 0;
    }
#endif
    return rc;
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
