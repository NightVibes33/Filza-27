#!/bin/bash
set -euo pipefail

# ByeTunes 2.5 owns metadata provider behavior. Do not restore the historical
# Filza/ByeTunes 2.4 parity layer over upstream 2.5.
echo "ByeTunes 2.5: legacy metadata post-parity disabled"
