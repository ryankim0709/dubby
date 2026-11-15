#!/usr/bin/env bash
# Looks for a provider key or its variable name inside run artifacts: an app bundle, a log directory,
# a text export. Never prints a matched value, only the file and the kind of match.
#
#   scripts/qa/e2e/check-no-key-in-artifacts.sh <path> [path...]
#
# Exit 0 when nothing is found, 1 when a hit exists, 2 on usage error.
set -uo pipefail
[ "$#" -ge 1 ] || { echo "usage: $0 <path> [path...]" >&2; exit 2; }

FOUND=0
scan() {
  local kind="$1" pattern="$2"
  shift 2
  local files
  files="$(grep -rlaE "$pattern" "$@" 2>/dev/null || true)"
  if [ -n "$files" ]; then
    FOUND=1
    echo "FAIL  $kind found in:"
    echo "$files" | sed 's/^/        /'
  else
    echo "PASS  no $kind"
  fi
}

scan "OPENAI_API_KEY variable name" 'OPENAI_API_KEY' "$@"
scan "key-shaped string (sk-...)" 'sk-[A-Za-z0-9_-]{20,}' "$@"
scan "bearer credential" 'Bearer +[A-Za-z0-9._-]{20,}' "$@"
scan "other provider key name" 'LIVEAVATAR_API_KEY|ANTHROPIC_API_KEY' "$@"
exit "$FOUND"
