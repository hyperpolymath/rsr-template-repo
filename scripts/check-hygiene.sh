#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-hygiene.sh — the file-hygiene checks that used to live only as
# pre-commit hooks (ci/.pre-commit-config.yaml, retired with pre-commit.ci).
# Run by `just hygiene` and by the "lint" job of .github/workflows/quality.yml.
#
#   check-yaml            every tracked .yml/.yaml parses (yq)
#   check-toml            every tracked .toml parses (yq -p toml); the three
#                         build/container/stapeln templates are excluded: they
#                         hold {{TOKEN}} mint placeholders and are valid TOML
#                         only after repo-init substitutes them
#   check-merge-conflict  no tracked file has a conflict marker at line start
#   check-added-large-files  no tracked file over MAX_KB (default 1024)
#
# Covered elsewhere (see ci/README.adoc for the full hook-to-check map):
# check-json -> check-ijson-jcs.sh; detect-private-key -> gitleaks;
# trailing-whitespace / end-of-file-fixer -> editorconfig-checker.
#
# Fails closed: a missing yq is a failure, never a skip.
#
# Usage: check-hygiene.sh [REPO_ROOT]
# Exit: 0 clean; 1 findings; 2 bad path or missing tool.
set -euo pipefail

ROOT="${1:-.}"
MAX_KB="${MAX_KB:-1024}"
[ -d "$ROOT" ] || { echo "ERROR: repository path does not exist: $ROOT" >&2; exit 2; }
command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -q mikefarah \
  || { echo "ERROR: yq (mikefarah, v4+) is required; refusing to skip (found: $(command -v yq || echo none))" >&2; exit 2; }
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "ERROR: $ROOT is not a git work tree" >&2; exit 2; }

cd "$ROOT"
rc=0
bad() { echo "FAIL ($1): $2" >&2; rc=1; }

# Tracked files that still exist in the work tree, NUL-delimited.
tracked() {
  git ls-files -z -- "$@" | while IFS= read -r -d '' f; do
    [ -f "$f" ] && [ ! -L "$f" ] && printf '%s\0' "$f"
  done
}

while IFS= read -r -d '' f; do
  yq -e '.' "$f" >/dev/null 2>&1 || bad check-yaml "$f does not parse as YAML"
done < <(tracked '*.yml' '*.yaml')

while IFS= read -r -d '' f; do
  case "$f" in
    build/container/stapeln/manifest.toml|build/container/stapeln/compose.toml|build/container/stapeln/compose.example.toml) continue ;;
  esac
  yq -p toml -o json '.' "$f" >/dev/null 2>&1 || bad check-toml "$f does not parse as TOML"
done < <(tracked '*.toml')

# A conflict has both a <<<<<<< and a >>>>>>> line, so two anchors are enough
# and a bare ======= rule (valid in AsciiDoc and Markdown) is not a finding.
while IFS= read -r -d '' f; do
  if grep -IqE '^(<<<<<<<|>>>>>>>)( |$)' "$f"; then
    bad check-merge-conflict "$f has a merge-conflict marker"
  fi
done < <(tracked)

while IFS= read -r -d '' f; do
  kb=$(( ( $(wc -c < "$f") + 1023 ) / 1024 ))
  [ "$kb" -le "$MAX_KB" ] || bad check-added-large-files "$f is ${kb} KB (limit ${MAX_KB} KB)"
done < <(tracked)

if [ "$rc" -eq 0 ]; then echo "hygiene: yaml, toml, merge markers, large files — clean"; fi
exit "$rc"
