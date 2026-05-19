#!/usr/bin/env bash
# Minimal terminal client for HPC (status + chat). Requires curl and jq.
set -euo pipefail

API_BASE="${ACOULM_API_BASE:-http://127.0.0.1:8000}"
API_BASE="${API_BASE%/}"
CMD="${1:-chat}"
shift || true

api_get() {
  curl -fsS "${API_BASE}$1"
}

api_post() {
  local path="$1"
  local body="$2"
  local extra_hdr=()
  # Server allows chat only from terminal clients (see RestAPIServer.cpp).
  if [[ "$path" == "/v1/chat/completions" ]]; then
    extra_hdr=(-H "x-npu-cli: true")
  fi
  curl -fsS -H "Content-Type: application/json" "${extra_hdr[@]}" -X POST -d "$body" "${API_BASE}${path}"
}

case "$CMD" in
  status)
    api_get "/v1/cli/status" | jq .
    ;;
  health)
    api_get "/v1/health" | jq .
    ;;
  chat)
    PROMPT="$*"
    if [[ -z "$PROMPT" ]]; then
      echo "Usage: $0 chat \"your message\"" >&2
      exit 1
    fi
    # Non-streaming: works with OpenVINO REST and cuda-llama (llama-server) proxies.
    BODY="$(jq -n --arg p "$PROMPT" '{messages:[{role:"user",content:$p}], stream:false, max_tokens:64, temperature:0.2, chat_template_kwargs:{enable_thinking:false}}')"
    echo "[chat] Waiting for model (27B first reply can take 1–3 min)..." >&2
    RESP="$(curl -fsS --max-time 600 -H "Content-Type: application/json" \
      -H "x-npu-cli: true" \
      -X POST -d "$BODY" "${API_BASE}/v1/chat/completions")"
    if echo "$RESP" | jq -e '.error' >/dev/null 2>&1; then
      echo "$RESP" | jq . >&2
      exit 1
    fi
    echo "$RESP" | jq -r '.choices[0].message.content // empty'
    echo ""
    ;;
  *)
    echo "Commands: status | health | chat <message>" >&2
    exit 1
    ;;
esac
