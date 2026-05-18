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

has_local_changes() {
  ! git diff --quiet 2>/dev/null || return 0
  ! git diff --cached --quiet 2>/dev/null || return 0
  return 1
}

echo "[git] Fetching $remote..."
git fetch "$remote"

if has_local_changes; then
  echo "[git] Stashing local edits..."
  git stash push -m "acoulm-before-pull-$(date +%Y%m%d-%H%M%S)"
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
