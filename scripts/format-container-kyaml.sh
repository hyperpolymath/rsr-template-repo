#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# format-container-kyaml.sh — reformat the container KYAML configs after
# their tokens are filled.
#
# The template quotes every token, keys included, because a brace token is
# not a plain YAML scalar. Once `repo-init` or `container-init` fills one,
# the quoting is no longer what canonical KYAML writes (a filled service-name
# key needs none), and Estate Rules' "Converted YAML stays KYAML" fails the
# child. Both recipes call this after their substitution pass.
#
# The formatter needs a yq that writes KYAML (mikefarah yq; mise.toml provides
# it). Both recipes run `--preflight` BEFORE they write anything, so a missing
# yq stops them with the tree untouched instead of half-minted.
#
# Usage: format-container-kyaml.sh [--preflight] [REPO_ROOT]
#   --preflight  write nothing; fail when configs are present and no
#                KYAML-capable yq is on PATH.
# Exit: 0 = formatted (or nothing to format: an archetype may prune
#       build/container/); 1 = no KYAML-capable yq, or the formatter refused
#       a file (unparseable, data change), with the reason on stderr.
set -euo pipefail
PREFLIGHT=0
if [ "${1:-}" = --preflight ]; then PREFLIGHT=1; shift; fi
cd "${1:-.}"

files=()
for f in build/container/compose.yaml build/container/compose.example.yaml \
         build/container/stapeln/.gatekeeper.yaml; do
    if [ -f "$f" ]; then files+=("$f"); fi
done
[ "${#files[@]}" -gt 0 ] || exit 0

if ! command -v yq >/dev/null 2>&1 || ! printf 'a: 1\n' | yq -p yaml -o kyaml '.' >/dev/null 2>&1; then
    {
        echo "error: the container configs need a yq that writes KYAML (mikefarah yq"
        echo "  v4.53.3+) once their tokens are filled, and none is on PATH."
        echo "  Run 'mise install' (mise.toml provides yq), or install mikefarah yq."
    } >&2
    exit 1
fi
[ "$PREFLIGHT" -eq 0 ] || exit 0

if ! bash scripts/kyaml-format.sh "${files[@]}"; then
    echo "error: the KYAML formatter refused a container config (see above)." >&2
    exit 1
fi
