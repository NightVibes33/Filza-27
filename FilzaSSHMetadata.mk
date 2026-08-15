# Embedded SSH + metadata-network integration.
# Kept separate from the large upstream source graph so the existing Filza,
# Mond, 3105 and ByeTunes staging order remains readable and auditable.

SSH_VENDOR ?= $(PWD)/Vendor/ssh
SSH_STATIC := $(SSH_VENDOR)/lib/libssh.a
SSH_MBEDTLS := $(SSH_VENDOR)/lib/libmbedtls.a
SSH_MBEDX509 := $(SSH_VENDOR)/lib/libmbedx509.a
SSH_MBEDCRYPTO := $(SSH_VENDOR)/lib/libmbedcrypto.a

FilzaApplySandboxExt_FILES += FilzaSSHServer.m FilzaSSHPreferences.m
FilzaApplySandboxExt_CFLAGS += -I$(SSH_VENDOR)/include -DLIBSSH_STATIC=1
FilzaApplySandboxExt_LDFLAGS += $(SSH_STATIC) $(SSH_MBEDTLS) $(SSH_MBEDX509) $(SSH_MBEDCRYPTO)

# This rule runs after the existing ByeTunes parity transformations declared in
# Makefile. It repairs the exact embedded local-only migration state seen in the
# device log and replaces the shared metadata transport with URLSession-first,
# WebKit-on-DNS-failure behavior.
before-FilzaApplySandboxExt-all::
	@bash scripts/patch-byetunes-metadata-network-resilience.sh
	@test -f "FilzaSSHServer.h" || (echo "Missing FilzaSSHServer.h" >&2; exit 1)
	@test -f "FilzaSSHServer.m" || (echo "Missing FilzaSSHServer.m" >&2; exit 1)
	@test -f "FilzaSSHPreferences.m" || (echo "Missing FilzaSSHPreferences.m" >&2; exit 1)
	@test -f "scripts/build-ssh-stack.sh" || (echo "Missing pinned SSH build script" >&2; exit 1)
	@test -f "scripts/patch-byetunes-metadata-network-resilience.sh" || (echo "Missing ByeTunes metadata-network repair" >&2; exit 1)
	@test -s "$(SSH_STATIC)" || (echo "Missing $(SSH_STATIC). Run: bash scripts/build-ssh-stack.sh" >&2; exit 1)
	@test -s "$(SSH_MBEDTLS)" || (echo "Missing $(SSH_MBEDTLS)" >&2; exit 1)
	@test -s "$(SSH_MBEDX509)" || (echo "Missing $(SSH_MBEDX509)" >&2; exit 1)
	@test -s "$(SSH_MBEDCRYPTO)" || (echo "Missing $(SSH_MBEDCRYPTO)" >&2; exit 1)
	@grep -Fq 'Repaired embedded default provider state' ByeTunesMetadataCompat.swift
	@grep -Fq 'retrying through WebKit network process' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
