#!/usr/bin/env bash
# Runtime AI provider policy: every AI agent inside the deployed app uses OpenAI only,
# through the Responses API, with OPENAI_API_KEY on the Convex backend only.
#
#   scripts/qa/check-llm-provider.sh [--root DIR]   check a tree (default: this repository)
#   scripts/qa/check-llm-provider.sh --self-test    prove each rule fires on fixture trees
#
# Rules (a match prints file:line and the rule id; matched values are never printed):
#   non-openai-vendor      a non-OpenAI LLM vendor SDK, endpoint, key name, or model name in
#                          convex/, Dubbing/, Config/, or the root package.json and lockfile
#   openai-non-responses   OpenAI text generation outside the Responses API (chat completions,
#                          legacy completions, assistants, threads) in the same runtime paths
#   openai-in-app          OPENAI_API_KEY, a literal key, a direct api.openai.com call, or an
#                          OpenAI client library in the iOS app, its configuration, its
#                          project settings, or its tests and fixtures
#
# Docs, .agents/, node_modules, convex/_generated, and this check's own fixtures are not scanned.
# Exit codes: 0 clean, 1 violations found, 2 usage error or failed self-test.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VENDOR_PATTERN='anthropic|(^|[^[:alnum:]])claude([^[:alnum:]]|$)|@google/(generative-ai|genai)|generativelanguage\.googleapis|gemini_api_key|cohere-ai|api\.cohere\.|@mistralai|api\.mistral\.ai|groq-sdk|api\.groq\.com|@ai-sdk/|openrouter\.ai|api\.together\.|togetherai|api\.deepseek\.|api\.x\.ai|client-bedrock|bedrock-runtime|api\.perplexity\.ai|huggingface\.co/api/inference'
NON_RESPONSES_PATTERN='chat\.completions|chat/completions|v1/completions|\.completions\.create|beta\.assistants|beta\.threads|/v1/assistants|/v1/threads'
APP_PATTERN='OPENAI_API_KEY|api\.openai\.com|(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}|import OpenAI|MacPaw/OpenAI|swift-openai|openai-swift|OpenAIKit'

EXCLUDES=(--exclude-dir=node_modules --exclude-dir=_generated --exclude-dir=.git --exclude-dir=.agents --exclude-dir=xcuserdata --exclude-dir=fixtures)

# scan_rule <rule id> <fold case: 0|1> <pattern> <paths...>
# Prints "file:line  [rule]" for each hit and returns 1 when there is any.
scan_rule() {
  local rule="$1" fold="$2" pattern="$3"
  shift 3
  local flags=(-rInE) hits path targets=()
  [ "$fold" = 1 ] && flags=(-rInEi)
  for path in "$@"; do
    [ -e "$path" ] && targets+=("$path")
  done
  [ "${#targets[@]}" -gt 0 ] || return 0
  hits="$(grep "${flags[@]}" "${EXCLUDES[@]}" -o -e "$pattern" "${targets[@]}" 2>/dev/null | cut -d: -f1,2 | sort -u || true)"
  [ -n "$hits" ] || return 0
  printf '%s\n' "$hits" | sed "s|\$|  [$rule]|"
  return 1
}

check_tree() {
  local failed=0
  cd "$1"
  scan_rule non-openai-vendor 1 "$VENDOR_PATTERN" convex Dubbing Config package.json package-lock.json || failed=1
  scan_rule openai-non-responses 1 "$NON_RESPONSES_PATTERN" convex Dubbing Config || failed=1
  scan_rule openai-in-app 0 "$APP_PATTERN" Dubbing Config DubbingTests DubbingUITests Dubbing.xcodeproj || failed=1
  return "$failed"
}

self_test() {
  local cases="$SCRIPT_DIR/fixtures/llm-provider" failures=0 case_dir name expected output status rule
  for case_dir in "$cases"/*/; do
    name="$(basename "$case_dir")"
    expected="$(cat "$case_dir/expected-rules" 2>/dev/null || true)"
    status=0
    output="$(check_tree "$case_dir/tree" 2>&1)" || status=$?
    if [ -z "$expected" ]; then
      if [ "$status" -ne 0 ]; then
        echo "self-test FAIL $name: expected a clean tree, got: $output" >&2
        failures=$((failures + 1))
      fi
      continue
    fi
    if [ "$status" -eq 0 ]; then
      echo "self-test FAIL $name: expected violations, found none" >&2
      failures=$((failures + 1))
      continue
    fi
    for rule in $expected; do
      if ! printf '%s\n' "$output" | grep -q "\[$rule\]"; then
        echo "self-test FAIL $name: rule $rule did not fire; output: $output" >&2
        failures=$((failures + 1))
      fi
    done
  done
  [ "$failures" -eq 0 ] || exit 2
  echo "self-test passed: $(find "$cases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') fixture trees behaved as expected"
}

case "${1:-}" in
  --self-test) self_test ;;
  --root)
    [ -d "${2:-}" ] || {
      echo "usage: $0 [--root DIR | --self-test]" >&2
      exit 2
    }
    check_tree "$2"
    ;;
  "")
    if check_tree "$ROOT"; then
      echo "LLM provider policy: clean"
    else
      echo >&2
      echo "LLM provider policy: violations above (see docs/qa/README.md#llm-provider-policy-check)" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 [--root DIR | --self-test]" >&2
    exit 2
    ;;
esac
