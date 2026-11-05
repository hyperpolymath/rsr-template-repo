#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# chain-mint.sh reads every checkout into a tree through git (tree_of), never
# by copying files: git keeps a submodule as its gitlink, does not recurse into
# a path that became a directory, and reads nothing an ignore rule matches
# (Codex review of #277). This sources tree_of from the script itself and
# checks those three properties in a second, without a mint.
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
g0() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c protocol.file.allow=always "$@"; }

# The functions under test, exactly as the script defines them.
sed -n '/^g() {/,/^}/p; /^link_objects() {/,/^}/p; /^tree_of() {/,/^}/p' "$repo/scripts/chain-mint.sh" > "$work/fns.sh"
grep -q '^tree_of() {' "$work/fns.sh" || fail 'tree_of not found in scripts/chain-mint.sh'
# shellcheck disable=SC1091
. "$work/fns.sh"

g0 init -q "$work/sub"; echo s > "$work/sub/f"; g0 -C "$work/sub" add -A; g0 -C "$work/sub" commit -q -m s
D="$work/d"
g0 init -q "$D"
printf 'plain\n' > "$D/becomes-dir"; printf 'a\n' > "$D/a"
g0 -C "$D" add -A; g0 -C "$D" commit -q -m a
g0 -C "$D" submodule -q add "$work/sub" vendor/sub; g0 -C "$D" commit -q -m sub
SUB_COMMIT=$(g0 -C "$work/sub" rev-parse HEAD)
# A tracked file turned into a directory holding an ignored file, and an
# untracked file no rule ignores.
rm "$D/becomes-dir"; mkdir "$D/becomes-dir"; printf 'secret\n' > "$D/becomes-dir/key"
printf '/becomes-dir/key\n' >> "$D/.git/info/exclude"
printf 'new\n' > "$D/untracked.txt"

WORK="$work/w"; mkdir -p "$WORK"
M="$work/m"; g init -q "$M"; mkdir -p "$M/.git/objects/info"
T=$(tree_of "$D" d)
g -C "$M" ls-tree -r "$T" > "$work/tree"

grep -qP "^160000 commit ${SUB_COMMIT}\tvendor/sub$" "$work/tree" \
    || { cat "$work/tree" >&2; fail 'the submodule did not stay a gitlink at its commit'; }
if grep -q 'vendor/sub/' "$work/tree"; then fail 'the submodule worktree was vendored as files'; fi
if grep -q 'becomes-dir' "$work/tree"; then cat "$work/tree" >&2; fail 'the ignored file in a path that became a directory was read'; fi
grep -qP '\tuntracked.txt$' "$work/tree" && grep -qP '\ta$' "$work/tree" \
    || { cat "$work/tree" >&2; fail 'the work tree was not read as git add -A would commit it'; }
# The checkout's own .git was not written: its index still lists becomes-dir.
g0 -C "$D" ls-files --error-unmatch becomes-dir >/dev/null 2>&1 || fail 'tree_of wrote to the checkout index'
echo 'PASS: tree_of keeps gitlinks, reads no ignored file, and leaves the checkout alone'
