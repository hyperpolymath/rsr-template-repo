#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# rsr-campaign.sh known-version guard and MANIFEST promote step.
# Positive: an older unedited copy (and the previous version after a rename of
# the spine) is UPDATED, and its quarantine line becomes gated, only that line.
# Negative: an edited copy is EDITED and byte-for-byte untouched; an absent
# path is ADDED only without the guard's targeting (here: reported ADDED, so
# the targeted-run rule is the repos file); a manifest without the guard
# still behaves as before. Network-free via git insteadOf.
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
g0() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

S="$work/rsr-template-repo"; g0 init -q -b main "$S"
mkdir -p "$S/p"
printf 'v1 rsr-template-repo\n' > "$S/p/a.idr"; printf 'v1\n' > "$S/p/b.idr"
g0 -C "$S" add -A; g0 -C "$S" commit -q -m v1
printf 'v2 rsr-template-repo\n' > "$S/p/a.idr"; printf 'v2\n' > "$S/p/b.idr"
g0 -C "$S" add -A; g0 -C "$S" commit -q -m v2
printf 'v3 rsr-template-repo\n' > "$S/p/a.idr"; printf 'v3\n' > "$S/p/b.idr"
g0 -C "$S" add -A; g0 -C "$S" commit -q -m v3
# Deliberately shallow spine: the guard must deepen it.
mkdir -p "$work/s2"; SS="$work/s2/rsr-template-repo"; g0 clone -q --depth 1 "file://$S" "$SS"

MF='# header
p|a.idr|quarantine| old note
p|b.idr|gated| keep me
p|c.idr|quarantine| not touched
'
mk() { # name a-content b-content
    local R="$work/src/$1"; g0 init -q -b main "$R"; mkdir -p "$R/p" "$R/v"
    printf '%s\n' "$2" > "$R/p/a.idr"; printf '%s\n' "$3" > "$R/p/b.idr"
    printf '%s' "$MF" > "$R/v/MANIFEST"
    g0 -C "$R" add -A; g0 -C "$R" commit -q -m init
    mkdir -p "$work/remotes/owner"; g0 clone -q --bare "$R" "$work/remotes/owner/$1.git"
}
mk older "v1 older" "v1"            # unedited v1 (name substituted)
mk edited "v2 AGPL-3.0-or-later local" "v2"   # a.idr edited, b.idr older
mk current "v3 current" "v3"        # already current
printf 'owner/older\nowner/edited\nowner/current\n' > "$work/repos.txt"
printf '[meta]\nname = t/guard\nupdate-guard = known-versions\n[paths]\np/a.idr\np/b.idr\n[promote]\nv/MANIFEST\n' > "$work/g.campaign"
printf '[meta]\nname = t/noguard\n[paths]\np/a.idr\np/b.idr\n' > "$work/n.campaign"

run() { # manifest report extra...
    local m="$1" r="$2"; shift 2
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$work/remotes/.insteadOf" GIT_CONFIG_VALUE_0="https://github.com/" \
        bash "$repo/scripts/rsr-campaign.sh" --manifest "$m" --repos-file "$work/repos.txt" \
        --spine "$SS" --work-dir "$work/run" --report "$r" "$@" >"$work/out" 2>&1 \
        || { cat "$work/out" >&2; fail "campaign run failed ($m)"; }
}
row() { grep -qP "^owner/$1\t$2\t$3\t" "${REP:-$work/rep.tsv}" || { cat "${REP:-$work/rep.tsv}" >&2; fail "owner/$1 $2: expected $3"; }; }

# 1. dry run: classification only
run "$work/g.campaign" "$work/rep.tsv"
row older p/a.idr UPDATED; row older p/b.idr UPDATED; row older p/a.idr PROMOTED
row edited p/a.idr EDITED; row edited p/b.idr UPDATED
row current p/a.idr UNCHANGED; row current p/b.idr UNCHANGED
grep -qP "^owner/edited\tp/a.idr\tUPDATED" "$work/rep.tsv" && fail "an edited copy was classed UPDATED"
grep -qP "^owner/(edited|current)\t.*\tPROMOTED" "$work/rep.tsv" && fail "promoted without an update to a quarantined module"
[[ "$(git -C "$SS" rev-parse --is-shallow-repository)" = false ]] || fail "the shallow spine was not deepened"
[[ ! -e "$work/run/repos/owner/older/p/a.idr" ]] || true

# 2. apply: files and MANIFEST really change, and only as promised
run "$work/g.campaign" "$work/rep2.tsv" --apply
O="$work/run/repos/owner/older"
[[ "$(cat "$O/p/a.idr")" = 'v3 older' ]] || fail "older a.idr not brought to current"
want='# header
p|a.idr|gated| promoted '"$(date -u +%F)"' by campaign t/guard: compiles after the fix (was: old note)
p|b.idr|gated| keep me
p|c.idr|quarantine| not touched
'
[[ "$(cat "$O/v/MANIFEST")" = "${want%$'\n'}" ]] || { diff <(printf '%s' "$want") "$O/v/MANIFEST" >&2 || true; fail "MANIFEST changed beyond the one quarantine line"; }
E="$work/run/repos/owner/edited"
[[ "$(cat "$E/p/a.idr")" = 'v2 AGPL-3.0-or-later local' ]] || fail "edited a.idr was touched"
[[ "$(cat "$E/p/b.idr")" = v3 ]] || fail "edited repo's unedited b.idr not updated"
[[ "$(cat "$E/v/MANIFEST")" = "${MF%$'\n'}" ]] || fail "MANIFEST of the edited repo changed though its quarantined module was not updated"

# 3. negative control: without the guard an edited copy is overwritten (the
#    old behaviour), proving the guard is what protects it
run "$work/n.campaign" "$work/rep3.tsv"
REP="$work/rep3.tsv" row edited p/a.idr UPDATED
grep -q EDITED "$work/rep3.tsv" && fail "guard active without being asked"

# 4. unknown guard value is refused
printf '[meta]\nupdate-guard = bogus\n[paths]\np/a.idr\n' > "$work/bad.campaign"
if bash "$repo/scripts/rsr-campaign.sh" --manifest "$work/bad.campaign" --repos-file "$work/repos.txt" --spine "$S" --work-dir "$work/run" >/dev/null 2>&1; then
    fail "an unknown update-guard value was accepted"
fi
echo 'PASS: rsr-campaign.sh guard updates only known template versions, leaves edited copies, and promotes only the one MANIFEST line'
