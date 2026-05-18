#!/usr/bin/env bash
# AcouLM backend launcher (Linux / HPC). Usage:
#   ./run.sh ./models/Qwen2.5-3B-Instruct --server --port 8000 --policy PERFORMANCE --device GPU
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

export ACOULM_HOME="${ACOULM_HOME:-$ROOT}"
# shellcheck source=scripts/hpc/openvino_env.sh
source "$ROOT/scripts/hpc/openvino_env.sh"
# shellcheck source=scripts/hpc/runtime_libs.sh
source "$ROOT/scripts/hpc/runtime_libs.sh"

if [[ -f "${OPENVINO_GENAI_DIR:-}/setupvars.sh" ]]; then
  source_openvino_setupvars "${OPENVINO_GENAI_DIR}"
elif [[ -f "${INTEL_OPENVINO_DIR:-}/setupvars.sh" ]]; then
  source_openvino_setupvars "${INTEL_OPENVINO_DIR}"
fi

resolve_backend_exe() {
  local reg="${ROOT}/registry/backends_registry.json"
  local default="${ROOT}/dist/npu_wrapper"
  if [[ ! -f "$reg" ]]; then
    echo "$default"
    return
  fi
  python3 - <<'PY' "$reg" "$ROOT" 2>/dev/null || echo "$default"
import json, sys, os
reg, root = sys.argv[1], sys.argv[2]
with open(reg) as f:
    data = json.load(f)
sel = data.get("selected_backend", "")
entry = "dist/npu_wrapper"
for b in data.get("backends", []):
    if b.get("id") == sel:
        entry = b.get("entrypoint", entry)
        break
entry = entry.replace("\\", "/").replace(".exe", "")
if not os.path.isabs(entry):
    entry = os.path.join(root, entry)
print(entry)
PY
}

TARGET="$(resolve_backend_exe)"
if [[ ! -x "$TARGET" ]]; then
  if [[ -x "${ROOT}/build/npu_wrapper" ]]; then
    TARGET="${ROOT}/build/npu_wrapper"
  elif [[ -x "${ROOT}/build/Release/npu_wrapper" ]]; then
    TARGET="${ROOT}/build/Release/npu_wrapper"
  else
    echo "[run.sh] Backend not found. Build first: ./build.sh" >&2
    exit 1
  fi
fi

hpc_export_runtime_ldpath

if [[ "${ACOULM_SNAPPY:-1}" != "0" ]]; then
  export ACOULM_SNAPPY=1
  export ACOULM_PERFORMANCE_MODE=1
  export ACOULM_FAST_LOAD=1
  export ACOULM_GPU_TIER="${ACOULM_GPU_TIER:-discrete}"
  mkdir -p "${ACOULM_HOME}/gpu_cache"
  export OV_CACHE_DIR="${OV_CACHE_DIR:-${ACOULM_HOME}/gpu_cache}"
fi

echo "[run.sh] $TARGET $*"
exec "$TARGET" "$@"
