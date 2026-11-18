#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Template Benchmarks (proven-tests-and-benches JSON v1 compatible)
#
# Usage:
#   benches/template_bench.sh [--json | --csv] [REPO_ROOT]
#   benches/template_bench.sh [REPO_ROOT] [human | json | csv]
#
# Exit contract (proven-tests-and-benches 3-outcome convention):
#   0 = all workloads succeeded (checksum == true for every workload)
#   1 = one or more benchmarked workloads failed (a broken workload is never timed as clean)
#   2 = setup error (missing repo root or required benchmark script)
set -euo pipefail

OUTPUT_FORMAT="human"
REPO_ROOT="."

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) OUTPUT_FORMAT="json"; shift ;;
    --csv) OUTPUT_FORMAT="csv"; shift ;;
    human|json|csv) OUTPUT_FORMAT="$1"; shift ;;
    *) REPO_ROOT="$1"; shift ;;
  esac
done

[ -d "$REPO_ROOT" ] || { echo "template_bench: repo root '$REPO_ROOT' does not exist" >&2; exit 2; }
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

for req in \
  "$REPO_ROOT/scripts/check-root-shape.sh" \
  "$REPO_ROOT/scripts/check-ijson-jcs.sh" \
  "$REPO_ROOT/scripts/check-required-contexts.sh" \
  "$REPO_ROOT/scripts/check-escape-hatches.sh"
do
  [ -f "$req" ] || { echo "template_bench: required workload script missing: $req" >&2; exit 2; }
done

# Print a message only in human output mode.
log_human() {
  if [ "$OUTPUT_FORMAT" = "human" ]; then
    printf '%s\n' "$*"
  fi
}

# median_of <n1> <n2> ... -> integer median on stdout
# Requires at least one integer sample; for even counts, truncate the average
# of the two middle samples toward zero.
median_of() {
  local sorted count mid
  mapfile -t sorted < <(printf '%s\n' "$@" | sort -n)
  count="${#sorted[@]}"
  mid=$(( count / 2 ))
  if [ $(( count % 2 )) -eq 1 ]; then
    printf '%s' "${sorted[$mid]}"
  else
    printf '%s' $(( (sorted[mid - 1] + sorted[mid]) / 2 ))
  fi
}

declare -A MEDIAN_NS
declare -A ITERS
declare -A CHECKSUM
WORKLOADS=(escape_hatches ijson_jcs required_contexts root_shape)
ANY_FAILED=0

# run_workload NAME ITERATIONS COMMAND... — run one warm-up and ITERATIONS timed
# samples, recording median nanoseconds, iterations, and checksum by NAME.
# Any failed invocation sets ANY_FAILED and a false checksum; sampling continues.
run_workload() {
  local name="$1" iterations="$2"
  shift 2
  local samples=() ok="true" i start end elapsed warmup

  # Warm-up run
  start="$(date +%s%N)"
  if ! "$@" >/dev/null 2>&1; then
    ok="false"
    ANY_FAILED=1
  fi
  end="$(date +%s%N)"
  warmup=$(( end - start ))

  for i in $(seq 1 "$iterations"); do
    start="$(date +%s%N)"
    if ! "$@" >/dev/null 2>&1; then
      ok="false"
      ANY_FAILED=1
    fi
    end="$(date +%s%N)"
    elapsed=$(( end - start ))
    [ "$elapsed" -gt 0 ] || elapsed=1
    samples+=("$elapsed")
    log_human "  [$name] sample $i/$iterations: $(( elapsed / 1000000 )) ms"
  done

  MEDIAN_NS["$name"]="$(median_of "${samples[@]}")"
  ITERS["$name"]="$iterations"
  CHECKSUM["$name"]="$ok"

  # The regression gate sees one median per workload. When it fails, the CI log
  # must show whether one sample or all of them were slow, and where the time
  # went. Diagnostics go to stderr (stdout is the document in --json and --csv
  # mode) and never change the result.
  if [ "$OUTPUT_FORMAT" != "human" ]; then
    {
      printf 'bench-samples: %s ms: warm-up %d; samples' "$name" "$(( warmup / 1000000 ))"
      for elapsed in "${samples[@]}"; do printf ' %d' "$(( elapsed / 1000000 ))"; done
      printf '\n'
    } >&2
  fi
  trace_if_slow "$name" "${MEDIAN_NS[$name]}" "$@" || true
}

# trace_if_slow NAME MEDIAN_NS COMMAND... — when the median is over the gate's
# absolute limit (2.5x the workload's mean in benches/baseline.json), run
# COMMAND once more with xtrace on in every bash it starts, and print on stderr
# the commands that took 5 ms or more. Silent without jq, without a baseline for
# NAME, and for a workload within the limit.
trace_if_slow() {
  local name="$1" median="$2" base="" line prev="" now last=0 delta
  shift 2
  [ -n "${EPOCHREALTIME:-}" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  [ -f "$REPO_ROOT/benches/baseline.json" ] || return 0
  base="$(jq -r --arg n "$name" '.workloads[$n].mean_median_ns // empty | floor' \
    "$REPO_ROOT/benches/baseline.json" 2>/dev/null)" || return 0
  [[ "$base" =~ ^[1-9][0-9]*$ ]] || return 0
  [ "$median" -gt $(( base * 5 / 2 )) ] || return 0
  printf 'bench-diag: %s median %d ms is over 2.5x its baseline mean of %d ms; one traced run, commands of 5 ms or more:\n' \
    "$name" "$(( median / 1000000 ))" "$(( base / 1000000 ))" >&2
  # xtrace prints a command before running it, so the gap to the next trace
  # line is the time that command took. Lines are stamped on arrival here.
  while IFS= read -r line; do
    now="${EPOCHREALTIME/./}"
    if [ "$last" -gt 0 ]; then
      delta=$(( now - last ))
      [ "$delta" -lt 5000 ] || printf 'bench-diag:   %5d ms  %.160s\n' "$(( delta / 1000 ))" "$prev" >&2
    fi
    prev="$line"; last="$now"
  done < <(env SHELLOPTS=xtrace "$@" 2>&1 >/dev/null)
  # the last command has no following trace line: its gap ends when the run does
  if [ "$last" -gt 0 ]; then
    now="${EPOCHREALTIME/./}"; delta=$(( now - last ))
    [ "$delta" -lt 5000 ] || printf 'bench-diag:   %5d ms  %.160s\n' "$(( delta / 1000 ))" "$prev" >&2
  fi
  printf 'bench-diag: end of traced run for %s\n' "$name" >&2
}

log_human "Template Benchmarks (proven-bench v1)"
log_human "====================================="

run_workload escape_hatches 5 bash "$REPO_ROOT/scripts/check-escape-hatches.sh" \
  "$REPO_ROOT/src" "$REPO_ROOT/verification" "$REPO_ROOT/.machine_readable/coaptation"
# Clear any caller-supplied IJSON_JCS binary override so the benchmark always
# measures the same deterministic JS RFC 7493/8785 workload calibrated in
# benches/baseline.json (production gates still honour IJSON_JCS on PATH).
run_workload ijson_jcs 5 env -u IJSON_JCS IJSON_JCS_FORCE_JS=1 bash "$REPO_ROOT/scripts/check-ijson-jcs.sh" --enforce "$REPO_ROOT"
run_workload required_contexts 5 bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$REPO_ROOT"
run_workload root_shape 5 bash "$REPO_ROOT/scripts/check-root-shape.sh" "$REPO_ROOT"

COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')"

if [ "$OUTPUT_FORMAT" = "json" ]; then
  # Emit strict RFC 7493 / RFC 8785 (JCS) JSON v1 document for proven-bench tools.
  printf '{"commit":"%s","results":[' "$COMMIT_SHA"
  first=1
  for w in "${WORKLOADS[@]}"; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"checksum":%s,"iterations":%d,"median_ns":%d,"name":"%s"}' \
      "${CHECKSUM[$w]}" "${ITERS[$w]}" "${MEDIAN_NS[$w]}" "$w"
  done
  printf '],"schema_version":1,"suite":"proven-bench"}\n'
elif [ "$OUTPUT_FORMAT" = "csv" ]; then
  printf 'workload,iterations,median_ns,checksum\n'
  for w in "${WORKLOADS[@]}"; do
    printf '%s,%d,%d,%s\n' "$w" "${ITERS[$w]}" "${MEDIAN_NS[$w]}" "${CHECKSUM[$w]}"
  done
else
  log_human ""
  for w in "${WORKLOADS[@]}"; do
    printf '  %-20s %8d ms (median of %d, checksum=%s)\n' \
      "$w" "$(( MEDIAN_NS[$w] / 1000000 ))" "${ITERS[$w]}" "${CHECKSUM[$w]}"
  done
fi

[ "$ANY_FAILED" -eq 0 ] || exit 1
exit 0
