#!/usr/bin/env bash
# glibc version — prefer getconf (no exec, not affected by LD_LIBRARY_PATH).
# Do not use `strings | sed s/^GLIBC_/` (GLIBC_PRIVATE -> "PRIVATE").

hpc_glibc_max() {
  local libc="${1:-}"
  # Host default: getconf is safest when LD_LIBRARY_PATH is poisoned.
  if [[ -z "$libc" || "$libc" == "/lib/x86_64-linux-gnu/libc.so.6" || "$libc" == "/lib64/libc.so.6" ]]; then
    local gc
    gc="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
    if [[ "$gc" =~ ([0-9]+\.[0-9]+) ]]; then
      echo "${BASH_REMATCH[1]}"
      return
    fi
    libc="/lib/x86_64-linux-gnu/libc.so.6"
    [[ -f "$libc" ]] || libc="/lib64/libc.so.6"
  fi

  if [[ ! -f "$libc" ]]; then
    echo "0.0"
    return
  fi
  # Running a specific libc.so.6 prints "GNU C Library ... GLIBC 2.xx ..."
  # Clear LD_LIBRARY_PATH for this subshell so we do not mix host ld with wrong libc.
  local line
  line="$(env -u LD_LIBRARY_PATH "$libc" 2>&1 | head -1)"
  if [[ "$line" =~ GLIBC[[:space:]]+([0-9]+\.[0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  echo "0.0"
}

hpc_ver_ge() {
  local a="$1" b="$2"
  local am="${a%%.*}" an="${a#*.}" bm="${b%%.*}" bn="${b#*.}"
  [[ "$an" =~ ^[0-9]+$ ]] || an=0
  [[ "$bn" =~ ^[0-9]+$ ]] || bn=0
  [[ "$am" =~ ^[0-9]+$ ]] || am=0
  [[ "$bm" =~ ^[0-9]+$ ]] || bm=0
  if [[ "$am" -gt "$bm" ]]; then return 0; fi
  if [[ "$am" -lt "$bm" ]]; then return 1; fi
  if [[ "$an" -ge "$bn" ]]; then return 0; fi
  return 1
}
