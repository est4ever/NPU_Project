#!/usr/bin/env bash
# Linux launcher — daily use: run `acoulm` only (same as acoulm.ps1 on Windows).
# One-time:  acoulm setup
set -euo pipefail

acoulm_find_root() {
  local d=""
  if [[ -n "${ACOULM_HOME:-}" && -f "${ACOULM_HOME}/npu_cli.sh" ]]; then
    echo "${ACOULM_HOME}"
    return 0
  fi
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$d/npu_cli.sh" ]]; then
    echo "$d"
    return 0
  fi
  return 1
}

acoulm_setup() {
  local root="$1"
  local bindir="${HOME}/.local/bin"
  local link="${bindir}/acoulm"
  mkdir -p "$bindir"
  ln -sf "${root}/acoulm.sh" "$link"
  chmod +x "${root}/acoulm.sh" "${root}/build.sh" "${root}/run.sh" "${root}/npu_cli.sh" \
    "${root}/scripts/linux/start_stack.sh" "${root}/scripts/linux/appshell_server.py" 2>/dev/null || true
  echo "[acoulm] Linked: $link -> ${root}/acoulm.sh"
  echo "[acoulm] Add to PATH (bash):"
  echo "  export PATH=\"\${HOME}/.local/bin:\$PATH\""
  echo "  export ACOULM_HOME=\"${root}\""
  if ! grep -qF '.local/bin' "${HOME}/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# AcouLM'
      echo 'export PATH="${HOME}/.local/bin:${PATH}"'
      echo "export ACOULM_HOME=\"${root}\""
    } >> "${HOME}/.bashrc"
    echo "[acoulm] Appended PATH + ACOULM_HOME to ~/.bashrc — run: source ~/.bashrc"
  fi
  echo "[acoulm] Then run:  acoulm"
  echo "[acoulm] Edit model/GPU paths:  ${root}/scripts/hpc/local_env.sh"
}

acoulm_no_args_hint() {
  echo "[AcouLM] Run acoulm with no arguments." >&2
  echo "[AcouLM] In terminal chat use /status or /exit (leading slash required)." >&2
}

acoulm_help() {
  cat <<'EOF'
AcouLM (Linux)

  acoulm              Start everything (API + panel in background, browser, terminal chat)
  acoulm setup        One-time: put acoulm on PATH

Configure once: copy scripts/hpc/local_env.example.sh -> scripts/hpc/local_env.sh
  (model path, LLAMA_SERVER, ACOULM_CUDA_DEVICES, etc.)

NVIDIA: registry backend cuda-llama + GGUF model (see scripts/hpc/use_cuda_backend.sh).
EOF
}

ROOT="$(acoulm_find_root || true)"
CMD="${1:-}"

if [[ -n "$CMD" ]]; then
  shift || true
fi

case "$CMD" in
  "")
    [[ -n "$ROOT" ]] || {
      echo "[acoulm] Cannot find AcouLM. cd to your clone and run: acoulm setup" >&2
      exit 1
    }
    export ACOULM_HOME="$ROOT"
    if [[ ! -f "${ROOT}/scripts/hpc/local_env.sh" ]]; then
      echo "[acoulm] Tip: create scripts/hpc/local_env.sh from local_env.example.sh" >&2
    fi
    exec bash "${ROOT}/scripts/linux/start_stack.sh"
    ;;
  setup)
    [[ -n "$ROOT" ]] || {
      echo "[acoulm] Run from your AcouLM clone (need npu_cli.sh)." >&2
      exit 1
    }
    acoulm_setup "$ROOT"
    ;;
  help|-h|--help)
    acoulm_help
    ;;
  *)
    acoulm_no_args_hint
    exit 1
    ;;
esac
