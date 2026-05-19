#!/usr/bin/env bash
# Terminal client for AcouLM (status + chat). Use: acoulm chat "hello"
set -euo pipefail

API_BASE="${ACOULM_API_BASE:-http://127.0.0.1:8000}"
API_BASE="${API_BASE%/}"
CMD="${1:-chat}"
shift || true

api_get() {
  curl -fsS "${API_BASE}$1"
}

api_backend() {
  api_get "/v1/health" 2>/dev/null | jq -r '.backend // "openvino"' 2>/dev/null || echo "openvino"
}

do_chat() {
  local prompt="$1"
  local backend
  backend="$(api_backend)"
  local max_tokens=32
  local extra_hdr=()

  # OpenVINO npu_wrapper requires x-npu-cli; cuda-llama proxy does not.
  if [[ "$backend" != "cuda-llama" ]]; then
    extra_hdr=(-H "x-npu-cli: true")
  fi

  local body
  body="$(jq -n --arg p "$prompt" --argjson mt "$max_tokens" \
    '{messages:[{role:"user",content:$p}], stream:false, max_tokens:$mt, temperature:0.2,
      chat_template_kwargs:{enable_thinking:false}}')"

  local resp
  if ! resp="$(curl -fsS --max-time 600 \
    -H "Content-Type: application/json" \
    "${extra_hdr[@]}" \
    -X POST -d "$body" \
    "${API_BASE}/v1/chat/completions")"; then
    echo "[chat] Request failed. Is the server running? (acoulm start in another terminal)" >&2
    return 1
  fi

  if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
    echo "$resp" | jq . >&2
    return 1
  fi

  local text
  text="$(echo "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)"
  if [[ -z "$text" ]]; then
    echo "[chat] No message content in response:" >&2
    echo "$resp" | jq . >&2
    return 1
  fi
  printf 'Assistant: %s\n' "$text"
}

case "$CMD" in
  status)
    api_get "/v1/cli/status" | jq .
    ;;
  health)
    api_get "/v1/health" | jq .
    ;;
  chat)
    if [[ $# -eq 0 ]]; then
      echo "AcouLM chat — API: $API_BASE (Ctrl+C to exit)"
      echo "Start the server first: acoulm start"
      while true; do
        read -r -p "You: " line || break
        [[ -z "$line" ]] && continue
        do_chat "$line" || true
        echo ""
      done
    else
      do_chat "$*"
    fi
    ;;
  *)
    echo "Usage: acoulm chat [message]   (no message = interactive)" >&2
    echo "       acoulm status | acoulm health" >&2
    exit 1
    ;;
esac
