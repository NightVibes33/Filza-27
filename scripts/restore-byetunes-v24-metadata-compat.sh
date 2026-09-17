#!/bin/bash
set -euo pipefail

# ByeTunes 2.5 is authoritative for metadata behavior.
# Retained as a no-op because the existing Filza Makefile calls this path.
# The previous implementation restored pre-v2.4 metadata behavior and is not
# a Filza-specific integration requirement.
echo "ByeTunes 2.5: using upstream metadata behavior unchanged"
