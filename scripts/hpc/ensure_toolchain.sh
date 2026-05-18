#!/usr/bin/env bash
# Prepare a new enough GCC + glibc sysroot to link OpenVINO GenAI 2026.1 on older HPC login nodes.
# OpenVINO ubuntu22 archives need glibc >= 2.34 and libstdc++ from GCC 11+ (GLIBCXX_3.4.29+).
#
# Usage (sourced from build.sh):
#   source scripts/hpc/ensure_toolchain.sh
set -euo pipefail

# shellcheck source=glibc_util.sh
source "$(dirname "${BASH_SOURCE[0]}")/glibc_util.sh"
_hpc_glibc_max() { hpc_glibc_max "$@"; }
_hpc_ver_ge() { hpc_ver_ge "$@"; }

_hpc_try_module_gcc() {
  if ! command -v module >/dev/null 2>&1; then
    return 1
  fi
  local mods
  mods="$(module -t avail gcc 2>&1 || true)"
  for guess in gcc/13 gcc/12 gcc/11 gcc; do
    if echo "$mods" | grep -qx "$guess"; then
      # shellcheck disable=SC1090
      module load "$guess"
      if command -v g++ >/dev/null 2>&1; then
        echo "[toolchain] module load $guess ($(g++ --version | head -1))"
        return 0
      fi
    fi
  done
  return 1
}

_hpc_setup_conda_toolchain() {
  if [[ -z "${CONDA_PREFIX:-}" ]] || ! command -v conda >/dev/null 2>&1; then
    return 1
  fi
  echo "[toolchain] Installing conda gcc 12 + sysroot (one-time; links OpenVINO 2026.1 on Ubuntu 20.04 nodes)..."
  conda install -y -c conda-forge \
    gcc_linux-64=12 gxx_linux-64=12 \
    sysroot_linux-64 \
    libstdcxx-ng \
    libgcc-ng \
    >/dev/null

  local triplet="x86_64-conda-linux-gnu"
  local sysroot="${CONDA_PREFIX}/${triplet}/sysroot"
  local gcc="${CONDA_PREFIX}/bin/${triplet}-gcc"
  local gxx="${CONDA_PREFIX}/bin/${triplet}-g++"
  if [[ ! -x "$gxx" || ! -d "$sysroot/lib64" ]]; then
    echo "[toolchain] conda toolchain install incomplete." >&2
    return 1
  fi

  export CC="$gcc"
  export CXX="$gxx"
  export CONDA_BUILD_SYSROOT="$sysroot"
  export CFLAGS="--sysroot=${sysroot} ${CFLAGS:-}"
  export CXXFLAGS="--sysroot=${sysroot} ${CXXFLAGS:-}"
  export LDFLAGS="-Wl,-rpath,${CONDA_PREFIX}/lib -Wl,-rpath-link,${sysroot}/lib64 -L${sysroot}/lib64 -L${CONDA_PREFIX}/lib ${LDFLAGS:-}"
  # Do not export LD_LIBRARY_PATH here — it breaks bash/git/python on the host shell.
  echo "[toolchain] Using conda $("$gxx" -dumpversion) with sysroot $(basename "$sysroot")"
  return 0
}

hpc_ensure_toolchain() {
  local glibc_max
  glibc_max="$(_hpc_glibc_max)"
  echo "[toolchain] Host glibc max: ${glibc_max:-unknown}"

  if _hpc_ver_ge "${glibc_max:-0.0}" "2.34"; then
    if _hpc_try_module_gcc; then
      :
    elif [[ -z "${CXX:-}" ]]; then
      export CXX="${CXX:-g++}"
      export CC="${CC:-gcc}"
    fi
    echo "[toolchain] Host glibc is new enough for OpenVINO 2026.1."
    return 0
  fi

  echo "[toolchain] Host glibc < 2.34 — OpenVINO 2026.1 ubuntu22 binaries need a newer toolchain/sysroot." >&2

  if _hpc_try_module_gcc && _hpc_ver_ge "$(_hpc_glibc_max)" "2.34"; then
    echo "[toolchain] Loaded module gcc with adequate glibc."
    return 0
  fi

  if _hpc_setup_conda_toolchain; then
    return 0
  fi

  cat >&2 <<'EOF'
[toolchain] Cannot link OpenVINO GenAI 2026.1 on this node.

Options:
  1) conda install -c conda-forge gcc_linux-64=12 gxx_linux-64=12 sysroot_linux-64
     then: source scripts/hpc/setup_env.sh && ./build.sh
  2) module load gcc/12 (or newer) if your site provides it
  3) Build inside Ubuntu 22.04+ (Apptainer/Singularity) or on a newer login node
  4) Run jobs on compute nodes with glibc >= 2.34 (runtime must match)

Check: strings /lib/x86_64-linux-gnu/libc.so.6 | grep GLIBC_2.34
EOF
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  hpc_ensure_toolchain
fi
