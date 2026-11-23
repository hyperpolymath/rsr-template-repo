#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Lockstep test: the shellcheck severity that
# pre-commit runs must equal the one .github/workflows/quality.yml enforces.
#
# The repo's shellcheck policy is stated once, in quality.yml (`shellcheck -S
# error`). ci/.pre-commit-config.yaml mirrors it with `--severity=error` so that
# pre-commit.ci and the quality gate agree about what is a failure. If one is
# raised or lowered alone, a file can pass one gate and fail the other, and the
# disagreement only shows up on a pull request.
#
# lockstep DIR — print why the two differ and return 1, or return 0. It is run
# on the real tree, then on fixtures that each break it one way: a different
# level on each side, a missing pre-commit severity, and a missing quality.yml
# level. Each must be refused, so a pass is not the instrument agreeing with
# everything.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PRE=ci/.pre-commit-config.yaml
QUAL=.github/workflows/quality.yml

fail() { echo "FAIL: $1" >&2; exit 1; }

# lockstep DIR — compare the two severities under DIR.
lockstep() {
    local d="$1" pre qual
    [ -f "$d/$PRE" ] || { echo "$PRE is missing"; return 1; }
    [ -f "$d/$QUAL" ] || { echo "$QUAL is missing"; return 1; }
    pre="$(sed -n 's/^[[:space:]]*args:[[:space:]]*\[--severity=\([a-z]*\)\].*/\1/p' "$d/$PRE")"
    qual="$(sed -n 's/^[[:space:]]*shellcheck -S \([a-z]*\) .*/\1/p' "$d/$QUAL")"
    [ "$(printf '%s\n' "$pre" | grep -c .)" = 1 ] || { echo "$PRE does not set exactly one --severity (found: '$pre')"; return 1; }
    [ "$(printf '%s\n' "$qual" | grep -c .)" = 1 ] || { echo "$QUAL does not run exactly one 'shellcheck -S <level>' (found: '$qual')"; return 1; }
    [ "$pre" = "$qual" ] || { echo "severity differs: pre-commit '$pre' vs quality.yml '$qual'"; return 1; }
    return 0
}

# 1. The real tree.
out="$(lockstep "$ROOT")" || fail "$out"

# 2. Fixtures. Each starts from a conforming pair and breaks it one way.
FIX="$(mktemp -d)"
trap 'rm -rf "${FIX:?}"' EXIT
fresh() {
    rm -rf "${FIX:?}/t"; mkdir -p "$FIX/t/ci" "$FIX/t/.github/workflows"
    printf '      - id: shellcheck\n        args: [--severity=error]\n' > "$FIX/t/$PRE"
    printf '            shellcheck -S error FILE || fail=1\n' > "$FIX/t/$QUAL"
}

fresh
out="$(lockstep "$FIX/t")" || fail "control: a conforming fixture was refused: $out"

fresh; sed -i 's/--severity=error/--severity=warning/' "$FIX/t/$PRE"
if out="$(lockstep "$FIX/t")"; then fail "pre-commit stricter than quality.yml was accepted"; fi
grep -q 'severity differs' <<<"$out" || fail "refused for the wrong reason: $out"

fresh; sed -i 's/-S error/-S warning/' "$FIX/t/$QUAL"
if out="$(lockstep "$FIX/t")"; then fail "quality.yml stricter than pre-commit was accepted"; fi
grep -q 'severity differs' <<<"$out" || fail "refused for the wrong reason: $out"

fresh; printf '      - id: shellcheck\n' > "$FIX/t/$PRE"
if out="$(lockstep "$FIX/t")"; then fail "a pre-commit config with no severity was accepted"; fi

fresh; printf '            shellcheck FILE || fail=1\n' > "$FIX/t/$QUAL"
if out="$(lockstep "$FIX/t")"; then fail "a quality.yml with no -S level was accepted"; fi

echo "PASS: pre-commit and quality.yml agree on shellcheck severity '$(sed -n 's/.*--severity=\([a-z]*\).*/\1/p' "$ROOT/$PRE")'; 4 broken shapes refused"
