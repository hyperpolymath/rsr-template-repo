#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# PR #244 configuration regressions: the retired runtime policy must not ship,
# and governance must run for pull requests targeting any branch with a locked
# checkout of metadatastician/standards at a full 40-hex SHA.
# Usage: bash tests/workflows/governance_policy_test.sh
# Requires Bun; parses local YAML only.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v bun >/dev/null 2>&1 || { echo 'FAIL: Bun is required' >&2; exit 1; }

bun run - "$REPO_DIR" <<'JS'
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const workflows = resolve(process.argv[2], ".github/workflows");
const readYaml = (name) => Bun.YAML.parse(readFileSync(resolve(workflows, name), "utf8"));
const governance = readYaml("governance.yml");
const lock = readYaml("actions.lock");

for (const extension of ["yml", "yaml"]) {
  const retired = `runtime-policy.${extension}`;
  assert.equal(existsSync(resolve(workflows, retired)), false,
    `${retired} must not be copied into newly minted repositories`);
  assert.equal(Object.hasOwn(lock.workflows, `.github/workflows/${retired}`), false,
    `actions.lock must not retain the retired ${retired} record`);
}
console.log("PASS: runtime policy workflow and lock records are retired");

// Check the parsed event, rather than grep for 'branches': push deliberately
// retains its branch filter, while pull_request must have no branch/path/type
// restrictions. Missing pull_request must fail as well as a filtered event.
assert.ok(Object.hasOwn(governance.on, "pull_request"),
  "governance must be triggered by pull requests");
assert.deepEqual(governance.on.pull_request ?? {}, {},
  "governance must accept pull requests targeting any branch without filters");
assert.deepEqual(governance.on.push.branches, ["main", "master"],
  "removing the pull-request branch filter must preserve the push filter");
assert.ok(Object.hasOwn(governance.on, "workflow_dispatch"),
  "manual governance dispatch must remain available");
console.log("PASS: unrestricted pull requests coexist with filtered pushes and manual dispatch");

// Governance must pin metadatastician/standards at a full 40-hex SHA and lock
// every step-level action it invokes in actions.lock.
const steps = governance.jobs.governance.steps ?? [];
const standardsCheckout = steps.find(
  (s) => s.with && /^(metadatastician|hyperpolymath)\/standards$/.test(String(s.with.repository ?? ""))
);
assert.ok(standardsCheckout, "governance must check out standards policy scripts");
assert.match(String(standardsCheckout.with.ref ?? ""), /^[a-f0-9]{40}$/,
  "governance must pin standards at a full 40-hex commit SHA");
const checkoutUse = String(standardsCheckout.uses ?? "");
assert.ok(
  (lock.workflows[".github/workflows/governance.yml"] ?? []).includes(checkoutUse),
  "governance's lock record must match its checkout action"
);
assert.ok(lock.dependencies[checkoutUse]?.commit,
  "governance's checkout action must have a corresponding locked dependency commit");
console.log("PASS: governance executes the pinned standards policy with locked actions");
JS
