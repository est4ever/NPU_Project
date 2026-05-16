#!/usr/bin/env bash
# Same as portable_setup.ps1 on Windows — run once after git clone.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$ROOT/scripts/hpc/linux_setup.sh"
chmod +x "$ROOT/portable_setup.sh" "$SETUP" 2>/dev/null || true
exec bash "$SETUP" "$@"
