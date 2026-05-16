#!/usr/bin/env bash
# Copy to scripts/hpc/local_env.sh and customize for your supercomputer.

# module load ...

export OPENVINO_GENAI_DIR=/path/to/openvino_genai_linux
export ACOULM_MODEL=/scratch/$USER/models/Qwen2.5-3B-Instruct
export ACOULM_DEVICE=GPU
