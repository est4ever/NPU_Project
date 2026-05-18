#!/usr/bin/env bash
# glibc version — use libc.so.6 self-report (reliable). Never use `strings | sed s/^GLIBC_/`
# because GLIBC_PRIVATE becomes "PRIVATE" and breaks comparisons.

hpc_glibc_max() {
  local libc="${1:-/lib/x86_64-linux-gnu/libc.so.6}"
  if [[ ! -f "$libc" ]]; then
    echo "0.0"
    return
  fi
  # Running libc.so.6 prints e.g. "GNU C Library (Ubuntu GLIBC 2.31-0ubuntu9.9) ..."
  local line
  line="$("$libc" 2>&1 | head -1)"
  if [[ "$line" =~ GLIBC[[:space:]]+([0-9]+\.[0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  # Fallback: getconf on host default only
  if [[ "$libc" == "/lib/x86_64-linux-gnu/libc.so.6" ]] || [[ "$libc" == "/lib64/libc.so.6" ]]; then
    local gc
    gc="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
    if [[ "$gc" =~ ([0-9]+\.[0-9]+) ]]; then
      echo "${BASH_REMATCH[1]}"
      return
    fi
  fi
  echo "0.0"
}

hpc_ver_ge() {
  # Pure bash version compare a >= b (major.minor only)
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
