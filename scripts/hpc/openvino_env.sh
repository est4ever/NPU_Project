#!/usr/bin/env bash
# Source Intel OpenVINO GenAI setupvars.sh safely from bash (set -u safe).

source_openvino_setupvars() {
  local ov_root="${1:-${OPENVINO_GENAI_DIR:-}}"
  local setupvars="${ov_root%/}/setupvars.sh"
  if [[ ! -f "$setupvars" ]]; then
    echo "[openvino] Missing $setupvars" >&2
    return 1
  fi
  # Intel setupvars.sh references python_version; fails under bash -u if unset.
  if [[ -z "${python_version:-}" ]]; then
    if [[ -n "${PYTHON_VERSION:-}" ]]; then
      export python_version="$PYTHON_VERSION"
    elif command -v python3 >/dev/null 2>&1; then
      export python_version="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')"
    else
      export python_version="3.10"
    fi
  fi
  local had_u=0
  if [[ $- == *u* ]]; then
    had_u=1
    set +u
  fi
  # shellcheck source=/dev/null
  source "$setupvars"
  if [[ $had_u -eq 1 ]]; then
    set -u
  fi
}
