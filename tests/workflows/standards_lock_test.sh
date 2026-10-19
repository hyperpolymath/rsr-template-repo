#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Regression tests for PR #243: standards callers and their lock must move
# together, and SHA-keyed action records need tag refs to pass runner setup.
# Usage: bash tests/workflows/standards_lock_test.sh
# Requires Bun with Bun.YAML; runs offline without executing any actions.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v bun >/dev/null 2>&1 || { echo 'FAIL: Bun is required' >&2; exit 1; }

bun run - "$REPO_DIR" <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const repo = process.argv[2];
const readYaml = (path) => Bun.YAML.parse(readFileSync(resolve(repo, path), "utf8"));
const lock = readYaml(".github/workflows/actions.lock");

// These are the reviewed rollout values. Intentional standards/action upgrades
// should update the corresponding fixtures along with the workflow and lock.
const pin = "75bd5994470661a099df562d6d5ad2fe744dbd66";
const oldPin = "6a9251037760690d56022ad6fab2cfe9d887dd76";
const standardsKey = `hyperpolymath/standards@${pin}`;
const callers = [
  ["governance", "governance", "governance-reusable"],
  ["hypatia-scan", "hypatia", "hypatia-scan-reusable"],
  ["mirror", "mirror", "mirror-reusable"],
  ["rust-ci", "rust-ci", "rust-ci-reusable"],
  ["scorecard", "scorecard", "scorecard-reusable"],
  ["secret-scanner", "scan", "secret-scanner-reusable"],
];

for (const [name, job, callee] of callers) {
  const path = `.github/workflows/${name}.yml`;
  const workflow = readYaml(path);
  assert.equal(workflow.jobs[job].uses,
    `hyperpolymath/standards/.github/workflows/${callee}.yml@${pin}`,
    `${path}: call the intended reusable at the reviewed standards revision`);
  assert.deepEqual(lock.workflows[path], [standardsKey],
    `${path}: the lock must use the same revision under this workflow's own path`);
  console.log(`PASS: ${name} caller and workflow lock agree on the new pin`);
}

const standards = lock.dependencies[standardsKey];
assert.ok(standards, "the new standards key must have a dependency record");
// Reusable-workflow records intentionally retain SHA refs. Only action refs
// were converted to tags; applying that conversion to standards breaks the pin.
assert.equal(standards.ref, pin, "standards keeps its immutable SHA ref");
assert.equal(standards.commit, `sha1-${pin}`, "standards commit matches the new key");
assert.equal(standards.owner_id, 6759885);
assert.equal(standards.repo_id, 1116521501);
assert.ok(!Object.hasOwn(lock.dependencies, `hyperpolymath/standards@${oldPin}`),
  "remove the old standards dependency record when re-keying the lock");
assert.ok(Array.isArray(standards.uses) && standards.uses.length > 0,
  "re-keying must retain standards' transitive dependencies");
console.log("PASS: standards is re-keyed with a matching SHA ref and commit");

const actions = [
  ["actions/cache", "55cc8345863c7cc4c66a329aec7e433d2d1c52a9", "v6.1.0"],
  ["actions/checkout", "3d3c42e5aac5ba805825da76410c181273ba90b1", "v7.0.1"],
  ["editorconfig-checker/action-editorconfig-checker", "51f63319f592f97930c73d9c46184d20bd206393", "v3.0.0"],
  ["erlef/setup-beam", "54075bcc5e249e4758d363f27d099f55d843f124", "v1.24.1"],
  ["github/codeql-action", "b96794f015dfd88f77b49b1c93e0fa7110f94c63", "v4.38.0"],
  ["goto-bus-stop/setup-zig", "abea47f85e598557f500fa1fd2ab7464fcb39406", "v2.2.1"],
  ["ossf/scorecard-action", "2d1146689b8cda280b9bc96326124645441f03bc", "v2.4.4"],
  ["swatinem/rust-cache", "6323deb102c322ba6fcbdcafc7e3dddab59af2b6", "v2.9.2"],
  ["webfactory/ssh-agent", "e83874834305fe9a4a2997156cb26c5de65a8555", "v0.10.0"],
];

for (const [action, sha, tag] of actions) {
  const key = `${action}@${sha}`;
  const record = lock.dependencies[key];
  assert.ok(record, `${key}: retain the SHA-keyed record used by standards`);
  assert.equal(record.ref, tag,
    `${key}: use the release tag, never the record's own SHA as ref`);
  assert.equal(record.commit, `sha1-${sha}`,
    `${key}: correcting ref must not change the locked commit`);
  assert.ok(standards.uses.includes(key), `${key}: retain the standards dependency edge`);

  // Some actions also have tag-keyed records for direct callers. Repairing the
  // transitive SHA record must leave both ways of resolving that action aligned.
  const alias = lock.dependencies[`${action}@${tag}`];
  if (alias) {
    assert.deepEqual(record, alias, `${action}: SHA and tag records must agree`);
  }
  console.log(`PASS: ${action} uses ${tag} and retains its locked commit`);
}

// The new standards record is reachable only if every edge below it resolves.
// Walk the full subtree so a missing nested record cannot hide behind a valid
// direct caller/lock match. Limit this check to the dependency being upgraded.
const visited = new Set();
function assertClosed(key) {
  if (visited.has(key)) return;
  visited.add(key);
  const record = lock.dependencies[key];
  assert.ok(record, `${key}: dangling dependency below the new standards pin`);
  const edges = record.uses ?? [];
  assert.ok(Array.isArray(edges), `${key}: dependency uses must be a list`);
  for (const edge of edges) assertClosed(edge);
}
assertClosed(standardsKey);
console.log("PASS: the new standards dependency subtree has no dangling edges");
JS
