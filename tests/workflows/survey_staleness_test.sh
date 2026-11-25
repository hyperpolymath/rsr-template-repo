#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# survey_staleness_test.sh — scripts/survey-template-staleness.sh and
# scripts/infer-template-pin.sh on a tiny forge built here, with counts known
# in advance. Network-free: the "forge" is a directory of repositories.
#
#   template history   c1: a=v1 b=v1 c=v1 | c2: a=v2 | c3: a=v3 b=v2        (HEAD = c3)
#   r1  a=v1 (stale)   b=v2 (current)  c=v1 (current: c never changed)   own file x
#   r2  a=v3 (current) b=EDIT (diverged) c=v1 (current)                   a deed with a recorded pin
#   r3  does not exist (counted as failed, not in the denominator)
#   expected, universe=head:  universe 6, current 4, stale 1, diverged 1
# Usage: bash tests/workflows/survey_staleness_test.sh
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
g() { git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
mkrepo() { rm -rf "$1"; mkdir -p "$1"; g -C "$1" init -q -b main; }

T="$work/template"; mkrepo "$T"
put() { mkdir -p "$(dirname "$T/$1")"; printf '%s\n' "$2" > "$T/$1"; }
put a v1; put b v1; put c v1; g -C "$T" add -A; g -C "$T" commit -q -m c1; C1=$(g -C "$T" rev-parse HEAD)
put a v2; g -C "$T" add -A; g -C "$T" commit -q -m c2
put a v3; put b v2; g -C "$T" add -A; g -C "$T" commit -q -m c3

F="$work/forge/o"; mkdir -p "$F"
mkchild() { # NAME a b c [extra-file content]
    local d="$F/$1.git"; mkrepo "$d"
    printf '%s\n' "$2" > "$d/a"; printf '%s\n' "$3" > "$d/b"; printf '%s\n' "$4" > "$d/c"
    [ -z "${5:-}" ] || printf '%s\n' "$6" > "$d/$5"
    g -C "$d" add -A; g -C "$d" commit -q -m init
}
mkchild r1 v1 v2 v1 x "own"
mkchild r2 v3 EDIT v1 r2_chora.deed "(repo-deed
  (provenance
    :template-repo \"o/template\"
    :template-commit \"$C1\")
  (mint-answers :schema-version \"1\"))"

out=$(bash "$repo/scripts/survey-template-staleness.sh" --template "$T" --ref main --forge "file://$work/forge" --jobs 2 --out "$work/out" o/r1 o/r2 o/r3 2>&1) \
    || { echo "$out" >&2; fail "the survey failed"; }
want() { grep -qE "$1" <<<"$out" || { echo "$out" >&2; fail "expected: $1"; }; }
want 'repositories surveyed +2 +\(failed/unreachable: 1'
want 'files at shared paths +6$'
want 'equal template HEAD +4$'
want 'equal an older one +1 '
want 'equal no version +1$'
pass "survey: universe 6 = current 4 + stale 1 + diverged 1; the missing repo is failed, not in the denominator"
[ "$(awk -F'\t' '$1=="o/r1" {print $4}' "$work/out/per-repo.tsv")" = 1 ] || fail "r1 should have one stale file"
[ "$(cut -f2,3 "$work/out/stale-files.tsv" | tr '\t' ' ')" = "a $(g -C "$T" rev-parse "$C1:a")" ] || fail "the stale file is not a@v1's blob"
awk -F'\t' '$1=="o/r2" { exit !($6=="yes" && $7=="'"$C1"'") }' "$work/out/per-repo.tsv" || fail "r2's recorded mint-answers and pin were not read"
awk -F'\t' '$1=="o/r1" { exit !($6=="none") }' "$work/out/per-repo.tsv" || fail "r1 has no deed and should read none"
pass "survey: the stale file is exactly a@v1; the deed's pin and (mint-answers) are read from a partial clone"
out2=$(bash "$repo/scripts/survey-template-staleness.sh" --template "$T" --ref main --forge "file://$work/forge" --jobs 1 o/r1 o/r2 o/r3 2>&1)
[ "$(grep -E '^(files|  equal)' <<<"$out")" = "$(grep -E '^(files|  equal)' <<<"$out2")" ] || fail "a second run gave other numbers"
pass "survey: a second run (other job count) gives the same numbers"
# the 'ever' universe adds files at since-deleted paths: delete c from the template and survey again
g -C "$T" rm -q c; g -C "$T" commit -q -m c4
e=$(bash "$repo/scripts/survey-template-staleness.sh" --template "$T" --ref main --universe ever --forge "file://$work/forge" o/r1 o/r2 2>&1)
grep -qE 'files at shared paths +6$' <<<"$e" && grep -qE 'equal an older one +3 ' <<<"$e" || { echo "$e" >&2; fail "--universe ever should count the two files at deleted path c as older versions"; }
h=$(bash "$repo/scripts/survey-template-staleness.sh" --template "$T" --ref main --forge "file://$work/forge" o/r1 o/r2 2>&1)
grep -qE 'files at shared paths +4$' <<<"$h" || { echo "$h" >&2; fail "--universe head should drop deleted path c"; }
pass "survey: --universe head ignores a since-deleted path; --universe ever counts files there as stale"

# ── infer-template-pin: unique on a child that is one commit's tree, ambiguous when files never changed ──
T2="$work/t2"; mkrepo "$T2"
for i in $(seq 1 60); do printf 'f%s v1\n' "$i" > "$T2/f$i"; done; g -C "$T2" add -A; g -C "$T2" commit -q -m base
for i in $(seq 1 5); do printf 'f%s v2\n' "$i" > "$T2/f$i"; done; g -C "$T2" add -A; g -C "$T2" commit -q -m second; S=$(g -C "$T2" rev-parse HEAD)
for i in $(seq 6 10); do printf 'f%s v2\n' "$i" > "$T2/f$i"; done; g -C "$T2" add -A; g -C "$T2" commit -q -m third
CH="$work/child2"; mkrepo "$CH"; git -C "$T2" archive "$S" | tar -x -C "$CH"; g -C "$CH" add -A; g -C "$CH" commit -q -m init
r=$(bash "$repo/scripts/infer-template-pin.sh" --template "$T2" --child "$CH" --top 3)
grep -q "^VERDICT unique" <<<"$r" && [ "$(sed -n 1p <<<"$r" | cut -f2)" = "$S" ] || { echo "$r" >&2; fail "the child is commit 'second''s tree: it should be named, uniquely"; }
pass "infer: a child equal to one commit's tree is named, with a unique verdict"
CH2="$work/child3"; mkrepo "$CH2"; printf 'f30 v1\n' > "$CH2/f30"; g -C "$CH2" add -A; g -C "$CH2" commit -q -m init
r=$(bash "$repo/scripts/infer-template-pin.sh" --template "$T2" --child "$CH2" --top 3)
grep -q "^VERDICT ambiguous" <<<"$r" || { echo "$r" >&2; fail "a child whose one file never changed must be ambiguous"; }
pass "infer: a child whose files never changed is reported ambiguous, not guessed"
echo "ALL PASS"
