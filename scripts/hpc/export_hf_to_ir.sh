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
# Do NOT upgrade base conda — use an isolated venv so acoulm build env stays intact.
EXPORT_VENV="${ACOULM_EXPORT_VENV:-$HOME/acoulm-export-venv}"
PYTHON="$EXPORT_VENV/bin/python"

if [[ "$QWEN35" -eq 1 ]]; then
  echo "[export] Qwen3.5 detected — using isolated venv: $EXPORT_VENV"
  echo "[export] (stable optimum-intel 1.27 does not support qwen3_5 yet; trying GitHub builds)"
  if [[ ! -x "$PYTHON" ]]; then
    python3 -m venv "$EXPORT_VENV"
  fi
  "$PYTHON" -m pip install -q -U pip wheel
  "$PYTHON" -m pip install -q -U "torch" --index-url https://download.pytorch.org/whl/cpu 2>/dev/null \
    || "$PYTHON" -m pip install -q -U "torch"
  "$PYTHON" -m pip install -q -U \
    "git+https://github.com/huggingface/transformers.git" \
    "git+https://github.com/huggingface/optimum-intel.git" \
    "openvino" "optimum" "huggingface_hub"
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
echo "[export] This can take a long time for large models..."

set +e
"$PYTHON" -m optimum.commands.optimum_cli export openvino \
  --model "$HF_DIR" \
  --task text-generation-with-past \
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
