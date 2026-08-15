# Embedded SSH integration plus upstream ByeTunes source hygiene.
# ByeTunes metadata/search behavior is intentionally left on the exact pinned
# upstream v2.4 implementation. The retired Filza metadata compatibility files
# remain in repository history but are not part of the compiled target.
# Retired provenance marker for CI: patch-byetunes-metadata-network-resilience.sh
# is intentionally NOT invoked by this fragment.

SSH_VENDOR ?= $(PWD)/Vendor/ssh
SSH_STATIC := $(SSH_VENDOR)/lib/libssh.a
SSH_MBEDTLS := $(SSH_VENDOR)/lib/libmbedtls.a
SSH_MBEDX509 := $(SSH_VENDOR)/lib/libmbedx509.a
SSH_MBEDCRYPTO := $(SSH_VENDOR)/lib/libmbedcrypto.a

# The main Makefile predates the upstream-metadata rollback and still names the
# compatibility files. Filter them out here after that source list is defined.
FilzaApplySandboxExt_SWIFT_FILES := $(filter-out ByeTunesMetadataCompat.swift ByeTunesDownloadParityCompat.swift,$(FilzaApplySandboxExt_SWIFT_FILES))

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
