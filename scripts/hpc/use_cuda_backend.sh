#!/usr/bin/env bash
# Register and select the CUDA (llama.cpp) backend in backends_registry.json.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REG="${ROOT}/registry/backends_registry.json"

python3 - "$REG" <<'PY'
import json
import sys
from pathlib import Path

reg = Path(sys.argv[1])
data = json.loads(reg.read_text()) if reg.exists() else {"schema": 1, "backends": []}
backends = {b["id"]: b for b in data.get("backends", [])}
backends["cuda-llama"] = {
    "id": "cuda-llama",
    "type": "external",
    "entrypoint": "scripts/hpc/launch_cuda_llm.sh",
    "formats": ["gguf"],
    "status": "ready",
}
if "openvino" not in backends:
    backends["openvino"] = {
        "id": "openvino",
        "type": "builtin",
        "entrypoint": "dist/npu_wrapper",
        "formats": ["openvino", "gguf"],
        "status": "ready",
    }
data["backends"] = list(backends.values())
data["selected_backend"] = "cuda-llama"
data["schema"] = 1
reg.write_text(json.dumps(data, indent=2) + "\n")
print("[cuda] selected_backend=cuda-llama")
print("[cuda] entrypoint=scripts/hpc/launch_cuda_llm.sh")
PY

chmod +x "${ROOT}/scripts/hpc/launch_cuda_llm.sh" "${ROOT}/scripts/cuda/acoulm_cuda_proxy.py" 2>/dev/null || true

echo "[cuda] Set ACOULM_MODEL to a .gguf file (OpenVINO IR will not work on this backend)."
echo "[cuda] Example:"
echo "  export ACOULM_MODEL=\$HOME/AcouLM/models/Qwen2.5-3B-Instruct-Q4_K_M.gguf"
echo "  bash acoulm.sh start"
