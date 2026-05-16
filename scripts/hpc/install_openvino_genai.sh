#!/usr/bin/env bash
# One-command OpenVINO GenAI Linux install (official archive — required to build npu_wrapper).
# Pip (openvino / openvino-genai) is Python-only and uses a different C++ ABI; do not use pip for ./build.sh.
#
# Usage:
#   bash scripts/hpc/install_openvino_genai.sh
#   bash scripts/hpc/install_openvino_genai.sh /home/twin/openvino_genai
set -euo pipefail

DEST="${1:-${OPENVINO_GENAI_DIR:-$HOME/openvino_genai}}"
VERSION="${OPENVINO_GENAI_VERSION:-2026.1.0.0}"
# Ubuntu 22.04 x86_64 archive (works on many RHEL/HPC systems; change if your site documents another).
PKG="openvino_genai_ubuntu22_2026.1.0.0_x86_64"
URL="https://storage.openvinotoolkit.org/repositories/openvino_genai/packages/2026.1/linux/${PKG}.tar.gz"

echo "[openvino] Installing OpenVINO GenAI to: $DEST"
echo "[openvino] Download: $URL"

mkdir -p "$(dirname "$DEST")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if command -v curl >/dev/null 2>&1; then
  curl -fL "$URL" -o "$TMP/openvino_genai.tgz"
elif command -v wget >/dev/null 2>&1; then
  wget -O "$TMP/openvino_genai.tgz" "$URL"
else
  echo "[openvino] Need curl or wget." >&2
  exit 1
fi

tar -xzf "$TMP/openvino_genai.tgz" -C "$TMP"
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
# Archive usually has a single top-level folder.
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

echo "[openvino] OK: $DEST/setupvars.sh"
echo "[openvino] Add to local_env.sh:  export OPENVINO_GENAI_DIR=$DEST"
echo "[openvino] Then:  source scripts/hpc/setup_env.sh && ./build.sh"
