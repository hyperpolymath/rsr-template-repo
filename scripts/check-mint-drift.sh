#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-mint-drift.sh — the exact drift gate for a minted repo.
#
# A minted repo differs from its template by design: the mint renders tokens,
# strips instruction blocks, prunes dependabot, splices the identity, seeds
# docs/, regenerates CLAUDE.md and the map. Diffing it against the template
# reported 101 rendered files on a fresh mint (2026-10-20), and no set of
# (normalise) rules could fold that without re-implementing the mint. So this
# gate does not compare against the template. It replays the mint:
#
#     child  ≡  repo-init(template @ :template-commit, (mint-answers))
#
# modulo the paths the child declares in its (variant (paths …)) clause. The
# replay runs the REAL recipe from the pinned template commit, with the answers
# and date the child recorded, so a fresh mint is green by construction and
# every later edit to a file the mint produced shows up, by name.
#
# Usage: check-mint-drift.sh <template-checkout> [child-dir]
#   <template-checkout>  a clone of the template that contains :template-commit
#   [child-dir]          the minted repo (default .)
# Needs what a mint needs: just, rustc, nickel, uuidgen.
# Exit: 0 no undeclared drift; 1 drift (listed); 2 usage or cannot replay.
set -euo pipefail

TDIR="${1:?usage: check-mint-drift.sh <template-checkout> [child-dir]}"
CDIR="${2:-.}"
TDIR="$(cd "$TDIR" && pwd)"; CDIR="$(cd "$CDIR" && pwd)"
READ="$CDIR/scripts/deed-field.sh"
die() { echo "check-mint-drift: $*" >&2; exit 2; }

DEED="$(bash "$READ" --find "$CDIR")" || die "no single *_chora.deed in $CDIR"
bash "$READ" --has "$DEED" mint-answers \
    || die "$(basename "$DEED") has no (mint-answers) clause: this repo was minted before answers were recorded, so its mint cannot be replayed"
ans() { bash "$READ" "$DEED" mint-answers "$1" 2>/dev/null || true; }
PIN="$(bash "$READ" "$DEED" provenance template-commit 2>/dev/null || true)"
SLUG="$(bash "$READ" "$DEED" provenance template-repo 2>/dev/null || true)"
[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] || die "(provenance :template-commit) is '${PIN}', not a commit"
git -C "$TDIR" cat-file -e "${PIN}^{commit}" 2>/dev/null \
    || die "$TDIR does not contain template commit $PIN (fetch ${SLUG:-the template}'s history)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The child as "Use this template" made it, minted again with its own
# recorded answers and date (scripts/replay-mint.sh, the one replay path).
R="$WORK/replay"
bash "$(dirname "$READ")/replay-mint.sh" "$TDIR" "$PIN" "$R" --answers-from "$DEED" \
    || die "the replay of the mint failed (above); nothing was compared"

# Declared divergence, from the CHILD's (variant (paths …)) clause, kept by
# category: each one is a claim the gate checks, not a blanket exemption
# (Codex review of #275). An entry ending in / covers a directory.
#   added     must exist here, and must NOT be something the mint produces;
#   removed   must be absent here;
#   diverged  (and -pending-upstream, operational-state) may differ in
#             content, but must still exist here.
section() { bash "$READ" --list "$DEED" variant/paths "$1" 2>/dev/null || true; }
ADDED="$(section added)"
REMOVED="$(section removed)"
DIVERGED="$(section diverged; section diverged-pending-upstream; section operational-state)"
in_list() {
    local p="$1" e
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        case "$e" in
            */) case "$p" in "$e"*) return 0 ;; esac ;;
            *) [ "$p" = "$e" ] && return 0 ;;
        esac
    done <<< "$2"
    return 1
}
# files DIR — the repository's own files: tracked, or untracked and not ignored.
files() {
    git -C "$1" ls-files -z --cached --others --exclude-standard \
        | while IFS= read -r -d '' f; do { [ -e "$1/$f" ] || [ -L "$1/$f" ]; } && printf '%s\n' "$f"; done \
        | LC_ALL=C sort -u
}
exists() { [ -e "$1" ] || [ -L "$1" ]; }
# same A B — identical as git would record them: content, the executable bit,
# and for a symlink its target (cmp alone follows links and ignores modes).
same() {
    if [ -L "$1" ] || [ -L "$2" ]; then
        [ -L "$1" ] && [ -L "$2" ] && [ "$(readlink "$1")" = "$(readlink "$2")" ]
        return
    fi
    { [ -x "$1" ] && [ -x "$2" ]; } || { [ ! -x "$1" ] && [ ! -x "$2" ]; } || return 1
    cmp -s "$1" "$2"
}

DRIFT=0
report() { DRIFT=1; echo "DRIFT: $*"; }
while IFS= read -r f; do
    if in_list "$f" "$REMOVED"; then
        report "$f exists here but is declared removed"
    elif in_list "$f" "$ADDED"; then
        exists "$R/$f" && report "$f is declared added, but the mint produces it (declare it diverged)"
    elif in_list "$f" "$DIVERGED"; then
        :
    elif ! exists "$R/$f"; then
        report "$f exists here but the mint did not produce it (declare in paths.added)"
    elif ! same "$R/$f" "$CDIR/$f"; then
        report "$f differs from what the mint produced, in content or mode (declare in paths.diverged, or restore it)"
    fi
done < <(files "$CDIR")
while IFS= read -r f; do
    exists "$CDIR/$f" && continue
    in_list "$f" "$REMOVED" && continue
    if in_list "$f" "$DIVERGED"; then
        report "$f is declared diverged but is absent here (declare it removed)"
    else
        report "$f was produced by the mint but is absent here (declare in paths.removed)"
    fi
done < <(files "$R")
# Every declared addition must actually be here.
while IFS= read -r e; do
    [ -n "$e" ] || continue
    case "$e" in
        */) [ -d "$CDIR/$e" ] || report "declared-added directory $e is missing" ;;
        *) exists "$CDIR/$e" || report "declared-added $e is missing" ;;
    esac
done <<< "$ADDED"

if [ "$DRIFT" -eq 0 ]; then
    echo "PASS: identical to a replay of the mint (${SLUG}@${PIN:0:12}, $(ans mint-date)), modulo declared variant paths"
else
    echo "FAIL: undeclared drift from a replay of the mint (${SLUG}@${PIN:0:12}) — declare it in the deed's (variant (paths …)) clause, or restore it"
    exit 1
fi
