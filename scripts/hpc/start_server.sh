#!/usr/bin/env bash
# Start OpenVINO REST API on a compute node (foreground). Use with srun or inside sbatch.
set -euo pipefail

HPC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HPC_DIR}/setup_env.sh"

MODEL="${ACOULM_MODEL:?Set ACOULM_MODEL to your model directory or .gguf path}"
PORT="${ACOULM_PORT:-8000}"
DEVICE="${ACOULM_DEVICE:-GPU}"

EXTRA=()
if [[ -n "${ACOULM_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  EXTRA=(${ACOULM_EXTRA_ARGS})
fi

echo "[hpc] Starting server on 0.0.0.0:${PORT} (device=${DEVICE})"
exec "${ACOULM_HOME}/run.sh" "$MODEL" \
  --server \
  --port "$PORT" \
  --policy PERFORMANCE \
  --device "$DEVICE" \
  "${EXTRA[@]}"
