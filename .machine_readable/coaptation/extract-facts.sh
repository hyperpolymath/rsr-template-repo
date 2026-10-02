#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# extract-facts.sh — the DESCRIPTIVE-side atomiser for Coaptation.
#
# Step 1 of the build path (descriptile half): give each descriptive fact a
# STABLE ID. Reads this repo's deed (<repo>_chora.deed, which took over
# CLADE / STATE / ECOSYSTEM / AGENTIC .a2ml in rsr-template-repo#209) through
# scripts/deed-field.sh, plus descriptiles/anchors/ANCHOR, and projects the
# fields that can bear witness to contractile obligations into one
# deterministic JSON document. Fact IDs keep their old family prefixes
# (clade., state., ecosystem., agentic.) so witness-map.ncl and coapt.ncl
# address them unchanged.
#
# READER only — authors nothing; the deed remains the single source of truth.
#
# Output (stdout): { "facts": [ {id,family,key,value,present} ... ],
#                   "provenance": { <source>: <hash> } }
set -euo pipefail
# A failed $(…) inside a function or assignment must stop the run, not read as "".
shopt -s inherit_errexit

ROOT="${1:-.}"
READ="$ROOT/scripts/deed-field.sh"
ANCHOR="$ROOT/.machine_readable/descriptiles/anchors/ANCHOR.a2ml"

DEED="$(bash "$READ" --find "$ROOT")" \
  || { echo "extract-facts.sh: need exactly one *_chora.deed in $ROOT" >&2; exit 2; }
[ -f "$ANCHOR" ] || { echo "extract-facts.sh: missing $ANCHOR" >&2; exit 2; }

# field PATH KEY -> the deed value, or "" when the clause or key is absent
# (rc 1); an unreadable deed or a usage error (rc 2) fails the run instead
field() {
  local rc=0
  bash "$READ" "$DEED" "$1" "$2" || rc=$?
  [ "$rc" -le 1 ] || return "$rc"
}

# items PATH KEY SEP -> the deed list :KEY ( … ) joined by the literal SEP,
# "" when absent; fails like field() when the deed cannot be read
items() {
  local out="" item first=1 list rc=0
  list="$(bash "$READ" --list "$DEED" "$1" "$2")" || rc=$?
  [ "$rc" -le 1 ] || return "$rc"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    if [ "$first" -eq 1 ]; then out="$item"; first=0; else out="$out$3$item"; fi
  done <<< "$list"
  printf '%s' "$out"
}

# scalar KEY FILE -> first `KEY = "value"` or unquoted `KEY = value` (anchored);
# ANCHOR only, which is not part of the deed
scalar() {
  local v
  v="$(grep -oP "^$1 = \"\K[^\"]+" "$2" | head -1 || true)"
  if [ -z "$v" ]; then
    v="$(grep -oP "^$1 = \K[^\"#]+" "$2" | head -1 | sed 's/[[:space:]]*$//' || true)"
  fi
  printf '%s' "$v"
}

# arr KEY FILE SEP -> join all quoted strings in the a2ml `KEY = [ ... ]` block
arr() {
  local key="$1" file="$2" sep="${3:-, }" out="" i
  local -a vals
  mapfile -t vals < <(
    awk -v k="$key" '
      index($0, k" = [")==1 {grab=1}
      grab {print}
      grab && /\]/ {exit}
    ' "$file" | grep -oP '"[^"]*"' | sed 's/^"//; s/"$//' || true
  )
  for i in "${!vals[@]}"; do
    if [ "$i" -eq 0 ]; then out="${vals[$i]}"; else out="$out$sep${vals[$i]}"; fi
  done
  printf '%s' "$out"
}

# hash12 -> short content hash of stdin (drift provenance)
hash12() { sha256sum | cut -c1-12; }

# read_clauses -> the deed clauses read below, one token per line, so that an
# unrelated deed edit (say a canon-pin bump) does not read as drift
read_clauses() {
  local c
  bash "$READ" "$DEED" '' canonical-name
  bash "$READ" "$DEED" '' repo-uuid
  for c in identity clade lineage forges status maturity ecosystem agentic; do
    bash "$READ" --clause "$DEED" "$c" || [ "$?" -eq 1 ] || return 2
  done
}

# id <TAB> value rows. Empty value => present:false in jq below.
emit() { printf '%s\t%s\n' "$1" "$2"; }

# fact ID CMD… -> emit ID with the output of CMD; a failed CMD stops the run,
# where `emit ID "$(CMD)"` would discard its exit status
fact() {
  local id="$1" v
  shift
  v="$("$@")"
  emit "$id" "$v"
}

# The uuid is derived from the header :repo-uuid name, never stored (deed.abnf).
uuid_name="$(field '' repo-uuid)"
uuid=""
[ -z "$uuid_name" ] || uuid="$(bash "$READ" --uuid "$DEED")"

rows="$(
  # --- identity / lineage: (identity) (clade) (lineage) (forges) ---
  emit 'clade.uuid'             "$uuid"
  fact 'clade.canonical-name'   field '' canonical-name
  fact 'clade.prefixed-name'    field identity prefixed-name
  fact 'clade.primary'          field clade primary
  fact 'clade.born'             field lineage born
  fact 'clade.forge-github'     field forges github
  # --- where things are now: (status) (maturity) ---
  fact 'state.phase'            field status phase
  fact 'state.maturity'         field maturity level
  # --- where it sits + IS-NOT boundary: (ecosystem) ---
  fact 'ecosystem.type'             field ecosystem position-type
  fact 'ecosystem.position'         field ecosystem pipeline-position
  fact 'ecosystem.coordination'     field ecosystem coordination
  fact 'ecosystem.what-this-is-not' items ecosystem not ' · '
  # --- may I act / integrity posture: (agentic) ---
  fact 'agentic.fail-closed'                       field agentic/integrity fail-closed
  fact 'agentic.allow-silent-skip'                 field agentic/integrity allow-silent-skip
  fact 'agentic.require-evidence-per-step'         field agentic/integrity require-evidence-per-step
  fact 'agentic.release-claim-requires-hard-pass'  field agentic/integrity release-claim-requires-hard-pass
  fact 'agentic.default-mode'                      field agentic/methodology default-mode
  # --- ANCHOR: semantic authority + golden path ---
  fact 'anchor.authority'            scalar 'authority' "$ANCHOR"
  fact 'anchor.policy'               scalar 'policy' "$ANCHOR"
  fact 'anchor.project'              scalar 'project' "$ANCHOR"
  fact 'anchor.golden-path'          arr 'smoke-test-command' "$ANCHOR" ' && '
  fact 'anchor.success-criteria'     arr 'success-criteria' "$ANCHOR" '; '
  fact 'anchor.must-have-anchor'     scalar 'must-have-anchor' "$ANCHOR"
  fact 'anchor.must-have-golden-path' scalar 'must-have-golden-path' "$ANCHOR"
)"

h_deed="$(read_clauses | hash12)"
h_anchor="$(hash12 < "$ANCHOR")"

printf '%s\n' "$rows" | jq -R -s \
  --arg deed      "$h_deed" \
  --arg anchor    "$h_anchor" \
  '
  {
    facts: (
      split("\n") | map(select(length > 0)) | map(split("\t")) | map({
        id:      .[0],
        family:  (.[0] | split(".")[0]),
        key:     (.[0] | split(".") | .[1:] | join(".")),
        value:   (.[1] // ""),
        present: ((.[1] // "") | length > 0)
      })
    ),
    provenance: { deed: $deed, anchor: $anchor }
  }
'
