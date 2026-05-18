#!/usr/bin/env bash
# Runtime LD_LIBRARY_PATH for OpenVINO 2026.1 on hosts with glibc < 2.34 (Ubuntu 20.04 login nodes).
# Sourced from setup_env.sh and run.sh.

_hpc_glibc_max() {
  local libc="${1:-/lib/x86_64-linux-gnu/libc.so.6}"
  [[ -f "$libc" ]] || { echo "0.0"; return; }
  strings "$libc" 2>/dev/null | sed -n 's/^GLIBC_//p' | sort -Vu | tail -1
}

_hpc_ver_ge() {
  python3 - "$1" "$2" <<'PY'
import sys
def p(v):
    return tuple(int(x) for x in v.split(".")[:3])
sys.exit(0 if p(sys.argv[1]) >= p(sys.argv[2]) else 1)
PY
}

hpc_export_runtime_ldpath() {
  local parts=()
  local glibc_max
  glibc_max="$(_hpc_glibc_max)"

  # Conda sysroot: same fix as build (OpenVINO ubuntu22 needs glibc >= 2.34 at runtime).
  if ! _hpc_ver_ge "${glibc_max:-0.0}" "2.34"; then
    if [[ -n "${CONDA_PREFIX:-}" ]]; then
      local sysroot="${CONDA_PREFIX}/x86_64-conda-linux-gnu/sysroot/lib64"
      if [[ -d "$sysroot" ]]; then
        parts+=("$sysroot" "${CONDA_PREFIX}/lib")
        echo "[hpc] Runtime: prepending conda sysroot (host glibc ${glibc_max} < 2.34)" >&2
      else
        echo "[hpc] WARNING: host glibc ${glibc_max} < 2.34 and conda sysroot missing." >&2
        echo "[hpc]   conda install -c conda-forge gcc_linux-64=12 gxx_linux-64=12 sysroot_linux-64" >&2
        echo "[hpc]   Or run on a compute node with Ubuntu 22.04+ / glibc >= 2.34." >&2
      fi
    else
      echo "[hpc] WARNING: host glibc ${glibc_max} < 2.34. Activate conda (base) or use a newer node." >&2
    fi
  fi

  if [[ -n "${OPENVINO_GENAI_DIR:-}" && -d "${OPENVINO_GENAI_DIR}/runtime/lib/intel64" ]]; then
    parts+=("${OPENVINO_GENAI_DIR}/runtime/lib/intel64")
  fi
  if [[ -n "${ACOULM_HOME:-}" && -d "${ACOULM_HOME}/dist" ]]; then
    parts+=("${ACOULM_HOME}/dist")
  fi

  local joined=""
  local p
  for p in "${parts[@]}"; do
    joined="${joined:+$joined:}$p"
  done
  if [[ -n "$joined" ]]; then
    export LD_LIBRARY_PATH="${joined}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  fi
}
