#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-identity-matches-repo.sh DEED [ROOT] — the deed names the repository it
# is checked out as. check-identity.sh checks only the literal FORM of
# :repo-uuid; some repos have been found carrying a template's deed unrenamed,
# and nothing compared the deed with the repository.
#
# N is the repository name and O its owner, from scripts/repo-slug.sh run on
# ROOT (default: the directory holding DEED): $GITHUB_REPOSITORY, else the git
# origin URL, else the directory name. O may be unknown (a path-like origin,
# the directory-name fallback). D is the deed's (identity :owner), E is O
# when known, else D. Strings are compared exactly, case-sensitively.
#
#   a. header :canonical-name is N.
#   b. the deed file is named N_chora.deed.
#   c. (identity :owner), when present and O is known, is O.
#   d. (forges :github "..."), when present, is E/N (its last segment is N
#      when E is unknown).
#   e. :repo-uuid recomputes from the BIRTH path: github.com/E/n for n in N
#      and the entries of (lineage :previous-names), in the domain
#      chora-registry or gv-clade-index (ids minted before ruling V9). #uuid
#      is compared to the v8 id (scripts/uuid-v8.sh); a legacy #u8 or #u5
#      literal to the path itself, bare or after "domain:". A missing or
#      unrecognised :repo-uuid, or an E that cannot be known, is a finding:
#      the check fails closed and never skips.
#
# The id is minted once and never re-derived (ruling U1): a renamed repo keeps
# its id and records the old name in (lineage :previous-names). A transferred
# repo has no way to record its previous owner yet, so it fails here by design.
# There is no allow-list and no switch that turns a finding off. A fork that
# runs its own CI (GITHUB_REPOSITORY of the forker) fails by design.
#
# Prints one line per finding on stderr and exits 1 if there is any, 2 on a
# usage error or an unreadable deed (or no SHA-256 tool), 0 otherwise.
set -uo pipefail

[[ $# -ge 1 && $# -le 2 && -n "$1" ]] || { echo "usage: check-identity-matches-repo.sh DEED [ROOT]" >&2; exit 2; }
DEED="$1"
[[ -f "$DEED" ]] || { echo "check-identity-matches-repo.sh: no such deed: $DEED" >&2; exit 2; }
ROOT="${2:-$(dirname "$DEED")}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READ="$HERE/deed-field.sh"
SLUG="$HERE/repo-slug.sh"
UUID8="$HERE/uuid-v8.sh"

bad=0
finding() { echo "$DEED: $*" >&2; bad=1; }
die() { echo "check-identity-matches-repo.sh: $*" >&2; exit 2; }

# field [--typed] PATH KEY -> the value on stdout; sets FOUND=1 or 0
field() {
  local mode="" rc=0
  if [[ "$1" = --typed ]]; then mode="--typed"; shift; fi
  FIELD_VALUE="$(bash "$READ" ${mode:+"$mode"} "$DEED" "$1" "$2")" || rc=$?
  [[ "$rc" -le 1 ]] || die "cannot read :$2 from $DEED"
  if [[ "$rc" -eq 0 && -n "$FIELD_VALUE" ]]; then FOUND=1; else FOUND=0; FIELD_VALUE=""; fi
}

N="$(bash "$SLUG" --name "$ROOT")" || die "cannot determine the repository name for $ROOT"
O=""; rc=0
O="$(bash "$SLUG" --owner "$ROOT")" || rc=$?
[[ "$rc" -le 1 ]] || die "cannot determine the repository owner for $ROOT"
[[ "$rc" -eq 0 ]] || O=""

field identity owner; D="$FIELD_VALUE"
E="${O:-$D}"
where="the repository it is checked out as"

# a. :canonical-name
field "" canonical-name
if [[ "$FOUND" -eq 0 ]]; then
  finding ":canonical-name is missing; this repository is $N"
elif [[ "$FIELD_VALUE" != "$N" ]]; then
  finding ":canonical-name is \"$FIELD_VALUE\", but $where is \"$N\""
fi

# b. the file name
if [[ "$(basename "$DEED")" != "${N}_chora.deed" ]]; then
  finding "the deed file name is $(basename "$DEED"), but $where is \"$N\": the deed must be named ${N}_chora.deed"
fi

# c. (identity :owner)
if [[ -n "$D" && -n "$O" && "$D" != "$O" ]]; then
  finding "(identity :owner) is \"$D\", but the owner of $where is \"$O\""
fi

# d. (forges :github)
field forges github
if [[ "$FOUND" -eq 1 ]]; then
  if [[ -n "$E" ]]; then
    [[ "$FIELD_VALUE" = "$E/$N" ]] \
      || finding "(forges :github) is \"$FIELD_VALUE\", but $where is \"$E/$N\""
  elif [[ "${FIELD_VALUE##*/}" != "$N" ]]; then
    finding "(forges :github) is \"$FIELD_VALUE\", whose repository name is not \"$N\", the name of $where"
  fi
fi

# e. :repo-uuid recomputes from the birth path
field --typed "" repo-uuid; lit="$FIELD_VALUE"; have_lit="$FOUND"
if [[ "$have_lit" -eq 0 ]]; then
  finding ":repo-uuid is missing"
elif [[ ! "$lit" =~ ^\#(uuid|u8|u5)\"(.*)\"$ ]]; then
  finding ":repo-uuid $lit is not a #uuid, #u8 or #u5 literal, so it cannot be compared with the repository"
elif [[ -z "$E" ]]; then
  finding ":repo-uuid cannot be recomputed without an owner: $where has none (no forge origin URL or GITHUB_REPOSITORY owner) and the deed has no (identity :owner)"
else
  tag="${BASH_REMATCH[1]}"; body="${BASH_REMATCH[2]}"
  names=("$N")
  prev_rc=0
  prev="$(bash "$READ" --list "$DEED" lineage previous-names)" || prev_rc=$?
  [[ "$prev_rc" -le 1 ]] || die "cannot read (lineage :previous-names) from $DEED"
  if [[ "$prev_rc" -eq 0 && -n "$prev" ]]; then
    while IFS= read -r p; do [[ -n "$p" ]] && names+=("$p"); done <<< "$prev"
  fi
  paths=(); for n in "${names[@]}"; do paths+=("github.com/$E/$n"); done
  ok=0
  for path in "${paths[@]}"; do
    case "$tag" in
      uuid)
        for dom in chora-registry gv-clade-index; do
          want="$(bash "$UUID8" "$dom" "$path")" || die "uuid-v8.sh failed (needs sha256sum, shasum or openssl)"
          [[ "$body" = "$want" ]] && ok=1
        done ;;
      *)
        [[ "$body" = "$path" || "$body" == *":$path" ]] && ok=1 ;;
    esac
  done
  if [[ "$ok" -eq 0 ]]; then
    recorded="none recorded"
    [[ "${#names[@]}" -gt 1 ]] && recorded="recorded: $(IFS=,; echo "${names[*]:1}")"
    finding ":repo-uuid $lit is not the v8 id of github.com/$E/$N nor of any path built from (lineage :previous-names) ($recorded); a renamed repo records its old name in (lineage :previous-names) and keeps its id, and a transferred repo has no recordable previous owner yet, so it fails by design"
  fi
fi

exit "$bad"
