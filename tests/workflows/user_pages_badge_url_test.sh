#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# A repository named <owner>.github.io is a user/organisation GitHub Pages site,
# served at https://<owner>.github.io/ with no /<repo> segment. The README's K9
# badge URL has both tokens, so `just repo-init` must drop /<repo> for that name
# form and keep it for an ordinary project repository.
#
# This runs the REAL substitution rule: it extracts the block between the
# `BEGIN/END pages-root-url` markers in build/just/repo-init.just, runs it with
# the generic OWNER and REPO rules in front of it (as in the recipe), and applies
# the resulting sed program to the README's actual badge line. A negative control
# runs the same program WITHOUT the block and must produce the wrong URL, so the
# assertions cannot pass vacuously.
#
# Template tree only: a minted child has real URLs and no tokens to substitute.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! bash "$ROOT/scripts/is-template-tree.sh" "$ROOT"; then
    echo "Self-skipping: not the template tree."
    exit 0
fi

RECIPE="$ROOT/build/just/repo-init.just"
README="$ROOT/README.adoc"
fail=0
bad() { echo "FAIL: $*" >&2; echo "::error::user-pages badge url: $*"; fail=1; }
ok() { echo "PASS: $*"; }

block="$(sed -n '/# BEGIN pages-root-url/,/# END pages-root-url/p' "$RECIPE")"
[[ -n "$block" ]] || { bad "no BEGIN/END pages-root-url block in $RECIPE"; exit 1; }

line="$(grep -F 'badges/k9.json' "$README" | head -1)"
[[ -n "$line" ]] || { bad "no badge line in README.adoc"; exit 1; }

LB=$(printf '\x7b\x7b'); RB=$(printf '\x7d\x7d')
sed_rhs() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# render OWNER REPO WITH_BLOCK -> the badge image URL after substitution
render() {
    local OWNER="$1" REPO="$2" with="$3"
    local SED_ARGS=(
        -e "s|${LB}REPO${RB}|$(sed_rhs "${REPO}")|g"
        -e "s|${LB}OWNER${RB}|$(sed_rhs "${OWNER}")|g"
    )
    if [[ "$with" = yes ]]; then eval "$block"; fi
    printf '%s\n' "$line" | sed "${SED_ARGS[@]}" | sed -E 's/.*endpoint\?url=([^[]*)\[.*/\1/'
}

check() { # check LABEL OWNER REPO EXPECTED
    local got; got="$(render "$2" "$3" yes)"
    if [[ "$got" = "$4" ]]; then ok "$1 -> $got"; else bad "$1: got '$got', want '$4'"; fi
}

check "project repo keeps /<repo>" acme widget "https://acme.github.io/widget/badges/k9.json"
check "user site drops /<repo>" acme acme.github.io "https://acme.github.io/badges/k9.json"
check "user site, mixed-case owner" Acme Acme.github.io "https://Acme.github.io/badges/k9.json"
check "user site, case-insensitive repo name" Acme acme.GitHub.io "https://Acme.github.io/badges/k9.json"
check "another owner's .github.io name is a project repo" acme other.github.io "https://acme.github.io/other.github.io/badges/k9.json"
check "name merely containing the owner stays a project repo" acme acme-site "https://acme.github.io/acme-site/badges/k9.json"

# Negative control: without the block the user-site form is wrong, so the
# assertions above are sensitive to it.
got="$(render acme acme.github.io no)"
if [[ "$got" = "https://acme.github.io/acme.github.io/badges/k9.json" ]]; then
    ok "control: without the rule the user-site URL carries a bogus /<repo> segment"
else
    bad "control: expected the bogus URL without the rule, got '$got'"
fi

if [[ "$fail" -ne 0 ]]; then echo "FAIL: user pages badge url" >&2; exit 1; fi
echo "PASS: user pages badge url (6 cases + 1 control)"
