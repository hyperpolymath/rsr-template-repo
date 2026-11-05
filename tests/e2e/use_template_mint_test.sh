#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# use_template_mint_test.sh — mint a repository created the way GitHub's
# "Use this template" button creates one, and check what the mint wrote.
#
# Why. On 2026-10-14 metadatastician/lintel was created with that button (one
# root commit whose tree equals rsr-template-repo c9bce25, none of its history)
# and minted in place with RSR_NON_INTERACTIVE=1 just repo-init. Every defect
# below needed a hand correction there, and no test had ever run a full mint:
# tests/e2e/template_instantiation_test.sh runs nowhere in CI, and it mints an
# uncommitted copy, which is not how real children are born.
#
#   (a) provenance named the CHILD's own HEAD as the template commit;
#   (b) the self-name and strip passes rewrote template-machinery tests, and
#       tests/workflows/self_name_pass_test.sh then failed in the child;
#   (c) the strip pass edited git-ignored sibling checkouts under _build/;
#   (d) the closing advice armed a drift gate that a fresh mint cannot pass;
#   plus a repository map generated from the stale index (Estate Rules red).
#
# This test drives the REAL recipe end to end, then asserts each property,
# with a negative control beside each new check so it cannot pass vacuously.
# It needs just, rustc, uuidgen, nickel and file, and fails (never skips)
# without them. Network-free: the template's history is read from a local
# snapshot via RSR_TEMPLATE_URL.
#
# Usage: bash tests/e2e/use_template_mint_test.sh [--keep]
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d)
if [ "${1:-}" = "--keep" ]; then echo "keeping $work"; else trap 'rm -rf "$work"' EXIT; fi

fail() {
    echo "FAIL: $*" >&2
    # One annotation per failure, so the reason reaches the check list and the
    # API and not only the raw log.
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        printf '::error title=use-this-template mint::%s\n' "$(printf '%s' "$*" | tr '\n' ' ')"
    fi
    exit 1
}
pass() { echo "PASS: $*"; }
g() { git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false "$@"; }

for tool in just rustc uuidgen nickel file; do
    command -v "$tool" >/dev/null 2>&1 \
        || fail "$tool is required to run a real mint (not skipping: a skipped mint test is how this went untested)"
done

# The four tests the lintel mint broke or rewrote.
FIXTURE_TESTS=(
    tests/workflows/self_name_pass_test.sh
    tests/workflows/template_conformance_test.sh
    tests/e2e/template_instantiation_test.sh
    tests/workflows/mint_cleanup_test.sh
)

# ── 1. The template: this checkout's tree, committed or not, on main ────────
T="$work/template"
g clone -q --no-local "$repo" "$T"
g -C "$T" checkout -q -B main
(cd "$repo" && git ls-files -z --cached --others --exclude-standard \
    | while IFS= read -r -d '' f; do { [ -e "$f" ] || [ -L "$f" ]; } && printf '%s\0' "$f"; done \
    | tar --null -T - -cf -) > "$work/tree.tar"
(cd "$T" && git ls-files -z | xargs -0 rm -f && tar xf "$work/tree.tar")
g -C "$T" add -A
g -C "$T" commit -q --allow-empty -m "template under test"
T_COMMIT=$(g -C "$T" rev-parse HEAD)
T_TREE=$(g -C "$T" rev-parse 'HEAD^{tree}')
T_OWNER=$(sed -n -E 's/^OWNER[[:space:]]*:=[[:space:]]*"([^"]+)".*/\1/p' "$T/Justfile" | head -1)
TEMPLATE_REPO=$(sed -n -E 's/^REPO[[:space:]]*:=[[:space:]]*"([^"]+)".*/\1/p' "$T/Justfile" | head -1)
T_SLUG="$T_OWNER/$TEMPLATE_REPO"

# use_template DIR — what "Use this template" creates: one root commit with
# the template's tree, no shared history, origin = the new repository.
use_template() {
    rm -rf "$1"; mkdir -p "$1"
    g -C "$T" archive "$T_COMMIT" | tar x -C "$1"
    g -C "$1" init -q -b main
    g -C "$1" add -A
    g -C "$1" commit -q -m "Initial commit"
    g -C "$1" remote add origin git@github.com:example-owner/mint-check.git
}

# The description carries `&` and `|`, which the substitution used to read as
# sed syntax (`&` inserted the token itself). MINT_ENV adds per-call settings.
DESC='Tools & proofs | checked'
MINT_ENV=()

# mint DIR LOG — the non-interactive mint, isolated from this host's defaults
# file and global git config (an ORCID or signing key there would leak in).
mint() {
    local cfg="$work/cfg"; mkdir -p "$cfg"; : > "$cfg/gitconfig"
    (cd "$1" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        ${RUSTUP_HOME:+RUSTUP_HOME="$RUSTUP_HOME"} ${CARGO_HOME:+CARGO_HOME="$CARGO_HOME"} \
        XDG_CONFIG_HOME="$cfg" GIT_CONFIG_GLOBAL="$cfg/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
        RSR_NON_INTERACTIVE=1 RSR_TEMPLATE_URL="$T" RSR_MINT_TOOL_CACHE="$work/tools" \
        PROJECT_NAME="Mint Check" REPO=mint-check OWNER=example-owner \
        AUTHOR="Example Author" AUTHOR_EMAIL=author@example.org PROJECT_DESCRIPTION="$DESC" \
        "${MINT_ENV[@]}" timeout 900 just repo-init </dev/null) > "$2" 2>&1
}

# ── 2. The child, with an ignored cache and an untracked probe ──────────────
C="$work/child"
use_template "$C"
[ "$(g -C "$C" rev-parse 'HEAD^{tree}')" = "$T_TREE" ] || fail 'fixture: the child tree is not the template tree'
C_HEAD=$(g -C "$C" rev-parse HEAD)
# The probe carries all three things the rewrite passes act on.
LB='{{'; RB='}}'
probe="<!-- TEMPLATE INSTRUCTIONS: delete this block -->
${TEMPLATE_REPO} by ${LB}OWNER${RB}"
# An ignored sibling checkout, like lintel's _build/dependencies/<sibling>/.
mkdir -p "$C/_build/dependencies/sibling"
printf '%s\n' "$probe" > "$C/_build/dependencies/sibling/README.md"
g -C "$C" check-ignore -q _build/dependencies/sibling/README.md || fail 'fixture: _build/ is not ignored'
# Positive twin of the ignored cache: the same content in an untracked,
# not-ignored file IS the repository's and must be rewritten. Without it, an
# untouched cache could mean "the passes never ran" rather than "scoped".
printf '%s\n' "$probe" > "$C/mint-probe.md"
ignored_list() { (cd "$C" && git ls-files -o -i --exclude-standard | LC_ALL=C sort); }
IGN_LIST=$(ignored_list)
IGN_BEFORE=$(cd "$C" && printf '%s\n' "$IGN_LIST" | xargs -d '\n' sha256sum)
[ -n "$IGN_LIST" ] || fail 'fixture: no ignored files to protect'

# ── 3. Negative control for (a): an unrecognisable tree aborts, untouched ───
N="$work/no-match"
use_template "$N"
printf 'edited before minting\n' >> "$N/README.adoc"
g -C "$N" commit -q --amend -am "Initial commit"
if mint "$N" "$work/no-match.log"; then fail 'a tree matching no template commit was minted'; fi
grep -q 'mint aborted before writing anything' "$work/no-match.log" \
    || { cat "$work/no-match.log" >&2; fail 'the no-match abort did not say why'; }
[ -z "$(g -C "$N" status --porcelain)" ] || fail 'the aborted mint wrote to the tree'
pass "(a-) a child whose tree matches no template commit aborts before writing"

# ── 4. Negative control for the manifest: a stale entry aborts, untouched ───
M="$work/stale"
use_template "$M"
printf 'tests/workflows/no_such_test.sh\n' >> "$M/.machine_readable/mint-verbatim.txt"
g -C "$M" commit -q --amend -am "Initial commit"
if mint "$M" "$work/stale.log"; then fail 'a stale mint-verbatim entry was accepted'; fi
grep -q 'stale entry' "$work/stale.log" || { cat "$work/stale.log" >&2; fail 'the stale-entry abort did not say why'; }
[ -z "$(g -C "$M" status --porcelain)" ] || fail 'the stale-manifest mint wrote to the tree'
pass "(b-) a stale mint-verbatim entry stops the mint before it writes"

# ── 4b. Control: a Justfile identity repo-init cannot read, no guess from origin
# The remote of a template-created child is the CHILD; falling back to it
# named the child as its own template (Codex review of #251).
J="$work/no-identity"
use_template "$J"
sed -i -E 's/^(OWNER|REPO)([[:space:]]*:=[[:space:]]*)"([^"]+)"/\1\2env("RSR_\1", "\3")/' "$J/Justfile"
grep -qE '^OWNER[[:space:]]*:=[[:space:]]*env\(' "$J/Justfile" || fail 'fixture: the OWNER declaration was not rewritten'
g -C "$J" commit -q --amend -am "Initial commit"
if mint "$J" "$work/no-identity.log"; then fail 'a Justfile without OWNER/REPO minted from a guessed template'; fi
grep -q 'RSR_TEMPLATE_SLUG' "$work/no-identity.log" \
    || { cat "$work/no-identity.log" >&2; fail 'the missing-identity abort did not say how to fix it'; }
[ -z "$(g -C "$J" status --porcelain)" ] || fail 'the missing-identity mint wrote to the tree'
pass "(a-) a Justfile identity repo-init cannot read stops the mint and names RSR_TEMPLATE_SLUG"

# ── 4c. Control: an answer with a newline is refused before the first write ─
# (Codex review of #274: the refusal used to come after the overlay, the
# prune and the docs seed had already written.)
NL="$work/newline"
use_template "$NL"
MINT_ENV=(PROJECT_DESCRIPTION=$'line one\nline two')
if mint "$NL" "$work/newline.log"; then fail 'an answer with a newline was accepted'; fi
MINT_ENV=()
grep -q 'contains a newline' "$work/newline.log" || { cat "$work/newline.log" >&2; fail 'the newline refusal did not say why'; }
[ -z "$(g -C "$NL" status --porcelain)" ] || { g -C "$NL" status --short | head >&2; fail 'the refused mint wrote to the tree'; }
pass "(a-) an answer containing a newline is refused before anything is written"

# ── 5. The mint ─────────────────────────────────────────────────────────────
# The project type is an answer no template file renders: (mint-answers)
# must not record it (Codex review of #275), and the replay must still be green.
MINT_ENV=(PROJECT_TYPE=zq-unrendered-kind)
mint "$C" "$work/mint.log" || {
    cat "$work/mint.log" >&2
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        printf '::error title=just repo-init failed::%s\n' \
            "$(tail -n 40 "$work/mint.log" | awk '{printf "%s%%0A", $0}')"
    fi
    fail 'just repo-init failed on a Use-this-template child'
}
MINT_ENV=()
pass "the non-interactive mint completes on a Use-this-template child"
DEED="$C/mint-check_chora.deed"
[ -f "$DEED" ] || fail 'the child deed was not renamed to mint-check_chora.deed'
field() { bash "$C/scripts/deed-field.sh" "$DEED" "$@"; }

# ── (a) provenance names the template's commit and tree ─────────────────────
[ "$(field provenance template-repo)" = "$T_SLUG" ]     || fail "template-repo is $(field provenance template-repo), want $T_SLUG"
[ "$(field provenance template-commit)" = "$T_COMMIT" ] || fail "template-commit is $(field provenance template-commit), want $T_COMMIT"
[ "$(field provenance template-tree)" = "$T_TREE" ]     || fail "template-tree is $(field provenance template-tree), want $T_TREE"
[ "$(field provenance template-branch)" = main ]        || fail "template-branch is $(field provenance template-branch), want main"
[ "$(field variant parent-pin)" = "$T_COMMIT" ]         || fail "variant parent-pin is $(field variant parent-pin), want $T_COMMIT"
if grep -qF "$C_HEAD" "$DEED"; then fail "the deed records the child's own commit $C_HEAD"; fi
pass "(a) provenance and variant name template commit ${T_COMMIT:0:12} and its tree, never the child's HEAD"
grep -qF -- "$DESC" "$C/README.adoc" \
    || { grep -n 'Tools' "$C/README.adoc" >&2; fail 'the description did not render literally'; }
pass "an answer containing & and | renders literally"

# ── (b) the fixture tests are carried unchanged, and pass in the child ──────
while IFS= read -r v; do
    g -C "$C" diff --quiet HEAD -- "$v" || fail "the mint modified $v, listed in mint-verbatim.txt"
done < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$C/.machine_readable/mint-verbatim.txt" | grep -v '^$')
for t in "${FIXTURE_TESTS[@]}"; do
    g -C "$C" diff --quiet HEAD -- "$t" || fail "the mint modified $t"
    (cd "$C" && RSR_MINT_TOOL_CACHE="$work/tools" bash "$t") > "$work/fixture.log" 2>&1 \
        || { cat "$work/fixture.log" >&2; fail "$t fails in the minted child"; }
done
pass "(b) the four template-machinery tests are byte-identical and pass in the child"

# ── (c) nothing outside the repository's own files changed ──────────────────
[ "$(cd "$C" && printf '%s\n' "$IGN_LIST" | xargs -d '\n' sha256sum)" = "$IGN_BEFORE" ] \
    || fail 'the mint changed git-ignored files'
# The one ignored file the mint may CREATE is the arrival pack's declared
# build artefact (.gitignore, arrival-pack/README.adoc), which `just claude-md`
# writes on every run. Any other new ignored file is a write outside the repo.
new_ignored=$(comm -13 <(printf '%s\n' "$IGN_LIST") <(ignored_list) \
    | grep -vxF .machine_readable/arrival-pack/claude-md-data.json || true)
[ -z "$new_ignored" ] || { echo "$new_ignored" >&2; fail 'the mint created files outside the repository'; }
if grep -q 'TEMPLATE INSTRUCTIONS' "$C/mint-probe.md"; then fail 'probe: the strip pass skipped a repository file'; fi
if grep -qF "$TEMPLATE_REPO" "$C/mint-probe.md"; then fail 'probe: the self-name pass skipped a repository file'; fi
if grep -qF "${LB}OWNER${RB}" "$C/mint-probe.md"; then fail 'probe: the substitution pass skipped a repository file'; fi
# The probe stays: it was a repository file at mint, so the map lists it.
pass "(c) ignored files are byte-identical, none created but the arrival-pack artefact; the same content in a repository file was rewritten"

# ── (d) the drift gate replays the mint, and a fresh mint is green ──────────
grep -q 'arm the drift gate' "$work/mint.log" || fail 'repo-init does not recommend arming the drift gate'
grep -q 'scripts/check-template-conformance.sh' "$work/mint.log" || fail 'repo-init does not point at the conformance check'
# The answers are recorded, verbatim (the description carries & and |).
[ "$(field mint-answers description)" = "$DESC" ] || fail "(mint-answers :description) is '$(field mint-answers description)'"
[ "$(field mint-answers repo)" = mint-check ] && [ -n "$(field mint-answers mint-date)" ] \
    || fail '(mint-answers) lacks the repo or the mint date'
# Only values already written into the child are recorded (owner ruling).
if grep -q 'zq-unrendered-kind\|:project-type' "$DEED"; then fail '(mint-answers) recorded an answer that no file renders'; fi
grep -q 'not recorded, written into no file here: project-type' "$work/mint.log" || fail 'the mint did not name the unrecorded answer'
# The probe is the child's own addition after the mint: declared, as a child
# declares its additions (and this exercises the declared path).
sed -i 's|^      :added ()|      :added ("mint-probe.md")|' "$DEED"
grep -q ':added ("mint-probe.md")' "$DEED" || fail 'fixture: could not declare the probe'
g -C "$C" add -A
g -C "$C" commit -q -m "mint"
# Minting this child again is a chain mint now (scripts/chain-mint.sh); that,
# and the refusal of a child minted before (mint-answers), are covered end to
# end by tests/e2e/chain_mint_test.sh.
(cd "$C" && bash scripts/check-template-conformance.sh --quiet) > "$work/conf.log" 2>&1 \
    || { cat "$work/conf.log" >&2; fail 'the conformance check fails on a fresh mint'; }
# A fresh mint is identical to a replay of itself: green, by construction.
drift() { (cd "$C" && RSR_MINT_TOOL_CACHE="$work/tools" bash scripts/check-variant-drift.sh "$T") > "$work/drift.log" 2>&1; }
drift || { cat "$work/drift.log" >&2; fail 'the drift gate is red on a fresh mint'; }
grep -q 'identical to a replay of the mint' "$work/drift.log" || fail 'the drift gate did not replay the mint'
pass "(d) the drift gate replays the mint from (provenance) and (mint-answers): green on a fresh mint"
# Negative control: an edit to a file the mint produced, and an undeclared
# addition, are each named. Then restored, and green again.
printf '\nedited after the mint\n' >> "$C/README.adoc"
printf 'stray\n' > "$C/stray.txt"
if drift; then fail 'the drift gate missed an edit and an undeclared addition'; fi
grep -q '^DRIFT: README.adoc differs' "$work/drift.log" || { cat "$work/drift.log" >&2; fail 'the edited README.adoc was not named'; }
grep -q '^DRIFT: stray.txt exists here' "$work/drift.log" || fail 'the undeclared stray.txt was not named'
[ "$(grep -c '^DRIFT:' "$work/drift.log")" -eq 2 ] || { cat "$work/drift.log" >&2; fail 'the drift gate reported more than the two changes'; }
g -C "$C" checkout -q -- README.adoc; rm "$C/stray.txt"
pass "(d-) an edited file and an undeclared addition are named; nothing else is"
# Each declaration is a claim the gate checks (Codex review of #275): a
# mode-only change, a file recreated under a declared-removed directory, and a
# declared addition that is gone are each named.
chmod +x "$C/README.adoc"
mkdir -p "$C/archetypes"; printf 'back\n' > "$C/archetypes/revived.txt"
rm "$C/mint-probe.md"
if drift; then fail 'the drift gate missed a mode change, a revived removal and a missing addition'; fi
grep -q '^DRIFT: README.adoc differs .*mode' "$work/drift.log" || { cat "$work/drift.log" >&2; fail 'the mode-only change was not named'; }
grep -q '^DRIFT: archetypes/revived.txt exists here but is declared removed' "$work/drift.log" || fail 'the revived removal was not named'
grep -q '^DRIFT: declared-added mint-probe.md is missing' "$work/drift.log" || fail 'the missing declared addition was not named'
[ "$(grep -c '^DRIFT:' "$work/drift.log")" -eq 3 ] || { cat "$work/drift.log" >&2; fail 'the drift gate reported more than the three changes'; }
chmod -x "$C/README.adoc"; rm -r "$C/archetypes"; g -C "$C" checkout -q -- mint-probe.md
pass "(d-) a mode change, a revived removal and a missing addition are each named"
# Membership is the repository file set (Codex review of #275): an ignored
# artefact the replay also generates, force-added here, is still an addition.
AP=.machine_readable/arrival-pack/claude-md-data.json
[ -f "$C/$AP" ] || fail "fixture: the mint did not generate $AP"
g -C "$C" add -f -- "$AP"
if drift; then fail 'the drift gate passed a force-added ignored artefact'; fi
grep -qF "DRIFT: $AP exists here but the mint did not produce it" "$work/drift.log" || { cat "$work/drift.log" >&2; fail 'the force-added artefact was not named'; }
[ "$(grep -c '^DRIFT:' "$work/drift.log")" -eq 1 ] || { cat "$work/drift.log" >&2; fail 'the drift gate reported more than the force-added artefact'; }
g -C "$C" rm -q --cached -- "$AP"
drift || { cat "$work/drift.log" >&2; fail 'the drift gate is not green again after the controls'; }
pass "(d-) a force-added ignored artefact the replay also generates is named; green again once untracked"

# ── The repository map is regenerated last ──────────────────────────────────
# Same check Estate Rules runs, on the committed mint: regenerate from the
# index and require no difference.
(cd "$C" && bash scripts/gen-repo-map.sh . >/dev/null)
g -C "$C" diff --quiet -- docs/architecture/REPOSITORY-MAP.adoc \
    || { g -C "$C" diff -- docs/architecture/REPOSITORY-MAP.adoc | head -20 >&2; fail 'the committed map is stale'; }
# Negative control: index mode, run where the mint runs it (before the first
# commit, after a removal), reproduces the stale map lintel shipped.
SM="$work/stale-map"
use_template "$SM"
(cd "$SM" && rm -rf archetypes && bash scripts/gen-repo-map.sh . >/dev/null)
grep -q '^| `archetypes' "$SM/docs/architecture/REPOSITORY-MAP.adoc" \
    || fail 'control: index mode no longer shows the pre-commit staleness; this check is vacuous'
pass "the committed map is fresh (the index-mode control reproduces lintel's stale map)"

(cd "$C" && env -u GITHUB_REPOSITORY bash scripts/check-no-placeholders.sh .) > "$work/ph.log" 2>&1 \
    || { cat "$work/ph.log" >&2; fail 'the minted child fails its own placeholder gate'; }
pass "the minted child passes its own placeholder gate"

echo "PASS: Use-this-template mint"
