#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# chain-mint.sh — mint a repository made from a MINTED repository.
#
# A minted repo has already filled its tokens and deleted build/templates, so
# minting it again rendered none of the new answers and skipped the identity
# splice: the grandchild inherited its parent's author, contacts and identity
# (Codex review of #251). The owner chose to support chains properly
# (2026-11-04). This is how, as a three-way merge that git performs:
#
#   base   = replay of the parent's own mint   (template @ pin, parent answers)
#   theirs = the parent as it stands           (base + the parent's own work)
#   ours   = the template @ pin minted with THIS repo's answers
#   result = merge-tree(base, ours, theirs)
#
# base -> theirs is exactly the parent's own work since its mint, and nothing
# else, so it is replayed onto a fresh mint for the new identity. Everything
# the template rendered is rendered afresh; the parent's own files and edits
# are carried; a conflict between the two stops before anything is written.
# Identity-bearing files (the deed, CLAUDE.md, the map, the roadmap) are never
# carried: they come from the new mint and are regenerated. Text the parent
# wrote about itself is renamed by the same bounded self-name pass repo-init
# uses (its SELF_PROV/SELF_NAME_SED lines, evaluated, so there is one rule).
#
# Called by `just repo-init` from the root of the new repository, whose tree is
# the parent's ("Use this template" on a minted repo), after the prompts, with
# the new answers exported under the names repo-init reads, plus
# TEMPLATE_REPO/TEMPLATE_OWNER (the parent) and RSR_MINT_DATE.
# RSR_TEMPLATE_URL overrides where the template's history is read from.
# Exit: 0 minted; 1 refused (reason on stderr, tree untouched); 2 usage.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READ="$HERE/deed-field.sh"
G="$(pwd)"
die() { echo "chain-mint: $*" >&2; exit 1; }
g() { git -c user.name=chain -c user.email=chain@example.invalid -c commit.gpgsign=false "$@"; }

for v in REPO OWNER TEMPLATE_REPO TEMPLATE_OWNER RSR_MINT_DATE; do
    [ -n "${!v:-}" ] || { echo "chain-mint: $v is not set (run through just repo-init)" >&2; exit 2; }
done
PDEED="$(bash "$READ" --find "$G")" || die "no single *_chora.deed in this tree"
PIN="$(bash "$READ" "$PDEED" provenance template-commit 2>/dev/null || true)"
TSLUG="$(bash "$READ" "$PDEED" provenance template-repo 2>/dev/null || true)"
[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] || die "the parent's (provenance :template-commit) is '${PIN}', not a commit"
P_ARCH="$(bash "$READ" "$PDEED" mint-answers archetype 2>/dev/null || true)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The root template's history, holding the parent's pin.
URL="${RSR_TEMPLATE_URL:-https://github.com/${TSLUG}.git}"
FILTER=(--filter=blob:none)
case "$URL" in *://*|*@*:*) ;; *) FILTER=() ;; esac
git clone -q --no-checkout "${FILTER[@]}" "$URL" "$WORK/template" 2>"$WORK/clone.err" \
    || { cat "$WORK/clone.err" >&2; die "cannot read ${TSLUG} from $URL (set RSR_TEMPLATE_URL)"; }
git -C "$WORK/template" cat-file -e "${PIN}^{commit}" 2>/dev/null \
    || die "$URL does not contain the parent's template commit $PIN"

echo "  chain: replaying the parent's mint (${TSLUG}@${PIN:0:12}, its own answers)"
bash "$HERE/replay-mint.sh" "$WORK/template" "$PIN" "$WORK/base" --answers-from "$PDEED" \
    || die "the replay of the parent's mint failed (above); nothing was written"
echo "  chain: minting ${TSLUG}@${PIN:0:12} with this repo's answers"
ARCHETYPE="$P_ARCH" bash "$HERE/replay-mint.sh" "$WORK/template" "$PIN" "$WORK/new" \
    || die "the mint with the new answers failed (above); nothing was written"

# files DIR — the repository's own files: tracked, or untracked and not ignored.
files() {
    git -C "$1" ls-files -z --cached --others --exclude-standard \
        | while IFS= read -r -d '' f; do { [ -e "$1/$f" ] || [ -L "$1/$f" ]; } && printf '%s\n' "$f"; done \
        | LC_ALL=C sort -u
}
# snapshot SRC — replace the merge repo's work tree with SRC's own files.
M="$WORK/merge"
g init -q -b base "$M"
snapshot() {
    find "$M" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
    files "$1" | tar -C "$1" -cf - -T - | tar -C "$M" -xf -
    g -C "$M" add -A
}
P_DEED_NAME="$(basename "$PDEED")"
IDENTITY=("$P_DEED_NAME" CLAUDE.md docs/architecture/REPOSITORY-MAP.adoc docs/status/ROADMAP.adoc)

snapshot "$WORK/base"; g -C "$M" commit -q --allow-empty -m base
B="$(g -C "$M" rev-parse HEAD)"
# theirs: the parent as it stands, with its identity files held at base, so
# they are never carried (they belong to the parent, not to this repo).
snapshot "$G"
for f in "${IDENTITY[@]}"; do
    if g -C "$M" cat-file -e "$B:$f" 2>/dev/null; then
        mkdir -p "$M/$(dirname "$f")"; g -C "$M" show "$B:$f" > "$M/$f"
    else
        rm -f "$M/$f"
    fi
done
g -C "$M" add -A; g -C "$M" commit -q --allow-empty -m theirs
THEIRS="$(g -C "$M" rev-parse HEAD)"
# The parent's own work, by kind: what this repo inherits and must declare.
mapfile -t CARRIED_M < <(g -C "$M" diff --no-renames --name-only --diff-filter=M "$B" "$THEIRS")
mapfile -t CARRIED_A < <(g -C "$M" diff --no-renames --name-only --diff-filter=A "$B" "$THEIRS")
mapfile -t CARRIED_D < <(g -C "$M" diff --no-renames --name-only --diff-filter=D "$B" "$THEIRS")

g -C "$M" checkout -q -b ours "$B"
snapshot "$WORK/new"
# ours differs from base only by rendering (same template commit, other
# answers), so a file the parent deleted stays deleted: its re-rendering is
# not a change anyone made. Without this, every deletion of a rendered file
# was a modify/delete conflict (measured: .machine_readable/ai/PLACEHOLDERS.adoc).
for f in "${CARRIED_D[@]}"; do g -C "$M" rm -q --cached --ignore-unmatch -- "$f"; rm -f -- "$M/$f"; done
g -C "$M" commit -q --allow-empty -m ours
OURS="$(g -C "$M" rev-parse HEAD)"

if ! g -C "$M" merge-tree --write-tree --name-only --merge-base="$B" "$OURS" "$THEIRS" > "$WORK/merge.out" 2>&1; then
    echo "chain-mint: the parent's own changes conflict with this repo's fresh mint in:" >&2
    # --name-only: the merged tree, then the conflicted paths, a blank line,
    # then git's messages (CONFLICT …), which say what kind of conflict.
    sed -n '2,$p' "$WORK/merge.out" | sed '/^$/d; s/^/    /' | head -n 60 >&2
    die "nothing was written. Resolve those in the parent (or mint from the template), then retry."
fi
RESULT="$(head -n 1 "$WORK/merge.out")"

# Write the result over this repo's own files; .git and ignored paths stay.
files "$G" | while IFS= read -r f; do rm -f -- "$G/$f"; done
find "$G" -mindepth 1 -type d -empty ! -path "$G/.git*" -delete 2>/dev/null || true
g -C "$M" archive "$RESULT" | tar -x -C "$G"

# Rename the parent where its own work names it: the same bounded rule as
# repo-init's self-name pass, read from the recipe so the two cannot differ.
RECIPE="$G/build/just/repo-init.just"
prov="$(grep -m1 -E "^ +SELF_PROV='" "$RECIPE")" || die "no SELF_PROV line in $RECIPE"
prog="$(grep -m1 -E '^ +SELF_NAME_SED="' "$RECIPE")" || die "no SELF_NAME_SED line in $RECIPE"
TEMPLATE_SLUG="${TEMPLATE_OWNER}/${TEMPLATE_REPO}"
eval "$prov"; eval "$prog"
VERBATIM="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$G/.machine_readable/mint-verbatim.txt" | grep -v '^$' || true)"
for f in "${CARRIED_M[@]}" "${CARRIED_A[@]}"; do
    [ -f "$G/$f" ] && [ ! -L "$G/$f" ] || continue
    grep -qxF -- "$f" <<< "$VERBATIM" && continue
    grep -qIF -- "$TEMPLATE_REPO" "$G/$f" 2>/dev/null || continue
    sed -i -E "$SELF_NAME_SED" "$G/$f"
done

# Record the lineage and the inherited divergence in the new deed.
DEED="$G/${REPO}_chora.deed"
[ -f "$DEED" ] || die "the new mint produced no ${REPO}_chora.deed"
PARENT_TREE="$(git -C "$G" rev-parse 'HEAD^{tree}' 2>/dev/null || echo UNASSIGNED)"
sed -i "s|^\(    :template-tree \"[^\"]*\"\)$|\1\n    ; minted from a minted repo: its own work since its mint was carried across\n    :derived-from \"${TEMPLATE_SLUG}\"\n    :derived-from-tree \"${PARENT_TREE}\"|" "$DEED"
grep -q ':derived-from "' "$DEED" || die "could not record :derived-from in $(basename "$DEED")"
q() { local s="" p; for p in "$@"; do s+=" \"$p\""; done; printf '%s' "$s"; }
sed -i -E "s|^(      :added \()([^)]*)\)|\1\2$(q "${CARRIED_A[@]}")\)|; s|^(      :removed \()([^)]*)\)|\1\2$(q "${CARRIED_D[@]}")\)|; s|^(      :diverged \()([^)]*)\)|\1\2$(q "${CARRIED_M[@]}")\)|" "$DEED"
sed -i -E '/^      :(added|removed|diverged) \(/s/\( "/("/' "$DEED"

# Derived files follow the merged tree and the new deed.
( cd "$G" && bash .machine_readable/arrival-pack/generate.sh >/dev/null )
( cd "$G" && bash scripts/gen-repo-map.sh --worktree . >/dev/null )
( cd "$G" && env -u GITHUB_REPOSITORY bash scripts/check-no-placeholders.sh . >/dev/null ) \
    || die "the merged tree still holds placeholder tokens (run scripts/check-no-placeholders.sh)"
echo "  chain: carried the parent's own work: ${#CARRIED_M[@]} edited, ${#CARRIED_A[@]} added, ${#CARRIED_D[@]} removed (declared in (variant (paths)))"
echo "  chain: ${REPO} minted from ${TEMPLATE_SLUG} (template ${TSLUG}@${PIN:0:12})"
