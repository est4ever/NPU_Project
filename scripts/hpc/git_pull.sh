#!/usr/bin/env bash
# Safe git pull for AcouLM on shared/cluster clones (local edits to tracked files are common).
# Stashes your changes, pulls, then re-applies them. Does not touch gitignored files
# (e.g. scripts/hpc/local_env.sh).
#
# Usage:
#   bash scripts/hpc/git_pull.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

branch="$(git rev-parse --abbrev-ref HEAD)"
remote="${ACOULM_GIT_REMOTE:-origin}"

echo "[git] Fetching $remote..."
git fetch "$remote"

echo "[git] Pulling $branch from $remote (autostash)..."
if ! git pull --autostash "$remote" "$branch"; then
  echo "[git] Pull failed. Check: git status" >&2
  exit 1
fi

echo "[git] OK: $(git rev-parse --short HEAD) $(git log -1 --format='%s')"

if git stash list | grep -q .; then
  echo "[git] You still have stash entries (pop may have conflicted):"
  git stash list
  echo "[git] Recover: git stash pop   or drop: git stash drop"
fi
