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
# yq is not part of the mint's toolchain, so without a yq that writes KYAML
# this leaves the files as they are and says so: the recipes have already
# written the tree, and aborting there would leave a half-minted checkout.
# The child's KYAML check still fails until the command named here is run.
#
# Usage: format-container-kyaml.sh [REPO_ROOT]
# Exit: 0 = formatted, nothing to format (an archetype may prune
#       build/container/), or no KYAML-capable yq (warned on stderr);
#       non-zero = the formatter refused a file (unparseable, data change).
set -euo pipefail
cd "${1:-.}"

files=()
for f in build/container/compose.yaml build/container/compose.example.yaml \
         build/container/stapeln/.gatekeeper.yaml; do
    if [ -f "$f" ]; then files+=("$f"); fi
done
[ "${#files[@]}" -gt 0 ] || exit 0

if ! command -v yq >/dev/null 2>&1 || ! printf 'a: 1\n' | yq -p yaml -o kyaml '.' >/dev/null 2>&1; then
    {
        echo "WARNING: no yq that writes KYAML (mikefarah yq v4.53.3+) is on PATH, so the"
        echo "  container configs keep the template's key quoting and Estate Rules'"
        echo "  \"Converted YAML stays KYAML\" check will fail until you run:"
        echo "    bash scripts/kyaml-format.sh ${files[*]}"
    } >&2
    exit 0
fi

if ! bash scripts/kyaml-format.sh "${files[@]}"; then
    echo "error: the KYAML formatter refused a container config (see above)." >&2
    exit 1
fi
