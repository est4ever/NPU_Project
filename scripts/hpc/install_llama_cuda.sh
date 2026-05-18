#!/usr/bin/env bash
# Build llama.cpp llama-server with CUDA (for AcouLM cuda-llama backend).
#
# Usage:
#   bash scripts/hpc/install_llama_cuda.sh
#   export LLAMA_SERVER=$HOME/llama.cpp/build/bin/llama-server
set -euo pipefail

LLAMA_ROOT="${LLAMA_CPP_ROOT:-$HOME/llama.cpp}"
JOBS="${LLAMA_BUILD_JOBS:-$(nproc 2>/dev/null || echo 4)}"

if ! command -v nvcc &>/dev/null && ! command -v nvidia-smi &>/dev/null; then
  echo "[llama] WARN: nvidia-smi/nvcc not found — build may still work if CUDA toolkit is installed" >&2
fi

if [[ ! -d "$LLAMA_ROOT/.git" ]]; then
  echo "[llama] Cloning llama.cpp into $LLAMA_ROOT ..."
  git clone --depth 1 https://github.com/ggerganov/llama.cpp.git "$LLAMA_ROOT"
else
  echo "[llama] Updating $LLAMA_ROOT ..."
  git -C "$LLAMA_ROOT" pull --ff-only || true
fi

echo "[llama] Configuring CMake (GGML_CUDA=ON) ..."
cmake -S "$LLAMA_ROOT" -B "$LLAMA_ROOT/build" \
  -DGGML_CUDA=ON \
  -DCMAKE_BUILD_TYPE=Release

echo "[llama] Building llama-server (-j$JOBS) ..."
cmake --build "$LLAMA_ROOT/build" --target llama-server -j"$JOBS"

BIN="$LLAMA_ROOT/build/bin/llama-server"
if [[ ! -x "$BIN" ]]; then
  echo "[llama] Build failed: missing $BIN" >&2
  exit 1
fi

echo ""
echo "[llama] OK: $BIN"
echo "[llama] Add to scripts/hpc/local_env.sh:"
echo "  export LLAMA_SERVER=$BIN"
echo "  export ACOULM_CUDA_DEVICES=0   # or 0,1,2,3 for multi-GPU"
echo ""
echo "[llama] Then: bash scripts/hpc/use_cuda_backend.sh"
