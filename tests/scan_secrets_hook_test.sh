#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# scan_secrets_hook_test.sh — contract test for .github/hooks/scan-secrets.sh.
#
# Uses a fake scanner that records its arguments and exits with a chosen code,
# so it tests the hook's own logic (flags passed, depth-limit handling, exit
# handling). It does NOT test TruffleHog's detection; that needs the real binary.
#
# SCRIPT=<path> runs the test against another copy of the hook (used to check
# that the test fails on the pre-fix hook).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO_ROOT/.github/hooks/scan-secrets.sh}"
ZERO="0000000000000000000000000000000000000000"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
check() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then echo "  PASS: $name"; else echo "  FAIL: $name (expected '$want', got '$got')"; fail=1; fi
}

cat > "$T/th" <<'FAKE_SCANNER'
#!/bin/sh
if [ "$1" = "--version" ]; then echo "trufflehog 3.96.0"; exit 0; fi
echo "$@" >> "$TH_LOG"
exit "${TH_RC:-0}"
FAKE_SCANNER
chmod +x "$T/th"

git init -q "$T/repo"
git -C "$T/repo" config user.email t@example.invalid
git -C "$T/repo" config user.name t
git -C "$T/repo" config commit.gpgsign false
for i in 1 2 3; do echo "$i" > "$T/repo/f"; git -C "$T/repo" add f; git -C "$T/repo" commit -qm "c$i"; done
HEAD_SHA="$(git -C "$T/repo" rev-parse HEAD)"

run() { # ranges depth rc -> sets RC, CALLS, ARGS
  export TH_LOG="$T/log"; : > "$TH_LOG"
  RC=0
  INPUT_PATH="$T/repo" TRUFFLEHOG="$T/th" K9_PUSH_RANGES="$1" K9_SECRETS_MAX_DEPTH="$2" TH_RC="${3:-0}" \
    bash "$SCRIPT" >"$T/out" 2>&1 || RC=$?
  CALLS="$(wc -l < "$TH_LOG" | tr -d ' ')"; ARGS="$(cat "$TH_LOG")"
}
NEW="refs/heads/x $HEAD_SHA refs/heads/x $ZERO"

echo "scan-secrets hook:"
run "$NEW" 500 0
check "clean new branch passes" "$RC" 0
check "scanner told to fail on scan errors" "$(grep -c -- '--fail-on-scan-errors' <<<"$ARGS")" 1

run "$NEW" 2 0
check "new branch larger than the depth limit is blocked" "$RC" 1
check "…and no partial scan is run" "$CALLS" 0

run "" 500 0
check "fallback scan passes" "$RC" 0
check "fallback scans HEAD explicitly" "$(grep -c -- '--branch HEAD' <<<"$ARGS")" 1

run "$NEW" 500 1
check "scanner error blocks" "$RC" 1
check "scanner error is reported as an error, not a secret" "$(grep -c 'SCANNER ERROR' "$T/out")" 1

run "$NEW" 500 183
check "findings block" "$RC" 1

if [[ "$fail" -eq 0 ]]; then echo "PASS: scan-secrets hook contract"; else echo "FAIL: scan-secrets hook contract"; exit 1; fi
