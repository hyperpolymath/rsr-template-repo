#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# deed-field.sh — read one field out of a repo deed (<repo>_chora.deed).
#
# The repo deed holds what the descriptiles CLADE / META / ECOSYSTEM / STATE /
# AGENTIC .a2ml files used to hold (rsr-template-repo#209). This is the one
# shell reader for it, so that every gate, extractor and recipe asks the same
# question the same way. It is a READER: it never writes the deed.
#
# Usage:
#   deed-field.sh DEED PATH KEY           first value of :KEY in the clause at PATH
#   deed-field.sh --list DEED PATH KEY    the items of the list :KEY ( … ), one per line
#   deed-field.sh --clause DEED PATH      the clause, one token per line (for hashing)
#   deed-field.sh --has DEED PATH         exit 0 iff the clause exists
#   deed-field.sh --find [DIR]            print the one *_chora.deed in DIR (default .)
#
# PATH names clauses below (repo-deed …), slash-separated: `status`,
# `agentic/integrity`, `meta/maintenance-axes`. An empty PATH is (repo-deed …)
# itself, so `deed-field.sh DEED "" canonical-name` reads the header.
#
# KEY is matched only at the top level of that clause, never inside a nested
# clause: `status` :phase is the clause's own phase, not a (history (entry …))
# phase. Comments (`;` to end of line, outside strings) are ignored, layout is
# irrelevant, string escapes \" \\ \n \t are decoded, and the booleans #t / #f
# print as true / false, because every caller is a shell test. A tagged
# literal prints its string: `:repo-uuid #u5"github.com/o/r"` gives
# github.com/o/r, the uuid5 name (uuidgen --sha1 --namespace @url --name …).
#
# Exit: 0 found; 1 clause or key absent (nothing printed); 2 usage error or no
# readable deed. --find exits 1 unless exactly one deed is present.
set -euo pipefail

mode=value
case "${1:-}" in
  --list|--clause|--has) mode="${1#--}"; shift ;;
  --find)
    shopt -s nullglob
    deeds=("${2:-.}"/*_chora.deed)
    [ "${#deeds[@]}" -eq 1 ] || exit 1
    printf '%s\n' "${deeds[0]}"
    exit 0 ;;
esac

deed="${1:-}"; path="${2-}"; key="${3:-}"
if [ -z "$deed" ] || [ ! -r "$deed" ]; then
  echo "deed-field.sh: no readable deed: '${deed}'" >&2; exit 2
fi
if { [ "$mode" = value ] || [ "$mode" = list ]; } && [ -z "$key" ]; then
  echo "deed-field.sh: KEY is required" >&2; exit 2
fi

awk -v mode="$mode" -v path="$path" -v key="$key" '
BEGIN { RS = "\001" }
{
  # Tokenise: "(" ")" , S<string> , A<atom>. Comments are dropped here.
  s = $0; n = length(s); i = 1; nt = 0
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == ";") { while (i <= n && substr(s, i, 1) != "\n") i++; continue }
    if (c == "(" || c == ")") { tok[++nt] = c; i++; continue }
    if (c == "\"") {
      v = ""; i++
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\") {
          d = substr(s, i + 1, 1)
          if (d == "n") v = v "\n"; else if (d == "t") v = v "\t"; else v = v d
          i += 2; continue
        }
        if (c == "\"") break
        v = v c; i++
      }
      i++; tok[++nt] = "S" v; continue
    }
    if (c == " " || c == "\t" || c == "\r" || c == "\n") { i++; continue }
    v = ""
    while (i <= n) {
      c = substr(s, i, 1)
      if (c == " " || c == "\t" || c == "\r" || c == "\n" || c == "(" || c == ")" || c == "\"" || c == ";") break
      v = v c; i++
    }
    tok[++nt] = "A" v
  }
}
# Index of the ")" token that closes the clause opening at token o, or 0.
function close_of(o,   d, t) {
  d = 0
  for (t = o; t <= nt; t++) {
    if (tok[t] == "(") d++
    else if (tok[t] == ")") { d--; if (d == 0) return t }
  }
  return 0
}
# First direct child clause of the clause opening at o whose head is name.
function child(o, name,   e, t, d) {
  e = close_of(o); d = 0
  for (t = o + 1; t < e; t++) {
    if (tok[t] == "(") { if (d == 0 && tok[t + 1] == "A" name) return t; d++ }
    else if (tok[t] == ")") d--
  }
  return 0
}
# A value token rendered for output: the type tag dropped, #t/#f as true/false.
function show(x) {
  x = substr(x, 2)
  if (x == "#t") return "true"
  if (x == "#f") return "false"
  return x
}
END {
  o = 0
  for (t = 1; t <= nt; t++) if (tok[t] == "(" && tok[t + 1] == "Arepo-deed") { o = t; break }
  if (!o) exit 1
  if (path != "") {
    np = split(path, part, "/")
    for (p = 1; p <= np; p++) { o = child(o, part[p]); if (!o) exit 1 }
  }
  e = close_of(o)
  if (mode == "has") exit 0
  if (mode == "clause") { for (t = o; t <= e; t++) print tok[t]; exit 0 }
  d = 0
  for (t = o + 1; t < e; t++) {
    if (tok[t] == "(") { d++; continue }
    if (tok[t] == ")") { d--; continue }
    if (d != 0 || tok[t] != "A:" key) continue
    nx = tok[t + 1]
    if (mode == "value") {
      if (nx == "(" || nx == ")" || nx == "") exit 1
      # A tagged literal such as #u5"github.com/o/r" prints its string.
      if (nx ~ /^A#[a-z0-9]+$/ && substr(tok[t + 2], 1, 1) == "S") nx = tok[t + 2]
      print show(nx); exit 0
    }
    if (nx != "(") exit 1
    le = close_of(t + 1); ld = 0
    for (u = t + 2; u < le; u++) {
      if (tok[u] == "(") ld++
      else if (tok[u] == ")") ld--
      else if (ld == 0) print show(tok[u])
    }
    exit 0
  }
  exit 1
}
' "$deed"
