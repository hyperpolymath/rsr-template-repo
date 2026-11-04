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
# Usage: format-container-kyaml.sh [REPO_ROOT]
# Exit: 0 = every config present is canonical KYAML (none present is fine:
#       an archetype may prune build/container/); non-zero = it could not
#       format them, with the command to run named on stderr.
set -euo pipefail
cd "${1:-.}"

files=()
for f in build/container/compose.yaml build/container/compose.example.yaml \
         build/container/stapeln/.gatekeeper.yaml; do
    if [ -f "$f" ]; then files+=("$f"); fi
done
[ "${#files[@]}" -gt 0 ] || exit 0

if ! bash scripts/kyaml-format.sh "${files[@]}"; then
    echo "error: container KYAML is not canonical after filling the tokens." >&2
    echo "  Install yq v4.53.3+ (mikefarah) and run: bash scripts/kyaml-format.sh ${files[*]}" >&2
    exit 1
fi
