#!/usr/bin/env bash
# Copy to scripts/hpc/local_env.sh and customize for your machine.
# Daily use: run  acoulm  (starts API + browser panel + terminal chat).

# module load gcc/12
# module load cmake/3.28    # if system cmake is 3.16 (AcouLM needs >= 3.18)
# Or: conda install -c conda-forge 'cmake>=3.18'

export OPENVINO_GENAI_DIR=/path/to/openvino_genai_linux
export ACOULM_MODEL=/scratch/$USER/models/Qwen2.5-3B-Instruct
export ACOULM_DEVICE=GPU

# Security (defaults are safe for laptop + SSH tunnel)
# export ACOULM_BIND_HOST=127.0.0.1
# If you must listen on all interfaces (trusted LAN only):
# export ACOULM_BIND_HOST=0.0.0.0
# export ACOULM_API_TOKEN=$(openssl rand -hex 32)

# CUDA backend (after: acoulm use-cuda) — must be a .gguf path, not HF/IR folder
# export ACOULM_MODEL=$HOME/AcouLM/models/Qwen3.6-27B-gguf/Qwen_Qwen3.6-27B-Q4_K_M.gguf
# export LLAMA_SERVER=$HOME/llama.cpp/build/bin/llama-server
# export ACOULM_CUDA_DEVICES=0
# export LLAMA_CTX=4096
# export LLAMA_PARALLEL=1
# export LLAMA_REASONING=off
# export LLAMA_CACHE_RAM=0
