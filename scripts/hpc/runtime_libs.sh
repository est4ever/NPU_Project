#!/usr/bin/env bash
# Run OpenVINO GenAI without putting conda libc on LD_LIBRARY_PATH (breaks bash/git).

# shellcheck source=glibc_util.sh
source "$(dirname "${BASH_SOURCE[0]}")/glibc_util.sh"

hpc_openvino_library_path() {
  local parts=()
  # Prefer GenAI install over dist/*.so (dist may hold stale OpenVINO from an older build).
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

hpc_sysroot_glibc_max() {
  local sysroot="${CONDA_PREFIX:-}/x86_64-conda-linux-gnu/sysroot/lib64/libc.so.6"
  if [[ -f "$sysroot" ]]; then
    hpc_glibc_max "$sysroot"
  else
    echo "0.0"
  fi
}

hpc_exec_backend() {
  local target="$1"
  shift

  local ov_path
  ov_path="$(hpc_openvino_library_path)"
  local host_glibc
  host_glibc="$(hpc_glibc_max)"

  if hpc_ver_ge "${host_glibc:-0.0}" "2.34"; then
    if [[ -n "$ov_path" ]]; then
      export LD_LIBRARY_PATH="${ov_path}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    exec "$target" "$@"
  fi

  # Host glibc < 2.34: prefer OpenVINO *ubuntu20* build (matches Ubuntu 20.04 / glibc 2.31).
  if hpc_ver_ge "${host_glibc:-0.0}" "2.31"; then
    if [[ -n "$ov_path" ]]; then
      export LD_LIBRARY_PATH="${ov_path}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    echo "[hpc] Using system loader (glibc ${host_glibc}); OpenVINO must be ubuntu20 build." >&2
    exec "$target" "$@"
  fi

  local sysroot="${CONDA_PREFIX:-}/x86_64-conda-linux-gnu/sysroot/lib64"
  local loader="${sysroot}/ld-linux-x86-64.so.2"
  local sys_glibc
  sys_glibc="$(hpc_sysroot_glibc_max)"

  if [[ -x "$loader" ]] && hpc_ver_ge "${sys_glibc:-0.0}" "2.34"; then
    local lp="${sysroot}:${CONDA_PREFIX}/lib"
    if [[ -n "$ov_path" ]]; then
      lp="${lp}:${ov_path}"
    fi
    echo "[hpc] Launching via conda sysroot loader (host ${host_glibc}, sysroot ${sys_glibc})" >&2
    exec "$loader" --library-path "$lp" "$target" "$@"
  fi

  cat >&2 <<EOF
[hpc] ERROR: Cannot run OpenVINO 2026.1 on this machine (host glibc ${host_glibc}).

Fix (recommended): install the Ubuntu 20 OpenVINO GenAI archive (not ubuntu22):
  rm -rf "\${HOME}/openvino_genai"
  bash scripts/hpc/install_openvino_genai.sh

Then: source scripts/hpc/setup_env.sh && acoulm start

Your conda sysroot glibc is ${sys_glibc} (need >= 2.34 for ubuntu22 libs).
EOF
  return 1
}
