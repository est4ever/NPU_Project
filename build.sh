#!/usr/bin/env bash
# Build npu_wrapper on Linux (login node or dev box with OpenVINO GenAI installed).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# Poisoned LD_LIBRARY_PATH (conda sysroot) breaks cmake, basename, and glibc detection.
if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
  echo "[build.sh] Unsetting inherited LD_LIBRARY_PATH (conda sysroot breaks host tools)." >&2
  unset LD_LIBRARY_PATH
fi

# shellcheck source=scripts/hpc/openvino_env.sh
source "$ROOT/scripts/hpc/openvino_env.sh"

# HPC paths (gitignored) — same as setup_env.sh
if [[ -f "$ROOT/scripts/hpc/local_env.sh" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/hpc/local_env.sh"
fi
if [[ -z "${OPENVINO_GENAI_DIR:-}" && -f "${HOME}/openvino_genai/setupvars.sh" ]]; then
  export OPENVINO_GENAI_DIR="${HOME}/openvino_genai"
fi

if [[ -f "${OPENVINO_GENAI_DIR:-}/setupvars.sh" ]]; then
  source_openvino_setupvars "${OPENVINO_GENAI_DIR}"
elif [[ -f "${INTEL_OPENVINO_DIR:-}/setupvars.sh" ]]; then
  source_openvino_setupvars "${INTEL_OPENVINO_DIR}"
fi

# setupvars may prepend long LD_LIBRARY_PATH; conda sysroot entries break host cmake — drop them.
if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
  _lp_clean=""
  IFS=':' read -ra _lp_parts <<<"${LD_LIBRARY_PATH}"
  for _p in "${_lp_parts[@]}"; do
    [[ "$_p" == *conda-linux-gnu/sysroot* ]] && continue
    [[ -z "$_p" ]] && continue
    _lp_clean="${_lp_clean:+${_lp_clean}:}${_p}"
  done
  export LD_LIBRARY_PATH="${_lp_clean}"
fi

if [[ -z "${OpenVINO_DIR:-}" && -z "${OPENVINO_GENAI_DIR:-}" && -z "${INTEL_OPENVINO_DIR:-}" ]]; then
  echo "[build.sh] Set OPENVINO_GENAI_DIR (or INTEL_OPENVINO_DIR) to your OpenVINO GenAI Linux root." >&2
  echo "[build.sh] Easiest:  echo 'export OPENVINO_GENAI_DIR=\$HOME/openvino_genai' >> scripts/hpc/local_env.sh" >&2
  echo "[build.sh] Or:       source scripts/hpc/setup_env.sh && ./build.sh" >&2
  exit 1
fi

cmake_version_ge() {
  python3 - "$1" "$2" <<'PY'
import re, sys

def parse(v):
    m = re.match(r"^(\d+)\.(\d+)(?:\.(\d+))?", str(v).strip())
    if not m:
        return (0, 0, 0)
    a, b, c = int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)
    return (a, b, c)

a, b = parse(sys.argv[1]), parse(sys.argv[2])
sys.exit(0 if a >= b else 1)
PY
}

ensure_cmake_318() {
  # Prefer conda cmake when system /usr/bin is too old (common on HPC login nodes).
  if [[ -n "${CONDA_PREFIX:-}" && -x "${CONDA_PREFIX}/bin/cmake" ]]; then
    export PATH="${CONDA_PREFIX}/bin:${PATH}"
  fi
  command -v cmake >/dev/null 2>&1 || {
    echo "[build.sh] cmake not found" >&2
    return 1
  }
  local ver
  ver="$(cmake --version | head -1 | awk '{print $3}')"
  if cmake_version_ge "$ver" "3.18.0"; then
    echo "[build.sh] cmake $ver"
    return 0
  fi
  echo "[build.sh] cmake $ver is too old (need >= 3.18)." >&2
  echo "[build.sh] On the cluster with conda:  conda install -c conda-forge 'cmake>=3.18'" >&2
  echo "[build.sh] Or: module avail cmake && module load cmake/3.28  (site-specific)" >&2
  return 1
}

ensure_cmake_318

# OpenVINO 2026.1 prebuilts need glibc >= 2.34 (ubuntu22 archive).
# shellcheck source=scripts/hpc/ensure_toolchain.sh
source "$ROOT/scripts/hpc/ensure_toolchain.sh"
hpc_ensure_toolchain

CMAKE_ARGS=(-S . -B build -DCMAKE_BUILD_TYPE=Release)
if [[ -n "${CC:-}" ]]; then CMAKE_ARGS+=(-DCMAKE_C_COMPILER="$CC"); fi
if [[ -n "${CXX:-}" ]]; then CMAKE_ARGS+=(-DCMAKE_CXX_COMPILER="$CXX"); fi
if [[ -n "${CONDA_BUILD_SYSROOT:-}" ]]; then
  CMAKE_ARGS+=(
    -DCMAKE_SYSROOT="$CONDA_BUILD_SYSROOT"
    -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS:-}"
    -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS:-}"
  )
fi

# Re-configure when compiler/sysroot changes.
cmake "${CMAKE_ARGS[@]}"
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

# Stage OpenVINO runtime libs next to the binary (Linux: replace stale copies when switching OV version).
if [[ -n "${OPENVINO_GENAI_DIR:-}" && -d "${OPENVINO_GENAI_DIR}/runtime/lib/intel64" ]]; then
  rm -f dist/libopenvino*.so* dist/libopenvino*.so dist/libtbb*.so* dist/libhwloc*.so* 2>/dev/null || true
  cp -a "${OPENVINO_GENAI_DIR}/runtime/lib/intel64/"*.so* dist/ 2>/dev/null || true
fi

echo "[build.sh] OK: dist/npu_wrapper"
