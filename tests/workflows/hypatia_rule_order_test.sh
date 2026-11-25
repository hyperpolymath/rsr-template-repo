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
    cp "$REPO_DIR/.github/workflows/verdict-grid-publish.yml" "$WORK/repo/.github/workflows/"
    cp "$REPO_DIR/scripts/verdict-grid-lane.sh" "$WORK/repo/scripts/"
    cp "$REPO_DIR/.hypatia-ignore" "$WORK/repo/.hypatia-ignore"
    local pin
    pin="$(jq -r '.scanner.commit' "$WORK/repo/.machine_readable/policies/hypatia-rule-order.json")"
    printf 'name: Hypatia Security Scan\njobs:\n  scan:\n    env:\n      HYPATIA_SHA: %s\n' "$pin" > "$WORK/repo/.github/workflows/hypatia-scan.yml"
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
cp "$REPO_DIR/.github/workflows/hypatia-scan.yml" "$WORK/repo/.github/workflows/hypatia-scan.yml"
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

# A caller of the shared reusable pins the scanner with its hypatia-ref input,
# not an env var: that pin is read and checked like HYPATIA_SHA.
caller_wf() {
    local pin="$1"
    cat > "$WORK/repo/.github/workflows/hypatia-scan.yml" <<YML
name: Hypatia Security Scan
on: [push]
permissions:
  contents: read
jobs:
  scan:
    uses: metadatastician/standards/.github/workflows/hypatia-scan-reusable.yml@46ee18323305d5b36e2eef936e47dd54c39ea736
    with:
      hypatia-ref: ${pin}
YML
}
fresh; caller_wf "$(jq -r '.scanner.commit' "$WORK/repo/.machine_readable/policies/hypatia-rule-order.json")"
expect_rc 0 "a reusable caller whose hypatia-ref matches the policy is accepted"

fresh; caller_wf '"4444444444444444444444444444444444444444"'
expect_rc 1 "a reusable caller whose hypatia-ref disagrees with the policy is refused"
says "the caller-pin failure names the input" "hypatia-ref input in hypatia-scan.yml"

fresh; caller_wf ''
expect_rc 1 "a reusable caller that passes no hypatia-ref cannot validate the policy"
says "the missing caller pin is stated" "passes no hypatia-ref input"

# Two pins for one scanner that disagree are refused even when one matches.
fresh; caller_wf '"5555555555555555555555555555555555555555"'
scanner_pin="$(jq -r '.scanner.commit' "$REPO_DIR/.machine_readable/policies/hypatia-rule-order.json")"
sed -i "/^jobs:/i\env:\n  HYPATIA_SHA: \"$scanner_pin\"" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "HYPATIA_SHA and a disagreeing hypatia-ref in one workflow are refused"
says "the double-pin failure names both" "pins the scanner twice"

# Minimal valid direct-scanner workflow for structural pin controls.
env_wf() {
    local pin="$1"
    cat > "$WORK/repo/.github/workflows/hypatia-scan.yml" <<YML
name: Hypatia Security Scan
on: [push]
env:
  HYPATIA_SHA: ${pin}
jobs:
  scan:
    runs-on: ubuntu-latest
    steps: []
YML
}
readonly WRONG_SCANNER_PIN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
fresh
cp "$REPO_DIR/.github/workflows/hypatia-scan.yml" "$WORK/repo/.github/workflows/hypatia-scan.yml"
sed -i "s/^      HYPATIA_SHA: .*/      HYPATIA_SHA: \&scanner \"$scanner_pin\"/" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 0 "an anchored env scanner pin matches the policy"
sed -i "s/$scanner_pin/$WRONG_SCANNER_PIN/" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "an anchored wrong env scanner pin is refused"

fresh
cp "$REPO_DIR/.github/workflows/hypatia-scan.yml" "$WORK/repo/.github/workflows/hypatia-scan.yml"
sed -i "s/^      HYPATIA_SHA: .*/      SCANNER_PIN: \&scanner \"$scanner_pin\"\n      HYPATIA_SHA: *scanner/" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 0 "an aliased env scanner pin matches the policy"
sed -i "s/$scanner_pin/$WRONG_SCANNER_PIN/" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "an aliased wrong env scanner pin is refused"

fresh; caller_wf "&scanner \"$scanner_pin\""
expect_rc 0 "an anchored reusable scanner input matches the policy"
sed -i "s/$scanner_pin/$WRONG_SCANNER_PIN/" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "an anchored wrong reusable scanner input is refused"

fresh; caller_wf '*scanner'
sed -i "/^jobs:/i\x-scanner: \&scanner \"$scanner_pin\"" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 0 "an aliased reusable scanner input matches the policy"
sed -i "s/$scanner_pin/$WRONG_SCANNER_PIN/" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "an aliased wrong reusable scanner input is refused"

fresh; env_wf "$scanner_pin"
sed -i 's/^on: .*/on:\n  workflow_call:\n    inputs:\n      HYPATIA_SHA:\n        type: string/' "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 0 "an input declaration cannot shadow an actual env scanner pin"
sed -i "s/$scanner_pin/$WRONG_SCANNER_PIN/" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "an input declaration cannot hide a wrong actual env scanner pin"

fresh; caller_wf "$scanner_pin"
sed -i 's/^on: .*/on:\n  workflow_dispatch:\n    inputs:\n      hypatia-ref:\n        type: string/' "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 0 "a dispatch declaration cannot shadow an actual reusable scanner input"
sed -i "s/$scanner_pin/$WRONG_SCANNER_PIN/" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "a dispatch declaration cannot hide a wrong reusable scanner input"

fresh; env_wf "$(printf '|-\n    %s' "$scanner_pin")"
expect_rc 0 "a chomped scanner block scalar matches the policy exactly"
sed -i 's/HYPATIA_SHA: |-/HYPATIA_SHA: |/' "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "a scanner block scalar newline is rejected before shell transport"
says "the scanner whitespace failure is explicit" "scanner pin must not contain whitespace"

fresh; env_wf "$scanner_pin"
printf '\nenv: {}\n' >> "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "duplicate YAML mapping keys cannot hide a scanner pin"
says "the scanner raw AST preflight remains visible" "duplicate YAML mapping keys"

fresh; env_wf '*undefined'
expect_rc 1 "an undefined scanner scalar alias fails closed"
fresh; env_wf "$scanner_pin"
printf '\n---\n{}\n' >> "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "multiple scanner workflow documents fail closed"
fresh; env_wf main; edit_policy '.scanner.commit = "main"'
expect_rc 1 "a floating policy and workflow cannot agree without a full SHA"

fresh
mkdir -p "$WORK/failing-parser"
cat > "$WORK/failing-parser/yq" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *--version*) echo 'yq (https://github.com/mikefarah/yq/) version v4.53.3' ;;
  *'explode(.)'*) printf '{"jobs":{}}\n'; exit 17 ;;
  *) printf '0\t0\t0\t0\n' ;;
esac
SH
chmod +x "$WORK/failing-parser/yq"
PATH="$WORK/failing-parser:$PATH" expect_rc 1 "a scanner decoder failure cannot publish partial JSON"
says "the scanner decoder failure is reported" "scanner pins could not be inspected"

# Malformed refs must not masquerade as immutable scanner pins.
for invalid in main be98f74ce93d 4444444444444444444444444444444444444444-extra; do
    fresh; caller_wf "$invalid"
    expect_rc 1 "a malformed reusable scanner pin $invalid is refused"
done

# A second declaration of the same kind is ambiguous even when the values
# agree: YAML consumers can disagree about duplicate-key handling.
fresh
printf '      HYPATIA_SHA: %s\n' "$scanner_pin" >> "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "duplicate identical HYPATIA_SHA declarations are refused"
says "the duplicate SHA diagnostic names the key" "declares HYPATIA_SHA more than once"

fresh
printf '      HYPATIA_SHA: "4444444444444444444444444444444444444444"\n' >> "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "conflicting HYPATIA_SHA declarations are refused"

fresh; caller_wf "$scanner_pin"
printf '      hypatia-ref: %s\n' "$scanner_pin" >> "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "duplicate identical hypatia-ref declarations are refused"
says "the duplicate input diagnostic names the key" "passes hypatia-ref more than once"

fresh; caller_wf "$scanner_pin"
printf '      hypatia-ref: "4444444444444444444444444444444444444444"\n' >> "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "conflicting hypatia-ref declarations are refused"

# Comments and similarly named keys cannot stand in for a scanner pin.
fresh
sed -i 's/^      HYPATIA_SHA: /      # HYPATIA_SHA: /' "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "a commented scanner pin is not accepted"

fresh
sed -i 's/^      HYPATIA_SHA: /      NOT_HYPATIA_SHA: /' "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "an unrelated key containing HYPATIA_SHA is not accepted"

# A 40-hex prefix is not a pin when the scalar has an extra suffix.
fresh
sed -i '/^      HYPATIA_SHA: /s/$/-extra/' "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "a HYPATIA_SHA with a suffix is refused"
says "the malformed SHA diagnostic names the key" "malformed HYPATIA_SHA scanner pin"

# A valid SHA cannot mask a malformed declaration of the other pin kind.
fresh; caller_wf main
sed -i "/^jobs:/i\env:\n  HYPATIA_SHA: \"$scanner_pin\"" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "a malformed hypatia-ref beside valid HYPATIA_SHA is refused"
says "the malformed input diagnostic names the key" "malformed hypatia-ref scanner pin"

# Quoted scalar pins with trailing YAML comments remain valid.
fresh; caller_wf "'$scanner_pin' # scanner revision"
expect_rc 0 "a quoted hypatia-ref with a comment is accepted"

# Distinct real scopes are ambiguous too, even without duplicate YAML keys.
fresh; env_wf "$scanner_pin"
sed -i "/    runs-on:/i\    env:\n      HYPATIA_SHA: \"$scanner_pin\"" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "identical scanner SHA bindings in different scopes are refused"
says "multiple scopes preserve the duplicate SHA diagnostic" "declares HYPATIA_SHA more than once"

fresh; caller_wf "$scanner_pin"
cat >> "$WORK/repo/.github/workflows/hypatia-scan.yml" <<YML
  second:
    uses: metadatastician/standards/.github/workflows/hypatia-scan-reusable.yml@46ee18323305d5b36e2eef936e47dd54c39ea736
    with:
      hypatia-ref: "$scanner_pin"
YML
expect_rc 1 "identical reusable scanner inputs in different jobs are refused"
says "multiple jobs preserve the duplicate input diagnostic" "passes hypatia-ref more than once"

# Null, empty and absent bindings still explain which scanner pin is missing.
fresh; env_wf null
expect_rc 1 "a null env scanner pin cannot validate the policy"
says "a null env scanner pin retains the missing-pin diagnostic" "declares no HYPATIA_SHA"
fresh; env_wf "$scanner_pin"
sed -i '/^  HYPATIA_SHA:/d' "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "an absent env scanner pin cannot validate the policy"
says "an absent env scanner pin retains the missing-pin diagnostic" "declares no HYPATIA_SHA"
fresh; caller_wf "''"
expect_rc 1 "an empty string reusable scanner input cannot validate the policy"
says "an empty reusable scanner input retains the missing-pin diagnostic" "passes no hypatia-ref input"
fresh; caller_wf "$scanner_pin"
sed -i '/^      hypatia-ref:/d' "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "an absent reusable scanner input cannot validate the policy"
says "an absent reusable scanner input retains the missing-pin diagnostic" "passes no hypatia-ref input"

fresh; caller_wf "''"
sed -i "/^jobs:/i\env:\n  HYPATIA_SHA: \"$scanner_pin\"" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "a valid env scanner pin cannot hide an empty reusable scanner input"
says "the empty input remains a malformed binding" "malformed hypatia-ref scanner pin"
fresh; caller_wf "$scanner_pin"
sed -i '/^jobs:/i\env:\n  HYPATIA_SHA: null' "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "a valid reusable scanner input cannot hide a null env scanner pin"
says "the null env pin remains a malformed binding" "malformed HYPATIA_SHA scanner pin"

fresh; caller_wf "$scanner_pin"
sed -i 's|uses: .*|uses: ./.github/workflows/hypatia-scan-reusable.yml|' "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 0 "a local reusable caller scanner input matches the policy"
sed -i "s/$scanner_pin/$WRONG_SCANNER_PIN/" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "a local reusable caller with a wrong scanner input is refused"
fresh; caller_wf "$scanner_pin"
sed -i 's|uses: .*|uses: $/.github/workflows/hypatia-scan-reusable.yml|' "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 0 "a dollar-prefixed local reusable caller scanner input matches the policy"

fresh; env_wf "$scanner_pin"
sed -i '/^env:/,/^jobs:/{ /^env:/d; /^  HYPATIA_SHA:/d; }' "$WORK/repo/.github/workflows/hypatia-scan.yml"
sed -i "/    runs-on:/i\    container:\n      image: alpine:3.23\n      env:\n        HYPATIA_SHA: \"$scanner_pin\"" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 0 "a job-container scanner env pin matches the policy"
sed -i "s/$scanner_pin/$WRONG_SCANNER_PIN/" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "a wrong job-container scanner env pin is refused"
sed -i -e "s/$WRONG_SCANNER_PIN/$scanner_pin/" -e "/^jobs:/i\env:\n  HYPATIA_SHA: \"$scanner_pin\"" "$WORK/repo/.github/workflows/hypatia-scan.yml"
expect_rc 1 "identical job-container and workflow scanner pins remain ambiguous"
says "container bindings preserve the duplicate scanner-pin diagnostic" "declares HYPATIA_SHA more than once"


echo "=== 7. Setup errors ==="
bash "$CHECK" "$WORK/nowhere" >"$WORK/out" 2>&1
[ $? -eq 2 ] && ok "a missing repository directory is a setup error" || bad "missing repo must exit 2"
fresh; rm -f "$WORK/repo/.machine_readable/policies/hypatia-rule-order.json"
bash "$CHECK" "$WORK/repo" >"$WORK/out" 2>&1
[ $? -eq 2 ] && ok "a missing policy is a setup error" || bad "missing policy must exit 2"

echo "=== 8. Independent schema, ordering and field failures ==="
# An empty exemption set is valid when there are no observed modules. The
# checker must still reach its verdict instead of exiting from an empty grep.
for contents in '' '# No repository-specific exemptions'; do
    fresh; edit_policy '.observed_modules = []'
    printf '%s\n' "$contents" > "$WORK/repo/.hypatia-ignore"
    expect_rc 0 "an empty or comment-only ignore file can describe no exemptions"
    says "the checker reaches its summary with zero modules" "0 module(s) classified"
done
fresh
: > "$WORK/repo/.hypatia-ignore"
expect_rc 1 "removing all exemptions exposes stale module classifications"
says "empty exemptions still produce an actionable policy diagnostic" "the policy describes a file that has moved on"

fresh; edit_policy '.schema = "hypatia-rule-order/2"'
expect_rc 1 "an unsupported policy schema is refused"
says "the schema diagnostic names the supported version" "policy schema is not hypatia-rule-order/1"

fresh; edit_policy '.layers |= reverse'
expect_rc 1 "complete unique ranks still fail when written in reverse order"
says "the sequence diagnostic explains document order" "not written in ascending rank order"

fresh; edit_policy 'del(.layers[1].scope)'
expect_rc 1 "a missing scope is refused independently of overrides"
says "the missing field is named accurately" "has no scope"

fresh; edit_policy 'del(.layers[1].overrides)'
expect_rc 1 "a missing overrides field cannot shift the scope field"
says "the absent overrides field is named accurately" "does not say what it overrides"

fresh; edit_policy '.clashes += [.clashes[0]]'
expect_rc 1 "a duplicated clash with a valid resolution is still refused"
says "the duplicate clash is named" "appears twice"

for missing in .github/workflows/hypatia-scan.yml scripts/verdict-grid-lane.sh .hypatia-ignore; do
    fresh; rm "$WORK/repo/$missing"
    expect_rc 2 "missing $missing is a setup error"
    says "the missing-input diagnostic identifies $missing" "missing $(basename "$missing")"
done
for invalid in '{broken' '[]' 'null'; do
    fresh
    printf '%s\n' "$invalid" > "$WORK/repo/.machine_readable/policies/hypatia-rule-order.json"
    expect_rc 2 "non-object policy $invalid is a setup error"
    says "the invalid policy shape is explained" "policy is not a JSON object"
done

echo "=== 9. Missing declarations retain actionable diagnostics ==="
fresh; edit_policy '.layers = .layers[:3] | .observed_modules = []'
printf '# No repository exemptions\n' > "$WORK/repo/.hypatia-ignore"
expect_rc 1 "three otherwise complete layers do not meet the minimum policy size"
says "the minimum layer count is explained" "policy declares fewer than four layers"

fresh; edit_policy '.concerns = []'
expect_rc 1 "a policy without any concerns is refused"
says "an empty ownership table is explained" "policy declares no concerns"

# This is the original TSV regression: neither field may stand in for the
# other when both are absent from a layer.
fresh; edit_policy 'del(.layers[1].scope, .layers[1].overrides)'
expect_rc 1 "simultaneously missing scope and overrides are both diagnosed"
says "a missing scope remains visible alongside missing overrides" "layer 2 (universal-excludes) has no scope"
says "missing overrides remain visible alongside a missing scope" "does not say what it overrides"

for declaration in STANDARDS_SHA RENDERER_SHA256 JQ_LIB_SHA256; do
    fresh
    sed -i "/^${declaration}=/d" "$WORK/repo/scripts/verdict-grid-lane.sh"
    expect_rc 1 "a removed $declaration cannot verify the policy pin"
    if [ "$declaration" = STANDARDS_SHA ]; then
        says "the missing grid commit pin is explained" "names no STANDARDS_SHA"
    else
        says "the missing $declaration is explained" "declares no $declaration"
    fi
done

echo ""
if [ "$fail" -ne 0 ]; then
    echo "FAIL: hypatia rule-order suite (${pass} passed, ${fail} failed)" >&2
    exit 1
fi
echo "PASS: hypatia rule-order suite (${pass} checks)"
