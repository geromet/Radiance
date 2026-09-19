#!/usr/bin/env bash
# Files one GitHub issue per "### H<n>. <title>" section of a blockers markdown file.
# Dry-run by default; pass --create to actually open issues. Skips titles that already exist.
set -euo pipefail

FILE=HUMAN_BLOCKERS.md
CREATE=0
REPO_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --create) CREATE=1 ;;
    --repo) REPO_ARGS=(--repo "$2"); shift ;;
    *) FILE="$1" ;;
  esac
  shift
done

LABEL=human-blocker
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Split into $tmp/H<n>.md ; the first line of each file is the title.
awk -v dir="$tmp" '
  /^### H[0-9]+\./ { if (out) close(out); id=$2; sub(/\.$/,"",id); out=dir "/" id ".md"
                     t=$0; sub(/^### /,"",t); print t > out; next }
  /^## / { if (out) close(out); out=""; next }
  out { print >> out }
' "$FILE"

shopt -s nullglob
files=("$tmp"/H*.md)
[ ${#files[@]} -gt 0 ] || { echo "no '### H<n>.' sections found in $FILE" >&2; exit 1; }

if [ "$CREATE" = 1 ]; then
  gh label create "$LABEL" "${REPO_ARGS[@]}" --color B60205 \
    --description "Needs a human (sudo, licences, hardware)" 2>/dev/null || true
  existing=$(gh issue list "${REPO_ARGS[@]}" --label "$LABEL" --state all --limit 200 --json title -q '.[].title')
fi

for f in "${files[@]}"; do
  title=$(head -n1 "$f"); body=$(tail -n +2 "$f")
  if [ "$CREATE" = 1 ]; then
    if grep -qxF "$title" <<<"$existing"; then echo "skip (exists): $title"; continue; fi
    gh issue create "${REPO_ARGS[@]}" --title "$title" --label "$LABEL" --body "$body"
  else
    echo "would create: $title ($(wc -l <"$f") lines)"
  fi
done
[ "$CREATE" = 1 ] || echo "(dry run; re-run with --create [--repo owner/name])"
