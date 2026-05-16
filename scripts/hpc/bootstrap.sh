#!/usr/bin/env bash
# One-time setup after git clone on Linux/HPC. Usage: ./scripts/hpc/bootstrap.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

copy_if_missing() {
  local src="$1"
  local dst="$2"
  if [[ ! -f "$dst" ]]; then
    cp "$src" "$dst"
    echo "[bootstrap] Created $dst"
  else
    echo "[bootstrap] Exists  $dst"
  fi
}

mkdir -p registry models gpu_cache export

copy_if_missing "registry/backends_registry.linux.example.json" "registry/backends_registry.json"
copy_if_missing "registry/models_registry.example.json" "registry/models_registry.json"
copy_if_missing "registry/performance_profile.example.json" "registry/performance_profile.json"

chmod +x build.sh run.sh restart_backend.sh restart_stack.sh npu_cli.sh hpc-setup.sh 2>/dev/null || true
chmod +x scripts/hpc/*.sh 2>/dev/null || true

cat <<'EOF'

[bootstrap] Done.

Next on this machine:
  1) ./portable_setup.sh
     (asks for OpenVINO folder, model path, backend — like Windows)

  2) source scripts/hpc/setup_env.sh && ./build.sh

  3) sbatch scripts/hpc/slurm_acoulm.sbatch
     (or: bash scripts/hpc/start_server.sh on an interactive GPU node)

  4) From your laptop:
     ssh -L 8000:<compute-host>:8000 user@cluster
     export ACOULM_API_BASE=http://127.0.0.1:8000
     ./npu_cli.sh chat "Hello"

EOF
