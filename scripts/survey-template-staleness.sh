#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# survey-template-staleness.sh — how many child files equal an OLDER template
# version?  The reproducible form of the mathesis proposal's count
# (docs/proposals/types-tropes-estate-upkeep.adoc: "of 45,854 child files at
# shared template paths, 14,711 equal template HEAD, 12,582 equal an older
# template version and 18,561 equal no version").
#
# Definition (by blob identity; no file content is read or fetched):
#   universe   every file (regular or symlink) in a child's default-branch tree
#              whose PATH also exists in the template at the survey ref
#              ("a shared template path");
#   current    the child's blob == the template's blob at that path, at the ref;
#   stale      not current, but == a blob the template has EVER had at that path
#              (any commit reachable from the ref);
#   diverged   equal to no version the template has had at that path.
# current + stale + diverged = universe, by construction (checked, and printed).
# A rename in the template is not followed: a path-keyed measure.
#
# Usage:
#   survey-template-staleness.sh [--template DIR] [--ref REF] [--jobs N]
#                                [--out DIR] (--repos FILE | OWNER/REPO …)
#   --template DIR   a full-history clone of the template (default: this repo's
#                    root; it is deepened if shallow)
#   --ref REF        the template version counted as "current" (default HEAD)
#   --repos FILE     one OWNER/REPO per line (# comments ok)
#   --forge URL      git base (default https://github.com)
#   --universe U     head (default): paths in the template at the ref; ever: any
#                    path the template has ever had (counts files at since-deleted
#                    template paths as stale too)
#   --own-pin M      also count, per repo, files equal to the template AT THAT REPO'S OWN
#                    PIN (the narrowed refresh basis): M = recorded (the deed's
#                    :template-commit only) or infer (infer-template-pin.sh when none is
#                    recorded, taken only on a `unique` verdict). Writes own-pin.tsv. The
#                    basis is blob equality with the template at the pin, an upper bound
#                    on equality with the replayed mint (no replay: no answers).
#   --jobs N         parallel child fetches (default 6)
#   --out DIR        keep per-repo tables here (default: a temp dir, removed);
#                    writes per-repo.tsv, stale-files.tsv, failed.txt
# Child trees are fetched with --depth 1 --filter=blob:none: trees only, so a
# survey of hundreds of repositories moves megabytes, not gigabytes.
# This is a survey: it never writes to any child and never needs credentials
# (public repositories). A private or unreachable repository is listed in
# failed.txt and excluded from the denominator, which is printed.
# Exit: 0 survey completed; 1 could not complete; 2 usage.
set -euo pipefail
export LC_ALL=C
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OWNPIN="" UNIVERSE=head TEMPLATE="$(cd "$HERE/.." && pwd)" REF=HEAD JOBS=6 OUT="" FORGE="https://github.com" LIST="" REPOS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --template) TEMPLATE="$(cd "${2:?}" && pwd)"; shift 2 ;;
        --ref) REF="${2:?}"; shift 2 ;;
        --jobs) JOBS="${2:?}"; shift 2 ;;
        --out) OUT="${2:?}"; shift 2 ;;
        --forge) FORGE="${2:?}"; shift 2 ;;
        --universe) UNIVERSE="${2:?}"; shift 2 ;;
        --own-pin) OWNPIN="${2:?}"; shift 2 ;;
        --repos) LIST="${2:?}"; shift 2 ;;
        -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "survey-template-staleness: unknown option $1" >&2; exit 2 ;;
        *) REPOS+=("$1"); shift ;;
    esac
done
if [ -n "$LIST" ]; then
    while IFS= read -r l; do l="${l%%#*}"; l="${l//[[:space:]]/}"; [ -n "$l" ] && REPOS+=("$l"); done < "$LIST"
fi
[ "${#REPOS[@]}" -gt 0 ] || { echo "survey-template-staleness: no repositories given" >&2; exit 2; }
for r in "${REPOS[@]}"; do
    [[ "$r" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "survey-template-staleness: not OWNER/REPO: $r" >&2; exit 2; }
done

W="$(mktemp -d)"
if [ -n "$OUT" ]; then mkdir -p "$OUT"; else OUT="$W/out"; mkdir -p "$OUT"; fi
trap 'rm -rf "$W"' EXIT

if [ "$(git -C "$TEMPLATE" rev-parse --is-shallow-repository)" = true ]; then
    git -C "$TEMPLATE" fetch -q --unshallow origin 2>/dev/null \
        || git -C "$TEMPLATE" fetch -q --depth=100000 origin \
        || { echo "survey-template-staleness: cannot deepen $TEMPLATE; the stale class needs full history" >&2; exit 1; }
fi
git -C "$TEMPLATE" rev-parse -q --verify "$REF^{commit}" >/dev/null \
    || { echo "survey-template-staleness: $REF is not a commit of $TEMPLATE" >&2; exit 1; }
TIP="$(git -C "$TEMPLATE" rev-parse "$REF^{commit}")"
NCOMMITS="$(git -C "$TEMPLATE" rev-list --count "$TIP")"

# Template side. head.tsv: path<TAB>blob at the ref. ever.tsv: path<TAB>blob for
# every version the path has had in any commit up to the ref (added, modified or
# type-changed; merges contribute through the commits they merge).
git -C "$TEMPLATE" ls-tree -r -z "$TIP" \
    | awk 'BEGIN { RS = "\0"; FS = "\t" } { split($1, m, " "); if (m[1] != "160000") print $2 "\t" m[3] }' \
    | sort -u > "$W/head.tsv"
{
    cat "$W/head.tsv"
    git -C "$TEMPLATE" log --format= --raw -r --no-renames --root --no-abbrev -z --diff-filter=AMT "$TIP" \
        | awk 'BEGIN { RS = "\0" }
               /^:/ { split($0, f, " "); mode = f[2]; blob = f[4]; getline p; if (mode != "160000") print p "\t" blob }'
} | sort -u > "$W/ever.tsv"

fetch_one() { # OWNER/REPO -> $W/child/<owner>__<repo>.tsv , or failed
    local r="$1" d="$W/child/${1//\//__}"
    mkdir -p "$W/child"
    if git clone -q --depth 1 --filter=blob:none --no-checkout "$FORGE/$r.git" "$d.git" 2>"$d.err"; then
        git -C "$d.git" ls-tree -r -z HEAD \
            | awk 'BEGIN { RS = "\0"; FS = "\t" } { split($1, m, " "); if (m[1] != "160000") print $2 "\t" m[3] }' \
            | sort -u > "$d.tsv"
        # what the root chora deed records: the pin, and whether the mint can be replayed
        local dp pin ans=no
        dp="$(awk -F'\t' '$1 ~ /^[^\/]*_chora\.deed$/ { print $1; exit }' "$d.tsv")"
        if [ -n "$dp" ] && git -C "$d.git" show "HEAD:$dp" > "$d.deed" 2>/dev/null; then
            pin="$(sed -n 's/^[[:space:]]*:template-commit[[:space:]]*"\([0-9a-f]\{40\}\)".*$/\1/p' "$d.deed" | head -1)"
            grep -q '^[[:space:]]*(mint-answers' "$d.deed" && ans=yes
            printf '%s\t%s' "$ans" "${pin:--}" > "$d.rec"
        else
            printf 'none\t-' > "$d.rec"
        fi
        rm -f "$d.deed"
        if [ -n "${OWNPIN:-}" ]; then
            # the pin this repo's own refresh is measured against, and where it came from
            pin="$(cut -f2 "$d.rec")"; basis=recorded
            if [ "$pin" = - ] && [ "$OWNPIN" = infer ]; then
                v="$(bash "$HERE/infer-template-pin.sh" --template "$TEMPLATE" --child "$d.git" --top 1 2>/dev/null || true)"
                if grep -q '^VERDICT unique' <<<"$v"; then pin="$(sed -n 1p <<<"$v" | cut -f2)"; basis=inferred; fi
            fi
            if [ "$pin" != - ] && git -C "$TEMPLATE" cat-file -e "${pin}^{commit}" 2>/dev/null; then printf '%s\t%s' "$basis" "$pin" > "$d.pin"; else printf 'none\t-' > "$d.pin"; fi
        fi
        rm -rf "$d.git" "$d.err"
    else
        echo "$r" >> "$W/failed.txt"
        rm -rf "$d.git"
    fi
}
export -f fetch_one; export W FORGE HERE TEMPLATE OWNPIN
: > "$W/failed.txt"
printf '%s\n' "${REPOS[@]}" | xargs -P "$JOBS" -I{} bash -c 'fetch_one {}'

: > "$OUT/per-repo.tsv"; : > "$OUT/stale-files.tsv"
printf 'repo\tuniverse\tcurrent\tstale\tdiverged\tmint_answers\tpin\n' > "$OUT/per-repo.tsv"
for t in "$W"/child/*.tsv; do
    [ -e "$t" ] || continue
    r="$(basename "$t" .tsv)"; r="${r/__//}"
    rec="$(cat "${t%.tsv}.rec" 2>/dev/null || printf 'none\t-')"
    awk -F'\t' -v repo="$r" -v stale="$OUT/stale-files.tsv" -v uni="$UNIVERSE" -v rec="$rec" '
        FILENAME == ARGV[1] { head[$1] = $2; next }
        FILENAME == ARGV[2] { ever[$1 SUBSEP $2] = 1; evpath[$1] = 1; next }
        (uni == "ever" ? ($1 in evpath) : ($1 in head)) {
            u++
            if ($2 == head[$1]) c++
            else if (($1 SUBSEP $2) in ever) { s++; print repo "\t" $1 "\t" $2 "\t" head[$1] >> stale }
            else d++
        }
        END { printf "%s\t%d\t%d\t%d\t%d\t%s\n", repo, u, c, s, d, rec }' "$W/head.tsv" "$W/ever.tsv" "$t" >> "$OUT/per-repo.tsv"
done
cp "$W/failed.txt" "$OUT/failed.txt"

if [ -n "$OWNPIN" ]; then
    printf 'repo\tpin_basis\tpin\town_pin_stale\town_pin_refreshable\n' > "$OUT/own-pin.tsv"
    for t in "$W"/child/*.tsv; do
        [ -e "$t" ] || continue
        r="$(basename "$t" .tsv)"; r="${r/__//}"
        IFS=$'\t' read -r basis pin < "${t%.tsv}.pin" || true
        if [ "$pin" = - ]; then printf '%s\tnone\t-\t0\t0\n' "$r" >> "$OUT/own-pin.tsv"; continue; fi
        [ -s "$W/pin.$pin" ] || git -C "$TEMPLATE" ls-tree -r -z "$pin" \
            | awk 'BEGIN { RS = "\0"; FS = "\t" } { split($1, m, " "); if (m[1] != "160000") print $2 "\t" m[3] }' | sort -u > "$W/pin.$pin"
        awk -F'\t' -v repo="$r" -v basis="$basis" -v pin="$pin" '
            FILENAME == ARGV[1] { head[$1] = $2; next }
            FILENAME == ARGV[2] { atpin[$1] = $2; next }
            ($1 in head) && ($1 in atpin) && $2 == atpin[$1] && $2 != head[$1] {
                s++
                b = $1; sub(/.*\//, "", b); lb = tolower(b)
                if (lb ~ /^(license|licence|copying|unlicense)/ || $1 ~ /(^|\/)(LICENSES|LICENCES)\// || $1 ~ /_chora\.deed$|CODEOWNERS|CITATION\.cff|^\.github\/settings|rulesets|actions\.lock/ \
                    || $1 ~ /(^|\/)docs\/status\/|PROOF-STATUS|PROOF-NEEDS|TEST-NEEDS|READINESS|ROADMAP|(^|\/)STATE[.-]|receipt|\.machine_readable\/coaptation\/|(^|\/)verification\/proofs\//) next
                r++
            }
            END { printf "%s\t%s\t%s\t%d\t%d\n", repo, basis, pin, s, r }' "$W/head.tsv" "$W/pin.$pin" "$t" >> "$OUT/own-pin.tsv"
    done
    awk -F'\t' 'NR > 1 { n++; if ($2 == "recorded") rec++; else if ($2 == "inferred") inf++; s += $4; r += $5 }
        END { printf "own-pin basis          recorded pins %d, inferred (unique) %d, none %d\n", rec, inf, n - rec - inf
              printf "  equal the template at their own pin, not HEAD: %d   <- the narrowed refresh set\n", s
              printf "  of which outside the never-touch classes:           %d\n", r }' "$OUT/own-pin.tsv" > "$W/ownpin.summary"
fi

tail -n +2 "$OUT/per-repo.tsv" | awk -F'\t' -v tip="$TIP" -v nc="$NCOMMITS" -v nf="$(grep -c . "$OUT/failed.txt" || true)" '
    { n++; u += $2; c += $3; s += $4; d += $5; if ($4 > 0) withstale++ }
    END {
        if (u != c + s + d) { print "survey-template-staleness: INTERNAL: classes do not sum to the universe" > "/dev/stderr"; exit 1 }
        printf "template ref            %s (%s commits of history)\n", tip, nc
        printf "repositories surveyed   %d   (failed/unreachable: %d, see failed.txt)\n", n, nf
        printf "files at shared paths   %d\n", u
        printf "  equal template HEAD   %d\n", c
        printf "  equal an older one    %d   <- the exact-stale refresh set\n", s
        printf "  equal no version      %d\n", d
        printf "repositories with >=1 stale file: %d\n", withstale
    }'
[ ! -s "$W/ownpin.summary" ] || cat "$W/ownpin.summary"
[ "$OUT" = "$W/out" ] || echo "tables kept in $OUT (per-repo.tsv, stale-files.tsv, failed.txt)"
