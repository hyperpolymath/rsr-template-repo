#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Silence + Firing tests for scripts/check-workflow-edges.sh.
#
# Each rule is exercised by mutating a
# COPY of the real workflows — a rename here, an artifact there — and asserting
# exactly one failure comes out. A check that only ever passes proves nothing:
# every firing control below is a mutation of something this repository ships.
set +e
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO_DIR/scripts/check-workflow-edges.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() {
    fail=$((fail + 1))
    echo "  FAIL: $1" >&2
    echo "::error::workflow-edges test failed: $1" # NOSONAR
}

run() { "$BASH" "$CHECK" "${1:-$WORK/repo}" >"$WORK/out" 2>&1; }
expect_rc() { # expect_rc RC LABEL [ROOT]
    local want="$1" label="$2" root="${3:-$WORK/repo}" got=0
    run "$root" || got=$?
    if [ "$got" -eq "$want" ]; then ok "$label"; else
        bad "$label (wanted exit ${want}, got ${got})"
        sed 's/^/        /' "$WORK/out"
    fi
}
says() { if grep -Fq -- "$2" "$WORK/out"; then ok "$1"; else bad "$1 (no '$2' in output)"; sed 's/^/        /' "$WORK/out"; fi; }

# Fresh copy of the workflows directory for each case.
fresh() {
    rm -rf "$WORK/repo"
    mkdir -p "$WORK/repo/.github"
    cp -r "$REPO_DIR/.github/workflows" "$WORK/repo/.github/workflows"
    printf '%s' "$WORK/repo"
}

echo "=== 1. The repository as it ships ==="
fresh >/dev/null
expect_rc 0 "every edge resolves on the shipped workflows"
says "the summary counts the edges it checked" "workflow_run edge(s)"

echo "=== 2. Firing: a dead workflow_run edge ==="
fresh >/dev/null
sed -i 's/^name: Hypatia Security Scan$/name: Hypatia Scan/' "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "renaming a producer is caught (workflow_run matches name:, not the file)" 
says "the failure names the dead edge" "Hypatia Security Scan"
says "the failure says what it breaks" "never re-render"

echo "=== 2b. A workflow name with the old name as a prefix is NOT a match ==="
fresh >/dev/null
sed -i 's/^name: Hypatia Security Scan$/name: Hypatia Security Scan v2/' "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "a renamed producer with the old name as a prefix is caught"
says "the mismatch names the exact old workflow" "Hypatia Security Scan"

echo "=== 3. Firing: a producer that stops running on pull_request ==="
fresh >/dev/null
python3 - "$WORK/repo/.github/workflows/static-analysis-gate.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("  pull_request:\n    branches: ['**']\n", "")
open(p, "w").write(s)
PY
expect_rc 1 "a producer with no pull_request trigger is caught"
says "the failure explains the consequence" "only after a push"

echo "=== 4. Firing: an artifact name that nothing produces ==="
fresh >/dev/null
python3 - "$WORK/repo/.github/workflows/static-analysis-gate.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("          name: static-analysis-findings\n", "          name: static-analysis\n", 1)
open(p, "w").write(s)
PY
expect_rc 1 "renaming the evidence artifact is caught"
says "the failure names the artifact" "never uploads"

echo "=== 5. Firing: a tool pin that disagrees with the producer ==="
fresh >/dev/null
sed -i 's/^  PANIC_ATTACK_SHA: b5530834a839734d1d181bfe6edb0d43d4233cf4$/  PANIC_ATTACK_SHA: b689a74d2762a1c19839ae3fbd59b7fe5ef920ea/' "$WORK/repo/.github/workflows/static-analysis-gate.yml"
sed -i 's/--panic-ref b5530834a839734d1d181bfe6edb0d43d4233cf4/--panic-ref b5530834a839734d1d181bfe6edb0d43d4233cf4/' "$WORK/repo/.github/workflows/fork-governance.yml"
expect_rc 1 "a producer pin that moves without the verdict job is caught"
says "the failure names the flag and the variable" "--panic-ref"

echo "=== 6. Firing: one tool pinned at two commits ==="
fresh >/dev/null
python3 - "$WORK/repo/.github/workflows/codeql.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("jobs:\n", "env:\n  PANIC_ATTACK_SHA: 1111111111111111111111111111111111111111\n\njobs:\n", 1)
open(p, "w").write(s)
PY
expect_rc 1 "a second pin for the same tool is caught"
says "the failure says the pin is in two places" "different commits"

echo "=== 7. Firing: no workflow_run at all ==="
fresh >/dev/null
python3 - "$WORK/repo/.github/workflows/verdict-grid-publish.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
start = s.index("  workflow_run:")
end = s.index("    types: [completed]\n") + len("    types: [completed]\n")
open(p, "w").write(s[:start] + s[end:])
PY
expect_rc 1 "a reporter with no workflow_run is caught"
says "the failure says the grid would never re-render" "never re-render"

echo "=== 8. Firing: two workflows with the same name: ==="
fresh >/dev/null
python3 - "$WORK/repo/.github/workflows/codeql.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
i = s.index("\nname: ")
j = s.index("\n", i + 1)
open(p, "w").write(s[:i] + "\nname: Hypatia Security Scan" + s[j:])
PY
expect_rc 1 "two files sharing a name: are caught"
says "the failure names the collision" "share a name"

echo "=== 9. Firing: no evidence sources at all ==="
fresh >/dev/null
sed -i 's/--source \(hypatia-scan\|static-analysis-gate\)\.yml:[a-z-]*/--quiet/g' "$WORK/repo/.github/workflows/fork-governance.yml"
expect_rc 1 "a reporter that collects nothing is caught"
says "the failure says the grid would have no rows" "no rows"

echo "=== 10. Setup errors ==="
expect_rc 2 "a missing repository directory is a setup error" "$WORK/nope"
rm -rf "$WORK/repo"; mkdir -p "$WORK/repo/.github/workflows"
expect_rc 2 "a missing reporter workflow is a setup error" "$WORK/repo"

echo "=== 11. Publisher edges and exact artifact identity ==="
fresh >/dev/null
sed -i 's/--source hypatia-scan.yml:/--source absent-scanner.yml:/' "$WORK/repo/.github/workflows/verdict-grid-publish.yml"
expect_rc 1 "a publisher source naming a missing workflow is refused"
says "the missing producer is identified" "absent-scanner.yml"

fresh >/dev/null
sed -i 's/--hypatia-ref [0-9a-f]*/--hypatia-ref 1111111111111111111111111111111111111111/' "$WORK/repo/.github/workflows/verdict-grid-publish.yml"
expect_rc 1 "a stale publisher pin fails even when the PR reporter pin is correct"
says "the diagnostic identifies the publisher" "--hypatia-ref in verdict-grid-publish.yml"

fresh >/dev/null
sed -i 's/--source \(hypatia-scan\|static-analysis-gate\)\.yml:[a-z-]*/--quiet/g' "$WORK/repo/.github/workflows/verdict-grid-publish.yml"
expect_rc 1 "a publisher with no evidence sources is refused"
says "the publisher-specific diagnostic explains the missing rows" "published grid would have no rows"

fresh >/dev/null
# A different step's name cannot stand in for an upload-artifact output name.
# The producer here is a local-upload job written by the test, so the control
# holds whatever shape this repository's hypatia-scan.yml has (a minted child
# may delegate its scan to a reusable workflow, section 10).
wf="$WORK/repo/.github/workflows/hypatia-scan.yml"
grid_pin="$(grep -o -- '--hypatia-ref [0-9a-f]\{40\}' "$WORK/repo/.github/workflows/fork-governance.yml" | head -n1 | awk '{print $2}')"
awk '/^jobs:/ { exit } { print }' "$wf" > "$wf.new"
printf 'jobs:\n  scan:\n    runs-on: ubuntu-latest\n    env:\n      HYPATIA_SHA: %s\n    steps:\n      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9\n        with:\n          name: hypatia-scan-findings-backup\n          path: out\n      - name: hypatia-scan-findings\n        run: true\n' "$grid_pin" >> "$wf.new"
mv "$wf.new" "$wf"
expect_rc 1 "an artifact prefix or unrelated step name cannot satisfy the source edge"
says "the diagnostic requires an actual artifact upload" "never uploads"

fresh >/dev/null
sed -i 's/^name: Hypatia Security Scan$/name: "Hypatia Security Scan"/' "$WORK/repo/.github/workflows/hypatia-scan.yml"
sed -i "s/^name: Static Analysis Gate$/name: 'Static Analysis Gate'/" "$WORK/repo/.github/workflows/static-analysis-gate.yml"
expect_rc 0 "quoted producer names preserve their workflow_run edges"

fresh >/dev/null
rm "$WORK/repo/.github/workflows/verdict-grid-publish.yml"
expect_rc 2 "a missing trusted publisher is a setup error"
says "the missing publisher is named" "publisher workflow"


echo "=== 10. A producer that delegates to a reusable workflow ==="
# Offline: the called workflow is served from EDGES_REUSABLE_DIR, never fetched.
HSHA="$(grep -o -- '--hypatia-ref [0-9a-f]\{40\}' "$REPO_DIR/.github/workflows/fork-governance.yml" | head -n1 | awk '{print $2}')"
RSHA=1111111111111111111111111111111111111111
REUSABLES="$WORK/reusables"
# delegate [WITH] — replace hypatia-scan.yml's jobs with one reusable call.
delegate() {
    local wf="$WORK/repo/.github/workflows/hypatia-scan.yml" ref="${2:-$RSHA}"
    awk '/^jobs:/ { exit } { print }' "$wf" > "$wf.new"
    printf 'jobs:\n  hypatia:\n    uses: owner/standards/.github/workflows/scan.yml@%s\n' "$ref" >> "$wf.new"
    [ -z "${1:-}" ] || printf '    with:\n      hypatia-ref: %s\n' "$1" >> "$wf.new"
    mv "$wf.new" "$wf"
}
# reusable [ARTIFACT] — the called workflow at RSHA, uploading ARTIFACT.
reusable() {
    local dir="$REUSABLES/owner/standards/$RSHA/.github/workflows"
    rm -rf "$REUSABLES"; mkdir -p "$dir"
    printf 'on:\n  workflow_call:\njobs:\n  scan:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9\n        with:\n          name: %s\n          path: out\n' "${1:-hypatia-scan-findings}" > "$dir/scan.yml"
}
export EDGES_REUSABLE_DIR="$REUSABLES"

fresh >/dev/null; reusable; delegate "$HSHA"
expect_rc 0 "a reusable producer passing the verdict's pin resolves both edges"

fresh >/dev/null; reusable; delegate
expect_rc 1 "a reusable producer that passes no hypatia-ref is caught"
says "the failure says the default runs instead" "without passing hypatia-ref"

fresh >/dev/null; reusable; delegate 2222222222222222222222222222222222222222
expect_rc 1 "a reusable producer passing a different pin is caught"
says "the mismatch names the input it read" "with: hypatia-ref"

fresh >/dev/null; reusable other-artifact; delegate "$HSHA"
expect_rc 1 "a reusable that does not upload the evidence artifact is caught"
says "the failure names the missing artifact" "never uploads"

fresh >/dev/null; reusable; delegate "$HSHA" v1
expect_rc 2 "a reusable call pinned to a tag cannot be followed (setup error)"
says "the failure asks for a full SHA" "full commit SHA"

fresh >/dev/null; rm -rf "$REUSABLES"; mkdir -p "$REUSABLES"; delegate "$HSHA"
expect_rc 2 "an unreadable reusable is a setup error, never a pass"
says "the failure names the unreadable call" "not in EDGES_REUSABLE_DIR"

fresh >/dev/null; reusable; delegate "$HSHA"
cat >> "$WORK/repo/.github/workflows/hypatia-scan.yml" <<'YML'
  local:
    runs-on: ubuntu-latest
    steps:
      - uses: owner/standards/.github/workflows/scan.yml@2222222222222222222222222222222222222222
YML
expect_rc 0 "a step action with a workflow-shaped path is not followed as a reusable call"
unset EDGES_REUSABLE_DIR

echo "=== 12. Hypatia checkout refs participate in the one-tool pin contract ==="
readonly PIN_REF='${{ env.PIN }}'
checkout_fixture() {
    local ref="$1" binding="${2:-}"
    cat > "$WORK/repo/.github/workflows/oracle-pin-control.yml" <<YML
name: Oracle checkout control
${binding}
jobs:
  score:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          repository: hyperpolymath/hypatia
          ref: ${ref}
YML
}
fresh >/dev/null; checkout_fixture "$HSHA"
expect_rc 0 "a matching literal Hypatia checkout ref is accepted"
fresh >/dev/null; checkout_fixture "$HSHA"
sed -i -e 's/repository:/Repository:/' -e 's/          ref:/          Ref:/' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 0 "mixed-case checkout input names preserve a matching pin"
fresh >/dev/null; checkout_fixture main
sed -i 's/repository:/Repository:/' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "a mixed-case Repository input cannot hide a floating pin"
fresh >/dev/null; checkout_fixture main
sed -i 's/          ref:/          REF:/' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "a mixed-case REF input is inspected"
fresh >/dev/null; checkout_fixture "$HSHA"
printf '          Ref: main\n' >> "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "checkout ref inputs colliding after case normalization are refused"
says "case-colliding inputs have an explicit diagnostic" "input names collide case-insensitively"
fresh >/dev/null; checkout_fixture "$HSHA"
printf '          Repository: example/other\n' >> "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "case-colliding repository inputs cannot hide a target"
fresh >/dev/null; checkout_fixture "$HSHA"
printf '          Ref: %s\n' "$HSHA" >> "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "identical values do not excuse case-colliding checkout inputs"
fresh >/dev/null; checkout_fixture 1111111111111111111111111111111111111111
sed -i '/      - uses:/,$s/^  //' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "a wrong Hypatia pin in an indentless steps sequence is refused"
fresh >/dev/null; checkout_fixture "$HSHA"
sed -i '/      - uses:/,$s/^  //' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 0 "a matching pin in an indentless steps sequence is accepted"
fresh >/dev/null; checkout_fixture 1111111111111111111111111111111111111111
sed -i '/      - uses:/,$s/^/    /' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "a more-indented steps sequence cannot hide a wrong Hypatia pin"
fresh >/dev/null; checkout_fixture main
sed -i 's/      - uses:/      - name: |\n          Oracle checkout\n        uses:/' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "a multiline initial step name cannot hide a floating checkout ref"
fresh >/dev/null; checkout_fixture "$HSHA"
sed -i 's/      - uses:/      - name: |\n          Oracle checkout\n        uses:/' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 0 "a multiline initial name preserves sibling checkout key boundaries"
fresh >/dev/null; checkout_fixture main
sed -i -e 's/      - uses:/      -   uses:/' -e '/        with:/,$s/^/  /' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "extra spaces after the list dash cannot hide a floating checkout ref"
fresh >/dev/null; checkout_fixture "$HSHA"
sed -i -e 's/      - uses:/      -   uses:/' -e '/        with:/,$s/^/  /' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 0 "checkout mappings use the actual inline key column after the dash"
fresh >/dev/null; checkout_fixture 1111111111111111111111111111111111111111
sed -i -e 's|hyperpolymath/hypatia|Hyperpolymath/Hypatia|' -e 's|actions/checkout@|Actions/Checkout@|' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "repository name casing cannot hide a different Hypatia checkout pin"
fresh >/dev/null; checkout_fixture "$HSHA"
sed -i -e "s/with:/'with':/" -e 's/repository:/"repository":/' -e "s/ref:/'ref':/" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 0 "matching checkout refs with quoted mapping keys are recognized"
sed -i "s/$HSHA/1111111111111111111111111111111111111111/" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "quoted mapping keys cannot hide a different Hypatia checkout pin"
fresh >/dev/null; checkout_fixture 1111111111111111111111111111111111111111 "$(printf 'env:\n  HYPATIA_SHA: %s' "$HSHA")"
expect_rc 1 "a wrong literal checkout ref is caught even with the correct env pin"
says "the disagreement identifies the actual checkout" "Hypatia checkout"
fresh >/dev/null; checkout_fixture '${{ env.HYPATIA_SHA }}' "$(printf 'env:\n  HYPATIA_SHA: %s' "$HSHA")"
expect_rc 0 "an exact, uniquely declared workflow env binding resolves"
fresh >/dev/null; checkout_fixture '${{ env.HYPATIA_SHA }}'
sed -i "/    runs-on:/i\    env:\n      HYPATIA_SHA: $HSHA" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 0 "an exact, uniquely declared binding in the same job resolves"
fresh >/dev/null; checkout_fixture "$PIN_REF"
sed -i "/^  score:/i\  sibling:\n    env:\n      PIN: $HSHA\n    runs-on: ubuntu-24.04" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
sed -i 's/^  score:$/  score: # scanner/' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "a commented job header cannot borrow a sibling job env binding"
says "the missing applicable binding is named" "env binding"
fresh >/dev/null; checkout_fixture "$PIN_REF"
sed -i "/    runs-on:/i\    env:\n      PIN: $HSHA" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
cat >> "$WORK/repo/.github/workflows/oracle-pin-control.yml" <<YML
  sibling: # another checkout
    env: # local binding
      PIN: $HSHA
    steps: # ordinary block steps
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          repository: hyperpolymath/hypatia
          ref: \${{ env.PIN }}
YML
expect_rc 0 "separate jobs may declare the same env variable name independently"
fresh >/dev/null; checkout_fixture "$PIN_REF" "$(printf 'env: # workflow binding\n  PIN: %s' "$HSHA")"
expect_rc 0 "an env header with a trailing comment still supplies workflow scope"
fresh >/dev/null; checkout_fixture "$PIN_REF" 'env:
  PIN: 1111111111111111111111111111111111111111'
sed -i "/    runs-on:/i\    env: # job overrides workflow\n      PIN: $HSHA" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 0 "a unique job binding overrides the same workflow env name"
fresh >/dev/null; checkout_fixture "$PIN_REF" "$(printf 'env:\n  PIN: %s' "$HSHA")"
sed -i '/    runs-on:/i\    env:\n      PIN: 1111111111111111111111111111111111111111' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "the job override determines the checked ref, not the workflow value"
fresh >/dev/null; checkout_fixture "$PIN_REF"
sed -i "/    runs-on:/i\    env:\n      PIN: $HSHA\n      PIN: $HSHA" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "duplicate declarations in the applicable job scope remain ambiguous"
fresh >/dev/null; checkout_fixture "$PIN_REF"
sed -i "/    runs-on:/i\    env:\n      PIN: $HSHA" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
cat >> "$WORK/repo/.github/workflows/oracle-pin-control.yml" <<'YML'
        env:
          PIN: 1111111111111111111111111111111111111111
YML
expect_rc 1 "a wrong step binding cannot hide behind the correct job binding"
fresh >/dev/null; checkout_fixture "$PIN_REF"
sed -i "/    runs-on:/i\    env:\n      PIN: $HSHA" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
sed -i 's/      - uses:/      - env:\n          PIN: 1111111111111111111111111111111111111111\n        uses:/' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "a first-key step env override cannot borrow the correct job value"
fresh >/dev/null; checkout_fixture "$PIN_REF"
sed -i "/    runs-on:/i\    env:\n      PIN: $HSHA" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
printf '        env: {PIN: 1111111111111111111111111111111111111111}\n' >> "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "a wrong flow step env override cannot hide behind a job value"
fresh >/dev/null; checkout_fixture "$PIN_REF"
sed -i "/    runs-on:/i\    env:\n      PIN: $HSHA" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
sed -i 's/      - uses:/      - env: {PIN: 1111111111111111111111111111111111111111}\n        uses:/' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "a wrong first-key flow step env is inspected"
fresh >/dev/null; checkout_fixture "$PIN_REF" "$(printf 'env:\n  PIN: %s' "$HSHA")"
sed -i '/    runs-on:/i\    env: {PIN: 1111111111111111111111111111111111111111}' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "a wrong flow job env override cannot fall back to a workflow value"
fresh >/dev/null; checkout_fixture main
sed -i 's/    steps:/    steps: # oracle/' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "a commented steps header cannot hide a floating checkout ref"
fresh >/dev/null
cat > "$WORK/repo/.github/workflows/oracle-pin-control.yml" <<'YML'
name: Oracle checkout control
jobs:
  score:
    steps:
      - {uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1, with: {repository: hyperpolymath/hypatia, ref: main}}
YML
expect_rc 1 "a floating ref in a complete flow step is refused"
says "the invalid flow-step ref is named" "full-SHA checkout ref"
sed -i "s/ref: main/ref: $HSHA/" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 0 "a matching ref in a complete flow step is accepted"
fresh >/dev/null; checkout_fixture "$HSHA"
printf '      - *checkout-options\n' >> "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "an undefined whole-step alias fails YAML parsing"
fresh >/dev/null; checkout_fixture '${{ env.HYPATIA_SHA }}'
expect_rc 1 "an undefined checkout env binding is refused"
fresh >/dev/null; checkout_fixture '${{ env.HYPATIA_SHA }}' "$(printf 'env:\n  HYPATIA_SHA: %s\n  HYPATIA_SHA: %s' "$HSHA" "$HSHA")"
expect_rc 1 "duplicate identical checkout env bindings are ambiguous"
fresh >/dev/null; checkout_fixture "$HSHA"
sed -i '/          ref:/d' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "a Hypatia checkout with no ref is refused"
fresh >/dev/null; checkout_fixture "$HSHA"
sed -i "/          ref:/a\          ref: $HSHA" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "duplicate checkout ref inputs are refused"
fresh >/dev/null; checkout_fixture "$HSHA"
sed -i '/          repository:/a\          repository: hyperpolymath/hypatia' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "duplicate checkout repository inputs are refused"
fresh >/dev/null; checkout_fixture "$HSHA"
printf '        with:\n          repository: hyperpolymath/hypatia\n          ref: %s\n' "$HSHA" >> "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "duplicate checkout with maps are refused"
fresh >/dev/null; checkout_fixture main
expect_rc 1 "a floating Hypatia checkout ref is refused"
fresh >/dev/null; checkout_fixture '${{ inputs.hypatia-ref }}'
expect_rc 1 "an unresolved checkout expression is refused"
fresh >/dev/null; checkout_fixture "$HSHA"
sed -i 's|repository: hyperpolymath/hypatia|repository: \&repo hyperpolymath/hypatia|' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 0 "an anchored literal checkout repository is decoded"
sed -i "s/ref: $HSHA/ref: main/" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "anchoring the repository cannot hide a floating ref"
fresh >/dev/null; checkout_fixture "$HSHA"
cat >> "$WORK/repo/.github/workflows/oracle-pin-control.yml" <<'YML'
      - name: 'repository: hyperpolymath/hypatia ref: wrong'
        run: |
          cat <<'EXAMPLE'
          - uses: actions/checkout@a-decoy
            with:
              repository: hyperpolymath/hypatia
              ref: a-shell-example-is-not-a-pin
          EXAMPLE
YML
expect_rc 0 "quoted labels and shell block checkout examples are not pin inputs"
fresh >/dev/null; checkout_fixture "$HSHA"
cat >> "$WORK/repo/.github/workflows/oracle-pin-control.yml" <<'YML'
      - uses: owner/reporter@1111111111111111111111111111111111111111
        with:
          repository: hyperpolymath/hypatia
YML
expect_rc 0 "a non-checkout action repository input is not a checkout pin"
fresh >/dev/null; checkout_fixture "$HSHA"
sed -i "s|        with:|        with: {repository: hyperpolymath/hypatia, ref: $HSHA}|" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "an invalid mix of flow and block checkout inputs fails parsing"
fresh >/dev/null; checkout_fixture "$HSHA"
sed -i 's/        with:/        with: *checkout-options/' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "an undefined inputs alias and trailing block fields fail parsing"

echo "=== 13. Structured YAML selectors, scopes and duplicate-key preflight ==="
fresh >/dev/null; checkout_fixture "$HSHA"
sed -i 's/      - uses: /      - uses: >-\n          /' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 0 "a block-scalar uses selector is decoded"
sed -i "s/ref: $HSHA/ref: main/" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "a block-scalar uses selector cannot hide a floating ref"

fresh >/dev/null
cat > "$WORK/repo/.github/workflows/oracle-pin-control.yml" <<YML
name: Oracle checkout control
jobs:
  score:
    steps:
      - &checkout_step
        uses: &checkout_action actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with: &checkout_inputs
          repository: hyperpolymath/hypatia
          ref: "$HSHA"
      - uses: *checkout_action
        with:
          <<: *checkout_inputs
          ref: "$HSHA" # alias override
      - *checkout_step
YML
expect_rc 0 "uses, input and whole-step aliases resolve to real checkout maps"
sed -i 's/ref:.*# alias override/ref: main # alias override/' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "an explicit wrong ref overrides merged inputs and is refused"

fresh >/dev/null
printf '{name: Oracle checkout control, jobs: {score: {steps: [{uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1, with: {repository: hyperpolymath/hypatia, ref: "%s"}}]}}}\n' "$HSHA" > "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 0 "a complete flow-style workflow with the correct pin is accepted"
sed -i "s/$HSHA/main/" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "a complete flow-style workflow cannot hide a floating pin"

fresh >/dev/null
cat > "$WORK/repo/.github/workflows/oracle-pin-control.yml" <<YML
name: Oracle checkout control
jobs:
   score:
       env:
             PIN: $HSHA
       steps:
       - with:
             repository: hyperpolymath/hypatia
             ref: \${{ env.PIN }}
         uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
YML
expect_rc 0 "job/env/child indentation and input order do not change binding scope"
sed -i "s/PIN: $HSHA/PIN: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "a wrong pin under arbitrary valid indentation is refused"

fresh >/dev/null; checkout_fixture "$PIN_REF"
sed -i '/    runs-on:/i\    env: {PIN: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
printf '        env: {PIN: "%s"}\n' "$HSHA" >> "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 0 "a literal step binding takes precedence over the job binding"
sed -i "s/        env: {PIN: \"$HSHA\"}/        env: {PIN: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}/" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "the selected step binding is checked rather than falling back"

fresh >/dev/null; checkout_fixture "$PIN_REF" "$(printf 'env: {PIN: "%s"}' "$HSHA")"
printf '        env: uninspectable\n' >> "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "an uninspectable step env override never falls back to workflow env"
fresh >/dev/null; checkout_fixture "$PIN_REF" "$(printf 'env: {PIN: "%s"}' "$HSHA")"
sed -i '/    runs-on:/i\    env: uninspectable' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "an uninspectable job env override never falls back to workflow env"

fresh >/dev/null; checkout_fixture "$HSHA"
printf '\njobs: {}\n' >> "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "duplicate root jobs keys are rejected before JSON conversion"
says "the duplicate-key AST preflight is identified" "duplicate YAML mapping keys"
fresh >/dev/null; checkout_fixture "$HSHA"
sed -i "/          ref:/a\          \"ref\": \"$HSHA\"" "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "quoted/unquoted duplicate nested ref keys remain visible to preflight"
fresh >/dev/null; checkout_fixture "$HSHA"
sed -i '/      - uses:/a\        uses: owner/reporter@1111111111111111111111111111111111111111' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "duplicate uses selectors cannot replace a checkout during JSON conversion"
fresh >/dev/null; checkout_fixture "$HSHA" 'env:
  REF_NAME: &ref_key ref'
sed -i '/          ref:/i\          *ref_key: main' "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "an aliased mapping key cannot collide with a literal ref during conversion"
says "the narrow mapping-key restriction is explicit" "mapping keys are unsupported"
fresh >/dev/null; checkout_fixture "$HSHA"
printf '\n? [complex, key]\n: ignored\n' >> "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "complex YAML mapping keys are refused before JSON conversion"
fresh >/dev/null; checkout_fixture "$HSHA"
printf '\nbroken: [\n' >> "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "invalid YAML is a detected failure, not a silent empty extraction"
fresh >/dev/null; checkout_fixture "$HSHA"
printf '\n---\n{}\n' >> "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "a multi-document workflow is explicitly refused"
fresh >/dev/null; checkout_fixture "$HSHA"
printf 'name: Oracle checkout control\njobs:\n  score:\n    steps: uninspectable\n' > "$WORK/repo/.github/workflows/oracle-pin-control.yml"
expect_rc 1 "uninspectable job steps do not become an empty successful scan"

fresh >/dev/null
mkdir -p "$WORK/no-tools"
PATH="$WORK/no-tools" expect_rc 2 "missing parser tools are a clear setup failure"
says "the setup diagnostic names Mike Farah yq and jq" "setup requires Mike Farah yq"

fresh >/dev/null
mkdir -p "$WORK/failing-parser"
cat > "$WORK/failing-parser/yq" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *--version*) echo 'yq (https://github.com/mikefarah/yq/) version v4.53.3' ;;
  *'explode(.)'*) printf '{"jobs":{}}\n'; exit 17 ;;
  *) printf '0\t0\n' ;;
esac
SH
chmod +x "$WORK/failing-parser/yq"
PATH="$WORK/failing-parser:$PATH" expect_rc 1 "a failing decode cannot disappear behind valid empty JSON output"
says "the captured parser failure is reported" "checkout refs could not be inspected"

echo ""
if [ "$fail" -ne 0 ]; then
    echo "FAIL: workflow edges suite (${pass} passed, ${fail} failed)" >&2
    exit 1
fi
echo "PASS: workflow edges suite (${pass} checks)"
