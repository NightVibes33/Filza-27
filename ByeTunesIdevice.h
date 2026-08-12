#pragma once

#include <stddef.h>
#include <stdint.h>
#include <sys/socket.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct IdeviceFfiError {
    int32_t code;
    int32_t sub_code;
    const char *message;
} IdeviceFfiError;

typedef struct RpPairingFileHandle RpPairingFileHandle;
typedef struct AdapterHandle AdapterHandle;
typedef struct RsdHandshakeHandle RsdHandshakeHandle;
typedef struct AfcClientHandle AfcClientHandle;
typedef struct AfcFileHandle AfcFileHandle;

typedef enum AfcFopenMode {
    AfcRdOnly = 0x00000001,
    AfcRw = 0x00000002,
    AfcWrOnly = 0x00000003,
    AfcWr = 0x00000004,
    AfcAppend = 0x00000005,
    AfcRdAppend = 0x00000006,
} AfcFopenMode;

typedef const char *(*IdevicePinCallback)(void *context);

IdeviceFfiError *rp_pairing_file_read(const char *path,
                                      RpPairingFileHandle **out);
void rp_pairing_file_free(RpPairingFileHandle *handle);

IdeviceFfiError *tunnel_create_rppairing(
    const struct sockaddr *addr,
    socklen_t addr_len,
    const char *hostname,
    RpPairingFileHandle *pairing_file,
    IdevicePinCallback pin_callback,
    void *pin_context,
    AdapterHandle **out_adapter,
    RsdHandshakeHandle **out_handshake);

IdeviceFfiError *afc_client_connect_rsd(AdapterHandle *provider,
                                       RsdHandshakeHandle *handshake,
                                       AfcClientHandle **client);
void afc_client_free(AfcClientHandle *handle);

IdeviceFfiError *afc_file_open(AfcClientHandle *client,
                               const char *path,
                               AfcFopenMode mode,
                               AfcFileHandle **handle);
IdeviceFfiError *afc_file_close(AfcFileHandle *handle);
IdeviceFfiError *afc_file_read_entire(AfcFileHandle *handle,
                                      uint8_t **data,
                                      size_t *length);
void afc_file_read_data_free(uint8_t *data, size_t length);

void adapter_free(AdapterHandle *handle);
void rsd_handshake_free(RsdHandshakeHandle *handle);
void idevice_error_free(IdeviceFfiError *error);

#ifdef __cplusplus
}
#endif
