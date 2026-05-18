#!/usr/bin/env bash
# AcouLM external CUDA backend entrypoint (llama.cpp + NVIDIA).
# Registered in registry/backends_registry.json as type external.
#
# Needs GGUF weights (not OpenVINO IR). Install llama-server once:
#   bash scripts/hpc/install_llama_cuda.sh
#
# Enable:
#   bash scripts/hpc/use_cuda_backend.sh
#   export ACOULM_MODEL=/path/to/model.gguf
#   bash acoulm.sh start
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ACOULM_HOME="${ACOULM_HOME:-$ROOT}"

if [[ -f "${ROOT}/scripts/hpc/local_env.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/hpc/local_env.sh"
fi

PY="${ACOULM_CUDA_PYTHON:-python3}"
if [[ -n "${CONDA_PREFIX:-}" && -x "${CONDA_PREFIX}/bin/python" ]]; then
  PY="${CONDA_PREFIX}/bin/python"
fi

exec "$PY" "${ROOT}/scripts/cuda/acoulm_cuda_proxy.py" "$@"
