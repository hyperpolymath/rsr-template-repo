#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Regression tests for PR #245's standards re-pin and nine action tag refs.
# Usage: bash tests/workflows/standards_lock_test.sh
# Requires Mike Farah yq v4 and the gawk used by check-lock-sync.sh.
# Tests are offline; upstream tag resolution is not simulated.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
lock="$repo/.github/workflows/actions.lock"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Exact commit values matter here: the repair changes only action refs, never
# their resolved commits. Keep the repaired records in one reviewable table.
while read -r action commit tag; do
    export record_key="$action@$commit"
    actual=$(yq -r '.dependencies[strenv(record_key)].ref' "$lock")
    [ "$actual" = "$tag" ] || fail "$record_key: expected tag $tag, got $actual"
    actual=$(yq -r '.dependencies[strenv(record_key)].commit' "$lock")
    [ "$actual" = "sha1-$commit" ] || fail "$record_key: resolved commit changed"

    # If the lock also records the action under its tag, both records must
    # resolve to the same commit and repository identity.
    export tag_key="$action@$tag"
    alias_record=$(yq -o json -I 0 '.dependencies[strenv(tag_key)]' "$lock")
    if [ "$alias_record" != null ]; then
        pinned=$(yq -o json -I 0 '.dependencies[strenv(record_key)] | [.commit, .owner_id, .repo_id]' "$lock")
        tagged=$(yq -o json -I 0 '.dependencies[strenv(tag_key)] | [.commit, .owner_id, .repo_id]' "$lock")
        [ "$pinned" = "$tagged" ] || fail "$record_key: tag alias changes the resolved identity"
    fi
done <<'RECORDS'
actions/cache 55cc8345863c7cc4c66a329aec7e433d2d1c52a9 v6.1.0
actions/checkout 3d3c42e5aac5ba805825da76410c181273ba90b1 v7.0.1
editorconfig-checker/action-editorconfig-checker 51f63319f592f97930c73d9c46184d20bd206393 v3.0.0
erlef/setup-beam 54075bcc5e249e4758d363f27d099f55d843f124 v1.24.1
github/codeql-action b96794f015dfd88f77b49b1c93e0fa7110f94c63 v4.38.0
goto-bus-stop/setup-zig abea47f85e598557f500fa1fd2ab7464fcb39406 v2.2.1
ossf/scorecard-action 2d1146689b8cda280b9bc96326124645441f03bc v2.4.4
swatinem/rust-cache 6323deb102c322ba6fcbdcafc7e3dddab59af2b6 v2.9.2
webfactory/ssh-agent e83874834305fe9a4a2997156cb26c5de65a8555 v0.10.0
RECORDS
echo 'PASS: all nine repaired actions retain their pinned commits and agree with tag aliases'

standards_key=$(yq -r '.dependencies | keys | .[] | select(test("^hyperpolymath/standards@"))' "$lock")
export standards_key
standards_pin=${standards_key#hyperpolymath/standards@}
[[ "$standards_pin" =~ ^[0-9a-f]{40}$ ]] || fail 'expected exactly one full standards commit pin'
[ "$(yq -r '.dependencies[strenv(standards_key)].ref' "$lock")" = "$standards_pin" ] || fail 'reusable workflow ref must retain its full SHA'
[ "$(yq -r '.dependencies[strenv(standards_key)].commit' "$lock")" = "sha1-$standards_pin" ] || fail 'standards ref and commit disagree'

while read -r workflow reusable; do
    export workflow_key=".github/workflows/$workflow.yml"
    actual=$(yq -r '.jobs[].uses' "$repo/$workflow_key")
    [ "$actual" = "hyperpolymath/standards/.github/workflows/$reusable-reusable.yml@$standards_pin" ] \
        || fail "$workflow: reusable workflow does not match the standards lock pin"
    actual=$(yq -o json -I 0 '.workflows[strenv(workflow_key)]' "$lock")
    [ "$actual" = "[\"$standards_key\"]" ] || fail "$workflow: lock mapping differs from the workflow"
done <<'WORKFLOWS'
governance governance
hypatia-scan hypatia-scan
mirror mirror
rust-ci rust-ci
scorecard scorecard
secret-scanner secret-scanner
WORKFLOWS

# Exercise the repository's lock consumer with all transitive dependencies,
# then show it rejects a stale reusable pin and a missing dependency record.
bash "$repo/scripts/check-lock-sync.sh" "$repo/.github/workflows" > "$scratch/sync.log" 2>&1 \
    || { cat "$scratch/sync.log" >&2; fail 'updated lock is not in sync or transitively closed'; }
mkdir -p "$scratch/workflows"
cp -a "$repo/.github/workflows/." "$scratch/workflows/"
sed "s/$standards_pin/0000000000000000000000000000000000000000/g" \
    "$repo/.github/workflows/governance.yml" > "$scratch/workflows/governance.yml"
if bash "$repo/scripts/check-lock-sync.sh" "$scratch/workflows" > "$scratch/stale.log" 2>&1; then
    fail 'a workflow with a stale standards pin was accepted'
fi
grep -q 'refs missing from the lockfile' "$scratch/stale.log" || fail 'stale pin failed for an unrelated reason'
cp "$repo/.github/workflows/governance.yml" "$scratch/workflows/governance.yml"
yq -I 4 'del(.dependencies[strenv(standards_key)])' "$lock" > "$scratch/workflows/actions.lock"
if bash "$repo/scripts/check-lock-sync.sh" "$scratch/workflows" > "$scratch/missing.log" 2>&1; then
    fail 'a standards pin without its dependency record was accepted'
fi
grep -q 'DANGLING EDGES' "$scratch/missing.log" || fail 'missing standards record failed for an unrelated reason'
echo 'PASS: six reusable callers match the closed standards lock; stale pins and missing records are rejected'
