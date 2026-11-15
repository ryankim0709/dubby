#!/usr/bin/env bash
# Fails when a Release app bundle still contains QA-only content: the synthetic microphone fixture.
#
#   scripts/qa/e2e/check-release-bundle.sh <path to Dubbing.app built with -configuration Release>
#
# Exit 0 when the bundle is clean, 1 when QA content is present, 2 on usage error.
set -uo pipefail
APP="${1:-}"
[ -d "$APP" ] || { echo "usage: $0 <Dubbing.app>" >&2; exit 2; }
HITS="$(find "$APP" \( -iname 'qa-speech-fixture*' -o -iname 'QAFixtures' \) 2>/dev/null)"
if [ -n "$HITS" ]; then
  echo "FAIL  QA-only content is inside the Release bundle:"
  echo "$HITS" | sed 's/^/        /'
  exit 1
fi
echo "PASS  no QA fixture inside $APP"
