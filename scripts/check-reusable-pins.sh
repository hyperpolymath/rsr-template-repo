#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
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
set -euo pipefail
dir=${1:-.github/workflows}
resolve() { # owner/repo sha
  if [ -n "${REUSABLE_RESOLVER:-}" ]; then $REUSABLE_RESOLVER "$1" "$2"
  else gh api "repos/$1/commits/$2" --jq .sha 2>/dev/null | grep -qx "$2"; fi
}
bad=0; n=0
shopt -s nullglob
for f in "$dir"/*.yml "$dir"/*.yaml; do
  # Fail closed: a `uses` key in flow-mapping ({uses: ...}) or quoted-key ("uses":)
  # form cannot be read by the line scan below, so it must not pass as "0 checked".
  if grep -Eq "^[[:space:]]*[\"']uses[\"'][[:space:]]*:|[{,][[:space:]]*[\"']?uses[\"']?[[:space:]]*:" "$f"; then
    echo "FAIL $f: a uses key is in flow-mapping or quoted-key form, which this check cannot verify; rewrite it in block style"
    bad=$((bad+1)); continue
  fi
  # job-level calls only: a `uses:` key NOT introduced by a list dash (step-level)
  while IFS= read -r line; do
    ref=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*uses:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^["'\'']//; s/["'\'']$//')
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
  done < <(grep -E '^[[:space:]]+uses:[[:space:]]' "$f" | grep -vE '^[[:space:]]*-[[:space:]]*uses:' || true)
done
echo "reusable-workflow calls checked: $n, failed: $bad"
[ "$bad" -eq 0 ]
