#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# chain_mint_test.sh — mint a repository made from a MINTED repository.
#
# Codex (review of #251) showed that minting a minted repo inherited the
# parent's author, contacts and identity, because the parent's tokens were
# already filled. The owner chose to support chains properly (2026-11-04):
# scripts/chain-mint.sh replays the parent's mint, mints the same template
# commit with the new answers, and carries the parent's own work across by a
# three-way merge. This mints parent -> grandchild end to end and checks:
#   * nothing of the parent's identity or contacts survives in the grandchild;
#   * the parent's own work (an edit, an addition, a removal) is carried, with
#     its name rewritten, and declared in the grandchild's (variant (paths));
#   * provenance names the root template commit and the parent;
#   * the grandchild's drift gate (a replay of ITS mint) is green;
# and, as negative controls, that a conflicting parent edit stops the chain
# before it writes, and that a parent without (mint-answers) is refused.
# Needs just, rustc, uuidgen, nickel, file. Network-free (RSR_TEMPLATE_URL).
#
# Usage: bash tests/e2e/chain_mint_test.sh [--keep]
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d)
if [ "${1:-}" = "--keep" ]; then echo "keeping $work"; else trap 'rm -rf "$work"' EXIT; fi
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
g() { git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false "$@"; }
for tool in just rustc uuidgen nickel file; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required to run a real mint (not skipping)"
done

# ── The template: this checkout's tree, committed or not, on main ───────────
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
T_SLUG="$(sed -n -E 's/^OWNER[[:space:]]*:=[[:space:]]*"([^"]+)".*/\1/p' "$T/Justfile" | head -1)/$(sed -n -E 's/^REPO[[:space:]]*:=[[:space:]]*"([^"]+)".*/\1/p' "$T/Justfile" | head -1)"

# use_template FROM COMMITISH DIR ORIGIN — what "Use this template" makes.
use_template() {
    rm -rf "$3"; mkdir -p "$3"
    g -C "$1" archive "$2" | tar x -C "$3"
    g -C "$3" init -q -b main; g -C "$3" add -A; g -C "$3" commit -q -m "Initial commit"
    g -C "$3" remote add origin "$4"
}
# mint DIR LOG REPO OWNER AUTHOR EMAIL DESC [ARCHETYPE [PROJECT_NAME]] — a
# non-interactive mint, isolated. The project name defaults to the repo name.
mint() {
    local cfg="$work/cfg"; mkdir -p "$cfg"; : > "$cfg/gitconfig"
    (cd "$1" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        ${RUSTUP_HOME:+RUSTUP_HOME="$RUSTUP_HOME"} ${CARGO_HOME:+CARGO_HOME="$CARGO_HOME"} \
        XDG_CONFIG_HOME="$cfg" GIT_CONFIG_GLOBAL="$cfg/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
        RSR_NON_INTERACTIVE=1 RSR_TEMPLATE_URL="$T" RSR_MINT_TOOL_CACHE="$work/tools" \
        PROJECT_NAME="${9:-$3}" REPO="$3" OWNER="$4" AUTHOR="$5" AUTHOR_EMAIL="$6" \
        PROJECT_DESCRIPTION="$7" timeout 1200 just repo-init ${8:+"$8"} </dev/null) > "$2" 2>&1
}

# ── The parent: a minted repo, then its own work ────────────────────────────
P="$work/parent"
use_template "$T" HEAD "$P" git@github.com:elder-owner/elder-proj.git
mint "$P" "$work/parent.log" elder-proj elder-owner "Eldra Author" elder@example.org "Elder tools" \
    || { tail -30 "$work/parent.log" >&2; fail 'the parent mint failed'; }
g -C "$P" add -A; g -C "$P" commit -q -m mint
printf '\nNotes for elder-proj users.\n' >> "$P/README.adoc"
mkdir -p "$P/notes"; printf 'elder-proj notes, see https://github.com/elder-owner/elder-proj\n' > "$P/notes/elder-proj-notes.md"
g -C "$P" rm -q .machine_readable/ai/PLACEHOLDERS.adoc
# A path holding characters special to sed and to deed strings, and a type
# change (a file the parent replaced with a symlink) (Codex review of #277).
printf 'odd name\n' > "$P/notes/R&D | \"q\".md"
rm "$P/SUPPORT.adoc"; ln -s README.adoc "$P/SUPPORT.adoc"
# A file listed in mint-verbatim.txt, deleted: the template's own preflights
# must not stop a chain mint over the parent's choices (Codex review of #277).
g -C "$P" rm -q tests/e2e/template_instantiation_test.sh
# Path bytes tar's line mode would mangle: a backslash and a leading dash; a
# file under archetypes/, which the mint declares removed; and an identity
# setting naming the parent's owner (all Codex review of #277).
printf 'slash\n' > "$P/notes/back\\slash.txt"
printf 'dash\n' > "$P/-lead.txt"
mkdir -p "$P/archetypes"; printf 'mine\n' > "$P/archetypes/custom.txt"
printf 'sonar.organization=elder-owner\nsonar.projectKey=elder-owner_elder-proj\n' > "$P/notes/extra-sonar.properties"
g -C "$P" add -A; g -C "$P" commit -q -m "the parent's own work"
pass "fixture: a minted parent with its own edit, addition and removal"

# ── The grandchild: "Use this template" on the parent, then a chain mint ────
G="$work/grandchild"
use_template "$P" HEAD "$G" git@github.com:other-owner/grand-check.git
# Uncommitted work in the checkout is carried too, and :derived-from-tree must
# name the snapshot actually used, not HEAD^{tree} (Codex review of #277).
printf 'local\n' > "$G/notes/local.txt"
HEAD_TREE=$(g -C "$G" rev-parse 'HEAD^{tree}')
P_TREE=$(cd "$G" && GIT_INDEX_FILE="$work/snap.index" git add -A . && GIT_INDEX_FILE="$work/snap.index" git write-tree)
[ "$P_TREE" != "$HEAD_TREE" ] || fail 'fixture: the uncommitted file did not change the tree'
mint "$G" "$work/chain.log" grand-check other-owner "Other Author" other@example.org "Grand tools" \
    || { tail -40 "$work/chain.log" >&2; fail 'the chain mint failed'; }
grep -q 'minted as a chain' "$work/chain.log" || fail 'repo-init did not take the chain path'
pass "a minted repo is minted again, as a chain"

DEED="$G/grand-check_chora.deed"
[ -f "$DEED" ] && [ ! -e "$G/elder-proj_chora.deed" ] || fail 'the deed is not the grandchild'"'"'s alone'
field() { bash "$G/scripts/deed-field.sh" "$DEED" "$@"; }
[ "$(field provenance template-repo)" = "$T_SLUG" ] && [ "$(field provenance template-commit)" = "$T_COMMIT" ] \
    || fail "provenance names $(field provenance template-repo)@$(field provenance template-commit), not the root template"
[ "$(field provenance derived-from)" = elder-owner/elder-proj ] || fail 'provenance does not name the parent'
[ "$(field provenance derived-from-tree)" = "$P_TREE" ] || fail 'provenance does not name the parent tree'
[ "$(field mint-answers author)" = "Other Author" ] && [ "$(field mint-answers description)" = "Grand tools" ] \
    || fail '(mint-answers) are not the grandchild'"'"'s'
pass "provenance names the root template commit and the parent; the answers are the grandchild's"

# Nothing of the parent's identity or contacts survives (the Codex finding).
# A file identical to the template's own copy is template text, not a leak
# (this test and the recipe name these fixtures on purpose).
leak=$(cd "$G" && git ls-files -co --exclude-standard | grep -vxF grand-check_chora.deed \
       | while IFS= read -r f; do
             [ -f "$f" ] || continue
             g -C "$T" show "$T_COMMIT:$f" 2>/dev/null | cmp -s - "$f" && continue
             grep -lIE 'elder-proj|Eldra Author|elder@example\.org|Elder tools' -- "$f"
         done || true)
[ -z "$leak" ] || { echo "$leak" >&2; fail 'the parent'"'"'s identity or contacts survive in the files above'; }
grep -q 'Eldra Author\|elder@example.org' "$DEED" && fail 'the deed carries the parent'"'"'s author'
grep -qF 'Grand tools' "$G/README.adoc" && grep -qF 'other@example.org' "$G/.github/SECURITY.adoc" 2>/dev/null \
    || grep -rqF 'other@example.org' "$G/.github" || fail 'the new contacts were not rendered'
pass "nothing of the parent's identity, author or contacts survives; the new answers are rendered"

# The parent's own work is carried, renamed, and declared. The rename is the
# self-name rule: the repo name and the owner/repo slug, never a bare owner
# (an owner is shared with real estate repos, the same reason the template's
# owner pass is narrow).
tail -n 1 "$G/README.adoc" | grep -qx 'Notes for grand-check users.' || fail 'the parent'"'"'s README edit was not carried and renamed'
grep -qx 'grand-check notes, see https://github.com/other-owner/grand-check' "$G/notes/elder-proj-notes.md" \
    || fail 'the parent'"'"'s added file was not carried and renamed'
[ ! -e "$G/.machine_readable/ai/PLACEHOLDERS.adoc" ] || fail 'the parent'"'"'s removal was not carried'
[ ! -e "$G/tests/e2e/template_instantiation_test.sh" ] || fail 'the deletion of a verbatim-listed file was not carried'
[ -f "$G/notes/local.txt" ] || fail 'uncommitted work in the checkout was not carried'
bash "$G/scripts/deed-field.sh" --list "$DEED" variant/paths added | grep -qx notes/elder-proj-notes.md \
    && bash "$G/scripts/deed-field.sh" --list "$DEED" variant/paths diverged | grep -qx README.adoc \
    && bash "$G/scripts/deed-field.sh" --list "$DEED" variant/paths removed | grep -qx .machine_readable/ai/PLACEHOLDERS.adoc \
    || { grep -n ':added\|:removed\|:diverged' "$DEED" >&2; fail 'the carried work is not declared in (variant (paths))'; }
bash "$G/scripts/deed-field.sh" --list "$DEED" variant/paths added | grep -qxF 'notes/R&D | "q".md' \
    || { grep -n ':added' "$DEED" >&2; fail 'a path with & | and quotes was not declared intact'; }
[ -L "$G/SUPPORT.adoc" ] && bash "$G/scripts/deed-field.sh" --list "$DEED" variant/paths diverged | grep -qx SUPPORT.adoc \
    || fail 'the type change (file to symlink) was not carried and declared'
added() { bash "$G/scripts/deed-field.sh" --list "$DEED" variant/paths added; }
[ -f "$G/notes/back\\slash.txt" ] && [ -f "$G/-lead.txt" ] \
    && added | grep -qxF 'notes/back\slash.txt' && added | grep -qxF -- '-lead.txt' \
    || { grep -n ':added' "$DEED" >&2; fail 'a path holding a backslash or a leading dash was not carried and declared intact'; }
[ -f "$G/archetypes/custom.txt" ] && added | grep -qx archetypes/custom.txt \
    || fail 'a file under the mint-removed archetypes/ was not carried and declared added'
[ "$(cat "$G/notes/extra-sonar.properties")" = "$(printf 'sonar.organization=other-owner\nsonar.projectKey=other-owner_grand-check')" ] \
    || { cat "$G/notes/extra-sonar.properties" >&2; fail 'a carried identity setting kept the parent'"'"'s owner'; }
pass "the parent's edit, addition and removal are carried, renamed, and declared"
pass "odd path bytes, an addition under a removed directory and a carried owner setting are handled"

# The grandchild's drift gate replays ITS mint: green, carried work declared.
g -C "$G" add -A; g -C "$G" commit -q -m "chain mint"
(cd "$G" && RSR_MINT_TOOL_CACHE="$work/tools" bash scripts/check-variant-drift.sh "$T") > "$work/drift.log" 2>&1 \
    || { cat "$work/drift.log" >&2; fail 'the grandchild'"'"'s drift gate is red'; }
(cd "$G" && bash scripts/gen-repo-map.sh . >/dev/null) && g -C "$G" diff --quiet -- docs/architecture/REPOSITORY-MAP.adoc \
    || fail 'the grandchild'"'"'s map is stale'
pass "the grandchild's drift gate (a replay of its own mint) is green; its map is fresh"

# ── Negative control: a parent edit that conflicts with the new rendering ───
# The parent rewrote the rendered description line; the new mint renders a
# different description on that line. That is a real conflict: stop, write
# nothing, name the file.
P2="$work/parent2"
g clone -q --no-local "$P" "$P2"
sed -i 's/^Elder tools$/Elder tools, rewritten by hand/' "$P2/README.adoc"
grep -qx 'Elder tools, rewritten by hand' "$P2/README.adoc" || fail 'fixture: the description line was not found'
g -C "$P2" commit -q -am "hand edit of a rendered line"
G2="$work/grandchild2"
use_template "$P2" HEAD "$G2" git@github.com:other-owner/grand-check.git
if mint "$G2" "$work/conflict.log" grand-check other-owner "Other Author" other@example.org "Grand tools"; then
    fail 'a conflicting parent edit was merged silently'
fi
grep -q 'conflict' "$work/conflict.log" && grep -q 'README.adoc' "$work/conflict.log" \
    || { tail -20 "$work/conflict.log" >&2; fail 'the conflict was not reported with its file'; }
[ -z "$(g -C "$G2" status --porcelain)" ] || fail 'the refused chain mint wrote to the tree'
pass "(-) a conflicting parent edit stops the chain before it writes, and names the file"

# ── Negative control: a parent minted before (mint-answers) is refused ──────
G3="$work/grandchild3"
use_template "$P" HEAD "$G3" git@github.com:other-owner/grand-check.git
bash "$G3/scripts/deed-clause.sh" delete "$G3/elder-proj_chora.deed" mint-answers 2>/dev/null \
    || perl -0pi -e 's/\n  ; mint-answers.*?\n  \(mint-answers.*?\)\n/\n/s' "$G3/elder-proj_chora.deed"
! bash "$G3/scripts/deed-field.sh" --has "$G3/elder-proj_chora.deed" mint-answers || fail 'fixture: (mint-answers) still present'
g -C "$G3" commit -q -am "an old child"
if mint "$G3" "$work/old.log" grand-check other-owner "Other Author" other@example.org "Grand tools"; then
    fail 'a parent without (mint-answers) was minted'
fi
grep -q 'records no (mint-answers)' "$work/old.log" || { tail -10 "$work/old.log" >&2; fail 'the refusal did not say why'; }
[ -z "$(g -C "$G3" status --porcelain)" ] || fail 'the refused mint wrote to the tree'
pass "(-) a parent minted before (mint-answers) is refused before anything is written"

# ── Negative control: a failure after the merge writes nothing ──────────────
# The parent carries a broken arrival-pack source: both replays pass (they use
# the pinned template), the merge succeeds, then regenerating CLAUDE.md from
# the merged tree fails. Every step runs in a scratch copy first, so the
# grandchild is untouched (Codex review of #277: the checkout used to be
# replaced before the later steps ran). (A carried unfilled token is refused
# even earlier, by check-mint-tokens.sh, before anything is written.)
P4="$work/parent4"
g clone -q --no-local "$P" "$P4"
printf 'this is not nickel\n' >> "$P4/.machine_readable/arrival-pack/arrival-pack.ncl"
g -C "$P4" commit -q -am "a broken arrival-pack source"
G4="$work/grandchild4"
use_template "$P4" HEAD "$G4" git@github.com:other-owner/grand-check.git
if mint "$G4" "$work/late.log" grand-check other-owner "Other Author" other@example.org "Grand tools"; then
    fail 'a chain mint carrying a broken arrival-pack source succeeded'
fi
grep -q 'arrival pack could not be regenerated; nothing was written' "$work/late.log" || { tail -20 "$work/late.log" >&2; fail 'the late failure did not say why'; }
[ -z "$(g -C "$G4" status --porcelain)" ] || { g -C "$G4" status --short | head >&2; fail 'a failure after the merge wrote to the tree'; }
pass "(-) a failure after the merge (a broken carried source) leaves the tree untouched"

# ── Negative control: a chain mint keeps the parent's archetype ─────────────
# `just repo-init <archetype>` on a chain must not die on the absent
# archetypes/ (Codex review of #277); naming a different archetype is refused.
G5="$work/grandchild5"
use_template "$P" HEAD "$G5" git@github.com:other-owner/grand-check.git
if (cd "$G5" && env -i PATH="$PATH" HOME="$HOME" RSR_NON_INTERACTIVE=1 just repo-init julia-library </dev/null) > "$work/arch.log" 2>&1; then
    fail 'a chain mint accepted a different archetype'
fi
grep -q "was minted as archetype 'none'; a chain mint keeps it" "$work/arch.log" || { cat "$work/arch.log" >&2; fail 'the archetype refusal did not say why'; }
[ -z "$(g -C "$G5" status --porcelain)" ] || fail 'the refused archetype wrote to the tree'
pass "(-) a chain mint refuses an archetype other than the parent's, before writing"

# ── An answer-dependent rename: a Julia package's entry point ───────────────
# The mint names src/<Package>.jl after the project, so a parent's edit to its
# entry point lives at another path in the grandchild. The merge carries the
# edit across that rename; the declaration must name where it now lives
# (Codex review of #277), which the grandchild's drift gate checks.
JP="$work/jparent"
use_template "$T" HEAD "$JP" git@github.com:elder-owner/ElderPkg.jl.git
mint "$JP" "$work/jparent.log" ElderPkg.jl elder-owner "Eldra Author" elder@example.org "Elder tools" julia-library ElderPkg \
    || { tail -30 "$work/jparent.log" >&2; fail 'the Julia parent mint failed'; }
[ -f "$JP/src/ElderPkg.jl" ] || fail 'fixture: the Julia parent has no src/ElderPkg.jl'
g -C "$JP" add -A; g -C "$JP" commit -q -m mint
sed -i 's/^# --- implementation .*/&\nanswer() = 42/' "$JP/src/ElderPkg.jl"
grep -qx 'answer() = 42' "$JP/src/ElderPkg.jl" || fail 'fixture: the entry-point edit did not apply'
g -C "$JP" commit -q -am "the parent's own code"
JG="$work/jgrandchild"
use_template "$JP" HEAD "$JG" git@github.com:other-owner/GrandPkg.jl.git
mint "$JG" "$work/jchain.log" GrandPkg.jl other-owner "Other Author" other@example.org "Grand tools" julia-library GrandPkg \
    || { tail -40 "$work/jchain.log" >&2; fail 'the Julia chain mint failed'; }
[ -f "$JG/src/GrandPkg.jl" ] && [ ! -e "$JG/src/ElderPkg.jl" ] && grep -qx 'answer() = 42' "$JG/src/GrandPkg.jl" \
    || { ls "$JG/src" >&2; fail 'the entry-point edit was not carried across the rename'; }
JDEED="$JG/GrandPkg.jl_chora.deed"
bash "$JG/scripts/deed-field.sh" --list "$JDEED" variant/paths diverged | grep -qx src/GrandPkg.jl \
    || { grep -n ':added\|:removed\|:diverged' "$JDEED" >&2; fail 'the renamed entry point is not declared where it now lives'; }
if bash "$JG/scripts/deed-field.sh" --list "$JDEED" variant/paths diverged | grep -qx src/ElderPkg.jl; then
    fail 'the deed declares the parent'"'"'s entry-point path'
fi
g -C "$JG" add -A; g -C "$JG" commit -q -m "chain mint"
(cd "$JG" && RSR_MINT_TOOL_CACHE="$work/tools" bash scripts/check-variant-drift.sh "$T") > "$work/jdrift.log" 2>&1 \
    || { cat "$work/jdrift.log" >&2; fail 'the Julia grandchild'"'"'s drift gate is red'; }
pass "an edit carried across an answer-dependent rename is declared where it lives; the drift gate is green"

echo "PASS: chain mint"
