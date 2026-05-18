#!/usr/bin/env bash
# Shared glibc version helpers (ignore GLIBC_PRIVATE etc. from strings).

hpc_glibc_max() {
  local libc="${1:-/lib/x86_64-linux-gnu/libc.so.6}"
  if [[ ! -f "$libc" ]]; then
    echo "0.0"
    return
  fi
  python3 - "$libc" <<'PY'
import re, subprocess, sys
libc = sys.argv[1]
try:
    out = subprocess.check_output(["strings", libc], stderr=subprocess.DEVNULL, text=True)
except (subprocess.CalledProcessError, FileNotFoundError):
    print("0.0")
    raise SystemExit
vers = []
for line in out.splitlines():
    m = re.match(r"^GLIBC_(\d+\.\d+)$", line.strip())
    if m:
        vers.append(tuple(int(x) for x in m.group(1).split(".")))
if not vers:
    print("0.0")
else:
    a, b = max(vers)
    print(f"{a}.{b}")
PY
}

hpc_ver_ge() {
  python3 - "$1" "$2" <<'PY'
import re, sys

def p(v):
    m = re.match(r"^(\d+)\.(\d+)(?:\.(\d+))?$", str(v).strip())
    if not m:
        return (0, 0, 0)
    a, b, c = int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)
    return (a, b, c)

a, b = p(sys.argv[1]), p(sys.argv[2])
sys.exit(0 if a >= b else 1)
PY
}
