#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check_hygiene_test.sh — scripts/check-hygiene.sh must pass a clean tree and
# FAIL on each defect it claims to catch. A gate whose only exercised path is
# the passing one is the fake-gate class; each case below plants one defect in
# a throwaway git repo and requires exit 1 naming the right check.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/check-hygiene.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

fresh() {
  rm -rf "${T:?}/r"; mkdir -p "$T/r"
  git -C "$T/r" init -q
  printf 'a: 1\n' > "$T/r/ok.yml"
  printf 'a = 1\n' > "$T/r/ok.toml"
  printf 'text\n' > "$T/r/ok.txt"
  git -C "$T/r" add -A
}
# expect_fail NAME CHECK — gate must exit 1 and mention CHECK
expect_fail() {
  local out rc=0
  out="$(bash "$GATE" "$T/r" 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] || fail "$1: expected exit 1, got $rc ($out)"
  printf '%s\n' "$out" | grep -q "($2)" || fail "$1: output does not name $2 ($out)"
  echo "ok: $1 refused"
}

fresh; bash "$GATE" "$T/r" >/dev/null || fail "clean tree refused"; echo "ok: clean tree passes"

fresh; printf 'a: [1\n' > "$T/r/bad.yml"; git -C "$T/r" add -A
expect_fail "broken YAML" check-yaml

fresh; printf 'a = \n' > "$T/r/bad.toml"; git -C "$T/r" add -A
expect_fail "broken TOML" check-toml

# The exclusion is by exact path: a placeholder TOML elsewhere is still refused,
# and the named template path is not.
fresh; mkdir -p "$T/r/build/container/stapeln"
printf 'x = {{TOKEN}}\n' > "$T/r/build/container/stapeln/manifest.toml"; git -C "$T/r" add -A
bash "$GATE" "$T/r" >/dev/null || fail "stapeln template exclusion lost"
echo "ok: stapeln template excluded"
printf 'x = {{TOKEN}}\n' > "$T/r/other.toml"; git -C "$T/r" add -A
expect_fail "placeholder TOML outside the exclusion" check-toml

fresh; printf 'x\n<<<<<<< HEAD\ny\n=======\nz\n>>>>>>> branch\n' > "$T/r/c.txt"; git -C "$T/r" add -A
expect_fail "merge-conflict marker" check-merge-conflict

fresh; printf 'Title\n=======\n' > "$T/r/rule.adoc"; git -C "$T/r" add -A
bash "$GATE" "$T/r" >/dev/null || fail "a bare ======= rule was refused"
echo "ok: bare ======= rule allowed"

fresh; head -c 2200000 /dev/zero > "$T/r/big.bin"; git -C "$T/r" add -A
expect_fail "file over the size limit" check-added-large-files

fresh; mkdir "$T/fakebin"; printf '#!/bin/sh\necho yq 0.0.0\n' > "$T/fakebin/yq"; chmod +x "$T/fakebin/yq"
rc=0; PATH="$T/fakebin:$PATH" bash "$GATE" "$T/r" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "a non-mikefarah yq must fail closed with exit 2, got $rc"
echo "ok: wrong yq fails closed"
echo "check-hygiene gate: all controls behave"
