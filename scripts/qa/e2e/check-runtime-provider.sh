#!/usr/bin/env bash
# Static check of the runtime AI provider rule: the deployed app uses OpenAI only, through the
# official SDK and the Responses API, with the key on the Convex backend only.
#
#   scripts/qa/e2e/check-runtime-provider.sh [repo-root]
#
# Exit 0 when every check passes, 1 when any fails. Documentation mentions are reported but do not fail.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$ROOT"

FAILED=0
fail() { echo "FAIL  $*"; FAILED=1; }
pass() { echo "PASS  $*"; }

RUNTIME_PATHS=()
for path in convex package.json package-lock.json Dubbing Config; do
  [ -e "$path" ] && RUNTIME_PATHS+=("$path")
done

VENDOR='anthropic|claude-(opus|sonnet|haiku|fable)|ANTHROPIC_API_KEY|api\.anthropic\.com|generativelanguage\.googleapis|GEMINI_API_KEY|GOOGLE_API_KEY|MISTRAL_API_KEY|GROQ_API_KEY|api\.x\.ai|XAI_API_KEY'
HITS="$(grep -rniE "$VENDOR" "${RUNTIME_PATHS[@]}" --exclude-dir=node_modules --exclude-dir=_generated 2>/dev/null || true)"
if [ -n "$HITS" ]; then
  fail "runtime code or dependencies reference a non-OpenAI vendor:"
  echo "$HITS" | cut -c1-200 | sed 's/^/        /'
else
  pass "no non-OpenAI vendor SDK, key name, endpoint or model id in the runtime paths"
fi

if [ -d convex ]; then
  if grep -rqE "from ['\"]openai['\"]|require\(['\"]openai['\"]\)" convex --include='*.ts' --include='*.js' 2>/dev/null; then
    pass "convex/ imports the official openai SDK"
  else
    fail "convex/ does not import the official openai SDK"
  fi
  if grep -rqE '\.responses\.create|responses\.stream' convex --include='*.ts' --include='*.js' 2>/dev/null; then
    pass "convex/ calls the Responses API"
  else
    fail "convex/ does not call the Responses API (responses.create)"
  fi
  if grep -rqE 'chat\.completions' convex --include='*.ts' --include='*.js' 2>/dev/null; then
    fail "convex/ uses the Chat Completions API instead of the Responses API"
  else
    pass "convex/ does not use Chat Completions"
  fi
fi

if grep -rnE 'OPENAI_API_KEY|sk-[A-Za-z0-9_-]{20,}' Dubbing Config DubbingTests DubbingUITests .github .revyl scripts 2>/dev/null | grep -v 'scripts/qa/e2e/check-' | grep -q .; then
  fail "a key name or key-shaped string appears outside the backend:"
  grep -rnE 'OPENAI_API_KEY|sk-[A-Za-z0-9_-]{20,}' Dubbing Config DubbingTests DubbingUITests .github .revyl scripts 2>/dev/null | grep -v 'scripts/qa/e2e/check-' | cut -c1-160 | sed 's/^/        /'
else
  pass "no OPENAI_API_KEY name or key-shaped string in the app, tests, workflows or Revyl config"
fi

DOCS="$(grep -lniE "$VENDOR" README.md AGENTS.md docs/*.md 2>/dev/null | grep -v '^docs/qa/' || true)"
[ -n "$DOCS" ] && echo "NOTE  documentation still mentions another vendor (not a failure): $(echo $DOCS | tr '\n' ' ')"

exit "$FAILED"
