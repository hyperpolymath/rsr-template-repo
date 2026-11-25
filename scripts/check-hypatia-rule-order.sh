#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-hypatia-rule-order.sh — the sequencing rules for Hypatia's layers.
#
# `.machine_readable/policies/hypatia-rule-order.json` says which layer wins,
# which concern belongs to which workflow, and which clash each rule settles.
# The prose is docs/HYPATIA-RULE-ORDER.adoc. This script is what makes the
# statement binding: without it the table is one more description of the
# pipeline that can drift from the four files that implement it.
#
# What it refuses:
#
#   * two layers with one rank, or a rank sequence with a hole (an "order" that
#     leaves a layer's position to the reader);
#   * a layer with no statement of what it overrides;
#   * an owner that is not one of the four declared, a concern with no owner, or
#     an owner path that does not exist;
#   * a module exempted in .hypatia-ignore that the policy does not classify, or
#     a classification for a module the ignore file no longer mentions (a policy
#     describing a file that has moved on);
#   * a scanner or grid pin in the policy that disagrees with the workflow or
#     with the renderer digests the lane script verifies;
#   * a clash with no stated resolution.
#
# Exit contract (proven-tests-and-benches 3-outcome convention):
#   0 = ordered, complete, consistent with the workflows and the ignore file
#   1 = a rule above is violated
#   2 = setup error (missing repo, policy, workflow, or ignore file)
set -euo pipefail

REPO_ROOT="${1:-.}"
POLICY="$REPO_ROOT/.machine_readable/policies/hypatia-rule-order.json"
HYPATIA_WF="$REPO_ROOT/.github/workflows/hypatia-scan.yml"
LANE="$REPO_ROOT/scripts/verdict-grid-lane.sh"
IGNORE="$REPO_ROOT/.hypatia-ignore"

for f in "$POLICY" "$HYPATIA_WF" "$LANE" "$IGNORE"; do
  if [ ! -f "$f" ]; then
    echo "check-hypatia-rule-order: missing $(basename "$f") (looked for $f)" >&2
    exit 2
  fi
done

if ! command -v yq >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "check-hypatia-rule-order: setup requires Mike Farah yq >=4.53.3 (v4) and jq" >&2
  exit 2
fi
yq_version="$(yq --version 2>&1)" || {
  echo "check-hypatia-rule-order: cannot read the required yq version" >&2; exit 2;
}
if [[ ! "$yq_version" =~ mikefarah/yq/.*version\ v([0-9]+)\.([0-9]+)\.([0-9]+) ]] ||
   (( BASH_REMATCH[1] != 4 || BASH_REMATCH[2] < 53 || (BASH_REMATCH[2] == 53 && BASH_REMATCH[3] < 3) )); then
  echo "check-hypatia-rule-order: setup requires Mike Farah yq >=4.53.3 (v4); got $yq_version" >&2
  exit 2
fi

errors=0
fail() {
  echo "FAIL: $*" >&2
  errors=$((errors + 1))
}

jq -e 'type == "object"' "$POLICY" >/dev/null 2>&1 || {
  echo "check-hypatia-rule-order: policy is not a JSON object" >&2
  exit 2
}

# ── shape ───────────────────────────────────────────────────────────────────
jq -e '.schema == "hypatia-rule-order/1"' "$POLICY" >/dev/null 2>&1 ||
  fail "policy schema is not hypatia-rule-order/1"

jq -e '(.layers | type == "array") and (.layers | length) >= 4' "$POLICY" >/dev/null 2>&1 ||
  fail "policy declares fewer than four layers"

# ── ranks: unique, complete, and ascending in the order they are written ────
ranks="$(jq -r '.layers[].rank' "$POLICY" | tr '\n' ' ')"
dupe_rank="$(jq -r '[.layers[].rank] | group_by(.) | map(select(length > 1) | .[0]) | join(",")' "$POLICY")"
[ -z "$dupe_rank" ] || fail "two layers share a rank: ${dupe_rank}"

ascending="$(jq -r '[.layers[].rank] as $r | ($r == ($r | sort))' "$POLICY")"
[ "$ascending" = "true" ] || fail "layers are not written in ascending rank order (${ranks% }); the document is the sequence"

count="$(jq -r '.layers | length' "$POLICY")"
expected="$(seq 1 "$count" | tr '\n' ' ')"
[ "${ranks% }" = "${expected% }" ] ||
  fail "ranks are ${ranks% } but a complete sequence from 1 to ${count} is required"

# ── each layer states itself ────────────────────────────────────────────────
# Fields are read as base64-encoded JSON, not @tsv: a tab is IFS whitespace, so
# an empty field would collapse and shift every field after it. That is exactly
# how a missing `overrides` used to be reported as a missing `scope`.
while read -r packed; do
  [ -n "$packed" ] || continue
  obj="$(printf '%s' "$packed" | jq -Rr '@base64d')"
  rank="$(printf '%s' "$obj" | jq -r '.rank')"
  id="$(printf '%s' "$obj" | jq -r '.id // ""')"
  owner="$(printf '%s' "$obj" | jq -r '.owner // ""')"
  overrides="$(printf '%s' "$obj" | jq -r '.overrides // ""')"
  scope="$(printf '%s' "$obj" | jq -r '.scope // ""')"
  [ -n "$id" ] || fail "layer ${rank} has no id"
  [ -n "$scope" ] || fail "layer ${rank} (${id}) has no scope"
  [ -n "$overrides" ] || fail "layer ${rank} (${id}) does not say what it overrides"
  case "$owner" in
    hypatia | this-repository | the-gate | the-grid) : ;;
    *) fail "layer ${rank} (${id}) has owner '${owner}', which is not one of hypatia / this-repository / the-gate / the-grid" ;;
  esac
done < <(jq -r '.layers[] | @base64' "$POLICY")

jq -r '.layers[].id' "$POLICY" | sort | uniq -d | while read -r dup; do
  [ -z "$dup" ] || echo "FAIL: layer id '${dup}' appears twice" >&2
done
[ -z "$(jq -r '.layers[].id' "$POLICY" | sort | uniq -d)" ] || errors=$((errors + 1))

# ── concerns: one owner each, and the owner exists ──────────────────────────
jq -e '(.concerns | type == "array") and (.concerns | length) > 0' "$POLICY" >/dev/null 2>&1 ||
  fail "policy declares no concerns"

jq -r '.concerns[].id' "$POLICY" | sort | uniq -d | while read -r dup; do
  [ -z "$dup" ] || echo "FAIL: concern '${dup}' appears twice" >&2
done
[ -z "$(jq -r '.concerns[].id' "$POLICY" | sort | uniq -d)" ] || errors=$((errors + 1))

while read -r packed; do
  [ -n "$packed" ] || continue
  obj="$(printf '%s' "$packed" | jq -Rr '@base64d')"
  id="$(printf '%s' "$obj" | jq -r '.id // ""')"
  owner="$(printf '%s' "$obj" | jq -r '.owner // ""')"
  if [ -z "$owner" ]; then
    fail "concern '${id}' has no owner"
  elif [[ "$owner" == .* && ! -e "$REPO_ROOT/$owner" ]]; then
    fail "concern '${id}' names '${owner}', which does not exist"
  fi
done < <(jq -r '.concerns[] | @base64' "$POLICY")

# ── clashes: every one has a resolution ─────────────────────────────────────
jq -e '(.clashes | type == "array") and (.clashes | length) > 0' "$POLICY" >/dev/null 2>&1 ||
  fail "policy records no clashes; the eight found are recorded in docs/HYPATIA-RULE-ORDER.adoc"

while read -r packed; do
  [ -n "$packed" ] || continue
  obj="$(printf '%s' "$packed" | jq -Rr '@base64d')"
  id="$(printf '%s' "$obj" | jq -r '.id // ""')"
  resolution="$(printf '%s' "$obj" | jq -r '.resolution // ""')"
  [ -n "$resolution" ] || fail "clash '${id}' has no stated resolution"
done < <(jq -r '.clashes[] | @base64' "$POLICY")

jq -r '.clashes[].id' "$POLICY" | sort | uniq -d | while read -r dup; do
  [ -z "$dup" ] || echo "FAIL: clash '${dup}' appears twice" >&2
done
[ -z "$(jq -r '.clashes[].id' "$POLICY" | sort | uniq -d)" ] || errors=$((errors + 1))

# ── the ignore file and the policy must describe the same modules ───────────
ignore_modules="$(sed -nE 's#^([a-z][a-z0-9_]*)/.*#\1#p' "$IGNORE" | sort -u)"
policy_modules="$(jq -r '.observed_modules[].module' "$POLICY" | sort -u)"

while read -r m; do
  [ -n "$m" ] || continue
  grep -qxF "$m" <<< "$policy_modules" ||
    fail "module '${m}' is exempted in .hypatia-ignore but the policy does not classify it (add it to observed_modules)"
done <<< "$ignore_modules"

while read -r m; do
  [ -n "$m" ] || continue
  grep -qxF "$m" <<< "$ignore_modules" ||
    fail "policy classifies module '${m}', but .hypatia-ignore no longer exempts it (the policy describes a file that has moved on)"
done <<< "$policy_modules"

# a classified module must point at a layer that permits repository changes
while IFS=$'\t' read -r m layer; do
  [ -n "$m" ] || continue
  can="$(jq -r --argjson r "$layer" '.layers[] | select(.rank == $r) | .repository_can_change' "$POLICY")"
  if [ -z "$can" ]; then
    fail "module '${m}' points at layer ${layer}, which does not exist"
  elif [ "$can" != "true" ]; then
    fail "module '${m}' points at layer ${layer}, which this repository cannot change"
  fi
done < <(jq -r '.observed_modules[] | [.module, .layer] | @tsv' "$POLICY")

# ── pins must agree with the files that use them ────────────────────────────
policy_hypatia="$(jq -r '.scanner.commit' "$POLICY")"
# The scanner pin is HYPATIA_SHA where hypatia-scan.yml runs the scan itself,
# or the `hypatia-ref:` input where it calls a reusable workflow (the call
# passes the pin; the reusable has none of its own). Both present must agree:
# two pins for one scanner leave the policy two answers.
# Inspect the raw AST before expanding aliases or converting to JSON. Decode
# this one workflow once for both pins; declarations and run text are not inputs.
workflow_pins() {
  local workflow="$1" preflight duplicates keys sha_duplicates ref_duplicates
  preflight="$(yq -p yaml -o yaml -r -N '
    ([.. | select(kind == "map") | to_entries | group_by(.key) |
      .[] | select(length > 1)]) as $duplicates |
    ([.. | select(kind == "map") | to_entries[] | .key |
      select(kind != "scalar" or (tag != "!!str" and tag != "!!merge"))] | length) as $keys |
    ([$duplicates[] | select(.[0].key == "HYPATIA_SHA")] | length) as $sha_duplicates |
    ([$duplicates[] | select(.[0].key == "hypatia-ref")] | length) as $ref_duplicates |
    [($duplicates | length), $keys, $sha_duplicates, $ref_duplicates] | @tsv
  ' "$workflow")" || return 1
  while IFS=$'\t' read -r duplicates keys sha_duplicates ref_duplicates; do
    [[ "$duplicates" =~ ^[0-9]+$ && "$keys" =~ ^[0-9]+$ &&
       "$sha_duplicates" =~ ^[0-9]+$ && "$ref_duplicates" =~ ^[0-9]+$ ]] || return 1
    if (( duplicates > 0 )); then
      echo "duplicate YAML mapping keys (raw AST)" >&2
      if (( sha_duplicates > 0 )); then echo "hypatia-scan.yml declares HYPATIA_SHA more than once" >&2; fi
      if (( ref_duplicates > 0 )); then echo "hypatia-scan.yml passes hypatia-ref more than once" >&2; fi
      return 1
    fi
    if (( keys > 0 )); then
      echo "aliased, complex or non-string YAML mapping keys are unsupported" >&2; return 1
    fi
  done <<< "$preflight"
  yq --yaml-fix-merge-anchor-to-spec=true -p yaml -o json -I0 'explode(.)' "$workflow" |
    jq -sc '
def pin($var; $scope):
  . as $root |
  [paths as $p | select($p[-1] == $var) |
    select(
      ($scope == "env" and (
        (($p | length) == 2 and $p[0] == "env") or
        (($p | length) == 4 and $p[0] == "jobs" and $p[2] == "env") or
        (($p | length) == 5 and $p[0] == "jobs" and $p[2] == "container" and $p[3] == "env") or
        (($p | length) == 6 and $p[0] == "jobs" and $p[2] == "steps" and
          ($p[3] | type) == "number" and $p[4] == "env"))) or
      ($scope == "with" and ($p | length) == 4 and $p[0] == "jobs" and $p[2] == "with" and
        ($root.jobs[$p[1]].uses | type) == "string" and
        ($root.jobs[$p[1]].uses | test("^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/\\.github/workflows/[^@]+@|[.$]/\\.github/workflows/[^@]+$)")))) |
    $root | getpath($p)] |
  if length > 1 then
    if $var == "HYPATIA_SHA" then error("hypatia-scan.yml declares HYPATIA_SHA more than once")
    else error("hypatia-scan.yml passes hypatia-ref more than once") end
  elif length == 0 then ""
  else .[0] |
    ("hypatia-scan.yml has a malformed " + $var + " scanner pin") as $malformed |
    if type != "string" then error($malformed + ": must be a literal string")
    elif test("\\s") then error($malformed + ": scanner pin must not contain whitespace")
    elif (test("^[0-9a-f]{40}$") | not) then error($malformed + ": must be a literal full SHA")
    else . end
  end;
if length != 1 then error("expected exactly one YAML document")
elif (.[0] | type) != "object" or (.[0].jobs | type) != "object" then error("workflow and jobs must be mappings")
else .[0] | {sha:pin("HYPATIA_SHA"; "env"), ref:pin("hypatia-ref"; "with")} end
    '
}
wf_pins="$(workflow_pins "$HYPATIA_WF")" || {
  fail "hypatia-scan.yml scanner pins could not be inspected"
  wf_pins='{"sha":"","ref":""}'
}
wf_sha="$(jq -r '.sha' <<< "$wf_pins")"
wf_ref="$(jq -r '.ref' <<< "$wf_pins")"
wf_hypatia="${wf_sha:-$wf_ref}"
wf_pin_name="HYPATIA_SHA"; [ -n "$wf_sha" ] || wf_pin_name="the hypatia-ref input"
if [ -z "$wf_hypatia" ]; then
  fail "hypatia-scan.yml declares no HYPATIA_SHA and passes no hypatia-ref input; the policy's scanner.commit cannot be verified"
elif [ -n "$wf_sha" ] && [ -n "$wf_ref" ] && [ "$wf_sha" != "$wf_ref" ]; then
  fail "hypatia-scan.yml pins the scanner twice and disagrees: HYPATIA_SHA ${wf_sha:0:12}, hypatia-ref ${wf_ref:0:12}"
elif [ "$policy_hypatia" != "$wf_hypatia" ]; then
  fail "policy scanner.commit (${policy_hypatia:0:12}) does not match ${wf_pin_name} in hypatia-scan.yml (${wf_hypatia:0:12})"
fi

policy_grid="$(jq -r '.grid.commit' "$POLICY")"
lane_grid="$(sed -nE 's/.*STANDARDS_SHA:-([0-9a-f]{40}).*/\1/p' "$LANE" | head -n1)"
if [ -z "$lane_grid" ]; then
  fail "verdict-grid-lane.sh names no STANDARDS_SHA; the policy's grid.commit cannot be verified"
elif [ "$policy_grid" != "$lane_grid" ]; then
  fail "policy grid.commit (${policy_grid:0:12}) does not match STANDARDS_SHA in scripts/verdict-grid-lane.sh (${lane_grid:0:12})"
fi

for pair in "renderer_sha256:RENDERER_SHA256" "library_sha256:JQ_LIB_SHA256"; do
  key="${pair%%:*}"; var="${pair##*:}"
  want="$(jq -r --arg k "$key" '.grid[$k]' "$POLICY")"
  got="$(sed -nE "s/.*${var}=\"([0-9a-f]{64})\".*/\1/p" "$LANE" | head -n1)"
  if [ -z "$got" ]; then
    fail "verdict-grid-lane.sh declares no ${var}; the policy's grid.${key} cannot be verified"
  elif [ "$want" != "$got" ]; then
    fail "policy grid.${key} (${want:0:12}) does not match ${var} in scripts/verdict-grid-lane.sh (${got:0:12})"
  fi
done

# ── verdict ────────────────────────────────────────────────────────────────
if [ "$errors" -ne 0 ]; then
  echo "check-hypatia-rule-order: ${errors} rule violation(s)" >&2
  exit 1
fi
echo "check-hypatia-rule-order: $(jq -r '.layers | length' "$POLICY") layer(s) ordered, $(jq -r '.concerns | length' "$POLICY") concern(s) owned, $(jq -r '.clashes | length' "$POLICY") clash(es) resolved, $(jq -r '.observed_modules | length' "$POLICY") module(s) classified"
