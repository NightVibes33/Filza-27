# Embedded SSH integration only.
# ByeTunes metadata/search behavior is intentionally left on the exact pinned
# upstream v2.4 implementation instead of being rewritten from this fragment.

SSH_VENDOR ?= $(PWD)/Vendor/ssh
SSH_STATIC := $(SSH_VENDOR)/lib/libssh.a
SSH_MBEDTLS := $(SSH_VENDOR)/lib/libmbedtls.a
SSH_MBEDX509 := $(SSH_VENDOR)/lib/libmbedx509.a
SSH_MBEDCRYPTO := $(SSH_VENDOR)/lib/libmbedcrypto.a

FilzaApplySandboxExt_FILES += FilzaSSHServer.m FilzaSSHPreferences.m
FilzaApplySandboxExt_CFLAGS += -I$(SSH_VENDOR)/include -DLIBSSH_STATIC=1
FilzaApplySandboxExt_LDFLAGS += $(SSH_STATIC) $(SSH_MBEDTLS) $(SSH_MBEDX509) $(SSH_MBEDCRYPTO)

before-FilzaApplySandboxExt-all::
	@test -f "FilzaSSHServer.h" || (echo "Missing FilzaSSHServer.h" >&2; exit 1)
	@test -f "FilzaSSHServer.m" || (echo "Missing FilzaSSHServer.m" >&2; exit 1)
	@test -f "FilzaSSHPreferences.m" || (echo "Missing FilzaSSHPreferences.m" >&2; exit 1)
	@test -f "scripts/build-ssh-stack.sh" || (echo "Missing pinned SSH build script" >&2; exit 1)
	@test -s "$(SSH_STATIC)" || (echo "Missing $(SSH_STATIC). Run: bash scripts/build-ssh-stack.sh" >&2; exit 1)
	@test -s "$(SSH_MBEDTLS)" || (echo "Missing $(SSH_MBEDTLS)" >&2; exit 1)
	@test -s "$(SSH_MBEDX509)" || (echo "Missing $(SSH_MBEDX509)" >&2; exit 1)
	@test -s "$(SSH_MBEDCRYPTO)" || (echo "Missing $(SSH_MBEDCRYPTO)" >&2; exit 1)
	@grep -Fq 'return try await URLSession.shared.data(for: request)' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@grep -Fq 'return try await URLSession.shared.data(from: url)' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@! grep -Fq 'MetadataWebKitRequest' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
