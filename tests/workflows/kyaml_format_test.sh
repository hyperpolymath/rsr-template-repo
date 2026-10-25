#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Formatting must preserve symlinks and their targets.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SCRIPT="$REPO_DIR/scripts/kyaml-format.sh"

printf 'name: sample\n' > "$WORK/target.kyaml"
cp "$WORK/target.kyaml" "$WORK/original"
ln -s target.kyaml "$WORK/link.kyaml"
rc=0
bash "$SCRIPT" "$WORK/link.kyaml" > "$WORK/out" 2>&1 || rc=$?
[ "$rc" -eq 2 ] && grep -q 'symlink' "$WORK/out"
[ -L "$WORK/link.kyaml" ] && [ "$(readlink "$WORK/link.kyaml")" = target.kyaml ]
cmp -s "$WORK/target.kyaml" "$WORK/original"

# Check mode may inspect the target but must not change it.
rc=0
bash "$SCRIPT" --check "$WORK/link.kyaml" > "$WORK/out" 2>&1 || rc=$?
[ "$rc" -eq 1 ] && [ -L "$WORK/link.kyaml" ]
cmp -s "$WORK/target.kyaml" "$WORK/original"

bash "$SCRIPT" "$WORK/target.kyaml"
bash "$SCRIPT" --check "$WORK/target.kyaml"
cp "$WORK/target.kyaml" "$WORK/formatted"
rc=0
bash "$SCRIPT" "$WORK/link.kyaml" > "$WORK/out" 2>&1 || rc=$?
[ "$rc" -eq 2 ] && [ -L "$WORK/link.kyaml" ]
cmp -s "$WORK/target.kyaml" "$WORK/formatted"

ln -s missing.kyaml "$WORK/dangling.kyaml"
rc=0
bash "$SCRIPT" "$WORK/dangling.kyaml" > "$WORK/out" 2>&1 || rc=$?
[ "$rc" -eq 2 ] && [ -L "$WORK/dangling.kyaml" ]
echo 'PASS: formatter refuses symlinks, preserves targets, and formats regular files'
