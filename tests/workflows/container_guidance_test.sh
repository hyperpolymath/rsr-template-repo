#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# The base-image guidance must agree with the gate that enforces it.
# scripts/check-container-pins.sh rejects a tag with no digest (`:latest` and
# version tags included). It accepts `@sha256:<digest>` and also a tag followed by
# a digest; this guidance asks for the digest alone, because the tag adds nothing. Guidance that tells a
# reader or an assistant to use `:latest` therefore sends every child to a red
# gate (seen as a CodeRabbit finding on two downstream pull requests).
#
# A guidance line that names a wolfi-base or static image (bare, `:latest` or a
# version tag) must also say it is pinned by digest. Controls run on a fixture first: the old
# wording must FAIL and the new wording must PASS, so the check cannot go green
# by matching nothing.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# stale_lines FILE... — print "file:line:text" for each floating reference that
# is not accompanied by a statement that it is pinned by digest.
stale_lines() {
    local f
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        grep -nE 'cgr\.dev/chainguard/(wolfi-base|static)' "$f" \
            | grep -viE 'sha256|digest' \
            | sed "s|^|$f:|" || true
    done
}

printf '%s\n' '- Base image: `cgr.dev/chainguard/wolfi-base:latest`.' > "$scratch/old.md"
printf '%s\n' '- Base image: `cgr.dev/chainguard/wolfi-base`, pinned by digest (`@sha256:<digest>`).' > "$scratch/new.md"
[[ -n "$(stale_lines "$scratch/old.md")" ]] || fail 'control: the old wording was not flagged'
printf '%s\n' '- Base image: `cgr.dev/chainguard/wolfi-base`.' > "$scratch/bare.md"
printf '%s\n' '- Base image: `cgr.dev/chainguard/wolfi-base:2026.11.14`.' > "$scratch/ver.md"
printf '%s\n' '- Runtime: `cgr.dev/chainguard/static:latest`.' > "$scratch/static.md"
[[ -n "$(stale_lines "$scratch/bare.md")" ]] || fail 'control: a bare reference was not flagged'
[[ -n "$(stale_lines "$scratch/ver.md")" ]] || fail 'control: a version-tagged reference was not flagged'
[[ -n "$(stale_lines "$scratch/static.md")" ]] || fail 'control: a static:latest reference was not flagged'
[[ -z "$(stale_lines "$scratch/new.md")" ]] || fail 'control: the new wording was flagged'
echo 'PASS: controls (old wording flagged, new wording accepted)'

files=(
    "$repo/.clinerules"
    "$repo/.github/copilot-instructions.md"
    "$repo/build/container/README.adoc"
    "$repo/docs/practice/AI-CONVENTIONS.adoc"
)
found=$(stale_lines "${files[@]}")
if [[ -n "$found" ]]; then
    printf '%s\n' "$found" >&2
    fail 'base-image guidance recommends a floating reference without a digest pin'
fi
echo 'PASS: base-image guidance says digest-pinned'
