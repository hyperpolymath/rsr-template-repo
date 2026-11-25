#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# lock-negative-test.sh — a hand-edited actions.lock MUST fail the gate.
# Builds a throwaway repo, checks the clean lock passes, then applies each
# hand-edit and requires `gh actions-lock --verify-local` to exit non-zero.
# Offline by design. What it cannot show: a lock AND workflow hand-edited to
# the same fabricated SHA; only `--verify` (network) catches that, in CI.
# Env: GH_ACTIONS_LOCK_BIN (default: gh actions-lock)
set -euo pipefail
lock=${GH_ACTIONS_LOCK_BIN:-}
run() { if [ -n "$lock" ]; then "$lock" "$@"; else gh actions-lock "$@"; fi; }
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT; cd "$t"; git init -q
mkdir -p .github/workflows
sha=3d3c42e5aac5ba805825da76410c181273ba90b1
cat > .github/workflows/a.yml <<YML
name: a
on: push
jobs:
  j:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@$sha
YML
good() { printf "version: 'v0.0.3'\nworkflows:\n    '.github/workflows/a.yml':\n        - 'actions/checkout@%s'\ndependencies:\n" "$1" > .github/workflows/actions.lock; }
fail=0
good $sha
if run --verify-local >/dev/null 2>&1; then echo "ok   clean lock passes"; else echo "FAIL clean lock rejected"; fail=1; fi
good deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
if run --verify-local >/dev/null 2>&1; then echo "FAIL fabricated sha accepted"; fail=1; else echo "ok   fabricated sha rejected"; fi
printf "version: 'v0.0.3'\nworkflows:\ndependencies:\n" > .github/workflows/actions.lock
if run --verify-local >/dev/null 2>&1; then echo "FAIL deleted entry accepted"; fail=1; else echo "ok   deleted entry rejected"; fi
exit $fail
