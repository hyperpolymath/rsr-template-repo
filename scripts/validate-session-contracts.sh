#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Validate the two session policies with their actual Nickel evaluator.
set -euo pipefail
command -v nickel >/dev/null || {
    echo "nickel is required to validate .k9.ncl session policies" >&2
    exit 2
}
for file in coordination.k9.ncl session/custom-checks.k9.ncl; do
    envelope_line=$(awk '/[^ ]/ { if ($0 == "K9!") print NR; exit }' "$file")
    if [[ -z "$envelope_line" ]]; then
        echo "$file: missing K9! envelope" >&2
        exit 1
    fi
    # K9! is a transport envelope, not a Nickel expression. These standalone
    # records have no imports; evaluation also exercises their field contracts.
    sed "${envelope_line}d" "$file" | nickel export --format json >/dev/null
    echo "$file: Nickel evaluation passed"
done
