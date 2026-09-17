#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# run-all.sh — execute every www/tests/check-*.sh probe in order.
# Exit non-zero on the first failing check (all checks are listed at the end).

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0
ran=0
for check in "$here"/check-*.sh; do
    [ -f "$check" ] || continue
    ran=$((ran + 1))
    name="$(basename "$check")"
    if bash "$check"; then
        echo "PASS  $name"
    else
        echo "FAIL  $name" >&2
        fail=$((fail + 1))
    fi
done

echo "www/tests: ran $ran check(s), $fail failure(s)"
[ "$fail" -eq 0 ]
