#!/usr/bin/env bash
# Linux default launcher: background API + app_shell, open browser, foreground terminal chat.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ACOULM_HOME="${ACOULM_HOME:-$ROOT}"
# shellcheck source=/dev/null
source "${ROOT}/scripts/hpc/setup_env.sh"

API_PORT="${ACOULM_PORT:-8000}"
APP_PORT="${ACOULM_APP_PORT:-5173}"
API_BASE="http://127.0.0.1:${API_PORT}"
APP_URL="http://127.0.0.1:${APP_PORT}/"
RUN_DIR="${ACOULM_RUN_DIR:-${ACOULM_HOME}/.acoulm}"
BACKEND_LOG="${RUN_DIR}/runlog.txt"
APPSHELL_LOG="${RUN_DIR}/appshell.log"
WAIT_SEC="${ACOULM_BACKEND_WAIT_SEC:-360}"
BROWSER_OPENED=0

mkdir -p "$RUN_DIR"

acoulm_banner() {
  echo ""
  echo "      _    ____   ___   _   _  _      __  __ "
  echo "     / \\  / ___| / _ \\ | | | || |    |  \\/  |"
  echo "    / _ \\| |    | | | || | | || |    | |\\/| |"
  echo "   / ___ \\ |___ | |_| || |_| || |___ | |  | |"
  echo "  /_/   \\_\\____| \\___/  \\___/ |_____||_|  |_|"
  echo ""
}

api_http_up() {
  curl -fsS --max-time 3 "${API_BASE}/v1/health" >/dev/null 2>&1
}

api_chat_ready() {
  local ready
  ready="$(curl -fsS --max-time 3 "${API_BASE}/v1/health" 2>/dev/null \
    | jq -r 'if .chat_ready == false then "no" else "yes" end' 2>/dev/null || echo "no")"
  [[ "$ready" == "yes" ]]
}

appshell_up() {
  curl -fsS --max-time 2 "${APP_URL}" >/dev/null 2>&1
}

backend_running() {
  pgrep -f '[/]dist/npu_wrapper|[/]build/.*/npu_wrapper|acoulm_cuda_proxy\.py|llama-server' >/dev/null 2>&1
}

appshell_running() {
  pgrep -f 'appshell_server\.py' >/dev/null 2>&1 || \
    pgrep -f "http\.server ${APP_PORT}.*app_shell" >/dev/null 2>&1
}

open_browser() {
  local url="$1"
  [[ "$BROWSER_OPENED" -eq 1 ]] && return 0
  if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    if command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$url" >/dev/null 2>&1 && BROWSER_OPENED=1 && return 0
    fi
    for cmd in sensible-browser firefox chromium chromium-browser google-chrome; do
      if command -v "$cmd" >/dev/null 2>&1; then
        "$cmd" "$url" >/dev/null 2>&1 && BROWSER_OPENED=1 && return 0
      fi
    done
  fi
  echo "[AcouLM] Open the control panel in your browser: $url"
  return 1
}

start_appshell_bg() {
  if appshell_running || appshell_up; then
    # Replace legacy static-only server (no API proxy) with appshell_server.py
    if pgrep -f "http\.server ${APP_PORT}.*app_shell" >/dev/null 2>&1; then
      pkill -f "http\.server ${APP_PORT}.*app_shell" 2>/dev/null || true
      sleep 0.5
    elif pgrep -f 'appshell_server\.py' >/dev/null 2>&1; then
      return 0
    fi
  fi
  echo "[AcouLM] Starting control panel on :${APP_PORT} (API proxied on same port)..."
  export ACOULM_API_UPSTREAM="${API_BASE}"
  nohup python3 "${ACOULM_HOME}/scripts/linux/appshell_server.py" --port "$APP_PORT" \
    --upstream "${API_BASE}" >>"$APPSHELL_LOG" 2>&1 &
  disown 2>/dev/null || true
  local i=0
  while (( i < 20 )); do
    if appshell_up; then
      echo "[AcouLM] Control panel ready: $APP_URL"
      return 0
    fi
    sleep 0.5
    ((i++)) || true
  done
  echo "[AcouLM] Control panel still starting — see $APPSHELL_LOG"
}

start_backend_bg() {
  if backend_running || api_http_up; then
    if backend_running; then
      echo "[AcouLM] Backend already running — not starting a second copy."
    fi
    return 0
  fi
  if [[ -z "${ACOULM_MODEL:-}" ]]; then
    echo "[AcouLM] ACOULM_MODEL is not set." >&2
    echo "  Run:  bash scripts/hpc/configure_cuda_env.sh" >&2
    echo "  Then: source scripts/hpc/local_env.sh && acoulm" >&2
    return 1
  fi
  local model="${ACOULM_MODEL}"
  local device="${ACOULM_DEVICE:-GPU}"
  echo "[AcouLM] Starting API on :${API_PORT} (background, logs: $BACKEND_LOG)..."
  local extra=()
  if [[ -n "${ACOULM_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    extra=(${ACOULM_EXTRA_ARGS})
  fi
  nohup "${ACOULM_HOME}/run.sh" "$model" \
    --server \
    --port "$API_PORT" \
    --policy PERFORMANCE \
    --device "$device" \
    "${extra[@]}" >>"$BACKEND_LOG" 2>&1 &
  disown 2>/dev/null || true
}

wait_api_chat_ready() {
  if api_chat_ready; then
    echo "[AcouLM] Model ready."
    return 0
  fi
  echo "[AcouLM] Waiting for model (first load can take 1–5 min)..."
  local t0=$SECONDS
  local next=$((t0 + 12))
  while (( SECONDS - t0 < WAIT_SEC )); do
    if api_chat_ready; then
      echo "[AcouLM] Model ready ($((SECONDS - t0))s)."
      return 0
    fi
    if (( SECONDS >= next )); then
      if api_http_up; then
        echo "[AcouLM] API online — loading weights ($((SECONDS - t0))s)..."
      elif backend_running; then
        echo "[AcouLM] Backend starting ($((SECONDS - t0))s)..."
      else
        echo "[AcouLM] Still waiting ($((SECONDS - t0))s) — see $BACKEND_LOG"
      fi
      next=$((SECONDS + 12))
    fi
    sleep 0.4
  done
  echo "[AcouLM] Model not ready within ${WAIT_SEC}s — chat may fail until load finishes."
  return 1
}

browser_when_ready() {
  (
    local deadline=$((SECONDS + 480))
    while (( SECONDS < deadline )); do
      if api_chat_ready && appshell_up; then
        open_browser "$APP_URL" && exit 0
      fi
      sleep 2
    done
    open_browser "$APP_URL" || true
  ) &
  disown 2>/dev/null || true
}

acoulm_banner

if api_chat_ready; then
  echo "[AcouLM] Hot start — model already loaded."
else
  start_appshell_bg
  start_backend_bg
  if ! api_http_up; then
    i=0
    while (( i < 90 )); do
      api_http_up && break
      sleep 0.4
      ((i++)) || true
    done
  fi
  browser_when_ready
  wait_api_chat_ready || true
fi

if ! appshell_up; then
  start_appshell_bg
fi
if api_chat_ready && [[ "$BROWSER_OPENED" -eq 0 ]]; then
  open_browser "$APP_URL" || true
fi

export ACOULM_API_BASE="$API_BASE"
exec "${ACOULM_HOME}/npu_cli.sh" chat
