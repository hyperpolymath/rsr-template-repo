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

ROOT="${1:-.}"
READ="$ROOT/scripts/deed-field.sh"
ANCHOR="$ROOT/.machine_readable/descriptiles/anchors/ANCHOR.a2ml"

DEED="$(bash "$READ" --find "$ROOT")" \
  || { echo "extract-facts.sh: need exactly one *_chora.deed in $ROOT" >&2; exit 2; }
[ -f "$ANCHOR" ] || { echo "extract-facts.sh: missing $ANCHOR" >&2; exit 2; }

# field PATH KEY -> the deed value, or "" when the clause or key is absent
field() { bash "$READ" "$DEED" "$1" "$2" || true; }

# items PATH KEY SEP -> the deed list :KEY ( … ) joined by the literal SEP
items() {
  local out="" item first=1
  while IFS= read -r item; do
    if [ "$first" -eq 1 ]; then out="$item"; first=0; else out="$out$3$item"; fi
  done < <(bash "$READ" --list "$DEED" "$1" "$2" || true)
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
    bash "$READ" --clause "$DEED" "$c" || true
  done
}

# id <TAB> value rows. Empty value => present:false in jq below.
emit() { printf '%s\t%s\n' "$1" "$2"; }

# The uuid is derived from the header :repo-uuid name, never stored (deed.abnf).
uuid_name="$(field '' repo-uuid)"
uuid=""
[ -z "$uuid_name" ] || uuid="$(uuidgen --sha1 --namespace @url --name "$uuid_name")"

rows="$(
  # --- identity / lineage: (identity) (clade) (lineage) (forges) ---
  emit 'clade.uuid'             "$uuid"
  emit 'clade.canonical-name'   "$(field '' canonical-name)"
  emit 'clade.prefixed-name'    "$(field identity prefixed-name)"
  emit 'clade.primary'          "$(field clade primary)"
  emit 'clade.born'             "$(field lineage born)"
  emit 'clade.forge-github'     "$(field forges github)"
  # --- where things are now: (status) (maturity) ---
  emit 'state.phase'            "$(field status phase)"
  emit 'state.maturity'         "$(field maturity level)"
  # --- where it sits + IS-NOT boundary: (ecosystem) ---
  emit 'ecosystem.type'             "$(field ecosystem position-type)"
  emit 'ecosystem.position'         "$(field ecosystem pipeline-position)"
  emit 'ecosystem.coordination'     "$(field ecosystem coordination)"
  emit 'ecosystem.what-this-is-not' "$(items ecosystem not ' · ')"
  # --- may I act / integrity posture: (agentic) ---
  emit 'agentic.fail-closed'                       "$(field agentic/integrity fail-closed)"
  emit 'agentic.allow-silent-skip'                 "$(field agentic/integrity allow-silent-skip)"
  emit 'agentic.require-evidence-per-step'         "$(field agentic/integrity require-evidence-per-step)"
  emit 'agentic.release-claim-requires-hard-pass'  "$(field agentic/integrity release-claim-requires-hard-pass)"
  emit 'agentic.default-mode'                      "$(field agentic/methodology default-mode)"
  # --- ANCHOR: semantic authority + golden path ---
  emit 'anchor.authority'            "$(scalar 'authority' "$ANCHOR")"
  emit 'anchor.policy'               "$(scalar 'policy' "$ANCHOR")"
  emit 'anchor.project'              "$(scalar 'project' "$ANCHOR")"
  emit 'anchor.golden-path'          "$(arr 'smoke-test-command' "$ANCHOR" ' && ')"
  emit 'anchor.success-criteria'     "$(arr 'success-criteria' "$ANCHOR" '; ')"
  emit 'anchor.must-have-anchor'     "$(scalar 'must-have-anchor' "$ANCHOR")"
  emit 'anchor.must-have-golden-path' "$(scalar 'must-have-golden-path' "$ANCHOR")"
)"

printf '%s\n' "$rows" | jq -R -s \
  --arg deed      "$(read_clauses | hash12)" \
  --arg anchor    "$(hash12 < "$ANCHOR")" \
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
