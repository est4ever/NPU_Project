#!/usr/bin/env bash
# Run once after git clone on the supercomputer.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/hpc/bootstrap.sh" "$@"
