#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-repo-slug.sh ARCHETYPE OWNER REPO
#
# The repository-slug rule `just repo-init` applies. Exit 0 when REPO is an
# acceptable slug, otherwise print the reason to stderr and exit 1.
#
# Accepted:
#   - the estate slug: lowercase alphanumeric words separated by single hyphens;
#   - for the julia-library archetype, <Name>.jl with <Name> in UpperCamelCase;
#   - <owner>.github.io, the user/organisation GitHub Pages site name, compared
#     case-insensitively with OWNER (as scripts/pages-root-url.sh does). Another
#     owner's .github.io name is not that owner's site, so it stays rejected.
#
# It needs OWNER, so the recipe calls it after the owner prompt. One definition,
# used by the mint and by tests/workflows/repo_slug_check_test.sh.
set -euo pipefail

arch="${1-}"
owner="${2:?usage: check-repo-slug.sh ARCHETYPE OWNER REPO}"
repo="${3:?usage: check-repo-slug.sh ARCHETYPE OWNER REPO}"

if [[ "$arch" = "julia-library" && "$repo" =~ ^[A-Z][A-Za-z0-9]*\.jl$ ]]; then
    exit 0
elif [[ "${repo,,}" = "${owner,,}.github.io" ]]; then
    exit 0
elif [[ ! "$repo" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "Error: repo slug must be lowercase alphanumeric words separated by single hyphens" >&2
    [ "$arch" = "julia-library" ] && echo "       (or, for a Julia package, <Name>.jl with <Name> in UpperCamelCase)" >&2
    echo "       (or <owner>.github.io, the owner's own GitHub Pages site)" >&2
    exit 1
fi
