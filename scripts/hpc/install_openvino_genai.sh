#!/usr/bin/env bash
# One-command OpenVINO GenAI Linux install (official archive — required to build npu_wrapper).
# Pip (openvino / openvino-genai) is Python-only and uses a different C++ ABI; do not use pip for ./build.sh.
#
# Usage:
#   bash scripts/hpc/install_openvino_genai.sh
#   bash scripts/hpc/install_openvino_genai.sh /home/twin/openvino_genai
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=glibc_util.sh
source "${SCRIPT_DIR}/glibc_util.sh"

DEST="${1:-${OPENVINO_GENAI_DIR:-$HOME/openvino_genai}}"
VERSION="${OPENVINO_GENAI_VERSION:-2026.1.0.0}"
BASE="https://storage.openvinotoolkit.org/repositories/openvino_genai/packages/2026.1/linux"

HOST_GLIBC="$(hpc_glibc_max)"
# Intel docs list ubuntu20, but CDN only serves real archives for ubuntu22/ubuntu24 (ubuntu20 URL = 1KB HTML).
FLAVOR="ubuntu22"
PKG="openvino_genai_${FLAVOR}_${VERSION}_x86_64"
URL="${BASE}/${PKG}.tar.gz"

echo "[openvino] Host glibc ${HOST_GLIBC}"
if ! hpc_ver_ge "${HOST_GLIBC:-0.0}" "2.34"; then
  echo "[openvino] NOTE: Ubuntu 20.04 / glibc < 2.34 cannot run this binary on the host OS directly." >&2
  echo "[openvino]       Use Ubuntu 22.04+ OR run inside: apptainer exec docker://ubuntu:22.04 ..." >&2
  echo "[openvino]       See scripts/hpc/README.txt" >&2
fi
echo "[openvino] Package: ${PKG} (ubuntu20 archives are not published on Intel CDN for 2026.1)"

echo "[openvino] Installing OpenVINO GenAI to: $DEST"
echo "[openvino] Download: $URL"

mkdir -p "$(dirname "$DEST")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TARBALL="$TMP/openvino_genai.tgz"
_hpc_download() {
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 5 -o "$TARBALL" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$TARBALL" "$1"
  else
    echo "[openvino] Need curl or wget." >&2
    exit 1
  fi
}

_hpc_download "$URL"

if [[ ! -s "$TARBALL" ]]; then
  echo "[openvino] Download failed: empty file." >&2
  exit 1
fi
if file "$TARBALL" 2>/dev/null | grep -qiE 'HTML|ASCII text'; then
  echo "[openvino] Download failed: got HTML (not a .tar.gz). URL may be wrong or blocked." >&2
  head -5 "$TARBALL" >&2
  exit 1
fi
SIZE_MB="$(du -m "$TARBALL" | awk '{print $1}')"
if [[ "${SIZE_MB:-0}" -lt 50 ]]; then
  echo "[openvino] Download too small (${SIZE_MB}MB). Expected ~100MB+." >&2
  echo "[openvino] Got HTML listing page — try from another network or scp from a PC." >&2
  exit 1
fi
echo "[openvino] Downloaded ${SIZE_MB}MB"

tar -xzf "$TARBALL" -C "$TMP"
EXTRACTED="$(find "$TMP" -maxdepth 2 -name setupvars.sh -printf '%h\n' 2>/dev/null | head -1)"
if [[ -z "$EXTRACTED" ]]; then
  EXTRACTED="$(find "$TMP" -maxdepth 3 -type d -name 'runtime' -printf '%h\n' 2>/dev/null | head -1)"
fi
if [[ -z "$EXTRACTED" ]]; then
  echo "[openvino] Extracted archive but could not find setupvars.sh" >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"
if [[ -f "$EXTRACTED/setupvars.sh" ]]; then
  shopt -s dotglob
  mv "$EXTRACTED"/* "$DEST/" 2>/dev/null || cp -a "$EXTRACTED/." "$DEST/"
  shopt -u dotglob
else
  echo "[openvino] Missing setupvars.sh under $EXTRACTED" >&2
  exit 1
fi

if [[ ! -f "$DEST/setupvars.sh" ]]; then
  echo "[openvino] Install failed: $DEST/setupvars.sh not found" >&2
  exit 1
fi

echo "[openvino] OK: $DEST/setupvars.sh (${FLAVOR}, ${SIZE_MB}MB)"
echo "[openvino] Add to local_env.sh:  export OPENVINO_GENAI_DIR=$DEST"
echo "[openvino] Then:  source scripts/hpc/setup_env.sh && ./build.sh"
