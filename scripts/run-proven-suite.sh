#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Unified 3-outcome test & proof runner grounded in hyperpolymath/proven-tests-and-benches.
#
# Usage: scripts/run-proven-suite.sh [--require-zig] [--bench] [--report FILE]
#
# Exit contract:
#   0 = every tier passed (Silence on clean tree + Firing on every negative mutant)
#   1 = a subject check, proof honesty lint, or contract test failed
#   2 = setup / cannot-look failure (missing tool or missing suite — never a pass)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRE_ZIG=0
RUN_BENCH=0
REPORT_PATH="$REPO_ROOT/build/report/proven-tests-report.json"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --require-zig) REQUIRE_ZIG=1; shift ;;
    --bench) RUN_BENCH=1; shift ;;
    --report)
      [ "$#" -ge 2 ] || { echo "run-proven-suite: --report needs a path" >&2; exit 2; }
      REPORT_PATH="$2"
      shift 2
      ;;
    *) echo "run-proven-suite: unknown option '$1'" >&2; exit 2 ;;
  esac
done

cd "$REPO_ROOT" || exit 2

subject_failures=0
setup_failures=0

run_lane() {
  local label="$1" rc=0
  shift
  printf '==> [proven-suite] %s\n' "$label"
  "$@" || rc=$?
  case "$rc" in
    0) printf '    PASS (0): %s\n' "$label" ;;
    2)
      printf '    INERT/SETUP (2): %s\n' "$label" >&2
      setup_failures=$((setup_failures + 1))
      ;;
    *)
      printf '    FAIL (%d): %s\n' "$rc" "$label" >&2
      subject_failures=$((subject_failures + 1))
      ;;
  esac
}

# ── Tier 1: Actually-Proven honesty lint + panic-attack proof-ladder report ──
run_lane "Idris2 proof escape-hatch & totality gate" \
  bash scripts/check-escape-hatches.sh src verification .machine_readable/coaptation

mkdir -p "$(dirname "$REPORT_PATH")"
mapfile -t PROOF_FILES < <(find src verification .machine_readable/coaptation -name '*.idr' -type f | sort)
{
  printf '{"entries":[{"name":"rsr-idris2-proof-corpus","proof_ladder":['
  first=1
  for pf in "${PROOF_FILES[@]}"; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"proof_file":"%s"}' "$pf"
  done
  printf '],"provenance":"Actually-Proven"}],"schema_version":1}\n'
} > "$REPORT_PATH"

run_lane "Proof-ladder aggregation (emit-aggregate-inputs)" \
  bash scripts/emit-aggregate-inputs.sh "$REPORT_PATH"

# ── Tier 2: Repository invariant & estate data-format gates ──────────────────
run_lane "Root shape bidirectional allowlist" \
  bash scripts/check-root-shape.sh .
run_lane "I-JSON (RFC 7493) + JCS (RFC 8785) canonical gate" \
  bash scripts/check-ijson-jcs.sh --enforce .
run_lane "Workflow actions.lock integrity" \
  bash scripts/check-lock-sync.sh .github/workflows
if [ -f scripts/check-required-contexts.sh ]; then
  run_lane "Required status contexts producibility gate" \
    bash scripts/check-required-contexts.sh .
fi
run_lane "CHORA deed validation & retired .a2ml refusal" \
  bash .github/hooks/validate-deed.sh
run_lane "K9 pedigree & contract validation" \
  bash .github/hooks/validate-k9.sh

# ── Tier 3: Silence + Firing contract & E2E test suites ──────────────────────
run_lane "Proven tools Silence + Firing self-tests" \
  bash tests/proven_suite_test.sh
run_lane "I-JSON/JCS Silence + Firing self-tests" \
  bash tests/workflows/check_ijson_jcs_test.sh
if [ -f tests/workflows/squabble_gate_test.sh ]; then
  run_lane "CICD-Squabbler & required-context Silence + Firing self-tests" \
    bash tests/workflows/squabble_gate_test.sh
fi
run_lane "Root shape Silence + Firing self-tests" \
  bash tests/shape/check_root_shape_test.sh
run_lane "Site & .well-known boundary + planted controls" \
  bash www/tests/run-all.sh

# ── Tier 4: Zig FFI unit tests + E2E mint instantiation ──────────────────────
run_zig_ffi_tests() {
  local work
  work="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN
  cp -R src/interface/ffi "$work/ffi"
  sed -i -e 's/{{project}}/test_project/g' -e 's/{{PROJECT}}/TEST_PROJECT/g' \
    "$work/ffi/build.zig" "$work/ffi/src/main.zig" "$work/ffi/test/integration_test.zig" 2>/dev/null || true
  (cd "$work/ffi" && zig build test)
}

if command -v zig >/dev/null 2>&1; then
  run_lane "Zig FFI ABI layout & memory-leak unit tests" run_zig_ffi_tests
elif [ "$REQUIRE_ZIG" -eq 1 ]; then
  printf '    INERT/SETUP (2): zig compiler required (--require-zig) but missing on PATH\n' >&2
  setup_failures=$((setup_failures + 1))
else
  printf '==> [proven-suite] Zig FFI unit tests: skipped locally (pass --require-zig in CI to fail-closed)\n'
fi

if command -v rustc >/dev/null 2>&1 && command -v just >/dev/null 2>&1; then
  run_lane "Template mint instantiation E2E" \
    bash tests/e2e/template_instantiation_test.sh .
fi

# ── Tier 5: Benchmark regression gate (optional --bench) ─────────────────────
if [ "$RUN_BENCH" -eq 1 ]; then
  if ! command -v jq >/dev/null 2>&1; then
    printf '    INERT/SETUP (2): jq required for --bench regression gate\n' >&2
    setup_failures=$((setup_failures + 1))
  else
    BENCH_TMP="$(mktemp)"
    trap 'rm -f "$BENCH_TMP"' EXIT
    run_lane "Template benchmark execution (--json)" \
      bash -c "bash benches/template_bench.sh --json . > '$BENCH_TMP'"
    run_lane "Six-Sigma leave-one-out benchmark regression gate" \
      bash scripts/check-bench-regression.sh "$BENCH_TMP" benches/baseline.json
  fi
fi

rm -rf "$(dirname "$REPORT_PATH")"

if [ "$setup_failures" -gt 0 ]; then
  printf 'proven-suite: SETUP/INERT FAILURE (%d setup, %d subject)\n' "$setup_failures" "$subject_failures" >&2
  exit 2
fi
if [ "$subject_failures" -gt 0 ]; then
  printf 'proven-suite: SUBJECT FAILURE (%d failing lane(s))\n' "$subject_failures" >&2
  exit 1
fi
printf 'proven-suite: ALL LANES PASSED\n'
exit 0
