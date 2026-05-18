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
source "$ROOT/scripts/hpc/runtime_libs.sh"  # defines hpc_exec_backend

resolve_backend() {
  local reg="${ROOT}/registry/backends_registry.json"
  local default="${ROOT}/dist/npu_wrapper"
  local default_type="builtin"
  if [[ ! -f "$reg" ]]; then
    echo "$default"
    echo "$default_type"
    return
  fi
  python3 - <<'PY' "$reg" "$ROOT" 2>/dev/null || { echo "$default"; echo "$default_type"; return; }
import json, sys, os
reg, root = sys.argv[1], sys.argv[2]
with open(reg) as f:
    data = json.load(f)
sel = data.get("selected_backend", "")
entry = "dist/npu_wrapper"
btype = "builtin"
for b in data.get("backends", []):
    if b.get("id") == sel:
        entry = b.get("entrypoint", entry)
        btype = b.get("type", "builtin") or "builtin"
        break
entry = entry.replace("\\", "/").replace(".exe", "")
if not os.path.isabs(entry):
    entry = os.path.join(root, entry)
print(entry)
print(btype)
PY
}

mapfile -t _be < <(resolve_backend)
TARGET="${_be[0]}"
BTYPE="${_be[1]:-builtin}"

if [[ "$BTYPE" == "builtin" ]]; then
  if [[ -f "${OPENVINO_GENAI_DIR:-}/setupvars.sh" ]]; then
    source_openvino_setupvars "${OPENVINO_GENAI_DIR}"
  elif [[ -f "${INTEL_OPENVINO_DIR:-}/setupvars.sh" ]]; then
    source_openvino_setupvars "${INTEL_OPENVINO_DIR}"
  fi
fi

if [[ ! -x "$TARGET" ]]; then
  if [[ "$BTYPE" == "builtin" && -x "${ROOT}/build/npu_wrapper" ]]; then
    TARGET="${ROOT}/build/npu_wrapper"
  elif [[ "$BTYPE" == "builtin" && -x "${ROOT}/build/Release/npu_wrapper" ]]; then
    TARGET="${ROOT}/build/Release/npu_wrapper"
  elif [[ -f "$TARGET" ]]; then
    chmod +x "$TARGET" 2>/dev/null || true
  else
    echo "[run.sh] Backend not found: $TARGET" >&2
    if [[ "$BTYPE" == "builtin" ]]; then
      echo "[run.sh] Build first: ./build.sh" >&2
    fi
    exit 1
  fi
fi

if [[ "$BTYPE" == "builtin" && "${ACOULM_SNAPPY:-1}" != "0" ]]; then
  export ACOULM_SNAPPY=1
  export ACOULM_PERFORMANCE_MODE=1
  export ACOULM_FAST_LOAD=1
  export ACOULM_GPU_TIER="${ACOULM_GPU_TIER:-discrete}"
  mkdir -p "${ACOULM_HOME}/gpu_cache"
  export OV_CACHE_DIR="${OV_CACHE_DIR:-${ACOULM_HOME}/gpu_cache}"
fi

echo "[run.sh] backend=$BTYPE target=$TARGET $*"
if [[ "$BTYPE" == "external" ]]; then
  exec "$TARGET" "$@"
else
  hpc_exec_backend "$TARGET" "$@"
fi
