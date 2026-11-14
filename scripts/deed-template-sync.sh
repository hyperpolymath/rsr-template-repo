#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# deed-template-sync.sh, carry the template's edits to template-owned clauses
# into a minted repo's deed at a template upgrade.
#
# A template upgrade keeps the child's deed, because the deed is the child's
# identity. But some clauses are the template's text, copied in at mint: the
# (ply) directory tree. When the template fixes such a clause (#356 wrapped a
# (ply) line over the 998-octet deed line limit), the fix must reach the
# child too, or the child's DEED syntax check stays red after the upgrade.
#
# Usage:
#   deed-template-sync.sh DEED BASE NEW [CLAUSE...]
#
# DEED is the child's deed. BASE and NEW are the template's own deed at the
# commit the child was cut from (or last upgraded to) and at the upgrade
# target, e.g. `git -C <template> show <pin>:rsr-template-repo_chora.deed`.
# CLAUSE is a deed-clause.sh PATH; the default is `ply`.
#
# A three-way rule per clause, after the template's self-name
# (<template>_chora.deed) is renamed to the child's, as the mint renames it:
#   child == NEW   nothing to do;
#   child == BASE  replace the clause with NEW's text;
#   otherwise      the child changed the clause: it is left alone, and the
#                  script fails so that the clause is merged by hand.
#
# Exit: 0 every clause is in step; 1 a clause needs a hand merge or is absent;
# 2 usage error or unreadable deed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ $# -ge 3 ] || { sed -n '14,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
deed="$1"; base="$2"; new="$3"; shift 3
[ $# -gt 0 ] || set -- ply
for f in "$deed" "$base" "$new"; do
    [ -r "$f" ] || { echo "deed-template-sync: no readable deed: '$f'" >&2; exit 2; }
done
child_name="$(bash "$here/deed-field.sh" "$deed" "" canonical-name)"
tpl_name="$(bash "$here/deed-field.sh" "$new" "" canonical-name)"

rc=0
for clause in "$@"; do
    # get prints the clause with its leading comments; the rename is literal.
    mine="$(bash "$here/deed-clause.sh" get "$deed" "$clause")" \
        || { echo "deed-template-sync: ($clause) is absent from $deed" >&2; rc=1; continue; }
    old="$(bash "$here/deed-clause.sh" get "$base" "$clause")" || old=""
    upd="$(bash "$here/deed-clause.sh" get "$new" "$clause")" \
        || { echo "deed-template-sync: ($clause) is absent from the template deed $new" >&2; rc=1; continue; }
    old="${old//"${tpl_name}_chora.deed"/"${child_name}_chora.deed"}"
    upd="${upd//"${tpl_name}_chora.deed"/"${child_name}_chora.deed"}"
    if [ "$mine" = "$upd" ]; then
        echo "deed-template-sync: ($clause) already matches the template"
    elif [ -n "$old" ] && [ "$mine" = "$old" ]; then
        printf '%s' "$upd" | bash "$here/deed-clause.sh" replace "$deed" "$clause" -
        echo "deed-template-sync: ($clause) updated to the template's text"
    else
        echo "deed-template-sync: ($clause) differs from the template at both commits; merge it by hand" >&2
        rc=1
    fi
done
exit "$rc"
