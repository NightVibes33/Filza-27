# Historical Filza-only ByeTunes network fragment retained for provenance.
# The user requested the original ByeTunes implementation, so this fragment
# MUST NOT rewrite MetadataBackgroundURLSession.swift or install a WebKit DNS
# fallback. Foreground metadata networking remains the exact pinned v2.4 path:
# URLSession.shared; background requests remain MetadataBackgroundURLSession.

before-FilzaApplySandboxExt-all::
	@test -f "ByeTunes/MusicManager/MetadataBackgroundURLSession.swift" || (echo "Missing upstream ByeTunes metadata transport" >&2; exit 1)
	@grep -Fq 'return try await URLSession.shared.data(for: request)' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@grep -Fq 'return try await URLSession.shared.data(from: url)' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@grep -Fq 'return try await MetadataBackgroundURLSession.shared.data(for: request)' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@! grep -Fq 'FilzaMetadataWebRequest' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@! grep -Fq 'retrying through WebKit network process' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@! grep -Fq 'MetadataWebKitRequest' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift

# Retired script (intentionally not invoked):
# scripts/patch-byetunes-metadata-network-resilience.sh
