#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# migrate-wellknown-to-www.sh — conflict-safe migration of a repository-root
# .well-known/ tree into www/.well-known/ (rsr-template-repo#53, stage 1).
#
# Semantics, per the issue's migration requirements:
#   * identical content in both locations  -> root copy removed, www kept;
#   * content only at the root             -> moved into www/.well-known/;
#   * content only under www/              -> no-op;
#   * DIVERGENT content in both            -> conflict reported, BOTH copies
#     preserved, exit status 1. Never overwrite on path name alone.
#
# Run from the repository root. Uses `git mv`/`git rm` when the tree is a git
# checkout and the files are tracked, plain mv/rm otherwise, so it is safe on
# minted-but-uncommitted trees too. Propagation runners should combine this
# with a `git status --porcelain` / unpushed-commit check of their own; this
# script compares CONTENT, and content comparison is what "divergent" means
# here.

set -euo pipefail

ROOT=".well-known"
DEST="www/.well-known"

if [ ! -d "$ROOT" ]; then
    echo "migrate-wellknown: no $ROOT/ at repository root — nothing to migrate."
    exit 0
fi

mkdir -p "$DEST"

git_tracked() { git ls-files --error-unmatch "$1" >/dev/null 2>&1; }

moved=0; deduped=0; conflicts=0; kept=0

while IFS= read -r -d '' src; do
    rel="${src#"$ROOT"/}"
    dst="$DEST/$rel"
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ]; then
        if cmp -s "$src" "$dst"; then
            # Identical: the duplicate root copy goes; www is canonical.
            if git_tracked "$src"; then git rm -q "$src"; else rm "$src"; fi
            deduped=$((deduped + 1))
            echo "  identical, root copy removed: $rel"
        else
            # Divergent: preserve BOTH, report, non-zero exit at the end.
            conflicts=$((conflicts + 1))
            echo "  CONFLICT (both preserved): $rel differs between $ROOT/ and $DEST/" >&2
            echo "    root sha256: $(sha256sum "$src" | cut -d' ' -f1)" >&2
            echo "    www  sha256: $(sha256sum "$dst" | cut -d' ' -f1)" >&2
        fi
    else
        if git_tracked "$src"; then git mv "$src" "$dst"; else mv "$src" "$dst"; fi
        moved=$((moved + 1))
        echo "  moved: $rel -> $DEST/$rel"
    fi
done < <(find "$ROOT" -type f -print0 | sort -z)

# Drop the root directory only when it is fully empty of files.
if [ -z "$(find "$ROOT" -type f -print -quit 2>/dev/null)" ]; then
    find "$ROOT" -depth -type d -empty -delete 2>/dev/null || true
    kept=0
else
    kept=$(find "$ROOT" -type f | wc -l)
fi

echo "migrate-wellknown: moved=$moved deduped=$deduped conflicts=$conflicts left_in_root=$kept"
if [ "$conflicts" -gt 0 ]; then
    echo "migrate-wellknown: DIVERGENT CONTENT — both locations preserved; resolve by hand." >&2
    exit 1
fi
if [ "$kept" -gt 0 ]; then
    echo "migrate-wellknown: WARNING — $kept file(s) remain under $ROOT/ (unexpected)." >&2
    exit 1
fi
