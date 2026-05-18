#!/usr/bin/env bash
# Export Hugging Face folder (config.json + *.safetensors) to OpenVINO IR for acoulm start.
# Same role as Export-HfFolderToOpenVinoIR.ps1 on Windows.
#
# Usage:
#   bash scripts/hpc/export_hf_to_ir.sh /home/twin/AcouLM/models/Qwen3.6-27B
#   bash scripts/hpc/export_hf_to_ir.sh ./models/Qwen3.6-27B ./models/Qwen3.6-27B-ov-ir int4
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HF_DIR="${1:?HF model folder (has config.json)}"
IR_DIR="${2:-${HF_DIR}-ov-ir}"
WEIGHT_FORMAT="${3:-int8}"
TRUST_FLAG=()

if [[ ! -f "$HF_DIR/config.json" ]]; then
  echo "[export] Missing config.json in $HF_DIR" >&2
  exit 1
fi

if find "$HF_DIR" -maxdepth 1 -name 'openvino*.xml' -print -quit 2>/dev/null | grep -q .; then
  echo "[export] Folder already has OpenVINO IR — use it directly:"
  echo "  export ACOULM_MODEL=$HF_DIR"
  exit 0
fi

QWEN35=0
if grep -qE 'qwen3_5|qwen3\.5' "$HF_DIR/config.json" 2>/dev/null; then
  QWEN35=1
fi
QWEN3=0
if [[ "$QWEN35" -eq 1 ]] || grep -qE '"qwen3"|qwen3_moe|Qwen3' "$HF_DIR/config.json" 2>/dev/null; then
  TRUST_FLAG=(--trust-remote-code)
  QWEN3=1
  echo "[export] Qwen3 family: using --trust-remote-code"
fi

if [[ -f "$IR_DIR/openvino_model.xml" ]] || find "$IR_DIR" -maxdepth 2 -name 'openvino*.xml' -print -quit 2>/dev/null | grep -q .; then
  echo "[export] IR already present under $IR_DIR"
  exit 0
fi

# Qwen3.5 (qwen3_5) needs bleeding-edge optimum-intel + transformers.
# Do NOT upgrade base conda — use an isolated env so acoulm build env stays intact.
ensure_export_env() {
  local env_dir="$1"
  local py="$env_dir/bin/python"
  if [[ -x "$py" ]] && "$py" -m pip --version &>/dev/null; then
    return 0
  fi
  rm -rf "$env_dir"
  if command -v conda &>/dev/null; then
    echo "[export] Creating conda env at $env_dir (works without python3-venv / sudo)..."
    conda create -y -p "$env_dir" python=3.12 pip git
    return 0
  fi
  echo "[export] Trying python3 -m venv..."
  if python3 -m venv "$env_dir"; then
    return 0
  fi
  echo "[export] Cannot create export env. Use conda (above) or: sudo apt install python3-venv" >&2
  exit 1
}

EXPORT_ENV="${ACOULM_EXPORT_ENV:-${ACOULM_EXPORT_VENV:-$HOME/acoulm-export-env}}"
PYTHON="$EXPORT_ENV/bin/python"

install_qwen35_export_stack() {
  # optimum-intel main + transformers 5.x (see optimum-intel PR #1689). Do not install both
  # in one pip line — PyPI metadata still pins transformers<4.58 on older releases.
  "$PYTHON" -m pip install -q -U pip wheel
  "$PYTHON" -m pip install -q -U "torch" --index-url https://download.pytorch.org/whl/cpu 2>/dev/null \
    || "$PYTHON" -m pip install -q -U "torch"
  "$PYTHON" -m pip install -q -U \
    "transformers==5.2.0" \
    "openvino" "optimum" "nncf" "huggingface_hub" "onnx" "sentencepiece"
  "$PYTHON" -m pip install -q -U --no-deps \
    "git+https://github.com/huggingface/optimum-intel.git"
}

EXPORT_TASK="text-generation-with-past"
if [[ "$QWEN35" -eq 1 ]]; then
  echo "[export] Qwen3.5+ detected — using isolated env: $EXPORT_ENV"
  echo "[export] Installing optimum-intel (main) + transformers 5.2.0..."
  ensure_export_env "$EXPORT_ENV"
  install_qwen35_export_stack
  # optimum-intel only registers qwen3_5 / Qwen3.6 for image-text-to-text (not text-generation-with-past).
  EXPORT_TASK="image-text-to-text"
  echo "[export] Qwen3.5/3.6 export task: image-text-to-text"
  if [[ -f "$HF_DIR/video_preprocessor_config.json" ]]; then
    echo "[export] Note: This is a multimodal (video/VLM) checkpoint. AcouLM text-only LLMPipeline may not load it."
  fi
else
  PYTHON="${PYTHON:-python3}"
  if [[ -n "${CONDA_PREFIX:-}" && -x "${CONDA_PREFIX}/bin/python" ]]; then
    PYTHON="${CONDA_PREFIX}/bin/python"
  fi
  echo "[export] Installing optimum-intel (one-time)..."
  "$PYTHON" -m pip install -q -U pip
  # 4.57+ is not on PyPI for all indexes; optimum-intel 1.27 wants >=4.45,<4.58
  "$PYTHON" -m pip install -q -U "optimum" "optimum-intel[openvino]" "openvino" \
    "transformers>=4.45,<4.58" "huggingface_hub<1.0"
fi

TMP="${IR_DIR}.tmp.$$"
rm -rf "$TMP"
mkdir -p "$TMP"

echo "[export] HF:  $HF_DIR"
echo "[export] IR:  $IR_DIR"
echo "[export] Format: $WEIGHT_FORMAT (use int4 for 27B to save disk/RAM)"
echo "[export] Task:   $EXPORT_TASK"
echo "[export] This can take a long time for large models..."

set +e
"$PYTHON" -m optimum.commands.optimum_cli export openvino \
  --model "$HF_DIR" \
  --task "$EXPORT_TASK" \
  --weight-format "$WEIGHT_FORMAT" \
  "${TRUST_FLAG[@]}" \
  "$TMP"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  echo "[export] Failed (exit $rc)." >&2
  if [[ "$QWEN35" -eq 1 ]]; then
    cat >&2 <<'EOF'
[export] Qwen3.5 (architecture qwen3_5) may not be exportable on this stack yet.
Try on your Windows PC (newer OpenVINO / AcouLM):
  .\Export-HfFolderToOpenVinoIR.ps1 -ProjectRoot . -HfModelDir .\models\Qwen3.6-27B `
    -IrOutputDir .\models\Qwen3.6-27B-ov-ir -WeightFormat int4 -TrustRemoteCode
Then copy models\Qwen3.6-27B-ov-ir to the cluster and set ACOULM_MODEL to that path.
EOF
  else
    echo "[export] For 27B you need lots of RAM; try int4 on a machine with 64GB+." >&2
  fi
  rm -rf "$TMP"
  exit $rc
fi

rm -rf "$IR_DIR"
mv "$TMP" "$IR_DIR"

echo ""
echo "[export] OK: $IR_DIR"
echo "[export] Update AcouLM:"
echo "  export ACOULM_MODEL=$IR_DIR"
cat <<EOF

Or in scripts/hpc/local_env.sh:
  export ACOULM_MODEL=$IR_DIR
EOF
