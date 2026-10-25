#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# The honesty lint (from hyperpolymath/proven-tests-and-benches): fail if any
# proof escape hatch appears in Idris2 sources or if '%default total' is absent.
#
# Exit codes (proven-tests-and-benches 3-outcome convention):
#   0  no escape hatches found across >= 1 .idr file
#   1  at least one escape hatch or missing '%default total' found
#   2  the scan could not be performed (missing directory or 0 .idr files — a
#      skip is NOT a pass)
set -uo pipefail

if [ "$#" -gt 0 ]; then
  SCOPE=("$@")
else
  SCOPE=(src verification .machine_readable/coaptation)
fi

LITERAL_PATTERNS='believe_me|assert_total|assert_smaller|%partial|%default (partial|covering)|unsafePerformIO|idris_crash'
PARTIAL_DECL='^[[:space:]]*((public )?export[[:space:]]+|private[[:space:]]+)?partial([[:space:]]|$)'
COVERING_DECL='^[[:space:]]*((public )?export[[:space:]]+|private[[:space:]]+)?covering([[:space:]]|$)'
COVERING_ALLOWED=()
HOLE_PATTERN='(^|[[:space:](=,[])\?[a-zA-Z_][a-zA-Z0-9_'"'"']*'

missing=0
for dir in "${SCOPE[@]}"; do
  if [ ! -d "$dir" ]; then
    echo "check-escape-hatches: scope directory '$dir' does not exist" >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "FAIL: NO SCAN WAS PERFORMED — the scan scope is incomplete." >&2
  echo "      A missing directory is not a clean result." >&2
  exit 2
fi

mapfile -t IDR_FILES < <(find "${SCOPE[@]}" -name '*.idr' -type f | sort)
if [ "${#IDR_FILES[@]}" -eq 0 ]; then
  echo "check-escape-hatches: 0 .idr files found in scope (${SCOPE[*]})" >&2
  echo "FAIL: NO SCAN WAS PERFORMED — an empty proof corpus is not a pass." >&2
  exit 2
fi

echo "Scanning ${#IDR_FILES[@]} Idris2 file(s) for proof escape hatches in: ${SCOPE[*]}"

hits=0

# strip_idr_line_comments <file>: emit lines with Idris2 '-- ...' comments
# blanked (preserving line numbers) so prose saying "do not use X" in a comment
# does not masquerade as an escape hatch while code occurrences still fire.
scan_idr_code() {
  local pattern="$1" f line_no=0 found=0
  for f in "${IDR_FILES[@]}"; do
    line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      code="${line%%--*}"
      if [[ "$code" =~ $pattern ]]; then
        printf '%s:%d:%s\n' "$f" "$line_no" "$line"
        found=1
      fi
    done < "$f"
  done
  return $(( 1 - found ))
}

if scan_idr_code "$LITERAL_PATTERNS"; then
  hits=1
fi

if scan_idr_code "$HOLE_PATTERN"; then
  hits=1
fi

if scan_idr_code "$PARTIAL_DECL"; then
  hits=1
fi

while IFS=: read -r f ln _; do
  [ -n "$f" ] || continue
  name="$(sed -n "$((ln + 1))p" "$f" | sed -E 's/^[[:space:]]*([^[:space:]:]+).*/\1/')"
  allowed=0
  for pair in "${COVERING_ALLOWED[@]}"; do
    [ "$pair" = "$f:$name" ] && allowed=1
  done
  if [ "$allowed" -eq 0 ]; then
    echo "$f:$ln: covering $name is not on the I/O allowlist"
    hits=1
  fi
done < <(grep -rnE "$COVERING_DECL" "${SCOPE[@]}" --include="*.idr" || true)

for f in "${IDR_FILES[@]}"; do
  if ! grep -qE '^%default total([[:space:]]|$)' "$f"; then
    echo "$f: missing '%default total'"
    hits=1
  fi
done

if [ "$hits" -ne 0 ]; then
  echo
  echo "FAIL: proof escape hatch found. Actually-Proven content may not use these."
  echo "      Banned: believe_me, assert_total, assert_smaller, %partial,"
  echo "              %default partial|covering, partial declarations,"
  echo "              covering outside the I/O allowlist,"
  echo "              unsafePerformIO, idris_crash, and hole syntax (?name)."
  echo "      Required: '%default total' in every .idr file."
  exit 1
fi

echo "OK: no proof escape hatches across ${#IDR_FILES[@]} file(s) in ${SCOPE[*]}"
