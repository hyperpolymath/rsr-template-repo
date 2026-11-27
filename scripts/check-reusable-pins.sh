#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-reusable-pins.sh — every cross-repo reusable-workflow call
# (`jobs.<id>.uses: owner/repo/.github/workflows/x.yml@REF`) must be pinned to a
# FULL 40-hex commit SHA, and that SHA must resolve in owner/repo.
#
# Why: actions.lock (gh actions-lock) does not pin these calls, so a moved tag
# would run unreviewed code while every other check stays green.
#
# Usage: check-reusable-pins.sh [WORKFLOW_DIR]   (default .github/workflows)
# Env:   REUSABLE_RESOLVER  command taking "owner/repo sha"; exit 0 if the commit
#                           exists. Default: `gh api repos/<owner>/<repo>/commits/<sha>`
#                           (REST; needs GH_TOKEN for private repos).
#        REUSABLE_RESOLVE=0 skip resolution (offline pre-commit use ONLY; the CI
#                           gate must not set it).
# Exit 0 only if all calls pass. Same-repo `./` calls are exempt (same commit).
# Needs yq (mikefarah, Go): the transitional YAML reader per the estate format directives.
set -euo pipefail
dir=${1:-.github/workflows}
resolve() { # owner/repo sha
  if [ -n "${REUSABLE_RESOLVER:-}" ]; then $REUSABLE_RESOLVER "$1" "$2"
  else gh api "repos/$1/commits/$2" --jq .sha 2>/dev/null | grep -qx "$2"; fi
}
bad=0; n=0
shopt -s nullglob
for f in "$dir"/*.yml "$dir"/*.yaml; do
  # Read job-level `uses` from the parsed document (yq), so block, flow-mapping
  # and quoted-key spellings are all seen. A file yq cannot parse fails closed.
  if ! refs=$(yq -r '(.jobs // {}) | to_entries | .[] | .value.uses // ""' "$f" 2>/dev/null); then
    echo "FAIL $f: not parseable as YAML, so its reusable calls cannot be verified"
    bad=$((bad+1)); continue
  fi
  while IFS= read -r ref; do
    case "$ref" in ./*|"") continue ;; esac
    case "$ref" in */.github/workflows/*@*) ;; *) continue ;; esac
    n=$((n+1)); path=${ref%@*}; sha=${ref##*@}
    or=$(printf '%s' "$path" | cut -d/ -f1-2)
    if ! printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$'; then
      echo "FAIL $f: '$ref' is not pinned to a full 40-hex SHA (a tag or branch can move)"; bad=$((bad+1)); continue
    fi
    if [ "${REUSABLE_RESOLVE:-1}" != 0 ] && ! resolve "$or" "$sha"; then
      echo "FAIL $f: $or@$sha does not resolve"; bad=$((bad+1)); continue
    fi
    echo "ok   $f: $path@${sha:0:12}"
  done <<< "$refs"
done
echo "reusable-workflow calls checked: $n, failed: $bad"
[ "$bad" -eq 0 ]
