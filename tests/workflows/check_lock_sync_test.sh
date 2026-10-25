#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Verify self-SHA refs fail regardless of hexadecimal letter case.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/check.yml" <<'YAML'
jobs:
  check:
    steps:
      - uses: owner/action@v1
YAML
for ref in v1 abcdef0123456789abcdef0123456789abcdef01 ABCDEF0123456789ABCDEF0123456789ABCDEF01 aBcDeF0123456789aBcDeF0123456789aBcDeF01; do
  cat > "$WORK/actions.lock" <<YAML
version: 'v0.0.3'
workflows:
    '.github/workflows/check.yml':
        - 'owner/action@v1'
dependencies:
    'owner/action@v1':
        ref: '$ref'
YAML
  rc=0
  bash "$REPO_DIR/scripts/check-lock-sync.sh" "$WORK" > "$WORK/out" 2>&1 || rc=$?
  if [ "$ref" = v1 ]; then
    [ "$rc" -eq 0 ] || { cat "$WORK/out"; exit 1; }
  else
    [ "${#ref}" -eq 40 ]
    if [ "$rc" -ne 1 ] || ! grep -q 'SELF-SHA REFS' "$WORK/out"; then
      cat "$WORK/out"; exit 1
    fi
  fi
done
echo 'PASS: tag refs accepted; lower, upper, and mixed case self-SHA refs rejected'
