#!/usr/bin/env bash
# Build npu_wrapper on Linux (login node or dev box with OpenVINO GenAI installed).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if [[ -f "${OPENVINO_GENAI_DIR:-}/setupvars.sh" ]]; then
  # shellcheck source=/dev/null
  source "${OPENVINO_GENAI_DIR}/setupvars.sh"
elif [[ -f "${INTEL_OPENVINO_DIR:-}/setupvars.sh" ]]; then
  # shellcheck source=/dev/null
  source "${INTEL_OPENVINO_DIR}/setupvars.sh"
fi

if [[ -z "${OpenVINO_DIR:-}" && -z "${OPENVINO_GENAI_DIR:-}" && -z "${INTEL_OPENVINO_DIR:-}" ]]; then
  echo "[build.sh] Set OPENVINO_GENAI_DIR (or INTEL_OPENVINO_DIR) to your OpenVINO GenAI Linux root, then:" >&2
  echo "  source \"\$OPENVINO_GENAI_DIR/setupvars.sh\"" >&2
  exit 1
fi

command -v cmake >/dev/null 2>&1 || { echo "[build.sh] cmake not found" >&2; exit 1; }

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc 2>/dev/null || echo 4)"

mkdir -p dist
BIN=""
for candidate in build/npu_wrapper build/Release/npu_wrapper; do
  if [[ -x "$candidate" ]]; then
    BIN="$candidate"
    break
  fi
done
if [[ -z "$BIN" ]]; then
  echo "[build.sh] Build finished but npu_wrapper binary not found." >&2
  exit 1
fi
cp -f "$BIN" dist/npu_wrapper
chmod +x dist/npu_wrapper

# Stage OpenVINO runtime libs next to the binary when using a local GenAI tree.
if [[ -n "${OPENVINO_GENAI_DIR:-}" && -d "${OPENVINO_GENAI_DIR}/runtime/lib/intel64" ]]; then
  cp -a "${OPENVINO_GENAI_DIR}/runtime/lib/intel64/"*.so* dist/ 2>/dev/null || true
fi

echo "[build.sh] OK: dist/npu_wrapper"
