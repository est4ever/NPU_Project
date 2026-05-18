#!/usr/bin/env bash
# Copy to scripts/hpc/local_env.sh and customize for your supercomputer.

# module load gcc/12
# module load cmake/3.28    # if system cmake is 3.16 (AcouLM needs >= 3.18)
# Or: conda install -c conda-forge 'cmake>=3.18'

export OPENVINO_GENAI_DIR=/path/to/openvino_genai_linux
export ACOULM_MODEL=/scratch/$USER/models/Qwen2.5-3B-Instruct
export ACOULM_DEVICE=GPU
