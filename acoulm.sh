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
  acoulm start          Start API on this node (leave that terminal open)
  acoulm chat           Interactive terminal chat
  acoulm chat "..."     One-shot message
  acoulm status         API / model status
  acoulm cuda-setup     Build llama.cpp llama-server with CUDA (NVIDIA)
  acoulm use-cuda       Switch registry to cuda-llama backend (needs GGUF)
  acoulm use-openvino   Switch registry back to OpenVINO (Intel CPU/GPU/NPU)
  acoulm help

NVIDIA GPUs (4x RTX, etc.): OpenVINO builtin cannot use them. Use cuda-setup + use-cuda + a GGUF model.

HPC workflow:
  source scripts/hpc/setup_env.sh
  sbatch scripts/hpc/slurm_acoulm.sbatch
  ssh -L 8000:<compute-node>:8000 user@cluster
  export ACOULM_API_BASE=http://127.0.0.1:8000
  acoulm chat

One-time:  acoulm setup   then  source ~/.bashrc   (use "acoulm", not "bash acoulm.sh")

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
  cuda-setup)
    [[ -n "$ROOT" ]] || { echo "[acoulm] ACOULM_HOME not set." >&2; exit 1; }
    exec bash "$ROOT/scripts/hpc/install_llama_cuda.sh"
    ;;
  use-cuda)
    [[ -n "$ROOT" ]] || { echo "[acoulm] ACOULM_HOME not set." >&2; exit 1; }
    exec bash "$ROOT/scripts/hpc/use_cuda_backend.sh"
    ;;
  use-openvino)
    [[ -n "$ROOT" ]] || { echo "[acoulm] ACOULM_HOME not set." >&2; exit 1; }
    python3 - "$ROOT/registry/backends_registry.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["selected_backend"] = "openvino"
p.write_text(json.dumps(d, indent=2) + "\n")
print("[acoulm] selected_backend=openvino")
PY
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
