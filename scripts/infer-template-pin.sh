#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# infer-template-pin.sh — which template commit does a repo most resemble?
#
# For a repo whose deed records no (provenance :template-commit), or whose
# recorded pin is in doubt: score every template commit by how many of the
# repo's files equal that commit's blob at the same path, and rank them. This is
# EVIDENCE for a human, not a pin: a repo edits files, so the best commit is the
# one the most files still match, which is the commit the repo came from only if
# it was not changed much since (and a template that reverted a file matches
# several commits equally).
#
# Usage: infer-template-pin.sh --template DIR [--child DIR | --tree OID-OR-REPO-TREE] [--top N]
#   --template DIR  the template, full history
#   --child DIR     the repo whose HEAD tree is scored (default .); read by blob
#                   id from its tree, so a --filter=blob:none clone works
#   --top N         ranks printed (default 5)
# Output: score<TAB>commit<TAB>date<TAB>subject, best first, then a verdict line:
#   VERDICT unique    best leads the runner-up by more than 2% of the files scored
#   VERDICT ambiguous otherwise (the leaders are listed; do not pin from this)
# Exit: 0 verdict printed; 1 cannot score; 2 usage.
set -euo pipefail
export LC_ALL=C
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
TDIR="" CDIR="." TOP=5
while [ $# -gt 0 ]; do
    case "$1" in
        --template) TDIR="${2:-}"; shift 2 ;;
        --child) CDIR="${2:-}"; shift 2 ;;
        --top) TOP="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "infer-template-pin: unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$TDIR" ] && [ -d "$TDIR" ] || { echo "infer-template-pin: --template DIR is required" >&2; exit 2; }
[ "$(git -C "$TDIR" rev-parse --is-shallow-repository)" = false ] || { echo "infer-template-pin: $TDIR is shallow" >&2; exit 1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
git -C "$CDIR" ls-tree -r -z HEAD \
    | awk 'BEGIN { RS = "\0"; FS = "\t" } { split($1, m, " "); if (m[1] != "160000") print $2 "\t" m[3] }' | sort -u > "$W/child.tsv"
NF="$(wc -l < "$W/child.tsv" | tr -d ' ')"
[ "$NF" -gt 0 ] || { echo "infer-template-pin: no files in $CDIR's HEAD tree" >&2; exit 1; }
# each commit's tree, scored against the child's (path, blob) set
git -C "$TDIR" rev-list --first-parent HEAD | while IFS= read -r c; do
    n="$(git -C "$TDIR" ls-tree -r -z "$c" \
        | awk 'BEGIN { RS = "\0"; FS = "\t" } { split($1, m, " "); if (m[1] != "160000") print $2 "\t" m[3] }' \
        | sort -u | comm -12 - "$W/child.tsv" | wc -l | tr -d ' ')"
    printf '%s\t%s\n' "$n" "$c"
done | sort -t$'\t' -k1,1nr -k2,2 > "$W/scores.tsv"
head -n "$TOP" "$W/scores.tsv" | while IFS=$'\t' read -r n c; do
    printf '%s\t%s\t%s\t%s\n' "$n" "$c" "$(git -C "$TDIR" log -1 --format=%cs "$c")" "$(git -C "$TDIR" log -1 --format=%s "$c" | cut -c1-70)"
done
best="$(sed -n 1p "$W/scores.tsv" | cut -f1)"; second="$(sed -n 2p "$W/scores.tsv" | cut -f1)"
# the runner-up by DIFFERENT TREE: equal trees (reverts, empty merges) score alike by construction
bt="$(git -C "$TDIR" rev-parse "$(sed -n 1p "$W/scores.tsv" | cut -f2)^{tree}")"
second=0
while IFS=$'\t' read -r n c; do
    [ "$(git -C "$TDIR" rev-parse "$c^{tree}")" = "$bt" ] && continue
    second="$n"; break
done < "$W/scores.tsv"
margin=$(( best - second ))
if [ "$best" -gt 0 ] && [ $(( margin * 50 )) -gt "$NF" ]; then
    echo "VERDICT unique  best=$best second=$second files_in_child=$NF"
else
    echo "VERDICT ambiguous  best=$best second=$second files_in_child=$NF (margin ${margin}; do not pin from this)"
fi
