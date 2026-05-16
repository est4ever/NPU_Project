#!/usr/bin/env bash
# Same as portable_setup.ps1 on Windows — run once after git clone.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/hpc/linux_setup.sh" "$@"
