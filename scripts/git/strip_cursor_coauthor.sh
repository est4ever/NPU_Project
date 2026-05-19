#!/usr/bin/env bash
# Remove Cursor co-author trailers from git history (fixes GitHub Contributors list).
# After this:  git push --force-with-lease origin main
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "[strip] Not a git repository." >&2
  exit 1
fi

before="$(git log --all --grep='Co-authored-by: Cursor' --oneline 2>/dev/null | wc -l | tr -d ' ')"
echo "[strip] Commits mentioning Cursor co-author (before): ${before}"

export FILTER_BRANCH_SQUELCH_WARNING=1
STRIP_PY="$(cd "$(dirname "$0")" && pwd)/strip_cursor_msg.py"
git filter-branch -f --msg-filter "python \"$STRIP_PY\"" --tag-name-filter cat -- --all

after="$(git log --all --grep='Co-authored-by: Cursor' --oneline 2>/dev/null | wc -l | tr -d ' ')"
echo "[strip] Commits mentioning Cursor co-author (after): ${after}"

git for-each-ref --format='%(refname)' refs/original/ 2>/dev/null | while read -r ref; do
  git update-ref -d "$ref" 2>/dev/null || true
done

echo ""
echo "[strip] Done. Verify:  git log --grep='Co-authored-by: Cursor' --oneline"
echo "[strip] Update GitHub (rewrites history):"
echo "  git push --force-with-lease origin main"
