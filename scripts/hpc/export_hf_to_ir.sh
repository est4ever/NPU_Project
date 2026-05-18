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

QWEN3=0
if grep -qE 'qwen3|Qwen3|qwen3_5' "$HF_DIR/config.json" 2>/dev/null; then
  TRUST_FLAG=(--trust-remote-code)
  QWEN3=1
  echo "[export] Qwen3 / Qwen3.5: using --trust-remote-code"
fi

if [[ -f "$IR_DIR/openvino_model.xml" ]] || find "$IR_DIR" -maxdepth 2 -name 'openvino*.xml' -print -quit 2>/dev/null | grep -q .; then
  echo "[export] IR already present under $IR_DIR"
  exit 0
fi

PYTHON="${PYTHON:-python3}"
if [[ -n "${CONDA_PREFIX:-}" && -x "${CONDA_PREFIX}/bin/python" ]]; then
  PYTHON="${CONDA_PREFIX}/bin/python"
fi

echo "[export] Installing optimum-intel (one-time, may take a few minutes)..."
"$PYTHON" -m pip install -q -U pip
if [[ "$QWEN3" -eq 1 ]]; then
  echo "[export] Qwen3.5 needs a current transformers (pip install from GitHub)..."
  "$PYTHON" -m pip install -q -U "optimum" "optimum-intel[openvino]" "openvino" "huggingface_hub<1.0"
  "$PYTHON" -m pip install -q -U "git+https://github.com/huggingface/transformers.git"
else
  "$PYTHON" -m pip install -q -U "optimum" "optimum-intel[openvino]" "openvino" "transformers>=4.57.0,<4.58" "huggingface_hub<1.0"
fi

TMP="${IR_DIR}.tmp.$$"
rm -rf "$TMP"
mkdir -p "$TMP"

echo "[export] HF:  $HF_DIR"
echo "[export] IR:  $IR_DIR"
echo "[export] Format: $WEIGHT_FORMAT (use int4 for 27B to save disk/RAM)"
echo "[export] This can take a long time for large models..."

set +e
if command -v optimum-cli >/dev/null 2>&1; then
  optimum-cli export openvino \
    --model "$HF_DIR" \
    --task text-generation-with-past \
    --weight-format "$WEIGHT_FORMAT" \
    "${TRUST_FLAG[@]}" \
    "$TMP"
  rc=$?
else
  "$PYTHON" -m optimum.commands.optimum_cli export openvino \
    --model "$HF_DIR" \
    --task text-generation-with-past \
    --weight-format "$WEIGHT_FORMAT" \
    "${TRUST_FLAG[@]}" \
    "$TMP"
  rc=$?
fi
set -e

if [[ $rc -ne 0 ]]; then
  echo "[export] Failed (exit $rc). For 27B you need lots of RAM; try int4 on a machine with 64GB+." >&2
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
