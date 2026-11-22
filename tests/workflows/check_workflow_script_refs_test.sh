#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Regression controls for scripts/check-workflow-script-refs.sh. No network used.
# Usage: bash tests/workflows/check_workflow_script_refs_test.sh
#
# Every refusal is paired with a case that must stay clean, so the check cannot
# pass because it stopped matching, nor fail because it started matching too much.
set -uo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
chk="$repo/scripts/check-workflow-script-refs.sh"
work=$(mktemp -d) || { echo "FAIL: mktemp" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT
fail=0
bad() { echo "FAIL: $*" >&2; [ -f "$work/out" ] && sed 's/^/    | /' "$work/out" >&2; fail=1; }
ok() { echo "PASS: $*"; }

# fixture NAME: a root with one workflow whose body is read from stdin.
fixture() {
  rm -rf "$work/r"; mkdir -p "$work/r/.github/workflows" "$work/r/scripts"
  cat > "$work/r/.github/workflows/$1"
}
run() { bash "$chk" "$work/r" > "$work/out" 2>&1; echo $?; }
expect() { # expect CODE LABEL [GREP]
  local want="$1" label="$2" pat="${3:-}" got
  got=$(run)
  if [ "$got" != "$want" ]; then bad "$label (exit $got, wanted $want)"; return; fi
  if [ -n "$pat" ] && ! grep -qE -- "$pat" "$work/out"; then bad "$label (output lacks: $pat)"; return; fi
  ok "$label"
}
script() { printf '#!/usr/bin/env bash\nexit 0\n' > "$work/r/scripts/$1"; [ "${2:-x}" = x ] && chmod +x "$work/r/scripts/$1"; return 0; }

# 1. The phronesis#122 case: workflow copied, companion script absent.
fixture empty-linter.yml <<'YML'
jobs:
  empty-lint:
    steps:
      - name: Scan
        run: |
          if ! scripts/check-invisible-characters.sh "$GITHUB_WORKSPACE" a b; then
            exit 2
          fi
YML
expect 1 "workflow copied without its companion script is refused" \
  'empty-linter.yml,line=6::.*scripts/check-invisible-characters.sh does not exist'
script check-invisible-characters.sh
expect 0 "same workflow with the companion script present is clean"

# 2. Interpreter calls need existence, not a mode bit; direct calls need both.
fixture ci.yml <<'YML'
jobs:
  a:
    steps:
      - run: bash scripts/one.sh .
      - run: bun scripts/two.js
YML
script one.sh nox; script two.js nox
expect 0 "interpreter-called scripts need no exec bit"
fixture ci.yml <<'YML'
jobs:
  a:
    steps:
      - run: ./scripts/three.sh
YML
script three.sh nox
expect 1 "directly-run script without exec bit is refused" 'runs scripts/three.sh directly but it is not executable'
chmod +x "$work/r/scripts/three.sh"
expect 0 "directly-run script with exec bit is clean"
fixture ci.yml <<'YML'
jobs:
  a:
    steps:
      - run: scripts/four.sh
YML
expect 1 "run: scripts/x with the script absent is refused" 'does not exist'

# 3. Out of scope: other checkouts, lists, messages, comments.
fixture ci.yml <<'YML'
jobs:
  a:
    steps:
      # bash scripts/in-a-comment.sh
      - run: bash .standards-checkout/scripts/other.sh
      - run: bash "$d/scripts/other2.sh" .
      - run: bash "$RUNNER_TEMP/fleet-src/scripts/other3.sh"
      - run: echo "::warning::run scripts/in-a-message.sh to fix"
      - uses: actions/checkout@v1
        with:
          sparse-checkout: |
            scripts/listed-only.sh
YML
expect 0 "other checkouts, lists, messages and comments are not read"

# 4. A script the same workflow tests for is optional by design there.
fixture ci.yml <<'YML'
jobs:
  a:
    steps:
      - run: |
          if [ -f scripts/optional.sh ]; then
            bash scripts/optional.sh
          fi
      - run: |
          test -x scripts/required.sh || exit 1
          ./scripts/required.sh
YML
expect 0 "a script the workflow itself guards is not demanded"

# 5. Flags before the script; command substitution; quotes.
fixture ci.yml <<'YML'
jobs:
  a:
    steps:
      - run: bash -e scripts/flagged.sh
      - run: X=$(bash scripts/subst.sh --find .)
      - run: bash 'scripts/quoted.sh'
YML
expect 1 "flagged, substituted and quoted calls are all read" 'scripts/flagged.sh does not exist'
grep -q 'scripts/subst.sh' "$work/out" && ok "command-substitution call named in the output" || bad "command-substitution call not detected"
grep -q 'scripts/quoted.sh' "$work/out" && ok "quoted call named in the output" || bad "quoted call not detected"

# 6. Edge handling.
rm -rf "$work/r"; mkdir -p "$work/r"
expect 0 "no .github/workflows directory: nothing to check" 'nothing to check'
mkdir -p "$work/r/.github/workflows"
expect 0 "an empty workflows directory: nothing to check" 'nothing to check'
if bash "$chk" "$work/does-not-exist" >/dev/null 2>&1; then bad "non-directory ROOT was accepted"; else ok "non-directory ROOT is refused"; fi

# 7. The template itself must satisfy the rule it ships.
if bash "$chk" "$repo" > "$work/out" 2>&1; then ok "this repository's own workflows pass"; else bad "this repository's own workflows fail the check"; fi

# 8. Wiring: the check must actually run in CI, or it guards nothing.
if grep -q 'check-workflow-script-refs_test\|check_workflow_script_refs_test' "$repo/.github/workflows/estate-rules.yml" \
   && grep -q 'scripts/check-workflow-script-refs.sh' "$repo/.github/workflows/estate-rules.yml"; then
  ok "estate-rules.yml runs the check and its test"
else
  bad "estate-rules.yml does not run check-workflow-script-refs.sh and its test"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "FAILURES above" >&2; exit 1; }
