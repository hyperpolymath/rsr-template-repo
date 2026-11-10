#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# scripts/canon-pin-check.sh: the decision behind dogfood-gate.yml `Canon
# lockstep`, including two-phase adoption (:proposed-by). Offline: fixtures
# only, no network.
# Usage: bash tests/workflows/canon_pin_check_test.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
check="$root/scripts/canon-pin-check.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

# lock <file> <version> <criteria> <gates>: a canon.lock in the real layout.
lock() {
  cat > "$1" <<EOF
# criteria = { sha256 = "$C" }   <- a comment must not be read
[canon]
# version = "9.9.9"   <- a commented-out value must not be read
version      = "$2"
status       = "draft"          # draft | stable

[canon.artifacts]
criteria = { path = "0-canon/rsr/rsr-criteria-v2.a2ml",
             # previously sha256 = "$C" (a comment inside the entry)
             sha256 = "$3",
             slot = "criteria", normative = true }

gates = { path = ".machine_readable/template-capability-gates.toml",
          sha256 = "$4",
          slot = "gates", normative = true }
EOF
}

# deed <file> <version> <criteria> <gates> [extra fields…]
deed() {
  local f="$1" v="$2" c="$3" g="$4"; shift 4
  {
    echo '(repo-deed'
    echo '  :schema-version "1.0.0"'
    echo '  ; (canon :version "9.9.9") <- a comment, not a second clause'
    echo "  (canon"
    echo "    :version \"$v\""
    echo "    :criteria-sha256 \"$c\""
    echo "    :gates-sha256 \"$g\""
    for x in "$@"; do echo "    $x"; done
    echo '    :order "spine-adopts-then-canon-releases"))'
  } > "$f"
}

pass=0
expect() { # expect <want-rc> <name> <cmd…>
  local want="$1" name="$2"; shift 2
  local rc=0
  "$@" > "$tmp/out" 2> "$tmp/err" || rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL: $name (rc $rc, want $want)"; cat "$tmp/out" "$tmp/err"; exit 1
  fi
  pass=$((pass + 1)); echo "PASS: $name"
}

lock "$tmp/released.lock" 2.1.5 "$A" "$B"
lock "$tmp/next.lock"     2.1.6 "$A" "$C"

deed "$tmp/same.deed" 2.1.5 "$A" "$B"
expect 0 "released: a pin equal to canon.lock passes" bash "$check" released "$tmp/same.deed" "$tmp/released.lock"

deed "$tmp/behind.deed" 2.1.4 "$A" "$C"
expect 1 "released: a different pin naming no canon PR fails" bash "$check" released "$tmp/behind.deed" "$tmp/released.lock"

deed "$tmp/ahead.deed" 2.1.6 "$A" "$C" ':proposed-by "metadatastician/standards#1440"'
expect 3 "released: a different pin naming a canon PR defers to that PR" bash "$check" released "$tmp/ahead.deed" "$tmp/released.lock"
grep -qx 'PROPOSED_BY=metadatastician/standards#1440' "$tmp/out" || { echo "FAIL: PROPOSED_BY line missing"; exit 1; }

expect 0 "pending: open canon PR with the same canon.lock passes" bash "$check" pending "$tmp/ahead.deed" "$tmp/next.lock" open
expect 1 "pending: a closed canon PR fails (the pin was never released)" bash "$check" pending "$tmp/ahead.deed" "$tmp/next.lock" closed
expect 1 "pending: an amended canon PR fails (its canon.lock moved)" bash "$check" pending "$tmp/ahead.deed" "$tmp/released.lock" open

deed "$tmp/spent.deed" 2.1.5 "$A" "$B" ':proposed-by "hyperpolymath/standards#1424"'
expect 0 "released: a spent :proposed-by still passes" bash "$check" released "$tmp/spent.deed" "$tmp/released.lock"
grep -q 'is spent' "$tmp/out" || { echo "FAIL: spent notice missing"; exit 1; }

deed "$tmp/badref.deed" 2.1.6 "$A" "$C" ':proposed-by "someone/else#12"'
expect 2 "a :proposed-by outside the canon repo is malformed" bash "$check" released "$tmp/badref.deed" "$tmp/released.lock"

deed "$tmp/badhash.deed" 2.1.5 "$A" "not-a-hash"
expect 2 "a pin of the wrong shape is malformed, never equal" bash "$check" released "$tmp/badhash.deed" "$tmp/released.lock"

{ cat "$tmp/same.deed"; echo '(canon :version "2.1.5")'; } > "$tmp/two.deed"
expect 2 "two (canon …) clauses are malformed" bash "$check" released "$tmp/two.deed" "$tmp/released.lock"

expect 2 "pending mode without :proposed-by is malformed" bash "$check" pending "$tmp/same.deed" "$tmp/next.lock" open

# The real deed against a lock built from its own pins: the reader agrees
# with the deed this repository ships.
real="$root/rsr-template-repo_chora.deed"
v="$(bash "$root/scripts/deed-field.sh" "$real" canon version)"
c="$(bash "$root/scripts/deed-field.sh" "$real" canon criteria-sha256)"
g="$(bash "$root/scripts/deed-field.sh" "$real" canon gates-sha256)"
lock "$tmp/own.lock" "$v" "$c" "$g"
expect 0 "the shipped deed passes against its own pins" bash "$check" released "$real" "$tmp/own.lock"

echo "canon_pin_check: $pass passed"
