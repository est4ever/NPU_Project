#!/usr/bin/env bash
# Run OpenVINO 2026.1 on hosts with glibc < 2.34 WITHOUT poisoning LD_LIBRARY_PATH
# (never put conda sysroot libc on LD_LIBRARY_PATH — it breaks bash, python, git).

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

# OpenVINO + dist only — safe to export for a single backend process if needed.
hpc_openvino_library_path() {
  local parts=()
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
  echo "$joined"
}

# Exec backend only — uses conda sysroot dynamic linker when host glibc is too old.
hpc_exec_backend() {
  local target="$1"
  shift

  local ov_path
  ov_path="$(hpc_openvino_library_path)"
  local glibc_max
  glibc_max="$(_hpc_glibc_max)"

  if _hpc_ver_ge "${glibc_max:-0.0}" "2.34"; then
    if [[ -n "$ov_path" ]]; then
      export LD_LIBRARY_PATH="${ov_path}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    exec "$target" "$@"
  fi

  local sysroot="${CONDA_PREFIX:-}/x86_64-conda-linux-gnu/sysroot/lib64"
  local loader="${sysroot}/ld-linux-x86-64.so.2"
  if [[ ! -x "$loader" ]]; then
    echo "[hpc] ERROR: host glibc ${glibc_max} < 2.34 and no conda sysroot loader." >&2
    echo "[hpc]   conda install -c conda-forge gcc_linux-64=12 gxx_linux-64=12 sysroot_linux-64" >&2
    echo "[hpc]   Or run on a node with glibc >= 2.34 (Ubuntu 22.04+)." >&2
    return 1
  fi

  local lp="${sysroot}:${CONDA_PREFIX}/lib"
  if [[ -n "$ov_path" ]]; then
    lp="${lp}:${ov_path}"
  fi
  echo "[hpc] Launching backend via conda sysroot loader (host glibc ${glibc_max} < 2.34)" >&2
  exec "$loader" --library-path "$lp" "$target" "$@"
}
