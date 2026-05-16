#!/bin/bash
#SBATCH --job-name=acoulm
#SBATCH --output=acoulm-%j.out
#SBATCH --error=acoulm-%j.err
#SBATCH --time=04:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --gres=gpu:1
#SBATCH --mem=64G

set -euo pipefail
cd "${SLURM_SUBMIT_DIR:-$PWD}"

./hpc-setup.sh
source scripts/hpc/setup_env.sh

# Build on the login node first (recommended). Uncomment to rebuild inside the job:
# ./build.sh

export ACOULM_MODEL="${ACOULM_MODEL:-./models/Qwen2.5-3B-Instruct}"
export ACOULM_PORT="${ACOULM_PORT:-8000}"
export ACOULM_DEVICE="${ACOULM_DEVICE:-GPU}"

echo "Node: $(hostname)"
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-}"
nvidia-smi || true

bash scripts/hpc/start_server.sh
