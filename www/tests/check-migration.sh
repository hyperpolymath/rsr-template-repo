#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-migration.sh — prove scripts/migrate-wellknown-to-www.sh honours the
# four required behaviours (rsr-template-repo#53 acceptance: "Migration
# handles identical, missing and divergent root/www copies without data
# loss"). Each scenario runs in a throwaway git repository.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MIGRATOR="$REPO_ROOT/scripts/migrate-wellknown-to-www.sh"
[ -f "$MIGRATOR" ] || { echo "migrator not found at $MIGRATOR" >&2; exit 1; }

fail=0
scenario() { # name -> fresh git repo path on stdout
    local dir; dir="$(mktemp -d)"
    git -C "$dir" init -q
    git -C "$dir" config user.email t@example.invalid
    git -C "$dir" config user.name t
    echo "$dir"
}
commit_all() { git -C "$1" add -A >/dev/null && git -C "$1" commit -qm fixture; }

# ── 1. identical copies: root removed, www kept, exit 0 ─────────────────────
d="$(scenario)"
mkdir -p "$d/.well-known" "$d/www/.well-known"
printf 'Contact: mailto:s@example.invalid\n' | tee "$d/.well-known/security.txt" > "$d/www/.well-known/security.txt"
commit_all "$d"
if (cd "$d" && bash "$MIGRATOR" >/dev/null); then
    [ ! -e "$d/.well-known/security.txt" ] && [ -f "$d/www/.well-known/security.txt" ] \
        && echo "ok: identical -> root removed, www kept" \
        || { echo "FAIL: identical scenario left wrong tree" >&2; fail=1; }
else
    echo "FAIL: identical scenario exited non-zero" >&2; fail=1
fi
rm -rf "$d"

# ── 2. root-only: moved into www, exit 0 ─────────────────────────────────────
d="$(scenario)"
mkdir -p "$d/.well-known/groove"
printf '{"service_id":"x"}\n' > "$d/.well-known/groove/manifest.json"
printf 'User-Agent: *\n' > "$d/.well-known/ai.txt"
commit_all "$d"
if (cd "$d" && bash "$MIGRATOR" >/dev/null); then
    [ -f "$d/www/.well-known/groove/manifest.json" ] && [ -f "$d/www/.well-known/ai.txt" ] \
        && [ ! -d "$d/.well-known" ] \
        && echo "ok: root-only -> moved (nested dirs too)" \
        || { echo "FAIL: root-only move incomplete" >&2; fail=1; }
else
    echo "FAIL: root-only scenario exited non-zero" >&2; fail=1
fi
rm -rf "$d"

# ── 3. www-only (no root): no-op, exit 0 ─────────────────────────────────────
d="$(scenario)"
mkdir -p "$d/www/.well-known"
printf 'Contact: mailto:s@example.invalid\n' > "$d/www/.well-known/security.txt"
commit_all "$d"
if (cd "$d" && bash "$MIGRATOR" >/dev/null) && [ -f "$d/www/.well-known/security.txt" ]; then
    echo "ok: www-only -> no-op"
else
    echo "FAIL: www-only scenario damaged tree or exited non-zero" >&2; fail=1
fi
rm -rf "$d"

# ── 4. divergent: BOTH preserved, exit 1 (conflict reported) ────────────────
d="$(scenario)"
mkdir -p "$d/.well-known" "$d/www/.well-known"
printf 'Contact: mailto:old@example.invalid\n' > "$d/.well-known/security.txt"
printf 'Contact: mailto:new@example.invalid\n' > "$d/www/.well-known/security.txt"
commit_all "$d"
if (cd "$d" && bash "$MIGRATOR" >/dev/null 2>&1); then
    echo "FAIL: divergent scenario must exit non-zero" >&2; fail=1
else
    if [ -f "$d/.well-known/security.txt" ] && [ -f "$d/www/.well-known/security.txt" ] \
       && grep -q old "$d/.well-known/security.txt" && grep -q new "$d/www/.well-known/security.txt"; then
        echo "ok: divergent -> both preserved, non-zero exit"
    else
        echo "FAIL: divergent scenario lost or overwrote content" >&2; fail=1
    fi
fi
rm -rf "$d"

exit "$fail"
