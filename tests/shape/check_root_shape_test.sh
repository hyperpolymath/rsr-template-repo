#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check_root_shape_test.sh — prove scripts/check-root-shape.sh can FAIL.
#
# The gate went one-directional for months and nobody noticed, because a gate
# that only ever passes looks identical to a gate that works. These cases pin
# both directions and the '?' optional marker.

set -euo pipefail

CHECKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/check-root-shape.sh"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.name "RSR fixture"
git -C "$FIXTURE" config user.email "fixture@example.invalid"

mkdir -p "$FIXTURE/machine-readable"
cat > "$FIXTURE/machine-readable/root-allow.txt" <<'ALLOW'
# fixture allowlist
.git/
machine-readable/
README.adoc
?OPTIONAL-THING.adoc
ALLOW
printf 'fixture\n' > "$FIXTURE/README.adoc"

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. A conforming root passes.
bash "$CHECKER" "$FIXTURE" | grep -q '^PASS:' || fail "conforming fixture did not pass"

# 2. An entry at root that is not allow-listed fails, and is named.
printf 'stray\n' > "$FIXTURE/STRAY.adoc"
if out=$(bash "$CHECKER" "$FIXTURE" 2>&1); then
    fail "stray root entry did not fail the gate"
fi
grep -q 'STRAY.adoc' <<<"$out" || fail "failure did not name the stray entry"
rm "$FIXTURE/STRAY.adoc"

# 3. A REQUIRED allowlist entry that is absent fails, and is named.
#    This is the direction that was missing, and the reason the allowlist rotted.
mv "$FIXTURE/README.adoc" "$FIXTURE/machine-readable/README.adoc.parked"
if out=$(bash "$CHECKER" "$FIXTURE" 2>&1); then
    fail "missing required entry did not fail the gate"
fi
grep -q 'README.adoc' <<<"$out" || fail "failure did not name the missing entry"
mv "$FIXTURE/machine-readable/README.adoc.parked" "$FIXTURE/README.adoc"

# 4. An OPTIONAL entry that is absent passes. Capability-gated and template-only
#    material is legitimately missing in a conforming repo.
bash "$CHECKER" "$FIXTURE" | grep -q '^PASS:' || fail "absent ?optional entry wrongly failed"

# 5. A git-ignored root entry is not drift: the allowlist governs tracked shape,
#    not build output. (A .tmp probe once made this gate look broken when it
#    was the probe that was wrong.)
printf '*.tmp\n' > "$FIXTURE/.gitignore"
printf 'x\n' > "$FIXTURE/build-output.tmp"
sed -i 's|^README.adoc$|README.adoc\n.gitignore|' "$FIXTURE/machine-readable/root-allow.txt"
bash "$CHECKER" "$FIXTURE" | grep -q '^PASS:' || fail "git-ignored root entry was wrongly treated as drift"

echo "PASS: check-root-shape.sh fails in both directions and honours '?'"
