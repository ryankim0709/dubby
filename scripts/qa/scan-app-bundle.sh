#!/usr/bin/env bash
# Scans a built .app bundle for provider secrets and direct LLM endpoints that must never ship
# in the iOS app: an OpenAI key (literal or the OPENAI_API_KEY name), direct api.openai.com
# calls, Anthropic key names and endpoints, and other LLM vendor endpoints. Only the pattern
# name and the file are printed, never the matched text.
#
#   scripts/qa/scan-app-bundle.sh <path to Dubbing.app>
#   scripts/qa/scan-app-bundle.sh --self-test
#
# Exit codes: 0 clean, 1 findings, 2 usage error or failed self-test.

set -euo pipefail

export LC_ALL=C

PATTERN_NAMES=(openai-key-literal openai-key-name openai-endpoint anthropic-key-name anthropic-endpoint other-llm-endpoint)
PATTERNS=(
  '(^|[^A-Za-z0-9])sk-(proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}'
  'OPENAI_API_KEY'
  'api\.openai\.com'
  'ANTHROPIC_API_KEY'
  'api\.anthropic\.com'
  'generativelanguage\.googleapis\.com|api\.cohere\.(com|ai)|api\.mistral\.ai|api\.groq\.com|openrouter\.ai|api\.deepseek\.com|api\.x\.ai'
)

scan_bundle() {
  local bundle="$1" found=0 index files
  for index in "${!PATTERNS[@]}"; do
    files="$(grep -rlaE -e "${PATTERNS[$index]}" "$bundle" 2>/dev/null || true)"
    [ -n "$files" ] || continue
    found=1
    printf '%s\n' "$files" | sed "s|^$bundle/||; s|^|[${PATTERN_NAMES[$index]}] |"
  done
  return "$found"
}

SELF_TEST_DIR=""

self_test() {
  local status=0 output
  SELF_TEST_DIR="$(mktemp -d)"
  trap 'rm -rf "$SELF_TEST_DIR"' EXIT
  local dir="$SELF_TEST_DIR"
  mkdir -p "$dir/clean.app" "$dir/dirty.app/Frameworks"
  printf 'Info\0task-abcdefghijklmnopqrstuvwxyz0123\0https://example.com\0' >"$dir/clean.app/Dubbing"
  {
    printf 'binary\0'
    printf '%s%s\0' 'sk-proj-' 'AAAAAAAAAAAAAAAAAAAAAAAA'
    printf '%s_%s\0' 'OPENAI' 'API_KEY'
    printf 'https://api.%s.com/v1/responses\0' 'openai'
    printf '%s_%s\0' 'ANTHROPIC' 'API_KEY'
    printf 'https://api.%s.com/v1/messages\0' 'anthropic'
    printf 'https://api.%s.ai/\0' 'mistral'
  } >"$dir/dirty.app/Frameworks/Core"
  scan_bundle "$dir/clean.app" || {
    echo "self-test FAIL: the clean bundle was flagged" >&2
    exit 2
  }
  output="$(scan_bundle "$dir/dirty.app")" && status=0 || status=$?
  [ "$status" -ne 0 ] || {
    echo "self-test FAIL: the dirty bundle was not flagged" >&2
    exit 2
  }
  for name in "${PATTERN_NAMES[@]}"; do
    printf '%s\n' "$output" | grep -q "\[$name\]" || {
      echo "self-test FAIL: pattern $name did not fire; output: $output" >&2
      exit 2
    }
  done
  echo "self-test passed: all ${#PATTERN_NAMES[@]} patterns fire on a dirty bundle and none on a clean one"
}

case "${1:-}" in
  --self-test) self_test ;;
  "")
    echo "usage: $0 <path to Dubbing.app> | --self-test" >&2
    exit 2
    ;;
  *)
    [ -d "$1" ] || {
      echo "error: $1 is not a directory" >&2
      exit 2
    }
    if scan_bundle "$(cd "$1" && pwd)"; then
      echo "Bundle scan: no provider keys or direct LLM endpoints in $1"
    else
      echo "Bundle scan: provider keys or direct LLM endpoints found (see above)" >&2
      exit 1
    fi
    ;;
esac
