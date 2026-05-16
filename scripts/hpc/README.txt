AcouLM on a remote supercomputer (Linux + SLURM)
===============================================

1) git clone https://github.com/est4ever/AcouLM.git && cd AcouLM

2) ./portable_setup.sh
   (same idea as portable_setup.ps1 on Windows — choose OpenVINO path, model path, backend)

3) cp scripts/hpc/local_env.example.sh scripts/hpc/local_env.sh
   Edit OPENVINO_GENAI_DIR and ACOULM_MODEL (model on scratch).

4) source scripts/hpc/setup_env.sh && ./build.sh

5) sbatch scripts/hpc/slurm_acoulm.sbatch

6) Laptop tunnel:  ssh -L 8000:<compute-node>:8000 user@cluster
   ./npu_cli.sh chat "Hello"

Notes
-----
- Prefer OpenVINO IR folders over GGUF on HPC for faster loads.
- API listens on 0.0.0.0:8000 inside the job (see RestAPIServer).
- Windows scripts (acoulm.ps1, start_app.ps1) are not used on the cluster.
- Keep the backend process alive for instant restarts; use the same node/port via SSH tunnel.
