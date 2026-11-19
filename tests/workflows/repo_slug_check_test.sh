#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# `just repo-init` must admit a repository named <owner>.github.io (a user/org
# GitHub Pages site) as a slug, or the root-relative badge rule in
# scripts/pages-root-url.sh can never be reached. This runs the REAL slug rule,
# scripts/check-repo-slug.sh (the one the recipe calls, after the owner prompt),
# and checks the recipe really calls it. A negative control runs the previous
# inline rule, which must reject acme.github.io, so the assertions are sensitive.
#
# Template tree only.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! bash "$root/scripts/is-template-tree.sh" "$root"; then
    echo "Self-skipping: not the template tree."
    exit 0
fi

recipe="$root/build/just/repo-init.just"
rule="$root/scripts/check-repo-slug.sh"
fail=0
bad() { echo "FAIL: $*" >&2; echo "::error::repo slug check: $*"; fail=1; }
ok() { echo "PASS: $*"; }

[[ -x "$rule" ]] || { bad "$rule is missing or not executable"; exit 1; }
grep -q 'scripts/check-repo-slug.sh' "$recipe" || bad "repo-init.just does not call scripts/check-repo-slug.sh"
# The slug rule must run after OWNER is known.
o="$(grep -n '"Owner \[' "$recipe" | head -1 | cut -d: -f1)"
c="$(grep -n 'scripts/check-repo-slug.sh "' "$recipe" | head -1 | cut -d: -f1)"
if [[ -n "$o" && -n "$c" && "$c" -gt "$o" ]]; then ok "slug check runs after the owner prompt"; else bad "slug check does not run after the owner prompt"; fi

accept() { # accept LABEL ARCH OWNER REPO
    if bash "$rule" "$2" "$3" "$4" >/dev/null 2>&1; then ok "$1"; else bad "$1: '$4' (owner '$3') was rejected"; fi
}
reject() {
    if bash "$rule" "$2" "$3" "$4" >/dev/null 2>&1; then bad "$1: '$4' (owner '$3') was accepted"; else ok "$1"; fi
}

accept "user site, owner acme" "" acme acme.github.io
reject "another owner's .github.io name" "" other acme.github.io
accept "user site, mixed-case owner" "" Acme Acme.github.io
accept "user site, owner and name differ in case" "" Acme acme.GitHub.io
accept "user site under julia-library" julia-library acme acme.github.io
reject "name merely containing the owner" "" acme acme.github.io.evil
reject "owner-prefixed but not .github.io" "" acme acme.example.io
accept "normal slug" "" acme my-project
reject "bad slug My_Repo" "" acme My_Repo
reject "uppercase slug" "" acme MyRepo
reject "doubled hyphen" "" acme my--project
reject "<Name>.jl outside julia-library" "" acme Apodeixis.jl
accept "<Name>.jl for julia-library" julia-library acme Apodeixis.jl
reject "lowercase .jl for julia-library" julia-library acme apodeixis.jl

# Negative control: the previous inline rule (no OWNER comparison) rejects the
# user-site name, which is the defect this test guards against.
old_rule() { # old_rule ARCH REPO
    if [[ "$1" = "julia-library" && "$2" =~ ^[A-Z][A-Za-z0-9]*\.jl$ ]]; then return 0
    elif [[ ! "$2" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then return 1; fi
}
if old_rule "" acme.github.io; then bad "control: the old rule unexpectedly accepted acme.github.io"
else ok "control: the old rule rejects acme.github.io"; fi

if [[ "$fail" -ne 0 ]]; then echo "FAIL: repo slug check" >&2; exit 1; fi
echo "PASS: repo slug check (14 cases, 1 control)"
