#!/usr/bin/env bash
# Linux / HPC launcher — same idea as acoulm.ps1 + acoulm.cmd on Windows.
# One-time:  acoulm setup   (adds ~/.local/bin/acoulm to PATH)
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
  chmod +x "${root}/acoulm.sh" "${root}/build.sh" "${root}/run.sh" "${root}/npu_cli.sh" 2>/dev/null || true
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
}

acoulm_help() {
  cat <<'EOF'
AcouLM (Linux / HPC)

  acoulm setup          Install ~/.local/bin/acoulm (PATH)
  acoulm build          Build dist/npu_wrapper
  acoulm start          Start API on this node (needs GPU + setup_env)
  acoulm chat [msg]     Talk to API (set ACOULM_API_BASE if tunneled)
  acoulm status         API / model status
  acoulm help

HPC workflow:
  source scripts/hpc/setup_env.sh
  sbatch scripts/hpc/slurm_acoulm.sbatch
  ssh -L 8000:<compute-node>:8000 user@cluster
  export ACOULM_API_BASE=http://127.0.0.1:8000
  acoulm chat "Hello"

Windows UI (start_app, panel) is not used on the cluster.
EOF
}

ROOT="$(acoulm_find_root || true)"
CMD="${1:-help}"
shift || true

case "$CMD" in
  setup)
    if [[ -z "$ROOT" ]]; then
      echo "[acoulm] Run from your AcouLM clone (need npu_cli.sh)." >&2
      exit 1
    fi
    acoulm_setup "$ROOT"
    ;;
  help|-h|--help)
    acoulm_help
    ;;
  build)
    [[ -n "$ROOT" ]] || { echo "[acoulm] ACOULM_HOME not set." >&2; exit 1; }
    export ACOULM_HOME="$ROOT"
    if [[ -f "$ROOT/scripts/hpc/setup_env.sh" ]]; then
      # shellcheck source=/dev/null
      source "$ROOT/scripts/hpc/setup_env.sh"
    fi
    exec "$ROOT/build.sh"
    ;;
  start)
    [[ -n "$ROOT" ]] || { echo "[acoulm] ACOULM_HOME not set." >&2; exit 1; }
    export ACOULM_HOME="$ROOT"
    exec bash "$ROOT/scripts/hpc/start_server.sh"
    ;;
  chat|status|health)
    [[ -n "$ROOT" ]] || { echo "[acoulm] ACOULM_HOME not set." >&2; exit 1; }
    export ACOULM_HOME="$ROOT"
    exec "$ROOT/npu_cli.sh" "$CMD" "$@"
    ;;
  *)
    if [[ -z "$ROOT" ]]; then
      echo "[acoulm] Unknown command and AcouLM root not found. Run: acoulm setup" >&2
      acoulm_help
      exit 1
    fi
    # Bare message: acoulm "hello"
    export ACOULM_HOME="$ROOT"
    exec "$ROOT/npu_cli.sh" chat "$CMD" "$@"
    ;;
esac
