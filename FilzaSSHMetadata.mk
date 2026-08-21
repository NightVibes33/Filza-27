# Embedded SSH + local-network runtime integration. The production server is
# wolfSSH; libssh remains only as an independent loopback protocol verifier.
# Mond is staged and verified independently and is not modified here.

SSH_VENDOR ?= $(PWD)/Vendor/ssh
SSH_STATIC := $(SSH_VENDOR)/lib/libssh.a
SSH_MBEDTLS := $(SSH_VENDOR)/lib/libmbedtls.a
SSH_MBEDX509 := $(SSH_VENDOR)/lib/libmbedx509.a
SSH_MBEDCRYPTO := $(SSH_VENDOR)/lib/libmbedcrypto.a

WOLFSSH_VENDOR ?= $(PWD)/Vendor/wolfssh
WOLFSSH_STATIC := $(WOLFSSH_VENDOR)/lib/libwolfssh.a
WOLFSSL_STATIC := $(WOLFSSH_VENDOR)/lib/libwolfssl.a

FilzaApplySandboxExt_FILES := $(filter-out WebDAVRuntimeFix.m,$(FilzaApplySandboxExt_FILES))
FilzaApplySandboxExt_FILES += WebDAVRuntimeV2.m NetworkRuntimeVerificationMarkers.m
FilzaApplySandboxExt_FILES += FilzaWolfSSHServer.m FilzaSSHPreferencesV2.m FilzaSSHProtocolHealth.m FilzaSSHPublicAccess.m

# libssh is a client-only health probe now. wolfSSH owns the actual listening
# socket, authentication, shell transport, and SFTP subsystem.
FilzaApplySandboxExt_CFLAGS += -I$(SSH_VENDOR)/include -DLIBSSH_STATIC=1
FilzaApplySandboxExt_CFLAGS += -I$(WOLFSSH_VENDOR)/include -DWOLFSSH_SFTP=1 -DWOLFSSH_SCP=1
FilzaApplySandboxExt_LDFLAGS += $(WOLFSSH_STATIC) $(WOLFSSL_STATIC)
FilzaApplySandboxExt_LDFLAGS += $(SSH_STATIC) $(SSH_MBEDTLS) $(SSH_MBEDX509) $(SSH_MBEDCRYPTO)

before-FilzaApplySandboxExt-all::
	@test -f "FilzaSSHServer.h" || (echo "Missing FilzaSSHServer.h" >&2; exit 1)
	@test -f "FilzaWolfSSHServer.m" || (echo "Missing FilzaWolfSSHServer.m" >&2; exit 1)
	@test -f "FilzaSSHPreferencesV2.m" || (echo "Missing FilzaSSHPreferencesV2.m" >&2; exit 1)
	@test -f "FilzaSSHProtocolHealth.m" || (echo "Missing independent SSH protocol health probe" >&2; exit 1)
	@test -f "WebDAVRuntimeV2.m" || (echo "Missing WebDAVRuntimeV2.m" >&2; exit 1)
	@test -f "NetworkRuntimeVerificationMarkers.m" || (echo "Missing network runtime migration markers" >&2; exit 1)
	@test -f "FilzaSSHPublicAccess.m" || (echo "Missing FilzaSSHPublicAccess.m" >&2; exit 1)
	@test -f "$(SSH_VENDOR)/include/libssh/libssh.h" || (echo "Missing libssh verifier headers" >&2; exit 1)
	@test -f "$(WOLFSSH_VENDOR)/include/wolfssh/ssh.h" || (echo "Missing wolfSSH headers" >&2; exit 1)
	@test -f "$(WOLFSSH_VENDOR)/include/wolfssh/wolfsftp.h" || (echo "Missing wolfSSH SFTP headers" >&2; exit 1)
	@test -f "$(WOLFSSH_VENDOR)/include/wolfssl/wolfcrypt/ecc.h" || (echo "Missing wolfCrypt headers" >&2; exit 1)
	@grep -Fq 'wolfSSH_accept' FilzaWolfSSHServer.m
	@grep -Fq 'wolfSSH_SFTP_read' FilzaWolfSSHServer.m
	@grep -Fq 'wolfSSH_CTX_UsePrivateKey_buffer' FilzaWolfSSHServer.m
	@grep -Fq 'wolfSSH password verifier updated' FilzaWolfSSHServer.m
	@grep -Fq 'silent-audio background keepalive active for wolfSSH' FilzaWolfSSHServer.m
	@grep -Fq 'SSH-2.0-' FilzaSSHProtocolHealth.m
	@grep -Fq 'protocol self-test passed' FilzaSSHProtocolHealth.m
	@grep -Fq 'PROPFIND / HTTP/1.1' WebDAVRuntimeV2.m
	@grep -Fq 'GCDWebServerOption_BindToLocalhost: @NO' WebDAVRuntimeV2.m
	@grep -Fq 'NAT-PMP (RFC 6886)' FilzaSSHPublicAccess.m
	@grep -Fq 'UPnP IGD WANIPConnection' FilzaSSHPublicAccess.m
	@grep -Fq 'PUBLIC via' FilzaSSHPublicAccess.m
	@test -f "scripts/build-ssh-stack.sh" || (echo "Missing pinned libssh verifier build script" >&2; exit 1)
	@test -f "scripts/build-wolfssh-stack.sh" || (echo "Missing pinned wolfSSH build script" >&2; exit 1)
	@test -s "$(WOLFSSH_STATIC)" || (echo "Missing $(WOLFSSH_STATIC). Run: bash scripts/build-wolfssh-stack.sh" >&2; exit 1)
	@test -s "$(WOLFSSL_STATIC)" || (echo "Missing $(WOLFSSL_STATIC). Run: bash scripts/build-wolfssh-stack.sh" >&2; exit 1)
	@test -s "$(SSH_STATIC)" || (echo "Missing $(SSH_STATIC). Run: bash scripts/build-ssh-stack.sh" >&2; exit 1)
	@test -s "$(SSH_MBEDTLS)" || (echo "Missing $(SSH_MBEDTLS)" >&2; exit 1)
	@test -s "$(SSH_MBEDX509)" || (echo "Missing $(SSH_MBEDX509)" >&2; exit 1)
	@test -s "$(SSH_MBEDCRYPTO)" || (echo "Missing $(SSH_MBEDCRYPTO)" >&2; exit 1)
	@grep -Fq 'return try await URLSession.shared.data(for: request)' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@grep -Fq 'return try await URLSession.shared.data(from: url)' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@! grep -Fq 'MetadataWebKitRequest' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift

# Keep the public mapper in every release/diagnostic arm64 build.
