#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Silence + Firing + Setup-error test suite for:
#   - .github/actions/squabble/{action.yml,install.sh,run.sh}
#   - scripts/check-required-contexts.sh
#
# Proves offline that tampered downloads, forged attestations, non-zero squabble
# exits, phantom ruleset contexts, path-filtered required workflows, and
# `gh pr merge --admin` bypasses all fail loudly with the expected exit code.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok() { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1"; }

assert_rc() { # assert_rc <want> <label> <cmd...>
  local want="$1" label="$2" got=0
  shift 2
  "$@" >"$WORK/out" 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    ok "$label"
  else
    bad "$label (wanted exit $want, got $got)"
    sed 's/^/        /' "$WORK/out"
  fi
}

echo "=== 1. squabble install.sh & run.sh guards ==="
# Source install.sh without running main
# shellcheck source=../../.github/actions/squabble/install.sh
source "$REPO_ROOT/.github/actions/squabble/install.sh"

printf 'tampered binary bytes' > "$WORK/bad-bin"
if verify_digest "$WORK/bad-bin" >"$WORK/out" 2>&1; then
  bad "Firing: tampered sha256 must fail verify_digest"
else
  ok "Firing: tampered sha256 rejected by verify_digest"
fi

printf '[]\n' > "$WORK/empty-att.json"
if check_attestation_json "$WORK/empty-att.json" >"$WORK/out" 2>&1; then
  bad "Firing: empty attestation array must fail check_attestation_json"
else
  ok "Firing: empty attestation array rejected by check_attestation_json"
fi

cat > "$WORK/good-att.json" <<JSON
[{"verificationResult":{"statement":{"subject":[{"name":"$SQUABBLE_ASSET","digest":{"sha256":"$SQUABBLE_SHA256"}}]}}}]
JSON
if check_attestation_json "$WORK/good-att.json" >"$WORK/out" 2>&1; then
  ok "Silence: matching SLSA subject digest accepted by check_attestation_json"
else
  bad "Silence: matching SLSA subject digest rejected"
fi

cat > "$WORK/wrong-att.json" <<JSON
[{"verificationResult":{"statement":{"subject":[{"name":"$SQUABBLE_ASSET","digest":{"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}}]}}}]
JSON
if check_attestation_json "$WORK/wrong-att.json" >"$WORK/out" 2>&1; then
  bad "Firing: mismatched SLSA subject digest must fail"
else
  ok "Firing: mismatched SLSA subject digest rejected"
fi

cat > "$WORK/standin-squabble" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--Blocking" ]; then exit 4; fi
printf 'args:%s\n' "$*"
exit 0
SH
chmod +x "$WORK/standin-squabble"

OUT_FILE="$WORK/gh-out"
: > "$OUT_FILE"
assert_rc 0 "Silence: run.sh propagates exit 0 and literal args" \
  env GITHUB_OUTPUT="$OUT_FILE" SQUABBLE_BIN="$WORK/standin-squabble" SQUABBLE_ARGS=$'chains\n.=' \
  bash "$REPO_ROOT/.github/actions/squabble/run.sh"
if grep -q '^exit-code=0$' "$OUT_FILE"; then
  ok "Silence: run.sh writes exit-code=0 to GITHUB_OUTPUT"
else
  bad "Silence: run.sh missing exit-code=0"
fi

: > "$OUT_FILE"
assert_rc 4 "Firing: run.sh propagates blocking exit 4 (dead upstream / cycle)" \
  env GITHUB_OUTPUT="$OUT_FILE" SQUABBLE_BIN="$WORK/standin-squabble" SQUABBLE_ARGS="--Blocking" \
  bash "$REPO_ROOT/.github/actions/squabble/run.sh"
if grep -q '^exit-code=4$' "$OUT_FILE"; then
  ok "Firing: run.sh writes exit-code=4 to GITHUB_OUTPUT"
else
  bad "Firing: run.sh missing exit-code=4"
fi

echo "=== 2. check-required-contexts.sh: Silence, Firing, Setup (0 / 1 / 2) ==="
assert_rc 0 "Silence: live repository required contexts pass" \
  bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$REPO_ROOT"

assert_rc 2 "Setup (exit 2): missing repo directory exits 2" \
  bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$WORK/does-not-exist"

# Mutant A: phantom workflow file
mkdir -p "$WORK/m_phantom/.github/workflows" "$WORK/m_phantom/.machine_readable"
printf 'scan / gitleaks => .github/workflows/missing.yml\n' > "$WORK/m_phantom/.machine_readable/required-contexts-allow.txt"
assert_rc 1 "Firing: missing producer workflow exits 1" \
  bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$WORK/m_phantom"

# Mutant B: path-filtered required workflow (strands PRs!)
mkdir -p "$WORK/m_paths/.github/workflows" "$WORK/m_paths/.machine_readable"
printf 'scan / gitleaks => .github/workflows/secret-scanner.yml\n' > "$WORK/m_paths/.machine_readable/required-contexts-allow.txt"
cat > "$WORK/m_paths/.github/workflows/secret-scanner.yml" <<'YML'
name: Secret Scanner
on:
  pull_request:
    paths:
      - 'src/**'
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YML
assert_rc 1 "Firing: path-filtered required workflow exits 1" \
  bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$WORK/m_paths"

# Mutant C: unmapped ruleset context
mkdir -p "$WORK/m_ruleset/.github/workflows" "$WORK/m_ruleset/.github/rulesets" "$WORK/m_ruleset/.machine_readable"
printf 'scan / gitleaks => .github/workflows/secret-scanner.yml\n' > "$WORK/m_ruleset/.machine_readable/required-contexts-allow.txt"
cat > "$WORK/m_ruleset/.github/workflows/secret-scanner.yml" <<'YML'
name: Secret Scanner
on:
  pull_request:
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YML
cat > "$WORK/m_ruleset/.github/rulesets/extra.json" <<'JSON'
{"rules":[{"parameters":{"required_status_checks":[{"context":"phantom / coverage"}]},"type":"required_status_checks"}]}
JSON
assert_rc 1 "Firing: unmapped ruleset required_status_checks context exits 1" \
  bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$WORK/m_ruleset"

# Mutant D: admin merge bypass in workflow
mkdir -p "$WORK/m_admin/.github/workflows" "$WORK/m_admin/.machine_readable"
printf 'scan / gitleaks => .github/workflows/secret-scanner.yml\n' > "$WORK/m_admin/.machine_readable/required-contexts-allow.txt"
cp "$WORK/m_ruleset/.github/workflows/secret-scanner.yml" "$WORK/m_admin/.github/workflows/secret-scanner.yml"
ADMIN_FLAG="--""admin"
cat > "$WORK/m_admin/.github/workflows/bad-merge.yml" <<YML
name: Bad Automerge
on:
  pull_request:
jobs:
  merge:
    runs-on: ubuntu-latest
    steps:
      - run: gh pr merge 1 --squash $ADMIN_FLAG
YML
assert_rc 1 "Firing: 'gh pr merge --admin' bypass in workflow exits 1" \
  bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$WORK/m_admin"

# Mutant E: multi-line backslash-continued admin bypass + array `on:` form
mkdir -p "$WORK/m_multiline/.github/workflows" "$WORK/m_multiline/.machine_readable"
printf 'scan / gitleaks => .github/workflows/secret-scanner.yml\n' > "$WORK/m_multiline/.machine_readable/required-contexts-allow.txt"
cat > "$WORK/m_multiline/.github/workflows/secret-scanner.yml" <<'YML'
name: Secret Scanner
on: [push, pull_request]
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YML
assert_rc 0 "Silence: array-form 'on: [push, pull_request]' accepted" \
  bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$WORK/m_multiline"

cat > "$WORK/m_multiline/.github/workflows/sneaky-merge.yml" <<YML
name: Sneaky Automerge
on: pull_request
jobs:
  merge:
    runs-on: ubuntu-latest
    steps:
      - run: |
          gh pr merge 1 --squash \\
            $ADMIN_FLAG
YML
assert_rc 1 "Firing: backslash-continued 'gh pr merge ... --admin' exits 1" \
  bash "$REPO_ROOT/scripts/check-required-contexts.sh" "$WORK/m_multiline"

echo "squabble_gate_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
