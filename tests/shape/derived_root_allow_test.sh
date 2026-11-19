#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# derived_root_allow_test.sh — the DERIVED term of the root allowlist.
#
# standards 0-canon/TEMPLATE-APPLICABILITY-POLICY.adoc:
#   effective-allowlist(repo) = baseline ∪ { M : gate(M) ⊆ profile(repo).capabilities }
#
# scripts/check-root-shape.sh reads the second term from the vendored gate
# table and the repo's declared capabilities. Every case that ADMITS something
# is paired with one that must still REFUSE, because a widening gate that is
# only ever shown passing is indistinguishable from one that admits everything.
#
# Fixtures use the REAL vendored gate table and the REAL deed reader, not
# copies, so a gate-table change that alters what is derived shows up here.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$REPO/scripts/check-root-shape.sh"
GATES="$REPO/.machine_readable/template-capability-gates.toml"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
[ -f "$GATES" ] || fail "precondition: vendored gate table absent at $GATES"
GATES_SHA="$(sha256sum "$GATES" | awk '{print $1}')"

# fixture <dir>: a minimal conforming root with no profile and no gate table.
fixture() {
    local d="$1"
    mkdir -p "$d/.machine_readable"
    git -C "$d" init -q
    cat > "$d/.machine_readable/root-allow.txt" <<'ALLOW'
.git/
.machine_readable/
README.adoc
?docs/
ALLOW
    printf 'fixture\n' > "$d/README.adoc"
}
a2ml_profile() { # <dir> <body lines of [rsr-profile]>
    printf '[rsr-profile]\nversion = "1.0.0"\n%s\n' "$2" > "$1/.machine_readable/rsr-profile.a2ml"
}
vendor_gates() { cp "$GATES" "$1/.machine_readable/template-capability-gates.toml"; }
passes() { bash "$CHECKER" "$1" > "$WORK/out" 2>&1 && grep -q '^PASS:' "$WORK/out"; }
fails_naming() { # <dir> <name> : exit 1 and the name appears
    local rc=0
    bash "$CHECKER" "$1" > "$WORK/out" 2>&1 || rc=$?
    [ "$rc" -eq 1 ] || { cat "$WORK/out" >&2; return 1; }
    grep -qF -- "$2" "$WORK/out"
}
exits_2() { local rc=0; bash "$CHECKER" "$1" > "$WORK/out" 2>&1 || rc=$?; [ "$rc" -eq 2 ]; }

# 1. No profile: today's behaviour. A root Cargo.toml is drift, and the failure
#    says which capability would admit it.
F="$WORK/noprofile"; fixture "$F"; vendor_gates "$F"
printf '[package]\n' > "$F/Cargo.toml"
fails_naming "$F" "Cargo.toml" || fail "no profile: root Cargo.toml was not drift"
grep -q "declares 'rust'" "$WORK/out" || fail "no profile: failure did not name the gating capability"

# 2. capabilities = [] (common-signal's profile at mint): unchanged, still drift.
a2ml_profile "$F" 'capabilities = []'
fails_naming "$F" "Cargo.toml" || fail "empty capabilities: root Cargo.toml was not drift"

# 3. Declared rust: Cargo.toml and Cargo.lock are derived and the root passes.
a2ml_profile "$F" 'capabilities = ["rust"]'
printf '# lock\n' > "$F/Cargo.lock"
passes "$F" || { cat "$WORK/out" >&2; fail "declared rust: Cargo.toml/Cargo.lock were not admitted"; }
grep -q 'derived: Cargo.toml Cargo.lock' "$WORK/out" || fail "PASS line did not report the derived entries"

# 4. ...but derivation admits only what the table gates: a planted stray, and a
#    root crates/ (no gate row names it), are still drift under rust.
printf 'x\n' > "$F/STRAY.adoc"
fails_naming "$F" "STRAY.adoc" || fail "declared rust: a stray root file was admitted"
rm "$F/STRAY.adoc"
mkdir -p "$F/crates/core"; : > "$F/crates/core/Cargo.toml"
fails_naming "$F" "crates/" || fail "declared rust: an ungated root crates/ was admitted"
rm -rf "$F/crates"

# 5. A derived entry is OPTIONAL: declaring rust does not require Cargo.toml at
#    the root (a workspace keeps it in <crate>/; MISSING is check-rsr-profile's job).
rm "$F/Cargo.toml" "$F/Cargo.lock"
passes "$F" || { cat "$WORK/out" >&2; fail "declared rust: absent root Cargo.toml wrongly failed"; }
printf '[package]\n' > "$F/Cargo.toml"

# 6. Multi-line capability array with comments (the shape the template shipped).
a2ml_profile "$F" 'capabilities = [  # comment
  "bash",   # scripts
  "rust",
]'
passes "$F" || { cat "$WORK/out" >&2; fail "multi-line capabilities array was not read"; }

# 7. remove wins over capabilities: rust removed, Cargo.toml is drift again.
a2ml_profile "$F" 'capabilities = ["rust"]
remove = ["rust"]'
fails_naming "$F" "Cargo.toml" || fail "remove = [rust] did not withdraw the derived entry"

# 8. A preset expands from the table's [presets]; an unknown preset is exit 2.
a2ml_profile "$F" 'preset = "rust-cli"'
passes "$F" || { cat "$WORK/out" >&2; fail "preset rust-cli did not admit Cargo.toml"; }
a2ml_profile "$F" 'preset = "no-such-preset"'
exits_2 "$F" || fail "unknown preset was not a setup error"

# 9. Capabilities declared but no vendored table: STRICTER, never looser.
a2ml_profile "$F" 'capabilities = ["rust"]'
rm "$F/.machine_readable/template-capability-gates.toml"
fails_naming "$F" "Cargo.toml" || fail "no gate table: Cargo.toml was admitted anyway"
grep -q 'no gate table' "$WORK/out" || fail "no gate table: the notice was not emitted"
vendor_gates "$F"
rm "$F/Cargo.toml"

# 10. Only ROOT-LEVEL alternatives are derived. governance-tier's rows include
#     0-canon/GOVERNANCE.adoc and 3-practice/MAINTAINERS.adoc; those must not
#     license a root 0-canon/ or 3-practice/. Its root-level AUDIT.adoc must.
a2ml_profile "$F" 'capabilities = ["governance-tier"]'
printf 'audit\n' > "$F/AUDIT.adoc"
passes "$F" || { cat "$WORK/out" >&2; fail "governance-tier: root AUDIT.adoc was not admitted"; }
mkdir -p "$F/0-canon"; : > "$F/0-canon/GOVERNANCE.adoc"
fails_naming "$F" "0-canon/" || fail "governance-tier: a nested alternative licensed its root ancestor"
rm -rf "$F/0-canon"
#     ffi's row is src/interface/ffi/: declaring ffi must not admit a root src/.
a2ml_profile "$F" 'capabilities = ["ffi"]'
rm "$F/AUDIT.adoc"
mkdir -p "$F/src/interface/ffi"; : > "$F/src/interface/ffi/x.zig"
fails_naming "$F" "src/" || fail "ffi: the nested row src/interface/ffi/ admitted a root src/"
rm -rf "$F/src"

# 11. The deed carries the profile, and its (canon :gates-sha256) pin binds the
#     vendored table: matching pin passes, any other pin is exit 2.
D="$WORK/deed"; fixture "$D"; vendor_gates "$D"
printf '[package]\n' > "$D/Cargo.toml"
deed() { # <pin>
    cat > "$D/fx_chora.deed" <<DEED
; SPDX-License-Identifier: MPL-2.0
(repo-deed
  :canonical-name "fx"
  (canon :version "0.0.0" :gates-sha256 "$1")
  (rsr-profile
    :version "1.0.0"
    :capabilities ("rust")))
DEED
}
sed -i 's|^README.adoc$|README.adoc\nfx_chora.deed|' "$D/.machine_readable/root-allow.txt"
deed "$GATES_SHA"
passes "$D" || { cat "$WORK/out" >&2; fail "deed profile with a matching gates pin did not admit Cargo.toml"; }
grep -q 'fx_chora.deed (rsr-profile' "$WORK/out" || fail "PASS line did not name the deed as the profile source"
deed "0000000000000000000000000000000000000000000000000000000000000000"
exits_2 "$D" || fail "a vendored table that does not match the deed's gates pin was not refused"
grep -q 'gates-sha256' "$WORK/out" || fail "pin mismatch error did not name the pin"

# 12. The deed wins over a legacy .a2ml (same order as check-rsr-profile.sh).
deed "$GATES_SHA"
a2ml_profile "$D" 'capabilities = []'
passes "$D" || { cat "$WORK/out" >&2; fail "deed profile did not take precedence over the legacy .a2ml"; }

# 13. Two deeds cannot both carry the profile: exit 2.
cp "$D/fx_chora.deed" "$D/other_chora.deed"
exits_2 "$D" || fail "two *_chora.deed files were not a setup error"
rm "$D/other_chora.deed"

# 14. A root-level GLOB alternative is never derived: the real table has none
#     today, so a synthetic one proves the guard. Membership is by exact name,
#     so the stray must still fail AND the derived set must not list "*" or "*.zig".
G="$WORK/glob"; fixture "$G"
printf '[gates]\n"*|*.zig" = "zig"\n"build.zig" = "zig"\n' > "$G/.machine_readable/template-capability-gates.toml"
a2ml_profile "$G" 'capabilities = ["zig"]'
: > "$G/build.zig"
passes "$G" || { cat "$WORK/out" >&2; fail "synthetic table: a literal root-level alternative was not derived"; }
grep -qE "derived: build\.zig$" "$WORK/out" || fail "a glob alternative was reported as derived: $(grep derived: "$WORK/out")"
: > "$G/STRAY.adoc"
fails_naming "$G" "STRAY.adoc" || fail "a root-level glob alternative was derived and admitted a stray"

# 15. The template's own vendored table is the one its deed pins (lockstep).
if bash "$REPO/scripts/is-template-tree.sh" "$REPO"; then
    pin="$(bash "$REPO/scripts/deed-field.sh" "$(bash "$REPO/scripts/deed-field.sh" --find "$REPO")" canon gates-sha256)"
    [ "$pin" = "$GATES_SHA" ] || fail "vendored gate table sha256 $GATES_SHA is not the deed's (canon :gates-sha256) $pin"
fi

echo "PASS: derived root allowlist admits declared, root-level gated entries only; stricter on missing data; pinned to the canon"
