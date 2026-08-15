# Filza-only ByeTunes metadata network repair.
# Provider choices, Settings UI, matching rules and background metadata behavior
# remain on pinned ByeTunes v2.4. This fragment only patches the shared
# foreground network dispatcher so DNS failures can retry through WebKit.

before-FilzaApplySandboxExt-all::
	@bash scripts/patch-byetunes-metadata-network-resilience.sh
	@test -f "scripts/patch-byetunes-metadata-network-resilience.sh" || (echo "Missing ByeTunes metadata network repair" >&2; exit 1)
	@grep -Fq 'FilzaMetadataWebRequest' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@grep -Fq 'return try await MetadataBackgroundURLSession.shared.data(for: request)' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@grep -Fq 'return try await URLSession.shared.data(for: request)' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@grep -Fq 'retrying through WebKit network process' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
	@! grep -Fq 'filzaMetadataSourcesRepairV2' ByeTunes/MusicManager/MetadataBackgroundURLSession.swift
