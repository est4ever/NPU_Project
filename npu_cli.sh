#!/usr/bin/env bash
# Terminal chat for AcouLM (started by bare `acoulm` on Linux / Windows npu_cli.ps1 on Windows).
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
  local backend max_tokens=96
  backend="$(api_backend)"
  local extra_hdr=()

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
    echo "[chat] Request failed — run acoulm (no arguments) and wait for the model to load." >&2
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
  printf '%s\n' "$text"
}

chat_loop() {
  echo "[chat] API: $API_BASE"
  echo "[chat] Control panel: http://127.0.0.1:${ACOULM_APP_PORT:-5173}/"
  echo "[chat] Type a message and press Enter. Commands: /status  /exit"
  while true; do
    read -r -p "You: " line || break
    [[ -z "$line" ]] && continue
    case "$line" in
      /exit|/quit)
        break
        ;;
      /status)
        api_get "/v1/cli/status" 2>/dev/null | jq . || api_get "/v1/health" | jq .
        continue
        ;;
      /*)
        echo "Unknown command. Use /status or /exit."
        continue
        ;;
    esac
    printf 'Assistant: '
    do_chat "$line" || true
    echo ""
  done
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
      chat_loop
    else
      do_chat "$*"
    fi
    ;;
  *)
    echo "Internal: use bare acoulm for terminal chat." >&2
    exit 1
    ;;
esac
