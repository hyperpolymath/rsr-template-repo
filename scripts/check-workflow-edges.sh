#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-workflow-edges.sh — the intra-repository half of the CICD-Squabbler gate.
#
# hyperpolymath/cicd-squabbler's `chains` command follows CROSS-repository CI
# edges: a reusable workflow or action pinned at a dead commit. This repository's
# verdict grid introduced edges of the same kind INSIDE one repository, which
# squabble cannot see and which fail silently:
#
#   * `.github/workflows/fork-governance.yml` is triggered by
#     `workflow_run: workflows: [...]`, which matches a workflow's `name:`, not
#     its file. Rename `name: Hypatia Security Scan` and the grid stops
#     re-rendering — no error, no red check, just an orange row forever.
#   * It reads artifacts by name (`--source <file>:<artifact>`). Rename an
#     upload step's `name:` and the evidence vanishes the same way.
#   * It names each scanner's pinned commit (`--hypatia-ref`, `--panic-ref`,
#     `--pons-ref`) for the grid's profile hash. If the producer moves its pin
#     and the reporter is not moved with it, two revisions look comparable when
#     they are not.
#   * One tool pinned at two different commits in two workflows is a clash, not
#     a choice: whichever workflow ran last decides what the grid graded.
#   * A producer may delegate its scan to a job-level reusable-workflow call.
#     Then the artifact and the scanner pin live in the CALLED workflow, read
#     here at the full SHA the call pins (network, or EDGES_REUSABLE_DIR), and
#     the pin is the one the call passes (`with: hypatia-ref:`): a call that
#     passes none runs the reusable's own default, not the verdict's pin.
#
# Every check here is a rule about the pipeline's shape, not about the code
# under test, which is why it belongs beside `check-required-contexts.sh` in the
# squabble gate rather than in the manifest-janitor set.
#
# Exit contract (proven-tests-and-benches 3-outcome convention):
#   0 = every edge resolves and no tool is pinned twice
#   1 = a dead edge, an unproduced artifact, a stale pin, or a duplicate tool pin
#   2 = setup error (missing repo, workflows dir, or the reporter workflow; a
#       reusable producer not pinned to a full SHA, or not readable)
#
# Deliberately NOT checked: that a producer's gate is "right". Gating is each
# producer's own decision (see the header of fork-governance.yml); this script
# only checks that the reporting edges still point at something.
set -euo pipefail

REPO_ROOT="${1:-.}"
if [ ! -d "$REPO_ROOT" ]; then
  echo "check-workflow-edges: repo directory '$REPO_ROOT' does not exist" >&2
  exit 2
fi
WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
REPORTER="$WORKFLOWS_DIR/fork-governance.yml"
PUBLISHER="$WORKFLOWS_DIR/verdict-grid-publish.yml"

if [ ! -d "$WORKFLOWS_DIR" ]; then
  echo "check-workflow-edges: workflows directory '$WORKFLOWS_DIR' does not exist" >&2
  exit 2
fi
if [ ! -f "$REPORTER" ]; then
  echo "check-workflow-edges: reporter workflow '$REPORTER' does not exist" >&2
  exit 2
fi
if [ ! -f "$PUBLISHER" ]; then
  echo "check-workflow-edges: publisher workflow '$PUBLISHER' does not exist" >&2
  exit 2
fi

# The YAML extractor needs Mike Farah yq, not the unrelated Python yq wrapper.
# CI installs exact checksum-pinned 4.53.3; local runs require v4 >=4.53.3.
if ! command -v yq >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "check-workflow-edges: setup requires Mike Farah yq >=4.53.3 (v4) and jq" >&2
  exit 2
fi
yq_version="$(yq --version 2>&1)" || {
  echo "check-workflow-edges: cannot read the required yq version" >&2; exit 2;
}
if [[ ! "$yq_version" =~ mikefarah/yq/.*version\ v([0-9]+)\.([0-9]+)\.([0-9]+) ]] ||
   (( BASH_REMATCH[1] != 4 || BASH_REMATCH[2] < 53 || (BASH_REMATCH[2] == 53 && BASH_REMATCH[3] < 3) )); then
  echo "check-workflow-edges: setup requires Mike Farah yq >=4.53.3 (v4); got $yq_version" >&2
  exit 2
fi

# ── helpers ─────────────────────────────────────────────────────────────────
errors=0
fail() {
  echo "FAIL: $*" >&2
  errors=$((errors + 1))
}

# workflow_name FILE — the `name:` of a workflow, or empty for `name:` absent.
# Only the FIRST top-level `name:` is read: `on: push: ...` keys and job names
# are indented, and a workflow with no `name:` is identified by its path alone.
workflow_name() {
  awk '
    /^name:[[:space:]]*/ { sub(/^name:[[:space:]]*/, ""); gsub(/^["'"'"']|["'"'"']$/, ""); print; exit }
    /^[^[:space:]#]/ { next }
  ' "$1"
}

# produced_artifacts FILE — every artifact name an upload-artifact step writes.
produced_artifacts() {
  awk '
    /uses:[[:space:]]*actions\/upload-artifact@/ { in_upload = 1; next }
    in_upload && /^[[:space:]]*- name:/ { in_upload = 0 }
    in_upload && /^[[:space:]]*name:[[:space:]]/ {
      sub(/^[[:space:]]*name:[[:space:]]*/, ""); gsub(/["'"'"']/, ""); print; in_upload = 0
    }
  ' "$1"
}

# env_pin FILE VAR — the value of a `VAR:` line in the workflow's env blocks.
env_pin() {
  awk -v var="$2" '
    $0 ~ "^[[:space:]]*" var ":[[:space:]]" {
      sub("^[[:space:]]*" var ":[[:space:]]*", ""); gsub(/["'"'"']/, ""); print; exit
    }
  ' "$1"
}


# hypatia_checkouts FILE — inspect real YAML nodes, never source indentation.
# Reject duplicate mapping keys on the raw AST before aliases are expanded or
# JSON is emitted; JSON conversion alone preserves/loses ambiguity downstream.
# yq decodes anchors, aliases, block scalars and flow maps. jq then checks typed
# jobs/steps/inputs and literal env bindings with step > job > workflow priority.
# An uninspectable overriding scope is an error, never permission to fall back.
hypatia_checkouts() {
  local workflow="$1" preflight duplicates keys
  preflight="$(yq -p yaml -o yaml -r -N '
    ([.. | select(kind == "map") | to_entries | group_by(.key) |
      .[] | select(length > 1)] | length) as $duplicates |
    ([.. | select(kind == "map") | to_entries[] | .key |
      select(kind != "scalar" or (tag != "!!str" and tag != "!!merge"))] | length) as $keys |
    [$duplicates, $keys] | @tsv
  ' "$workflow")" || return 1
  while IFS=$'\t' read -r duplicates keys; do
    [[ "$duplicates" =~ ^[0-9]+$ && "$keys" =~ ^[0-9]+$ ]] || return 1
    if (( duplicates > 0 )); then
      printf '!\tduplicate YAML mapping keys (raw AST)\n'; return 0
    fi
    if (( keys > 0 )); then
      printf '!\taliased, complex or non-string YAML mapping keys are unsupported\n'; return 0
    fi
  done <<< "$preflight"
  yq --yaml-fix-merge-anchor-to-spec=true -p yaml -o json -I0 'explode(.)' "$workflow" |
    jq -sr '
def text: gsub("^\\s+|\\s+$"; "");
def row($pin; $where): [$pin, $where] | @tsv;
def bad($where; $why): row("!"; $where + ": " + $why);
def binding($scope; $name):
  if ($scope | has("env") | not) then {present:false}
  elif ($scope.env | type) != "object" then {error:"uninspectable env mapping for checkout env binding"}
  elif ($scope.env | has($name)) then {present:true,value:$scope.env[$name]}
  else {present:false} end;
def lookup($scopes; $name):
  reduce $scopes[] as $scope ({present:false};
    if .present or has("error") then . else binding($scope; $name) end);
def inspect($root; $job; $entry):
  ("job " + ($job.key | tojson) + " step " + (($entry.key + 1) | tostring)) as $where |
  $entry.value as $step |
  if ($step | type) != "object" then bad($where; "step must be a mapping")
  elif ($step | has("uses") | not) then empty
  elif ($step.uses | type) != "string" then bad($where; "uninspectable uses selector")
  elif ($step.uses | text | contains("${{")) then bad($where; "uninspectable uses selector expression")
  elif ($step.uses | text | ascii_downcase | startswith("actions/checkout@") | not) then empty
  elif ($step | has("with") | not) then empty
  elif ($step.with | type) != "object" then bad($where; "checkout with inputs must be a mapping")
  elif ($step.with | to_entries | group_by(.key | ascii_downcase) | any(length > 1))
    then bad($where; "checkout input names collide case-insensitively")
  else
    ($step.with | with_entries(.key |= ascii_downcase)) as $inputs |
    if ($inputs | has("repository") | not) then empty
    elif ($inputs.repository | type) != "string" then bad($where; "uninspectable checkout repository selector")
    elif ($inputs.repository | text | contains("${{")) then bad($where; "uninspectable checkout repository expression")
    elif ($inputs.repository | text | ascii_downcase) != "hyperpolymath/hypatia" then empty
    elif ($inputs.ref | type) != "string" then bad($where; "missing or non-literal full-SHA checkout ref")
    else ($inputs.ref | text) as $raw |
      (if ($raw | test("^\\$\\{\\{\\s*env\\.[A-Za-z_][A-Za-z0-9_]*\\s*\\}\\}$"))
       then ($raw | capture("^\\$\\{\\{\\s*env\\.(?<name>[A-Za-z_][A-Za-z0-9_]*)\\s*\\}\\}$").name) as $name |
            lookup([$step,$job.value,$root]; $name)
       else {present:true,value:$raw} end) as $resolved |
      if ($resolved | has("error")) then bad($where; $resolved.error)
      elif ($resolved.present | not) then bad($where; "missing env binding for checkout ref")
      elif ($resolved.value | type) != "string" then bad($where; "checkout env binding is not a literal string")
      elif ($resolved.value | text | test("^[0-9a-f]{40}$") | not) then bad($where; "missing or non-literal full-SHA checkout ref (or unresolved env binding)")
      else row(($resolved.value | text); $where) end
    end
  end;
if length != 1 then bad("workflow"; "expected exactly one YAML document")
elif (.[0] | type) != "object" then bad("workflow"; "root must be a mapping")
elif (.[0].jobs | type) != "object" then bad("workflow"; "jobs must be a mapping")
else .[0] as $root | $root.jobs | to_entries[] as $job |
  if ($job.value | type) != "object" then bad("workflow"; "job must be a mapping")
  elif ($job.value | has("steps") | not) then empty
  elif ($job.value.steps | type) != "array" then bad("workflow"; "job steps must be a sequence")
  else $job.value.steps | to_entries[] | inspect($root; $job; .) end
end
    '
}

# reusable_calls FILE — every job-level reusable-workflow call in FILE
# (`uses: OWNER/REPO/.github/workflows/X.yml@REF` outside every job's `steps:`
# block), one per line. A producer may delegate its scan to such a call, and
# the artifact it uploads and the scanner it pins then live in the called
# workflow, not in FILE.
reusable_calls() {
  awk '
    BEGIN { stepind = -1 }
    { line = $0; sub(/[[:space:]]+#.*$/, "", line) }
    line ~ /[^[:space:]]/ {
      match(line, /^[[:space:]]*/); ind = RLENGTH
      if (stepind >= 0 && ind <= stepind) stepind = -1
      if (line ~ /^[[:space:]]*steps:/) stepind = ind
    }
    stepind < 0 && line ~ /^[[:space:]]+uses:[[:space:]]*["\047]?[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/\.github\/workflows\/[^[:space:]@]+\.ya?ml@/ {
      sub(/^[[:space:]]*uses:[[:space:]]*/, "", line); gsub(/["\047]/, "", line); sub(/[[:space:]]+$/, "", line)
      print line
    }
  ' "$1"
}

# reusable_source CALL — prints the path of a local copy of the called
# workflow, read at the commit the call pins. Only a full 40-hex SHA is
# followed: a tag or branch could move between this check and the run.
# EDGES_REUSABLE_DIR (the tests) supplies copies offline as
# <dir>/OWNER/REPO/SHA/PATH; otherwise raw.githubusercontent.com serves them.
# A call that cannot be read is a setup error (exit 2), never a pass: the edge
# through it would be unverified.
reusable_cache="$(mktemp -d)"
reusable_source() {
  local call="$1" spec ref owner repo path out
  spec="${call%@*}"; ref="${call##*@}"
  owner="${spec%%/*}"; spec="${spec#*/}"; repo="${spec%%/*}"; path="${spec#*/}"
  if [[ ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    echo "check-workflow-edges: reusable call '${call}' is not pinned to a full commit SHA; what it uploads and pins cannot be checked" >&2
    return 2
  fi
  out="$reusable_cache/$owner/$repo/$ref/$path"
  if [ ! -f "$out" ]; then
    mkdir -p "$(dirname "$out")"
    if [ -n "${EDGES_REUSABLE_DIR:-}" ]; then
      if ! cp "$EDGES_REUSABLE_DIR/$owner/$repo/$ref/$path" "$out" 2>/dev/null; then
        echo "check-workflow-edges: reusable '${call}' is not in EDGES_REUSABLE_DIR" >&2
        return 2
      fi
    elif ! curl --proto =https --proto-redir =https -fsSL --retry 3 --max-time 30 "https://raw.githubusercontent.com/$owner/$repo/$ref/$path" -o "$out"; then
      echo "check-workflow-edges: could not read reusable '${call}' at its pinned commit; the edge through it cannot be verified" >&2
      return 2
    fi
  fi
  printf '%s' "$out"
}
# ── 1. workflow_run edges resolve to a workflow `name:` ─────────────────────
# `workflow_run: workflows:` is a YAML list under the trigger. Read it as text:
# this legacy edge reader retains its existing implementation. The Hypatia
# checkout reader below uses the required structured YAML parser.
edges="$(awk '
  /^on:/ { in_on = 1; next }
  /^[^[:space:]#]/ { in_on = 0 }
  in_on && /^[[:space:]]+workflow_run:/ { in_wr = 1; next }
  in_wr && /^[[:space:]]+workflows:/ { in_list = 1; next }
  in_list && /^[[:space:]]+- / {
    sub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/["'"'"']/, ""); print; next
  }
  in_list && !/^[[:space:]]+- / { in_list = 0; in_wr = 0 }
' "$PUBLISHER")"

if [ -z "$edges" ]; then
  fail "verdict-grid-publish.yml declares no workflow_run trigger: the verdict grid would never re-render after a scanner finishes"
fi

names_file="$(mktemp)"
trap 'rm -rf "$names_file" "$reusable_cache"' EXIT
for wf in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
  [ -e "$wf" ] || continue
  n="$(workflow_name "$wf")"
  [ -n "$n" ] || continue
  printf '%s\t%s\n' "$n" "$(basename "$wf")" >> "$names_file"
done

while IFS= read -r edge; do
  [ -n "$edge" ] || continue
  if ! cut -f1 "$names_file" | grep -qxF "$edge"; then
    fail "workflow_run edge '${edge}' names no workflow's name: — the grid will never re-render for it"
  fi
done <<< "$edges"

# Two files with the same `name:` means workflow_run fires for a workflow whose
# identity is ambiguous (and GitHub's UI shows two identical checks).
dupes="$(cut -f1 "$names_file" | sort | uniq -d)"
if [ -n "$dupes" ]; then
  fail "two or more workflows share a name: (${dupes//$'\n'/, }) — workflow_run cannot tell them apart"
fi

# ── 2. every evidence source is produced by the workflow it names ──────────
source_scan() {
  awk '/--source[[:space:]]/ { for (i = 1; i <= NF; i++) if ($i == "--source") { print $(i + 1); break } }' "$1"
}
sources_pr="$(source_scan "$REPORTER")"
sources_pub="$(source_scan "$PUBLISHER")"
[ -n "$sources_pr" ] || fail "fork-governance.yml collects no evidence (--source <workflow>:<artifact>) — the grid would have no rows"
[ -n "$sources_pub" ] || fail "verdict-grid-publish.yml collects no evidence (--source <workflow>:<artifact>) — published grid would have no rows"
sources="$(printf '%s\n%s\n' "$sources_pr" "$sources_pub" | sed '/^$/d' | sort -u)"

while IFS= read -r src; do
  [ -n "$src" ] || continue
  wf_file="${src%%:*}"
  artifact="${src#*:}"
  target="$WORKFLOWS_DIR/$wf_file"
  if [ ! -f "$target" ]; then
    fail "evidence source names '${wf_file}', which is not a workflow in .github/workflows/"
    continue
  fi
  if ! produced_artifacts "$target" | grep -qxF "$artifact"; then
    # The producer may delegate to a reusable workflow, which then uploads it.
    via=""
    while IFS= read -r call; do
      [ -n "$call" ] || continue
      src="$(reusable_source "$call")" || exit 2
      if produced_artifacts "$src" | grep -qxF "$artifact"; then via="$call"; break; fi
    done <<< "$(reusable_calls "$target")"
    [ -n "$via" ] || fail "evidence source '${wf_file}:${artifact}' names an artifact '${wf_file}' never uploads"
  fi
  if ! grep -Eq '^[[:space:]]+pull_request:' "$target"; then
    fail "'${wf_file}' does not run on pull_request, so its artifact exists only after a push"
  fi
done <<< "$sources"

# ── 3. the reporter's tool pins equal the producers' pins ──────────────────
# Tool pin in the reporter (grid identity) vs the pin in the workflow that
# actually runs that tool. A mismatch makes the profile hash disagree with the
# binary that produced the findings.
check_pin() { # check_pin REPORTER REPORT_FLAG PRODUCER VAR [INPUT]
  # INPUT: when PRODUCER delegates to a reusable workflow, the input through
  # which it passes the pin; the reusable's own default is not the verdict's.
  local report="$1" flag="$2" producer="$3" var="$4" input="${5:-}"
  local in_reporter in_producer pin_name="$var"
  in_reporter="$({ grep -o -- "${flag}[[:space:]]\\+[0-9a-f]\\{40\\}" "$report" || true; } | awk '{print $2}' | head -n1)"
  in_producer="$(env_pin "$WORKFLOWS_DIR/$producer" "$var" | head -n1)"
  if [ -z "$in_reporter" ]; then
    fail "$(basename "$report") names no ${flag}; its findings would carry no tool identity"
    return
  fi
  if [ -z "$in_producer" ] && [ -n "$input" ] && [ -n "$(reusable_calls "$WORKFLOWS_DIR/$producer")" ]; then
    in_producer="$(env_pin "$WORKFLOWS_DIR/$producer" "$input" | head -n1)"
    pin_name="with: $input"
    if [ -z "$in_producer" ]; then
      fail "'${producer}' calls a reusable workflow without passing ${input}, so the scan runs that workflow's default, not the ${flag} ${in_reporter:0:12} the verdict claims; pass 'with: ${input}: <sha>'"
      return
    fi
  fi
  if [ -z "$in_producer" ]; then
    fail "'${producer}' pins no ${var}, but the verdict claims ${flag} ${in_reporter:0:12}"
    return
  fi
  if [ "$in_reporter" != "$in_producer" ]; then
    fail "${flag} in $(basename "$report") (${in_reporter:0:12}) does not match ${pin_name} in ${producer} (${in_producer:0:12})"
  fi
}
for report in "$REPORTER" "$PUBLISHER"; do
  check_pin "$report" --hypatia-ref hypatia-scan.yml HYPATIA_SHA hypatia-ref
  check_pin "$report" --panic-ref static-analysis-gate.yml PANIC_ATTACK_SHA
  check_pin "$report" --pons-ref static-analysis-gate.yml PONS_SHA
done

# ── 4. no tool pinned at two commits in this repository ────────────────────
# panic-attack is pinned once for its scan and once for patch-bridge triage; the
# pair must agree, which is why both use env.PANIC_ATTACK_SHA. A literal second
# pin in another workflow is the clash this catches.
pins_file="$(mktemp)"
trap 'rm -rf "$names_file" "$pins_file" "$reusable_cache"' EXIT
for wf in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
  [ -e "$wf" ] || continue
  for var in HYPATIA_SHA HYPATIA_REF PANIC_ATTACK_SHA PONS_SHA; do
    v="$(env_pin "$wf" "$var" | head -n1)"
    [ -n "$v" ] || continue
    case "$v" in
      *'${{'* | 'latest' | 'HEAD') continue ;; # floating by design, documented at the pin
    esac
    pin_name="$var"; [[ "$var" != HYPATIA_REF ]] || pin_name=HYPATIA_SHA
    printf '%s\t%s\t%s\n' "$pin_name" "$v" "$(basename "$wf")" >> "$pins_file"
  done
  checkout_rows="$(hypatia_checkouts "$wf")" || {
    fail "$(basename "$wf") checkout refs could not be inspected"
    continue
  }
  while IFS=$'\t' read -r pin site; do
    [[ -n "$pin" ]] || continue
    if [[ "$pin" = '!' ]]; then
      fail "$(basename "$wf") Hypatia checkout ${site}"
    else
      printf '%s\t%s\t%s\n' HYPATIA_SHA "$pin" "$(basename "$wf") (Hypatia checkout ${site})" >> "$pins_file"
    fi
  done <<< "$checkout_rows"
  # A reusable call's hypatia-ref input pins the same scanner as HYPATIA_SHA.
  if [ -n "$(reusable_calls "$wf")" ]; then
    v="$(env_pin "$wf" hypatia-ref | head -n1)"
    case "$v" in
      "" | *'${{'* | 'latest' | 'HEAD') ;;
      *) printf '%s\t%s\t%s\n' HYPATIA_SHA "$v" "$(basename "$wf") (with: hypatia-ref)" >> "$pins_file" ;;
    esac
  fi
done
while IFS= read -r var; do
  [ -n "$var" ] || continue
  n="$(awk -F'\t' -v v="$var" '$1 == v {print $2}' "$pins_file" | sort -u | grep -c . || true)"
  if [ "$n" -gt 1 ]; then
    detail="$(awk -F'\t' -v v="$var" '$1 == v {printf "%s %s; ", substr($2, 1, 12), $3}' "$pins_file")"
    fail "${var} is pinned at ${n} different commits in this repository (${detail%; })"
  fi
done <<< "$(cut -f1 "$pins_file" | sort -u)"

# HYPATIA_SHA and HYPATIA_REF are two spellings of the same pin.
h_sha="$(env_pin "$WORKFLOWS_DIR/hypatia-scan.yml" HYPATIA_SHA | head -n1)"
h_ref="$(env_pin "$WORKFLOWS_DIR/hypatia-scan.yml" HYPATIA_REF | head -n1)"
if [ -n "$h_sha" ] && [ -n "$h_ref" ] && [ "$h_sha" != "$h_ref" ]; then
  fail "hypatia-scan.yml pins HYPATIA_SHA ${h_sha:0:12} and HYPATIA_REF ${h_ref:0:12}"
fi

# ── verdict ────────────────────────────────────────────────────────────────
if [ "$errors" -ne 0 ]; then
  echo "check-workflow-edges: ${errors} broken edge(s)" >&2
  exit 1
fi
echo "check-workflow-edges: all workflow edges resolve; $(printf '%s' "$edges" | grep -c . || true) workflow_run edge(s), $(printf '%s' "$sources" | grep -c . || true) evidence source(s)"
