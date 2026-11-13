#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# is-template-tree.sh [ROOT] - exit 0 iff ROOT (default .) is the template tree
# itself, not a repo minted from it. The one definition the template-only test
# controls share.
#
# A file named rsr-template-repo_chora.deed is NOT enough: some minted repos
# still carry a deed with that name because it was copied and never renamed.
# So the tree is the template only when ALL of these hold:
#   * rsr-template-repo_chora.deed exists at ROOT;
#   * its header :canonical-name is "rsr-template-repo";
#   * archetypes/ exists (the mint removes it, see docs/architecture/REPOSITORY-MAP.adoc).
set -u
root="${1:-.}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deed="$root/rsr-template-repo_chora.deed"
[ -f "$deed" ] || exit 1
[ -d "$root/archetypes" ] || exit 1
name="$(bash "$here/deed-field.sh" "$deed" "" canonical-name 2>/dev/null)" || exit 1
[ "$name" = "rsr-template-repo" ]
