#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# upgrade_test.sh — scripts/upgrade-mint.sh, end to end, on throwaway repos.
#
# Two children are MINTED FROM AN OLD TEMPLATE COMMIT (UPGRADE_TEST_OLD, default
# c7a524c, 2026-11-09, the first with chain minting) with the real recipe, then
# upgraded to newer template versions:
#
#   A  clean      unedited child, upgraded across real history to the tip.
#                 Dry run writes nothing and is repeatable; --apply lands on a
#                 new branch, records the pin, leaves no conflict marker, and
#                 the result is what a fresh mint at the tip gives (the drift
#                 gate, run against the new pin, passes); --rollback restores
#                 the exact tree and deletes the branch.
#   B  conflict   a child with edits, upgraded to a synthetic template commit
#                 (on a branch of the throwaway template only) that changes:
#                   X  a line far from the child's own edit      -> MERGED
#                   Y  the same line the child edited            -> CONFLICT, markers
#                   Z  an SPDX line, child unedited              -> LICENCE-HELD
#                   LICENSE, LICENSES/*, the chora deed       -> PROTECTED (bytes equal)
#                   D  a file the child edited, then deleted     -> MODIFY-DELETE, kept
#                   D2 a file the child never touched, deleted   -> DELETE
#                   N  a new file                                -> ADD
#                 and the child's own file and its declared (paths) are untouched.
#
# The negative test the owner asked for is B's LICENSE rows: the template DID
# change the licence files (asserted first), the child still equalled the old
# mint there (so a plain fast-forward would have taken it), and after --apply
# the bytes are identical to before, listed PROTECTED.
# Needs just, rustc, uuidgen, nickel, yq (a mint's own tools). Network-free.
# Usage: bash tests/e2e/upgrade_test.sh [--keep]
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d)
if [ "${1:-}" = "--keep" ]; then echo "keeping $work"; else trap 'rm -rf "$work"' EXIT; fi
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
g() { git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
for tool in just rustc uuidgen nickel yq; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required to run a real mint (not skipping)"
done
UP="$repo/scripts/upgrade-mint.sh"
[ -f "$UP" ] || fail "scripts/upgrade-mint.sh is missing"

# A minted child has no template history: its own mint is covered elsewhere.
if [[ ! -f "$repo/build/templates/identity.deed.in" ]]; then
    echo "PASS: not a template tree; the upgrade is exercised from the template (nothing to mint from here)"
    exit 0
fi

# ── the throwaway template: full history, plus one synthetic branch ──────────
T="$work/template"
g clone -q --no-local "$repo" "$T"
if [ "$(git -C "$T" rev-parse --is-shallow-repository)" = true ]; then
    g -C "$T" fetch -q --unshallow "$(git -C "$repo" remote get-url origin)" 2>/dev/null \
        || fail "the template checkout is shallow and its history cannot be fetched; this test needs the commits between the old pin and the tip"
fi
g -C "$T" checkout -q -B main
# the tree under test, committed or not, is the tip (as chain_mint_test.sh)
(cd "$repo" && git ls-files -z --cached --others --exclude-standard \
    | while IFS= read -r -d '' f; do { [ -e "$f" ] || [ -L "$f" ]; } && printf '%s\0' "$f"; done \
    | tar --null -T - -cf -) > "$work/tree.tar"
(cd "$T" && git ls-files -z | xargs -0 rm -f && tar xf "$work/tree.tar")
g -C "$T" add -A
g -C "$T" commit -q --allow-empty -m "template under test"
TIP=$(g -C "$T" rev-parse HEAD)
OLD=$(g -C "$T" rev-parse --verify -q "${UPGRADE_TEST_OLD:-c7a524c}^{commit}") \
    || fail "the old template commit ${UPGRADE_TEST_OLD:-c7a524c} is not in this history"
g -C "$T" merge-base --is-ancestor "$OLD" "$TIP" || fail "$OLD is not an ancestor of the tip"
[ "$(g -C "$T" rev-list --count "$OLD..$TIP")" -ge 2 ] || fail "the tip is not newer than the old commit"
export RSR_MINT_TOOL_CACHE="$work/tools"

use_template() { # DIR ORIGIN — what "Use this template" makes from $OLD
    rm -rf "$1"; mkdir -p "$1"
    GIT_INDEX_FILE="$work/ut.index" g -C "$T" read-tree "$OLD"
    GIT_INDEX_FILE="$work/ut.index" g -C "$T" checkout-index -a -f --prefix="$1/"
    rm -f "$work/ut.index"
    g -C "$1" init -q -b main; g -C "$1" add -f -A; g -C "$1" commit -q -m "Initial commit"
    g -C "$1" remote add origin "$2"
}
mint() { # DIR LOG REPO
    local cfg="$work/cfg"; mkdir -p "$cfg"; : > "$cfg/gitconfig"
    (cd "$1" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        ${RUSTUP_HOME:+RUSTUP_HOME="$RUSTUP_HOME"} ${CARGO_HOME:+CARGO_HOME="$CARGO_HOME"} \
        XDG_CONFIG_HOME="$cfg" GIT_CONFIG_GLOBAL="$cfg/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
        RSR_NON_INTERACTIVE=1 RSR_TEMPLATE_URL="$T" RSR_MINT_TOOL_CACHE="$work/tools" \
        PROJECT_NAME="$3" REPO="$3" OWNER="upg-owner" AUTHOR="Upg Author" AUTHOR_EMAIL="upg@example.org" \
        PROJECT_DESCRIPTION="Upgrade fixture" timeout 1200 just repo-init </dev/null) > "$2" 2>&1
}
mkchild() { # NAME -> $work/NAME, minted from $OLD, committed
    use_template "$work/$1" "git@github.com:upg-owner/$1.git"
    mint "$work/$1" "$work/$1.log" "$1" || { tail -30 "$work/$1.log" >&2; fail "the mint of $1 at the old commit failed"; }
    g -C "$work/$1" add -A; g -C "$work/$1" commit -q -m "mint"
}
tree_of() { g -C "$1" rev-parse 'HEAD^{tree}'; }

# ═══ A: clean child, real history ═══════════════════════════════════════════
mkchild upg-clean
A="$work/upg-clean"
[ "$(bash "$repo/scripts/deed-field.sh" "$(bash "$repo/scripts/deed-field.sh" --find "$A")" provenance template-commit)" = "$OLD" ] \
    || fail "the child did not record the old commit as its pin"
before_head=$(g -C "$A" rev-parse HEAD); before_branches=$(g -C "$A" branch --list | sort)
bash "$UP" --template "$T" --to "$TIP" --child "$A" > "$work/a.dry1" 2> "$work/a.dry1.err" && rc=0 || rc=$?
{ [ "$rc" = 0 ] || [ "$rc" = 3 ]; } || { cat "$work/a.dry1.err" >&2; fail "A: dry run failed (exit $rc)"; }
bash "$UP" --template "$T" --to "$TIP" --child "$A" > "$work/a.dry2" 2>/dev/null || true
[ -z "$(g -C "$A" status --porcelain)" ] || fail "A: the dry run changed the work tree"
[ "$(g -C "$A" rev-parse HEAD)" = "$before_head" ] && [ "$(g -C "$A" branch --list | sort)" = "$before_branches" ] \
    || fail "A: the dry run moved HEAD or made a branch"
cmp -s "$work/a.dry1" "$work/a.dry2" || fail "A: two dry runs gave different plans"
grep -q '^FAST-FORWARD' "$work/a.dry1" || fail "A: the plan fast-forwards nothing across $(g -C "$T" rev-list --count "$OLD..$TIP") template commits"
# an unedited child can have no conflict. It MAY have licence holds: where the
# template itself changed an SPDX or copyright line, a human decides (exit 3).
! grep -E '^(CONFLICT|CONFLICT-UNMERGED|MODIFY-DELETE|MERGED)' "$work/a.dry1" >/dev/null || { grep -E '^(CONFLICT|MODIFY|MERGED)' "$work/a.dry1" >&2; fail "A: an unedited child has a conflict or a merge"; }
pass "A: dry run is the default, repeatable, and writes nothing ($(sed -n 's/^# summary: //p' "$work/a.dry1"))"

bash "$UP" --template "$T" --to "$TIP" --child "$A" --apply > "$work/a.apply" 2> "$work/a.apply.err" && rc=0 || rc=$?
[ "$rc" = 0 ] || { [ "$rc" = 3 ] && ! grep -qE '^(CONFLICT|MODIFY-DELETE)' "$work/a.apply" && grep -q '^LICENCE-HELD' "$work/a.apply"; } \
    || { cat "$work/a.apply.err" >&2; fail "A: --apply failed (exit $rc)"; }
[ "$(g -C "$A" rev-parse --abbrev-ref HEAD)" = "upgrade/rsr-${TIP:0:12}" ] || fail "A: not on the upgrade branch"
[ "$(g -C "$A" rev-parse HEAD~1)" = "$before_head" ] || fail "A: the upgrade commit is not one commit on the old HEAD"
DA="$(bash "$repo/scripts/deed-field.sh" --find "$A")"
[ "$(bash "$repo/scripts/deed-field.sh" "$DA" provenance template-commit)" = "$TIP" ] || fail "A: the new pin was not recorded"
[ -z "$(g -C "$A" grep -n -E '^(<<<<<<<|>>>>>>>) ' -- . || true)" ] || fail "A: a conflict marker in a clean upgrade"
g -C "$A" log -1 --format=%B | grep -q "^RSR-Upgrade-Base: $before_head$" || fail "A: the commit does not record its base"
# the oracle: the upgraded child is what a mint at the tip gives, EXCEPT on the
# paths the tool says it held back (licence lines, protected files, owner-held
# files) — and on those it must have left the child's own bytes (checked in B).
# The drift gate, run against the NEW pin, names every difference; each must be
# a path the plan reported as held.
bash "$repo/scripts/check-mint-drift.sh" "$T" "$A" > "$work/a.drift" 2>&1 || true
awk -F'\t' '$1 ~ /^(LICENCE-HELD|PROTECTED|OWNER-HELD)$/ { print $2 }' "$work/a.apply" | sort -u > "$work/a.held"
sed -n 's/^DRIFT: \([^ ]*\) .*/\1/p' "$work/a.drift" | sort -u > "$work/a.drifted"
unexplained="$(comm -13 "$work/a.held" "$work/a.drifted")"
[ -z "$unexplained" ] || { echo "$unexplained" >&2; tail -5 "$work/a.drift" >&2; fail "A: the upgraded child differs from a mint at the tip on paths the plan did not hold back (above)"; }
grep -q '^DRIFT' "$work/a.drift" || grep -q '^PASS' "$work/a.drift" || fail "A: the drift gate gave no verdict"
pass "A: --apply: one commit on a new branch, pin recorded, no marker; against the NEW pin the only drift is on $(wc -l < "$work/a.drifted" | tr -d ' ') path(s), all held back by the plan ($(wc -l < "$work/a.held" | tr -d ' ') held)"
bash "$UP" --rollback --child "$A" > /dev/null 2>&1 || fail "A: --rollback refused"
[ "$(g -C "$A" rev-parse --abbrev-ref HEAD)" = main ] && [ "$(g -C "$A" rev-parse HEAD)" = "$before_head" ] \
    && [ -z "$(g -C "$A" status --porcelain)" ] && [ -z "$(g -C "$A" branch --list 'upgrade/*')" ] \
    || fail "A: --rollback did not restore the branch, HEAD and an empty branch list"
pass "A: --rollback restores main at the same commit and deletes the upgrade branch"
bash "$UP" --template "$T" --to "$OLD" --child "$A" 2>&1 | grep -q "already at" || fail "A: --to the pin itself should say it is already there"
bash "$UP" --template "$T" --to "$(g -C "$T" rev-parse "$OLD~3")" --child "$A" > /dev/null 2>&1 && fail "A: a downgrade was accepted"
pass "A: the pin itself is a no-op and an older template commit (a downgrade) is refused"

# ═══ B: conflicts, protections, owner content ═══════════════════════════════
mkchild upg-conflict
B="$work/upg-conflict"
# files the child equals at the tip too (so only the synthetic commit changes them)
pick() { # [REQUIRED-REGEX] -> first suitable script: text, >= 30 lines, unrendered, unchanged OLD..TIP, unreferenced by the mint, not in $skip
    local f need="${1:-.}"
    for f in $(g -C "$B" ls-files 'scripts/*.sh' | sort); do
        case " $skip " in *" $f "*) continue ;; esac
        [ "$(wc -l < "$B/$f")" -ge 30 ] || continue
        grep -q -E "$need" "$B/$f" || continue
        grep -qF "$(basename "$f")" "$T/build/just" "$T/Justfile" -r 2>/dev/null && continue
        grep -q -E 'rsr-template-repo|\{\{|upg-owner' "$B/$f" && continue
        g -C "$T" diff --quiet "$OLD" "$TIP" -- "$f" || continue
        g -C "$T" cat-file -e "$TIP:$f" 2>/dev/null || continue
        [ "$(g -C "$T" rev-parse "$TIP:$f")" = "$(g -C "$B" hash-object "$B/$f")" ] || continue
        [ "$(g -C "$T" log -1 --format=%h "$TIP" -- "$f")" ] || continue
        echo "$f"; return
    done
    return 1
}
skip=""; X=$(pick) || fail "no suitable file X"; skip="$skip $X"
Y=$(pick) || fail "no suitable file Y"; skip="$skip $Y"
Z=$(pick "SPDX-License-Identifier") || fail "no suitable file Z"; skip="$skip $Z"
D=$(pick) || fail "no suitable file D"; skip="$skip $D"
D2=$(pick) || fail "no suitable file D2"
LIC=LICENSE; [ -f "$B/$LIC" ] || fail "the child has no LICENSE"
LICDIR=$(g -C "$B" ls-files 'LICENSES/*' | head -1); [ -n "$LICDIR" ] || fail "the child has no LICENSES/ file"
DEEDB="$(bash "$repo/scripts/deed-field.sh" --find "$B")"; DEEDREL="${DEEDB#"$B"/}"

# the synthetic template version, on its own branch of the throwaway template
g -C "$T" checkout -q -b synthetic "$TIP"
sedl() { sed -i "$1" "$T/$2"; }
sedl "12s|.*|# synthetic template edit of line 12|" "$X"
sedl "5s|.*|# synthetic template edit of line 5|" "$Y"
sedl "s|^\(.*SPDX-License-Identifier:\).*|\1 MPL-2.0 AND CC-BY-SA-4.0|" "$Z"
printf '\n(synthetic template edit of the licence text)\n' >> "$T/$LIC"
printf '\n(synthetic template edit of a licence text file)\n' >> "$T/$LICDIR"
git -C "$T" rm -q -f "$D" "$D2"
printf '#!/usr/bin/env bash\n# SPDX-License-Identifier: MPL-2.0\necho synthetic new file\n' > "$T/scripts/zz-upgrade-fixture-new.sh"
g -C "$T" add -A; g -C "$T" commit -q -m "synthetic template change"
SYN=$(g -C "$T" rev-parse HEAD); g -C "$T" checkout -q main
# the premise of the negative test: the template really did change them
for f in "$LIC" "$LICDIR" "$Z"; do
    g -C "$T" diff --quiet "$TIP" "$SYN" -- "$f" && fail "B: the synthetic commit did not change $f (the licence test would prove nothing)"
done
grep -q "SPDX-License-Identifier: MPL-2.0 AND" "$T/$Z" 2>/dev/null || g -C "$T" show "$SYN:$Z" | grep -q "SPDX-License-Identifier: MPL-2.0 AND" || fail "B: the SPDX edit did not take"
# every licence file equals the OLD mint in the child (a fast-forward would have taken the change)
for f in "$LIC" "$LICDIR"; do
    [ "$(g -C "$B" hash-object "$B/$f")" = "$(g -C "$T" rev-parse "$TIP:$f")" ] || fail "B: $f is not what the old mint wrote (the premise: the child still equals the old mint there)"
done

# the child's own work
sedl2() { sed -i "$1" "$B/$2"; }
sedl2 "30s|.*|# the child's own edit of line 30|" "$X"          # far from the template's line 12
sedl2 "5s|.*|# the child's own, different, edit of line 5|" "$Y" # the same line
sedl2 "3s|.*|# the child's own edit of the file the template deletes|" "$D"
printf 'owner content\n' > "$B/OWNER-NOTES.txt"
g -C "$B" add -A; g -C "$B" commit -q -m "child's own work"
sums() { (cd "$B" && sha256sum "$LIC" "$LICDIR" OWNER-NOTES.txt "$Z" "$D" "$Y"); }
sums_before="$(sums)"
head_before=$(g -C "$B" rev-parse HEAD)
bash "$UP" --template "$T" --to "$SYN" --child "$B" > "$work/b.dry" 2> "$work/b.dry.err" && rc=0 || rc=$?
[ "$rc" = 3 ] || { cat "$work/b.dry.err" >&2; fail "B: a dry run with conflicts should exit 3, got $rc"; }
row() { grep -q "^$1	$2	" "$work/b.dry" || { cat "$work/b.dry" >&2; fail "B: expected $1 for $2"; }; }
row MERGED "$X"; row CONFLICT "$Y"; row LICENCE-HELD "$Z"; row PROTECTED "$LIC"; row PROTECTED "$LICDIR"
row MODIFY-DELETE "$D"; row DELETE "$D2"; row ADD scripts/zz-upgrade-fixture-new.sh
! grep -q "OWNER-NOTES" "$work/b.dry" || fail "B: the owner's own file appears in the plan"
[ "$(g -C "$B" rev-parse HEAD)" = "$head_before" ] && [ -z "$(g -C "$B" status --porcelain)" ] || fail "B: the dry run wrote to the child"
pass "B: dry run classifies MERGED, CONFLICT, LICENCE-HELD, PROTECTED (licence, licence text), MODIFY-DELETE, DELETE, ADD, and exits 3"

bash "$UP" --template "$T" --to "$SYN" --child "$B" --apply > "$work/b.apply" 2> "$work/b.apply.err" && rc=0 || rc=$?
[ "$rc" = 3 ] || { cat "$work/b.apply.err" >&2; fail "B: --apply with conflicts should exit 3, got $rc"; }
[ "$(g -C "$B" rev-parse --abbrev-ref HEAD)" = "upgrade/rsr-${SYN:0:12}" ] || fail "B: not on the upgrade branch"
# conflict: markers, both sides present, nothing chosen
grep -q '^<<<<<<< repo$' "$B/$Y" && grep -q "the child's own, different, edit of line 5" "$B/$Y" \
    && grep -q "synthetic template edit of line 5" "$B/$Y" && grep -q '^>>>>>>> template@' "$B/$Y" \
    || fail "B: $Y is not written with both sides inside conflict markers"
# merged: both edits, no marker
grep -q "the child's own edit of line 30" "$B/$X" && grep -q "synthetic template edit of line 12" "$B/$X" \
    && ! grep -q '^<<<<<<<' "$B/$X" || fail "B: $X did not merge both edits cleanly"
# modify/delete: the child's edited file is kept as the child has it; unchanged one is gone; new one is there
grep -q "the child's own edit of the file the template deletes" "$B/$D" || fail "B: the child's edited $D was not kept"
[ ! -e "$B/$D2" ] || fail "B: the unchanged $D2 was not deleted"
[ -f "$B/scripts/zz-upgrade-fixture-new.sh" ] || fail "B: the new file was not added"
# THE NEGATIVE TEST: licence files, licence line, the deed's identity, owner content: bytes unchanged
sums_after="$(sums)"
# (Y is expected to change: it holds markers; compare everything else)
diff <(grep -v " $Y$" <<<"$sums_before") <(grep -v " $Y$" <<<"$sums_after") > "$work/b.sums.diff" || { cat "$work/b.sums.diff" >&2; fail "B: a licence file, the SPDX line, the citation, the deed or owner content changed"; }
grep -q "SPDX-License-Identifier: MPL-2.0 AND" "$B/$Z" && fail "B: the SPDX line of $Z was changed by the upgrade"
[ "$(bash "$repo/scripts/deed-field.sh" "$DEEDB" provenance template-commit)" = "$SYN" ] || fail "B: the pin was not recorded"
# the chora deed: the ONLY difference from before is the recorded pin (identity, answers, canon, paths untouched)
g -C "$B" show "$head_before:$DEEDREL" > "$work/deed.before"
changed="$(diff "$work/deed.before" "$B/$DEEDREL" | grep -E '^[<>]' | grep -v -E ':(template-commit|template-tree|parent-pin)[[:space:]]' || true)"
[ -z "$changed" ] || { echo "$changed" >&2; fail "B: the upgrade changed the chora deed beyond the three recorded pins"; }
[ "$(diff "$work/deed.before" "$B/$DEEDREL" | grep -c '^>')" = 3 ] || fail "B: expected exactly three pin lines to change in the deed"
pass "B: --apply: markers hold both sides of the conflict, the far edit merged, modify/delete kept, delete and add done"
pass "NEGATIVE: LICENSE, a LICENSES/ file, an SPDX line and the chora deed's identity are byte-identical after the upgrade, though the template changed each and the child equalled the old mint there; owner content untouched"
g -C "$B" log -1 --format=%B | grep -q "^RSR-Upgrade-Needs-Human: [1-9]" || fail "B: the commit does not say it needs a human"
bash "$UP" --rollback --child "$B" >/dev/null 2>&1 || fail "B: --rollback refused"
[ "$(g -C "$B" rev-parse HEAD)" = "$head_before" ] && [ "$(sums)" = "$sums_before" ] || fail "B: --rollback did not restore the child"
pass "B: --rollback restores the child exactly"

# a dirty tree is refused for --apply, and nothing is written
echo x >> "$B/OWNER-NOTES.txt"
bash "$UP" --template "$T" --to "$SYN" --child "$B" --apply >/dev/null 2>&1 && fail "B: --apply accepted a dirty tree"
[ -z "$(g -C "$B" branch --list 'upgrade/*')" ] || fail "B: a refused --apply left a branch"
pass "a dirty work tree refuses --apply and writes nothing"
echo "ALL PASS"
