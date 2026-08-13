# GCDWebServer provenance

- Repository: `https://github.com/swisspol/GCDWebServer`
- Commit: `c6d118f4ecc1d9c2c6130fe8522b50889e78524b`
- Imported paths: `GCDWebServer/Core`, `GCDWebServer/Requests`,
  `GCDWebServer/Responses`, and `GCDWebDAVServer`
- License: BSD 3-Clause; see `LICENSE`

FilzaSlop links the complete WebDAV server in-process because the jailed IPA
cannot load Filza's jailbreak-only launch daemon. The path normalizer includes
a local guard that keeps leading parent components pinned at the configured
WebDAV root instead of throwing on an empty component stack.
