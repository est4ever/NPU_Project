#!/usr/bin/env bash
# Linux one-shot setup (closest thing to portable_setup.ps1 on Windows).
# Usage (from repo root):  bash scripts/hpc/linux_setup.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

echo "=============================================="
echo " AcouLM Linux setup (like portable_setup.ps1)"
echo "=============================================="
echo ""

# 1) Registry + folders (same as ./hpc-setup.sh)
bash "$ROOT/scripts/hpc/bootstrap.sh"
echo ""

# 2) local_env.sh
ENV_FILE="$ROOT/scripts/hpc/local_env.sh"
if [[ ! -f "$ENV_FILE" ]]; then
  cp "$ROOT/scripts/hpc/local_env.example.sh" "$ENV_FILE"
  echo "[setup] Created $ENV_FILE"
fi

MODEL_DIR="${ACOULM_MODEL_DIR:-$HOME/models/Qwen2.5-0.5B-Instruct}"
mkdir -p "$(dirname "$MODEL_DIR")"

# 3) Download a small starter model if missing (optional, needs huggingface-cli)
if [[ -d "$MODEL_DIR" ]] && [[ -n "$(ls -A "$MODEL_DIR" 2>/dev/null)" ]]; then
  echo "[setup] Model already present: $MODEL_DIR"
else
  echo "[setup] No model at $MODEL_DIR"
  if command -v huggingface-cli >/dev/null 2>&1; then
    echo "[setup] Downloading Qwen2.5-0.5B-Instruct (small, good for first test)..."
    huggingface-cli download Qwen/Qwen2.5-0.5B-Instruct --local-dir "$MODEL_DIR"
  elif command -v hf >/dev/null 2>&1; then
    echo "[setup] Downloading Qwen2.5-0.5B-Instruct (small, good for first test)..."
    hf download Qwen/Qwen2.5-0.5B-Instruct --local-dir "$MODEL_DIR"
  else
    echo "[setup] huggingface-cli not found — skip auto-download."
    echo "        Install:  pip install -U 'huggingface_hub[cli]'"
    echo "        Or copy a model folder from your PC with scp."
  fi
fi

# 4) Patch local_env.sh model path if still placeholder
if grep -q '/path/to/openvino' "$ENV_FILE" 2>/dev/null; then
  echo ""
  echo "[setup] EDIT REQUIRED: $ENV_FILE"
  echo "        Set OPENVINO_GENAI_DIR to your OpenVINO GenAI Linux install."
  echo "        Find it with:  find /opt /usr/local \$HOME -name setupvars.sh 2>/dev/null | head -3"
fi

# Update ACOULM_MODEL line in local_env if we downloaded
if [[ -d "$MODEL_DIR" ]]; then
  if grep -q '^export ACOULM_MODEL=' "$ENV_FILE"; then
    sed -i.bak "s|^export ACOULM_MODEL=.*|export ACOULM_MODEL=$MODEL_DIR|" "$ENV_FILE"
  else
    echo "export ACOULM_MODEL=$MODEL_DIR" >> "$ENV_FILE"
  fi
  echo "[setup] Set ACOULM_MODEL=$MODEL_DIR in local_env.sh"
fi

# 5) Point registry at the model
python3 - <<PY "$ROOT" "$MODEL_DIR"
import json, os, sys
root, model_dir = sys.argv[1], sys.argv[2]
rp = os.path.join(root, "registry", "models_registry.json")
with open(rp) as f:
    reg = json.load(f)
rel = model_dir
if model_dir.startswith(root):
    rel = "./" + os.path.relpath(model_dir, root).replace(os.sep, "/")
reg["selected_model"] = "hpc-local"
found = False
for m in reg.get("models", []):
    if m.get("id") == "hpc-local":
        m["path"] = rel
        m["format"] = "openvino"
        found = True
if not found:
    reg.setdefault("models", []).append({
        "id": "hpc-local", "path": rel, "format": "openvino",
        "backend": "openvino", "status": "ready"
    })
reg["selected_model"] = "hpc-local"
with open(rp, "w") as f:
    json.dump(reg, f, indent=2)
print("[setup] Updated registry/models_registry.json ->", rel)
PY

echo ""
echo "=============================================="
echo " Setup phase 1 done."
echo "=============================================="
echo ""
echo "YOU STILL NEED (cluster admin or modules):"
echo "  - OpenVINO GenAI for Linux -> set OPENVINO_GENAI_DIR in:"
echo "      nano scripts/hpc/local_env.sh"
echo ""
echo "THEN run:"
echo "  cd $ROOT"
echo "  source scripts/hpc/setup_env.sh"
echo "  ./build.sh"
echo "  sbatch scripts/hpc/slurm_acoulm.sbatch"
echo ""
echo "Chat from laptop (after job is running):"
echo "  ssh -L 8000:<compute-node>:8000 you@cluster"
echo "  export ACOULM_API_BASE=http://127.0.0.1:8000"
echo "  ./npu_cli.sh chat \"Hello\""
echo ""
