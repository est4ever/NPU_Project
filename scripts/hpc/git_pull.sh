#!/usr/bin/env bash
# Safe git pull for AcouLM on shared/cluster clones (local edits to tracked files are common).
# Works on older git (Ubuntu 20.04) where "git pull --autostash" requires --rebase.
# Does not touch gitignored files (e.g. scripts/hpc/local_env.sh).
#
# Usage:
#   bash scripts/hpc/git_pull.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

branch="$(git rev-parse --abbrev-ref HEAD)"
remote="${ACOULM_GIT_REMOTE:-origin}"
stashed=0

echo "[git] Fetching $remote..."
git fetch "$remote"

stash_before="$(git stash list | wc -l)"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "[git] Stashing local edits (if any)..."
  git stash push -m "acoulm-before-pull-$(date +%Y%m%d-%H%M%S)" || true
fi
stash_after="$(git stash list | wc -l)"
if [[ "$stash_after" -gt "$stash_before" ]]; then
  stashed=1
fi

echo "[git] Pulling $branch from $remote..."
if ! git pull "$remote" "$branch"; then
  echo "[git] Pull failed. Check: git status" >&2
  if [[ "$stashed" -eq 1 ]]; then
    echo "[git] Your edits are in: git stash list" >&2
  fi
  exit 1
fi

if [[ "$stashed" -eq 1 ]]; then
  echo "[git] Re-applying stashed edits..."
  if ! git stash pop; then
    echo "[git] Stash pop had conflicts — resolve files, then: git stash drop (if done)" >&2
    exit 1
  fi
fi

echo "[git] OK: $(git rev-parse --short HEAD) $(git log -1 --format='%s')"
