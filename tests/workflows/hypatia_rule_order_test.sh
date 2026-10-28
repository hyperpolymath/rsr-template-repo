#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Silence + Firing tests for scripts/check-hypatia-rule-order.sh.
#
# The policy's value is that it cannot silently disagree with the files it
# describes. Each control below mutates ONE fact in a copy of the real policy —
# a rank, an owner, a pin, a classified module — and asserts the checker refuses
# it, so a green run means the layer order, the ownership table, the clash list
# and the four files that implement them all say the same thing.
set +e
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO_DIR/scripts/check-hypatia-rule-order.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() {
    fail=$((fail + 1))
    echo "  FAIL: $1" >&2
    echo "::error::hypatia rule-order test failed: $1" # NOSONAR
}

# fresh — a tree with exactly the four files the checker reads.
fresh() {
    rm -rf "$WORK/repo"
    mkdir -p "$WORK/repo/.machine_readable/policies" "$WORK/repo/.github/workflows" "$WORK/repo/scripts"
    cp "$REPO_DIR/.machine_readable/policies/hypatia-rule-order.json" "$WORK/repo/.machine_readable/policies/"
    cp "$REPO_DIR/.github/workflows/hypatia-scan.yml" "$WORK/repo/.github/workflows/"
    cp "$REPO_DIR/.github/workflows/static-analysis-gate.yml" "$WORK/repo/.github/workflows/"
    cp "$REPO_DIR/.github/workflows/fork-governance.yml" "$WORK/repo/.github/workflows/"
    cp "$REPO_DIR/scripts/verdict-grid-lane.sh" "$WORK/repo/scripts/"
    cp "$REPO_DIR/.hypatia-ignore" "$WORK/repo/.hypatia-ignore"
}

run() { bash "$CHECK" "$WORK/repo" >"$WORK/out" 2>&1; }
expect_rc() { # expect_rc RC LABEL
    local want="$1" label="$2" got=0
    run || got=$?
    if [ "$got" -eq "$want" ]; then ok "$label"; else
        bad "$label (wanted exit ${want}, got ${got})"
        sed 's/^/        /' "$WORK/out"
    fi
}
says() { if grep -Fq -- "$2" "$WORK/out"; then ok "$1"; else bad "$1 (no '$2' in output)"; sed 's/^/        /' "$WORK/out"; fi; }

# edit_policy JQ-FILTER — rewrite the copy through jq.
edit_policy() {
    local filter="$1" tmp="$WORK/policy.tmp"
    jq "$filter" "$WORK/repo/.machine_readable/policies/hypatia-rule-order.json" > "$tmp" &&
        mv "$tmp" "$WORK/repo/.machine_readable/policies/hypatia-rule-order.json"
}

echo "=== 1. The repository as it ships ==="
fresh
expect_rc 0 "the shipped policy is ordered, complete and consistent"
says "the summary counts what it checked" "layer(s) ordered"

echo "=== 2. Firing: the sequence itself ==="
fresh; edit_policy '.layers[2].rank = 4'
expect_rc 1 "two layers sharing a rank are refused"
says "the duplicate-rank failure names the rank" "share a rank"

fresh; edit_policy '.layers[3].rank = 9'
expect_rc 1 "a rank with a hole and an out-of-order layer is refused"
says "the completeness failure states the required sequence" "complete sequence"

fresh; edit_policy '.layers += [.layers[0]]'
expect_rc 1 "a fully duplicated layer is refused"
says "the duplicate-layer failure names the id" "appears twice"

echo "=== 3. Firing: each layer must state itself ==="
fresh; edit_policy '.layers[1].overrides = ""'
expect_rc 1 "a layer that does not say what it overrides is refused"
says "the overrides failure names the layer" "does not say what it overrides"

fresh; edit_policy '.layers[2].owner = "the-owner-nobody-declared"'
expect_rc 1 "an owner outside the declared set is refused"
says "the owner failure lists the legal owners" "not one of"

fresh; edit_policy '.layers[3].id = ""'
expect_rc 1 "a layer with no id is refused"
says "the id failure names the rank" "has no id"

echo "=== 4. Firing: ownership and clashes ==="
fresh; edit_policy '.concerns[0].owner = ".github/workflows/does-not-exist.yml"'
expect_rc 1 "a concern owned by a missing file is refused"
says "the missing-owner failure names the concern" "does not exist"

fresh; edit_policy '.concerns[1].owner = ""'
expect_rc 1 "a concern with no owner is refused"
says "the unowned concern failure names it" "has no owner"

fresh; edit_policy '.concerns += [.concerns[0]]'
expect_rc 1 "a duplicated concern is refused"
says "the duplicate-concern failure names the id" "concern 'hypatia-execution' appears twice"

fresh; edit_policy '.clashes[0].resolution = ""'
expect_rc 1 "a clash with no resolution is refused"
says "the unresolved-clash failure names the id" "has no stated resolution"

fresh; edit_policy '.clashes = []'
expect_rc 1 "an empty clash list is refused"
says "the empty-clash failure explains why" "records no clashes"

echo "=== 5. Firing: the ignore file and the policy describe the same modules ==="
fresh; edit_policy '.observed_modules |= map(select(.module != "workflow_audit"))'
expect_rc 1 "a module exempted but unclassified is refused"
says "the unclassified-module failure names the module" "workflow_audit"

fresh; edit_policy '.observed_modules += [{"module": "security_errors", "layer": 4, "rationale": "stale"}]'
expect_rc 1 "a classification for a module the ignore file does not exempt is refused"
says "the stale-classification failure says why" "has moved on"

fresh; edit_policy '.observed_modules[0].layer = 3'
expect_rc 1 "classifying a module under a layer the repository cannot change is refused"
says "the immutable-layer failure names the layer" "cannot change"

fresh; edit_policy '.observed_modules[0].layer = 42'
expect_rc 1 "a classification pointing at a layer that does not exist is refused"
says "the missing-layer failure names the layer" "does not exist"

echo "=== 6. Firing: pins must agree with the files that use them ==="
fresh; edit_policy '.scanner.commit = "0000000000000000000000000000000000000000"'
expect_rc 1 "a scanner pin that disagrees with hypatia-scan.yml is refused"
says "the scanner-pin failure names both files" "HYPATIA_SHA in hypatia-scan.yml"

fresh; edit_policy '.grid.commit = "1111111111111111111111111111111111111111"'
expect_rc 1 "a grid pin that disagrees with the lane script is refused"
says "the grid-pin failure names the lane script" "STANDARDS_SHA in scripts/verdict-grid-lane.sh"

fresh; edit_policy '.grid.renderer_sha256 = "2222222222222222222222222222222222222222222222222222222222222222"'
expect_rc 1 "a renderer digest that disagrees with the lane script is refused"
says "the digest failure names the variable" "RENDERER_SHA256"

fresh; edit_policy '.grid.library_sha256 = "3333333333333333333333333333333333333333333333333333333333333333"'
expect_rc 1 "a jq library digest that disagrees with the lane script is refused"
says "the library failure names the variable" "JQ_LIB_SHA256"

# A pin removed from the workflow leaves nothing to verify against: that is a
# failure, not a pass.
fresh
sed -i "s/^      HYPATIA_SHA: .*/      HYPATIA_SHA: ''/" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "a workflow with no pin cannot validate the policy"
says "the missing-pin failure says so" "declares no HYPATIA_SHA"

echo "=== 7. Setup errors ==="
bash "$CHECK" "$WORK/nowhere" >"$WORK/out" 2>&1
[ $? -eq 2 ] && ok "a missing repository directory is a setup error" || bad "missing repo must exit 2"
fresh; rm -f "$WORK/repo/.machine_readable/policies/hypatia-rule-order.json"
bash "$CHECK" "$WORK/repo" >"$WORK/out" 2>&1
[ $? -eq 2 ] && ok "a missing policy is a setup error" || bad "missing policy must exit 2"

echo ""
if [ "$fail" -ne 0 ]; then
    echo "FAIL: hypatia rule-order suite (${pass} passed, ${fail} failed)" >&2
    exit 1
fi
echo "PASS: hypatia rule-order suite (${pass} checks)"
