#!/usr/bin/env bash
set -euo pipefail

# Upstream ByeTunes 2.5 owns its download/search provider implementation.
# The historical pre-v2.4 provider restoration is not Filza integration code.
echo "ByeTunes 2.5: legacy download-provider parity disabled"
