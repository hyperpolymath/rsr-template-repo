#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# PR #244: preserve the runtime-policy fold and the standards lock repair.
# Usage: bash tests/workflows/standards_lock_test.sh
# Requires Bun with Bun.YAML; runs offline without fetching actions.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v bun >/dev/null 2>&1 || { echo 'FAIL: Bun is required' >&2; exit 1; }

bun run - "$REPO_DIR" <<'JS'
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const repo = process.argv[2];
const workflowPath = (name) => `.github/workflows/${name}.yml`;
const readYaml = (path) => Bun.YAML.parse(readFileSync(resolve(repo, path), "utf8"));
const lock = readYaml(".github/workflows/actions.lock");
const retired = workflowPath("runtime-policy");

assert.equal(existsSync(resolve(repo, retired)), false,
  "newly minted repos must not receive the retired runtime-policy workflow");
assert.equal(Object.hasOwn(lock.workflows, retired), false,
  "deleting runtime-policy.yml must also remove its orphaned lock record");
console.log("PASS: the retired runtime workflow and its lock record are absent");

// Check the six callers touched by this PR, including job-level uses: entries.
// Compare pins across callers and with the lock rather than freezing one SHA,
// so a future coordinated standards upgrade does not require rewriting tests.
const callers = [
  ["governance", "governance"],
  ["hypatia-scan", "hypatia"],
  ["mirror", "mirror"],
  ["rust-ci", "rust-ci"],
  ["scorecard", "scorecard"],
  ["secret-scanner", "scan"],
];
const pins = new Set();
for (const [name, job] of callers) {
  const path = workflowPath(name);
  const workflow = readYaml(path);
  const uses = workflow.jobs[job].uses;
  const prefix = `hyperpolymath/standards/.github/workflows/${name}-reusable.yml@`;
  assert.ok(uses.startsWith(prefix), `${path}: must call the corresponding standards workflow`);
  const pin = uses.slice(prefix.length);
  assert.match(pin, /^[a-f0-9]{40}$/, `${path}: standards must be pinned to a full commit`);
  assert.notEqual(pin, "6a9251037760690d56022ad6fab2cfe9d887dd76",
    `${path}: do not restore the standards revision with invalid action lock refs`);
  pins.add(pin);
  const dependency = `hyperpolymath/standards@${pin}`;
  assert.deepEqual(lock.workflows[path], [dependency], `${path}: lock must match its caller`);
  const record = lock.dependencies[dependency];
  assert.ok(record, `${path}: the standards dependency record must exist`);
  assert.equal(record.ref, pin, `${path}: lock ref must match the caller's commit`);
  assert.equal(record.commit, `sha1-${pin}`, `${path}: lock must resolve the pinned commit`);

  // The upgraded reusable's actions must remain resolvable after relocking.
  assert.ok(Array.isArray(record.uses) && record.uses.length > 0,
    `${dependency}: retain the reusable's transitive action references`);
  for (const action of record.uses) {
    assert.match(action, /^[^/]+\/[^/@]+@[a-f0-9]{40}$/, "nested actions use repository roots and commits");
    assert.ok(lock.dependencies[action], `${dependency}: dangling action reference ${action}`);
  }
  console.log(`PASS: ${name} caller and transitive lock records agree`);
}
assert.equal(pins.size, 1, "all six changed callers must use the same standards revision");

// These nine SHA-keyed action records caused GitHub's 'invalid lockfile pin'
// startup failure. Their ref must retain the repaired tag while their immutable
// commit remains unchanged. The standards record itself legitimately uses a SHA.
const repairedActions = [
  ["actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9", "v6.1.0"],
  ["actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "v7.0.1"],
  ["editorconfig-checker/action-editorconfig-checker@51f63319f592f97930c73d9c46184d20bd206393", "v3.0.0"],
  ["erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124", "v1.24.1"],
  ["github/codeql-action@b96794f015dfd88f77b49b1c93e0fa7110f94c63", "v4.38.0"],
  ["goto-bus-stop/setup-zig@abea47f85e598557f500fa1fd2ab7464fcb39406", "v2.2.1"],
  ["ossf/scorecard-action@2d1146689b8cda280b9bc96326124645441f03bc", "v2.4.4"],
  ["swatinem/rust-cache@6323deb102c322ba6fcbdcafc7e3dddab59af2b6", "v2.9.2"],
  ["webfactory/ssh-agent@e83874834305fe9a4a2997156cb26c5de65a8555", "v0.10.0"],
];
const standards = lock.dependencies[`hyperpolymath/standards@${[...pins][0]}`];
for (const [key, tag] of repairedActions) {
  const [action, sha] = key.split("@");
  const record = lock.dependencies[key];
  assert.ok(record, `${key}: repaired dependency must still exist`);
  assert.ok(standards.uses.includes(key), `${key}: repaired record must remain reachable`);
  assert.equal(record.ref, tag, `${key}: retain the tag ref that fixes runner startup`);
  assert.equal(record.commit, `sha1-${sha}`, `${key}: relocking must not change the action commit`);
  const alias = lock.dependencies[`${action}@${tag}`];
  if (alias) {
    assert.equal(alias.commit, record.commit, `${key}: tag and SHA aliases must resolve identically`);
  }
  console.log(`PASS: ${action} uses ${tag} and preserves its immutable commit`);
}
JS
