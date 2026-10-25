#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Silence + Firing + Setup-error test suite for the proven-tests-and-benches
# toolchain wired in scripts/:
#   - scripts/check-escape-hatches.sh
#   - scripts/compute-bench-baseline.sh
#   - scripts/check-bench-regression.sh
#   - scripts/emit-aggregate-inputs.sh
#
# Every negative fixture is generated ephemerally in $WORK (mktemp -d) so no
# static escape-hatch token ever resides in a tracked .idr file.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

assert_rc() { # assert_rc <wanted-rc> <label> <cmd...>
  local want="$1" label="$2" got=0
  shift 2
  "$@" >"$WORK/out" 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    pass=$((pass + 1))
    echo "  PASS: $label"
  else
    fail=$((fail + 1))
    echo "  FAIL: $label (wanted exit $want, got $got)"
    sed 's/^/        /' "$WORK/out"
  fi
}

assert_grep() { # assert_grep <pattern> <label>
  if grep -qE -- "$1" "$WORK/out"; then
    pass=$((pass + 1))
    echo "  PASS: $2"
  else
    fail=$((fail + 1))
    echo "  FAIL: $2 (missing pattern: $1)"
    sed 's/^/        /' "$WORK/out"
  fi
}

echo "=== 1. check-escape-hatches.sh: Silence, Firing, Setup (0 / 1 / 2) ==="
mkdir -p "$WORK/clean" "$WORK/empty"
cat > "$WORK/clean/Sound.idr" <<'IDR'
module Sound

%default total

public export
reflNat : (n : Nat) -> n = n
reflNat _ = Refl
IDR

assert_rc 0 "Silence: total Idris2 module passes" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/clean"

assert_rc 2 "Setup (exit 2): missing directory is never a pass" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/no-such-dir"

assert_rc 2 "Setup (exit 2): directory with 0 .idr files is never a pass" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/empty"

# Build banned tokens dynamically so scanners never confuse test generators with source
BM="believe""_me"
AT="assert""_total"

mkdir -p "$WORK/m_bm"
printf 'module Bad\n\n%%default total\n\nbad : a -> b\nbad x = %s x\n' "$BM" > "$WORK/m_bm/Bad.idr"
assert_rc 1 "Firing: believe-me escape hatch exits 1" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_bm"

mkdir -p "$WORK/m_at"
printf 'module Bad\n\n%%default total\n\nbad : Nat -> Nat\nbad n = %s (bad n)\n' "$AT" > "$WORK/m_at/Bad.idr"
assert_rc 1 "Firing: assert-total escape hatch exits 1" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_at"

mkdir -p "$WORK/m_hole"
printf 'module Bad\n\n%%default total\n\nbad : Nat\nbad = ?unproven_hole\n' > "$WORK/m_hole/Bad.idr"
assert_rc 1 "Firing: ?hole syntax exits 1" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_hole"

mkdir -p "$WORK/m_partial"
printf 'module Bad\n\n%%default total\n\npartial\nloop : Nat -> Nat\nloop n = loop n\n' > "$WORK/m_partial/Bad.idr"
assert_rc 1 "Firing: partial declaration exits 1" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_partial"

mkdir -p "$WORK/m_cov"
printf 'module Bad\n\n%%default total\n\ncovering\nunlisted : IO ()\nunlisted = pure ()\n' > "$WORK/m_cov/Bad.idr"
assert_rc 1 "Firing: unallowlisted covering declaration exits 1" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_cov"

mkdir -p "$WORK/m_nototal"
printf 'module Bad\n\nidNat : Nat -> Nat\nidNat x = x\n' > "$WORK/m_nototal/Bad.idr"
assert_rc 1 "Firing: missing '%default total' exits 1" \
  bash "$REPO_ROOT/scripts/check-escape-hatches.sh" "$WORK/m_nototal"
assert_grep "missing '%default total'" "Firing: names missing '%default total'"

echo "=== 2. compute-bench-baseline.sh & check-bench-regression.sh ==="
if command -v jq >/dev/null 2>&1; then
  mkdir -p "$WORK/runs"
  for idx in $(seq 1 10); do
    mkdir -p "$WORK/runs/100${idx}"
    cat > "$WORK/runs/100${idx}/run.json" <<JSON
{"commit":"deadbeef","results":[{"checksum":true,"iterations":5,"median_ns":10000000,"name":"alpha"},{"checksum":true,"iterations":5,"median_ns":20000000,"name":"beta"},{"checksum":true,"iterations":5,"median_ns":40000000,"name":"gamma"}],"schema_version":1,"suite":"proven-bench"}
JSON
  done

  assert_rc 2 "Setup (exit 2): fewer than 10 runs refused (BASELINE BOOTSTRAPPING)" \
    bash "$REPO_ROOT/scripts/compute-bench-baseline.sh" "$WORK/runs/1001/run.json" "$WORK/runs/1002/run.json"
  assert_grep "BASELINE BOOTSTRAPPING" "Setup: names BASELINE BOOTSTRAPPING"

  bash "$REPO_ROOT/scripts/compute-bench-baseline.sh" "$WORK"/runs/100*/run.json > "$WORK/baseline.json"

  assert_rc 0 "Silence: ordinary run within tolerance passes" \
    bash "$REPO_ROOT/scripts/check-bench-regression.sh" "$WORK/runs/1001/run.json" "$WORK/baseline.json"

  # 4x slowdown in gamma only: leave-one-out blames ONLY gamma
  cat > "$WORK/regressed.json" <<'JSON'
{"commit":"deadbeef","results":[{"checksum":true,"iterations":5,"median_ns":10000000,"name":"alpha"},{"checksum":true,"iterations":5,"median_ns":20000000,"name":"beta"},{"checksum":true,"iterations":5,"median_ns":160000000,"name":"gamma"}],"schema_version":1,"suite":"proven-bench"}
JSON
  assert_rc 1 "Firing: 4x slowdown in single workload exits 1" \
    bash "$REPO_ROOT/scripts/check-bench-regression.sh" "$WORK/regressed.json" "$WORK/baseline.json"
  assert_grep "Unacceptable regression in: gamma$" "Firing: leave-one-out blames only the regressed workload"

  # Broken workload (checksum: false) must refuse with exit 2, never pass
  cat > "$WORK/broken.json" <<'JSON'
{"commit":"deadbeef","results":[{"checksum":false,"iterations":5,"median_ns":1000,"name":"alpha"},{"checksum":true,"iterations":5,"median_ns":20000000,"name":"beta"},{"checksum":true,"iterations":5,"median_ns":40000000,"name":"gamma"}],"schema_version":1,"suite":"proven-bench"}
JSON
  assert_rc 2 "Setup/Inert (exit 2): checksum=false workload refused" \
    bash "$REPO_ROOT/scripts/check-bench-regression.sh" "$WORK/broken.json" "$WORK/baseline.json"
else
  echo "  NOTE: jq not installed locally; jq-backed bench tests run in CI"
fi

echo "=== 3. emit-aggregate-inputs.sh: Silence, Firing, Setup (0 / 1 / 2) ==="
assert_rc 2 "Setup (exit 2): missing report exits 2" \
  bash "$REPO_ROOT/scripts/emit-aggregate-inputs.sh" "$WORK/missing-report.json"

cat > "$WORK/report.json" <<JSON
{"entries":[{"name":"t","proof_ladder":[{"proof_file":"$WORK/clean/Sound.idr"}],"provenance":"Actually-Proven"}],"schema_version":1}
JSON

cat > "$WORK/mock-pa-ok" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$WORK/mock-pa-holes" <<'SH'
#!/usr/bin/env bash
echo "verdict: Holes" >&2
exit 1
SH
chmod +x "$WORK/mock-pa-ok" "$WORK/mock-pa-holes"

assert_rc 0 "Silence: Closed proof-ladder verdict exits 0" \
  bash "$REPO_ROOT/scripts/emit-aggregate-inputs.sh" "$WORK/report.json" "$WORK/mock-pa-ok"

assert_rc 1 "Firing: Holes proof-ladder verdict exits 1" \
  bash "$REPO_ROOT/scripts/emit-aggregate-inputs.sh" "$WORK/report.json" "$WORK/mock-pa-holes"

echo "proven_suite_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
