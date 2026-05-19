#!/usr/bin/env python3
"""stdin: commit message; stdout: same without Cursor co-author trailers."""
import sys

data = sys.stdin.read()
lines = data.splitlines(keepends=True)
out = []
for line in lines:
    if line.startswith("Co-authored-by: Cursor"):
        continue
    if "cursoragent@cursor.com" in line:
        continue
    out.append(line)
sys.stdout.write("".join(out))
