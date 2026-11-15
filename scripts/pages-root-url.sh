#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# pages-root-url.sh OWNER REPO
#
# Print the sed expression `just repo-init` must apply BEFORE its generic OWNER
# and REPO substitutions, or print nothing when none is needed.
#
# A repository named <owner>.github.io is a user/organisation GitHub Pages site:
# it is served at https://<owner>.github.io/ with NO /<repo> segment, whereas a
# project site lives at https://<owner>.github.io/<repo>/. The README's K9 badge
# URL has both tokens, so for the user-site name form the /<repo> part is dropped.
# The comparison is case-insensitive (GitHub host names are). The expression only
# matches that exact URL shape, so every other repository, including a
# <something-else>.github.io repo under a different owner, keeps /<repo>.
#
# One definition, used by the mint and by tests/workflows/user_pages_badge_url_test.sh.
set -euo pipefail

owner="${1:?usage: pages-root-url.sh OWNER REPO}"
repo="${2:?usage: pages-root-url.sh OWNER REPO}"

if [ "${repo,,}" = "${owner,,}.github.io" ]; then
    lb=$(printf '\x7b\x7b'); rb=$(printf '\x7d\x7d')
    printf 's|https://%sOWNER%s\\.github\\.io/%sREPO%s/|https://%sOWNER%s.github.io/|g\n' \
        "$lb" "$rb" "$lb" "$rb" "$lb" "$rb"
fi
