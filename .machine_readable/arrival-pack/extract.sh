#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# extract.sh — the thin *reader* for the arrival-pack compiler.
#
# Projects the fields the CLAUDE.md arrival pack needs out of this repo's deed
# (<repo>_chora.deed: identity, clade, lineage, status, maturity, ecosystem,
# agentic) and the golden path in anchors/ANCHOR.a2ml into a single
# deterministic JSON document on stdout. The deed took over CLADE / ECOSYSTEM /
# AGENTIC / STATE .a2ml (rsr-template-repo#209); every deed read goes through
# scripts/deed-field.sh.
#
# This is a READER only — it authors nothing. The deed remains the single
# source of truth; arrival-pack.ncl renders this JSON into the CLAUDE.md region.
# Determinism (no timestamps) is required so the k9 drift check can byte-compare.
set -euo pipefail

ROOT="${1:-.}"
READ="$ROOT/scripts/deed-field.sh"
ANCHOR="$ROOT/.machine_readable/descriptiles/anchors/ANCHOR.a2ml"

DEED="$(bash "$READ" --find "$ROOT")" \
  || { echo "extract.sh: need exactly one *_chora.deed in $ROOT" >&2; exit 2; }
[ -f "$ANCHOR" ] || { echo "extract.sh: missing $ANCHOR" >&2; exit 2; }

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

# arr KEY FILE SEP -> join all quoted strings in the a2ml `KEY = [ ... ]` block
# (ANCHOR is not part of the deed). SEP is a literal multi-char string.
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

# The uuid is derived from the header :repo-uuid name, never stored (deed.abnf).
uuid_name="$(field '' repo-uuid)"
uuid=""
[ -z "$uuid_name" ] || uuid="$(uuidgen --sha1 --namespace @url --name "$uuid_name")"

# read_clauses -> the clauses this pack reads, one token per line. Hashing only
# these keeps an unrelated deed edit (say a canon-pin bump) from reading as drift.
read_clauses() {
  local c
  bash "$READ" "$DEED" '' canonical-name
  printf '%s\n' "$uuid_name"
  for c in identity clade lineage forges status maturity ecosystem agentic; do
    bash "$READ" --clause "$DEED" "$c" || true
  done
}

isnot="$(items ecosystem not ' · ')"
[ -n "$isnot" ] || isnot="(not yet declared — add (ecosystem :not (…)) to the deed)"

jq -n \
  --arg canonical_name "$(field '' canonical-name)" \
  --arg prefixed_name  "$(field identity prefixed-name)" \
  --arg uuid           "$uuid" \
  --arg clade_primary  "$(field clade primary)" \
  --arg clade_secondary "$(items clade secondary ', ')" \
  --arg born           "$(field lineage born)" \
  --arg forge_gh       "$(field forges github)" \
  --arg purpose        "$(field ecosystem purpose)" \
  --arg isnot          "$isnot" \
  --arg pipeline_pos   "$(field ecosystem pipeline-position)" \
  --arg chain          "$(field ecosystem chain)" \
  --arg coordination   "$(field ecosystem coordination)" \
  --arg phase          "$(field status phase)" \
  --arg maturity       "$(field maturity level)" \
  --arg deed           "$(basename "$DEED")" \
  --arg golden_smoke   "$(arr 'smoke-test-command' "$ANCHOR" ' && ')" \
  --arg golden_crit    "$(arr 'success-criteria' "$ANCHOR" '; ')" \
  --arg h_deed         "$(read_clauses | hash12)" \
  --arg h_anchor       "$(hash12 < "$ANCHOR")" \
  '$ARGS.named'
