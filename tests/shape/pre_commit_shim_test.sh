#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# pre_commit_shim_test.sh — the root .pre-commit-config.yaml must stay a
# SYMLINK to ci/.pre-commit-config.yaml.
#
# pre-commit.ci reads its configuration from the repository ROOT only; with no
# file there it reports "error during ci config: `.pre-commit-config.yaml` is
# not a file" on every pull request. The real file lives in ci/ (root cleanup,
# docs/proposals/root-cleanup.adoc), so the root carries a one-line shim.
#
# The shim is only a shim while it is a link. Replaced by a copy it goes stale
# the first time ci/.pre-commit-config.yaml changes, and two configs can then
# disagree about which hooks run; pointed anywhere else it reads a different
# config from the one the repo documents. Both look healthy to
# check-root-shape.sh, which only asks that the name exist.
#
# check_shim is run on the real tree, then on fixtures that each break it one
# way: a copy, a link to another file, an absolute link, a dangling link, and a
# link whose target is itself a link. Each must be refused, so a pass is not
# the instrument agreeing with everything.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHIM=.pre-commit-config.yaml
TARGET=ci/.pre-commit-config.yaml

fail() { echo "FAIL: $1" >&2; exit 1; }

# check_shim DIR — print why DIR's shim is wrong and return 1, or return 0.
check_shim() {
    local d="$1" got
    [ -L "$d/$SHIM" ] || { echo "$SHIM is not a symlink (a copy goes stale)"; return 1; }
    got="$(readlink "$d/$SHIM")"
    [ "$got" = "$TARGET" ] || { echo "$SHIM points at '$got', not '$TARGET'"; return 1; }
    if [ ! -f "$d/$TARGET" ] || [ -L "$d/$TARGET" ]; then
        echo "$TARGET is not a regular file; the link would dangle or chain"; return 1
    fi
    return 0
}

# 1. The real tree.
out="$(check_shim "$ROOT")" || fail "$out"

# 2. In a git checkout the INDEX is the truth: a platform without symlink
#    support checks a link out as a text file, and committing that back would
#    turn it into a copy. Mode 120000 is a symlink.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    mode="$(git -C "$ROOT" ls-files -s -- "$SHIM" | cut -d' ' -f1)"
    [ -n "$mode" ] || fail "$SHIM is not tracked"
    [ "$mode" = 120000 ] || fail "$SHIM is tracked with mode $mode, not 120000 (a symlink)"
fi

# 3. Fixtures. Each starts from a conforming tree and breaks it one way.
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
fresh() {
    rm -rf "${FIX:?}/t"; mkdir -p "$FIX/t/ci"
    printf 'repos: []\n' > "$FIX/t/$TARGET"
    ln -s "$TARGET" "$FIX/t/$SHIM"
}

fresh
out="$(check_shim "$FIX/t")" || fail "control: a conforming fixture was refused: $out"

fresh; rm "$FIX/t/$SHIM"; cp "$FIX/t/$TARGET" "$FIX/t/$SHIM"
if out="$(check_shim "$FIX/t")"; then fail "a COPY of the config was accepted as the shim"; fi
grep -q 'not a symlink' <<<"$out" || fail "the copy was refused for the wrong reason: $out"

fresh; printf 'repos: []\n' > "$FIX/t/ci/other.yaml"
rm "$FIX/t/$SHIM"; ln -s ci/other.yaml "$FIX/t/$SHIM"
if out="$(check_shim "$FIX/t")"; then fail "a link to another file was accepted"; fi
grep -q 'not .ci/.pre-commit-config.yaml' <<<"$out" || fail "the wrong target was refused for the wrong reason: $out"

fresh; rm "$FIX/t/$SHIM"; ln -s "$FIX/t/$TARGET" "$FIX/t/$SHIM"
if out="$(check_shim "$FIX/t")"; then fail "an absolute link was accepted (it breaks in every other checkout)"; fi

fresh; rm "$FIX/t/$TARGET"
if out="$(check_shim "$FIX/t")"; then fail "a dangling link was accepted"; fi

fresh; rm "$FIX/t/$TARGET"; ln -s ../elsewhere.yaml "$FIX/t/$TARGET"
if out="$(check_shim "$FIX/t")"; then fail "a link to a link was accepted"; fi

echo "PASS: $SHIM is a relative symlink to $TARGET, tracked as mode 120000; 5 broken shapes refused"
