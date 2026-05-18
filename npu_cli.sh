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
    BODY="$(jq -n --arg p "$PROMPT" '{messages:[{role:"user",content:$p}], stream:true, max_tokens:256, temperature:0.2}')"
    api_post "/v1/chat/completions" "$BODY" | while IFS= read -r line; do
      [[ "$line" == data:* ]] || continue
      payload="${line#data: }"
      [[ "$payload" == "[DONE]" ]] && break
      echo -n "$(echo "$payload" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)"
    done
    echo ""
    ;;
  *)
    echo "Commands: status | health | chat <message>" >&2
    exit 1
    ;;
esac
