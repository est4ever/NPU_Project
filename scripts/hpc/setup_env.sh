#!/usr/bin/env bash
# Source on the cluster before build or run:  source scripts/hpc/setup_env.sh
# Copy to scripts/hpc/local_env.sh and edit module loads for your site.

ACOULM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ACOULM_HOME="${ACOULM_HOME:-$ACOULM_ROOT}"
cd "$ACOULM_HOME"
# shellcheck source=openvino_env.sh
source "$(dirname "${BASH_SOURCE[0]}")/openvino_env.sh"

if [[ ! -f "${ACOULM_HOME}/registry/backends_registry.json" ]]; then
  echo "[hpc] Run ./hpc-setup.sh first (creates registry files)." >&2
  exit 1
fi

# --- Site-specific (edit in local_env.sh) ---
if [[ -f "$(dirname "$0")/local_env.sh" ]]; then
  # shellcheck source=/dev/null
  source "$(dirname "$0")/local_env.sh"
elif [[ -f "$(dirname "$0")/local_env.example.sh" ]]; then
  echo "[hpc] Tip: copy scripts/hpc/local_env.example.sh to scripts/hpc/local_env.sh" >&2
  echo "[hpc]   Or re-run: bash scripts/hpc/linux_setup.sh" >&2
fi

# Default OpenVINO GenAI root from linux_setup / install_openvino_genai.sh
if [[ -z "${OPENVINO_GENAI_DIR:-}" && -f "${HOME}/openvino_genai/setupvars.sh" ]]; then
  export OPENVINO_GENAI_DIR="${HOME}/openvino_genai"
fi

# Git clone on Windows often drops +x on shell scripts
for _exe in build.sh run.sh hpc-setup.sh portable_setup.sh npu_cli.sh restart_backend.sh restart_stack.sh; do
  if [[ -f "${ACOULM_HOME}/${_exe}" && ! -x "${ACOULM_HOME}/${_exe}" ]]; then
    chmod +x "${ACOULM_HOME}/${_exe}"
  fi
done

# Example module lines (uncomment / edit for your supercomputer):
# module purge
# module load gcc/12 cuda/12.4
# module load openvino/2025.4  # if provided by the center

export ACOULM_SNAPPY=1
export ACOULM_PERFORMANCE_MODE=1
export ACOULM_FAST_LOAD=1
export ACOULM_GPU_TIER=discrete
export ACOULM_DEVICE="${ACOULM_DEVICE:-GPU}"

# Model: local_env.sh wins, else registry selected_model, else example default
if [[ -z "${ACOULM_MODEL:-}" ]]; then
  _reg_model="$(python3 - <<'PY' 2>/dev/null || true
import json, os
root = os.environ["ACOULM_HOME"]
path = os.path.join(root, "registry", "models_registry.json")
try:
    with open(path) as f:
        reg = json.load(f)
    sel = reg.get("selected_model")
    for m in reg.get("models", []):
        if m.get("id") == sel and m.get("path"):
            print(m["path"])
            break
except (OSError, json.JSONDecodeError, KeyError):
    pass
PY
)"
  if [[ -n "$_reg_model" ]]; then
    export ACOULM_MODEL="$_reg_model"
  else
    export ACOULM_MODEL="./models/Qwen2.5-3B-Instruct"
  fi
  unset _reg_model
fi
# Absolute model path for run.sh (avoid ././ under ACOULM_HOME)
if [[ -n "${ACOULM_MODEL:-}" ]]; then
  if [[ "$ACOULM_MODEL" == ./* ]]; then
    ACOULM_MODEL="${ACOULM_HOME}/${ACOULM_MODEL#./}"
  elif [[ "$ACOULM_MODEL" != /* ]]; then
    ACOULM_MODEL="${ACOULM_HOME}/${ACOULM_MODEL}"
  fi
  export ACOULM_MODEL="$(python3 -c "import os; print(os.path.normpath('''${ACOULM_MODEL}'''))")"
fi
export ACOULM_PORT="${ACOULM_PORT:-8000}"
export ACOULM_BIND_HOST="${ACOULM_BIND_HOST:-127.0.0.1}"

# OpenVINO GenAI root (required for build.sh / run.sh)
# export OPENVINO_GENAI_DIR=/path/to/openvino_genai_linux_...

mkdir -p "${ACOULM_HOME}/gpu_cache"
export OV_CACHE_DIR="${OV_CACHE_DIR:-${ACOULM_HOME}/gpu_cache}"

if [[ -n "${OPENVINO_GENAI_DIR:-}" && -f "${OPENVINO_GENAI_DIR}/setupvars.sh" ]]; then
  source_openvino_setupvars "${OPENVINO_GENAI_DIR}"
fi

_reg_id="$(python3 -c "
import json, os
p = os.path.join(os.environ['ACOULM_HOME'], 'registry', 'models_registry.json')
try:
    print(json.load(open(p)).get('selected_model', ''))
except Exception:
    pass
" 2>/dev/null || true)"
echo "[hpc] ACOULM_HOME=$ACOULM_HOME"
if [[ -n "$_reg_id" ]]; then
  echo "[hpc] ACOULM_MODEL=$ACOULM_MODEL (registry: $_reg_id)"
else
  echo "[hpc] ACOULM_MODEL=$ACOULM_MODEL"
fi
unset _reg_id
echo "[hpc] ACOULM_DEVICE=$ACOULM_DEVICE"
echo "[hpc] OPENVINO_GENAI_DIR=${OPENVINO_GENAI_DIR:-<not set>}"
