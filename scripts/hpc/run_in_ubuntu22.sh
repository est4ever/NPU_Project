#!/usr/bin/env bash
# Run acoulm start inside Ubuntu 22.04 when host is Ubuntu 20.04 (glibc < 2.34).
# Requires Apptainer/Singularity OR Docker.
#
#   bash scripts/hpc/run_in_ubuntu22.sh
#   bash scripts/hpc/run_in_ubuntu22.sh acoulm chat "hi"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACOULM_HOME="${ACOULM_HOME:-$ROOT}"
OV="${OPENVINO_GENAI_DIR:-$HOME/openvino_genai}"
MODEL="${ACOULM_MODEL:-$ACOULM_HOME/models/Qwen2.5-3B-Instruct}"
INNER="${1:-start}"
shift || true

if [[ ! -f "$OV/setupvars.sh" ]]; then
  echo "[apptainer] Install OpenVINO first: bash scripts/hpc/install_openvino_genai.sh" >&2
  exit 1
fi
if [[ ! -x "$ACOULM_HOME/dist/npu_wrapper" ]]; then
  echo "[apptainer] Build first on host: source scripts/hpc/setup_env.sh && ./build.sh" >&2
  exit 1
fi

_run_apptainer() {
  apptainer exec --nv \
    -B "$ACOULM_HOME:$ACOULM_HOME" \
    -B "$OV:$OV" \
    -B "$HOME:$HOME" \
    docker://ubuntu:22.04 \
    bash -lc "
      set -e
      apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl libgomp1 >/dev/null
      export ACOULM_HOME='$ACOULM_HOME' OPENVINO_GENAI_DIR='$OV' ACOULM_MODEL='$MODEL'
      export LD_LIBRARY_PATH='$OV/runtime/lib/intel64:$ACOULM_HOME/dist'
      cd '$ACOULM_HOME'
      if [[ '$INNER' == start ]]; then
        exec '$ACOULM_HOME/dist/npu_wrapper' '$MODEL' --server --port 8000 --policy PERFORMANCE --device GPU
      else
        exec '$ACOULM_HOME/acoulm.sh' '$INNER' \"\$@\"
      fi
    " -- "$@"
}

_run_docker() {
  docker run --rm -it --gpus all \
    -v "$ACOULM_HOME:$ACOULM_HOME" \
    -v "$OV:$OV" \
    -e ACOULM_HOME="$ACOULM_HOME" \
    -e OPENVINO_GENAI_DIR="$OV" \
    -e ACOULM_MODEL="$MODEL" \
    -e LD_LIBRARY_PATH="$OV/runtime/lib/intel64:$ACOULM_HOME/dist" \
  ubuntu:22.04 \
    bash -lc "apt-get update -qq && apt-get install -y -qq curl libgomp1 && cd '$ACOULM_HOME' && ./acoulm.sh $INNER \"\$@\"" -- "$@"
}

if command -v apptainer >/dev/null 2>&1; then
  _run_apptainer "$@"
elif command -v singularity >/dev/null 2>&1; then
  apptainer() { singularity "$@"; }
  _run_apptainer "$@"
elif command -v docker >/dev/null 2>&1; then
  _run_docker "$@"
else
  echo "[apptainer] Need apptainer, singularity, or docker." >&2
  echo "[apptainer] Or upgrade host OS to Ubuntu 22.04+ (glibc >= 2.34)." >&2
  exit 1
fi
