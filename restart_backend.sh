#!/usr/bin/env bash
# Relaunch API after registry/backend changes (also used by POST /v1/cli/backend/restart).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${ROOT}/registry/npu_launch_state.json"

sleep 2

if [[ ! -f "$STATE" ]]; then
  echo "[restart_backend] Missing $STATE" >&2
  exit 1
fi

PID="$(python3 - <<'PY' "$STATE"
import json, sys
with open(sys.argv[1]) as f:
    print(int(json.load(f).get("backend_pid") or 0))
PY
)"

if [[ "$PID" -gt 0 ]] && kill -0 "$PID" 2>/dev/null; then
  kill -9 "$PID" 2>/dev/null || true
fi

sleep 1
cd "$ROOT"

mapfile -t ARGV < <(python3 - <<'PY' "$STATE"
import json, sys
with open(sys.argv[1]) as f:
    doc = json.load(f)
for a in doc.get("argv", []):
    print(a)
PY
)

echo "[restart_backend] ./run.sh ${ARGV[*]}"
exec ./run.sh "${ARGV[@]}"
