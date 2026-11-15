#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# A repository named <owner>.github.io is a user/organisation GitHub Pages site,
# served at https://<owner>.github.io/ with no /<repo> segment. The README's K9
# badge URL has both tokens, so `just repo-init` must drop /<repo> for that name
# form and keep it for an ordinary project repository.
#
# This runs the REAL rule, scripts/pages-root-url.sh (the one `just repo-init`
# calls), in front of the generic OWNER and REPO rules exactly as the recipe
# orders them, and applies the resulting sed program to the README's actual badge
# line. A negative control runs the same program WITHOUT the rule and must give
# the wrong URL, so the assertions cannot pass vacuously. It also checks that the
# recipe really calls the script.
#
# Template tree only: a minted child has real URLs and no tokens to substitute.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! bash "$root/scripts/is-template-tree.sh" "$root"; then
    echo "Self-skipping: not the template tree."
    exit 0
fi

recipe="$root/build/just/repo-init.just"
readme="$root/README.adoc"
rule="$root/scripts/pages-root-url.sh"
fail=0
bad() { echo "FAIL: $*" >&2; echo "::error::user-pages badge url: $*"; fail=1; }
ok() { echo "PASS: $*"; }

[[ -x "$rule" ]] || { bad "$rule is missing or not executable"; exit 1; }
grep -q 'scripts/pages-root-url.sh' "$recipe" || bad "repo-init.just does not call scripts/pages-root-url.sh"

line="$(grep -F 'badges/k9.json' "$readme" | head -1)"
[[ -n "$line" ]] || { bad "no badge line in README.adoc"; exit 1; }

lb=$(printf '\x7b\x7b'); rb=$(printf '\x7d\x7d')
sed_rhs() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# render OWNER REPO WITH_RULE -> the badge image URL after substitution
render() {
    local owner_name="$1" repo_name="$2" with_rule="$3" expr=""
    local args=(
        -e "s|${lb}REPO${rb}|$(sed_rhs "$repo_name")|g"
        -e "s|${lb}OWNER${rb}|$(sed_rhs "$owner_name")|g"
    )
    if [[ "$with_rule" = yes ]]; then
        expr="$(bash "$rule" "$owner_name" "$repo_name")"
        if [[ -n "$expr" ]]; then args=(-e "$expr" "${args[@]}"); fi
    fi
    printf '%s\n' "$line" | sed "${args[@]}" | sed -E 's/.*endpoint\?url=([^[]*)\[.*/\1/'
}

check() { # check LABEL OWNER REPO EXPECTED
    local got
    got="$(render "$2" "$3" yes)"
    if [[ "$got" = "$4" ]]; then ok "$1 -> $got"; else bad "$1: got '$got', want '$4'"; fi
}

check "project repo keeps /<repo>" acme widget "https://acme.github.io/widget/badges/k9.json"
check "user site drops /<repo>" acme acme.github.io "https://acme.github.io/badges/k9.json"
check "user site, mixed-case owner" Acme Acme.github.io "https://Acme.github.io/badges/k9.json"
check "user site, case-insensitive repo name" Acme acme.GitHub.io "https://Acme.github.io/badges/k9.json"
check "another owner's .github.io name is a project repo" acme other.github.io "https://acme.github.io/other.github.io/badges/k9.json"
check "name merely containing the owner stays a project repo" acme acme-site "https://acme.github.io/acme-site/badges/k9.json"

# The rule prints nothing when it does not apply, and a sed expression when it does.
[[ -z "$(bash "$rule" acme widget)" ]] && ok "no expression for a project repo" || bad "an expression was printed for a project repo"
[[ -n "$(bash "$rule" acme acme.github.io)" ]] && ok "an expression for the user-site name" || bad "no expression for the user-site name"

# Negative control: without the rule the user-site form is wrong, so the
# assertions above are sensitive to it.
got="$(render acme acme.github.io no)"
if [[ "$got" = "https://acme.github.io/acme.github.io/badges/k9.json" ]]; then
    ok "control: without the rule the user-site URL carries a bogus /<repo> segment"
else
    bad "control: expected the bogus URL without the rule, got '$got'"
fi

if [[ "$fail" -ne 0 ]]; then echo "FAIL: user pages badge url" >&2; exit 1; fi
echo "PASS: user pages badge url (6 cases, 2 rule checks, 1 control)"
