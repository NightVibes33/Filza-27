#include "ByeTunesSocketProbe.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

bool ByeTunesTCPProbe(const char *host, uint16_t port, int timeoutMilliseconds) {
    if (host == NULL || host[0] == '\0' || port == 0) {
        return false;
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return false;
    }

    bool reachable = false;
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(fd);
        return false;
    }

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &address.sin_addr) != 1) {
        close(fd);
        return false;
    }

    int rc = connect(fd, (const struct sockaddr *)&address, sizeof(address));
    if (rc == 0) {
        reachable = true;
    } else if (errno == EINPROGRESS) {
        struct pollfd descriptor = {
            .fd = fd,
            .events = POLLOUT,
            .revents = 0,
        };

        rc = poll(&descriptor, 1, timeoutMilliseconds > 0 ? timeoutMilliseconds : 500);
        if (rc > 0) {
            int socketError = 0;
            socklen_t errorLength = sizeof(socketError);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0 &&
                socketError == 0) {
                reachable = true;
            }
        }
    }

    close(fd);
    return reachable;
}
