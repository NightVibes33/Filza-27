# Embedded SSH + local-network runtime integration. Mond is staged and verified
# independently and is not modified from this fragment. The old WebDAV runtime
# is removed from the source graph here so only one start/stop implementation
# owns the listener; WebDAVToggleStateFix remains the settings-state adapter.

SSH_VENDOR ?= $(PWD)/Vendor/ssh
SSH_STATIC := $(SSH_VENDOR)/lib/libssh.a
SSH_MBEDTLS := $(SSH_VENDOR)/lib/libmbedtls.a
SSH_MBEDX509 := $(SSH_VENDOR)/lib/libmbedx509.a
SSH_MBEDCRYPTO := $(SSH_VENDOR)/lib/libmbedcrypto.a

FilzaApplySandboxExt_FILES := $(filter-out WebDAVRuntimeFix.m,$(FilzaApplySandboxExt_FILES))
FilzaApplySandboxExt_FILES += WebDAVRuntimeV2.m
FilzaApplySandboxExt_FILES += FilzaSSHServerV2.m FilzaSSHPreferencesV2.m FilzaSSHPublicAccess.m
# libssh's public sftp.h hides its server declarations behind WITH_SERVER;
# these are consumer-side declaration guards, separate from the CMake options
# already used when the pinned static library itself is built.
FilzaApplySandboxExt_CFLAGS += -I$(SSH_VENDOR)/include -DLIBSSH_STATIC=1 -DWITH_SERVER=1 -DWITH_SFTP=1
FilzaApplySandboxExt_LDFLAGS += $(SSH_STATIC) $(SSH_MBEDTLS) $(SSH_MBEDX509) $(SSH_MBEDCRYPTO)

before-FilzaApplySandboxExt-all::
	@test -f "FilzaSSHServer.h" || (echo "Missing FilzaSSHServer.h" >&2; exit 1)
	@test -f "FilzaSSHServerV2.m" || (echo "Missing FilzaSSHServerV2.m" >&2; exit 1)
	@test -f "FilzaSSHPreferencesV2.m" || (echo "Missing FilzaSSHPreferencesV2.m" >&2; exit 1)
	@test -f "WebDAVRuntimeV2.m" || (echo "Missing WebDAVRuntimeV2.m" >&2; exit 1)
	@test -f "FilzaSSHPublicAccess.m" || (echo "Missing FilzaSSHPublicAccess.m" >&2; exit 1)
	@test -f "$(SSH_VENDOR)/include/libssh/sftp.h" || (echo "Missing libssh SFTP headers" >&2; exit 1)
	@test -f "$(SSH_VENDOR)/include/libssh/sftpserver.h" || (echo "Missing libssh SFTP server headers" >&2; exit 1)
	@grep -Fq 'sftp_channel_default_subsystem_request' FilzaSSHServerV2.m
	@grep -Fq 'sftp_channel_default_data_callback' FilzaSSHServerV2.m
	@grep -Fq 'SO_ACCEPTCONN' FilzaSSHServerV2.m
	@grep -Fq 'PROPFIND / HTTP/1.1' WebDAVRuntimeV2.m
	@grep -Fq 'GCDWebServerOption_BindToLocalhost: @NO' WebDAVRuntimeV2.m
	@grep -Fq 'NAT-PMP (RFC 6886)' FilzaSSHPublicAccess.m
	@grep -Fq 'UPnP IGD WANIPConnection' FilzaSSHPublicAccess.m
	@grep -Fq 'PUBLIC via' FilzaSSHPublicAccess.m
	@test -f "scripts/build-ssh-stack.sh" || (echo "Missing pinned SSH build script" >&2; exit 1)
	@test -s "$(SSH_STATIC)" || (echo "Missing $(SSH_STATIC). Run: bash scripts/build-ssh-stack.sh" >&2; exit 1)
	@test -s "$(SSH_MBEDTLS)" || (echo "Missing $(SSH_MBEDTLS)" >&2; exit 1)
	@test -s "$(SSH_MBEDX509)" || (echo "Missing $(SSH_MBEDX509)" >&2; exit 1)
	@test -s "$(SSH_MBEDCRYPTO)" || (echo "Missing $(SSH_MBEDCRYPTO)" >&2; exit 1)
	@grep -Fq 'return try await URLSession.shared.data(for: request)' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@grep -Fq 'return try await URLSession.shared.data(from: url)' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@! grep -Fq 'MetadataWebKitRequest' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift

# Keep the public mapper in every release/diagnostic arm64 build.
