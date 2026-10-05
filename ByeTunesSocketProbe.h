#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool ByeTunesTCPProbe(const char *host, uint16_t port, int timeoutMilliseconds);

#ifdef __cplusplus
}
#endif
