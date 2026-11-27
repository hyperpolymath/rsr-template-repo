#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# lock-census.sh — reproduce the two estate lock counts, read-only.
#   1. distinct contents (sha256) of every scripts/check-lock-sync.sh
#   2. locks that `gh actions-lock --verify-local` rejects (offline; no token)
# Usage: lock-census.sh DIR [DIR...]   (each DIR = one repo checkout, or a
#        parent whose immediate children are repo checkouts)
# Env:   GH_ACTIONS_LOCK_BIN  path to the pinned binary (default: gh actions-lock)
# Output: TSV on stdout (repo, script_sha256, lock_state), totals on stderr.
# This script never writes to any checkout. Offline verify-local is a
# necessary, not a sufficient, test: it cannot see unreachable or moved pins
# (that is `--verify`, which needs the network and a token).
set -euo pipefail
lock=${GH_ACTIONS_LOCK_BIN:-}
# A relative path override must still resolve after the cd below; bare names use PATH.
case "$lock" in /*|"") ;; */*) lock="$(cd "$(dirname "$lock")" && pwd)/$(basename "$lock")" ;; esac
run_lock() { if [ -n "$lock" ]; then "$lock" "$@"; else gh actions-lock "$@"; fi; }
# Fail loudly if the verifier cannot run at all: that is not "inconsistent".
run_lock --version >/dev/null 2>&1 || { echo "lock-census: verifier unavailable (GH_ACTIONS_LOCK_BIN or gh actions-lock); no census produced" >&2; exit 2; }
repos=()
for d in "$@"; do
  if [ -d "$d/.github/workflows" ] || [ -d "$d/scripts" ]; then repos+=("$d")
  else for c in "$d"/*/; do [ -d "$c/.github" ] && repos+=("${c%/}"); done; fi
done
printf 'repo\tcheck_lock_sync_sha256\tlock_state\n'
declare -A seen; nlock=0; nbad=0; nmiss=0
for r in "${repos[@]}"; do
  h=none; [ -f "$r/scripts/check-lock-sync.sh" ] && { h=$(sha256sum "$r/scripts/check-lock-sync.sh" | cut -c1-12); seen[$h]=1; }
  if [ ! -f "$r/.github/workflows/actions.lock" ]; then st=no-lock; nmiss=$((nmiss+1))
  else nlock=$((nlock+1))
    rc=0; (cd "$r" && GH_ACTIONS_LOCK_REPO_ROOT="$PWD" run_lock --verify-local >/dev/null 2>&1) || rc=$?
    case "$rc" in
      0) st=consistent ;;
      126|127) echo "lock-census: verifier could not be executed on $r (rc=$rc)" >&2; exit 2 ;;
      *) st=inconsistent; nbad=$((nbad+1)) ;;
    esac
  fi
  printf '%s\t%s\t%s\n' "$(basename "$r")" "$h" "$st"
done
n=0; for k in "${!seen[@]}"; do n=$((n+1)); done
echo "repos=${#repos[@]} locks=$nlock inconsistent=$nbad no-lock=$nmiss distinct_check_lock_sync_variants=$n" >&2
