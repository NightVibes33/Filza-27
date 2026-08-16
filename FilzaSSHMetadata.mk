# Embedded SSH integration. Mond is staged and verified independently by
# scripts/stage-mond-current.sh and is not modified from this fragment.
# ByeTunes metadata/search behavior is not rewritten from this fragment.

SSH_VENDOR ?= $(PWD)/Vendor/ssh
SSH_STATIC := $(SSH_VENDOR)/lib/libssh.a
SSH_MBEDTLS := $(SSH_VENDOR)/lib/libmbedtls.a
SSH_MBEDX509 := $(SSH_VENDOR)/lib/libmbedx509.a
SSH_MBEDCRYPTO := $(SSH_VENDOR)/lib/libmbedcrypto.a

FilzaApplySandboxExt_FILES += FilzaSSHServer.m FilzaSSHPreferences.m FilzaSSHPublicAccess.m
FilzaApplySandboxExt_CFLAGS += -I$(SSH_VENDOR)/include -DLIBSSH_STATIC=1
FilzaApplySandboxExt_LDFLAGS += $(SSH_STATIC) $(SSH_MBEDTLS) $(SSH_MBEDX509) $(SSH_MBEDCRYPTO)

before-FilzaApplySandboxExt-all::
	@test -f "FilzaSSHServer.h" || (echo "Missing FilzaSSHServer.h" >&2; exit 1)
	@test -f "FilzaSSHServer.m" || (echo "Missing FilzaSSHServer.m" >&2; exit 1)
	@test -f "FilzaSSHPreferences.m" || (echo "Missing FilzaSSHPreferences.m" >&2; exit 1)
	@test -f "FilzaSSHPublicAccess.m" || (echo "Missing FilzaSSHPublicAccess.m" >&2; exit 1)
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
