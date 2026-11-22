#!/usr/bin/env bun
// SPDX-License-Identifier: MPL-2.0
//
// Assert every workflow action ref is pinned — inline SHA, or via actions.lock.
//
// What counts as "pinned" changed when GitHub introduced workflow lockfiles. A
// ref is pinned if EITHER it is an inline 40-hex SHA, OR
// .github/workflows/actions.lock resolves it to one FOR THAT WORKFLOW. The
// previous inline-only rule rejected all 40 of this repo's own refs, so
// `Workflow Security Linter` was red on main permanently — and every repo minted
// from this template inherited both the tag-form workflows and the gate that
// rejects them.
//
// "Resolves it" is checked in full, not by the ref's mere presence in the file:
//   1. the workflow has its own entry under `workflows:` in the lock — GitHub
//      onboards workflows one at a time, and a workflow with no entry resolves
//      its tag at run time, whatever other workflows are locked;
//   2. that entry lists the ref (or the ref's repository root, for a subpath
//      action such as github/codeql-action/init);
//   3. the `dependencies:` section holds the same ref with a
//      `commit: 'sha1-<40 hex>'`.
//
// Runtime: Bun — the estate's first-choice runtime per LANGUAGE-POLICY.adoc §1
// (Bun > Deno > pnpm > npm). Plain JavaScript, not TypeScript: TypeScript is
// banned estate-wide (owner ruling; CLAUDE.md banned-languages table). Note
// LANGUAGE-POLICY.adoc §1.2 currently claims TS is "permitted under Bun" — that
// line is wrong and should be corrected; the ban stands.
//
// Python was the first draft of this script and is banned with no exceptions.
//
// Each of these is load-bearing and has a mutation test in
// tests/workflows/check_action_pinning_test.sh:
//
//   `-?` in the pattern. `- uses:` is the list-item form and by far the most
//   common; a `\s+uses:` pattern silently misses every one of them. Estate
//   memory records this exact failure — "green linter != full SHA-pinning". A
//   gate that cannot see the common case reads as coverage and enforces nothing.
//
//   Flow mappings. `- { uses: x@v1 }` and `{ name: n, uses: x@v1 }` are the same
//   step as the block form. The key is also recognised after `{` or `,`, and the
//   value stops at `,` or `}`.
//
//   Quoted values. `uses: 'x@v1'` and `uses: x@v1` are the same YAML scalar; the
//   quotes are removed before the ref is compared.
//
//   Case-insensitive comparison. Workflows write `SonarSource/...`; the lockfile
//   records `sonarsource/...`. Action refs are case-insensitive in practice, so
//   a case-sensitive match reports a false positive on a correctly-pinned action.
//
//   Only *.yml / *.yaml, depth 1. A bare recursive grep also reads actions.lock
//   (whose `uses:` keys are lockfile entries, not refs) and *.yml.template
//   (whose tag ref is deliberate and resolved at mint time). Both were reported
//   as unpinned, which made the gate unsatisfiable the moment a lockfile existed.
//
//   The actions/github-script exemption compares the repository name exactly.
//   A substring test would let any repository whose name contains that text skip
//   every check.
//
// Exit 0 if every ref is pinned, 1 otherwise, listing file:line: ref (reason).

import { readdirSync, readFileSync, existsSync, statSync } from "node:fs";
import { join } from "node:path";

const WF = ".github/workflows";
const LOCK = join(WF, "actions.lock");
// A `uses:` key at the start of a line (after an optional list dash) or after
// `{` / `,` in a flow mapping. The value stops at whitespace, `#`, `,` or `}`.
const USES = /(?:^\s*-?\s*|[{,]\s*)uses:\s*([^\s#,}]+)/g;
const SHA = /@[a-f0-9]{40}$/;
// The lock writes a resolved commit as `sha1-` plus 40 lower-case hex digits.
const LOCK_COMMIT = /^sha1-[0-9a-f]{40}$/;
const EXEMPT_PREFIX = ["./", "$", "docker://"];
const EXEMPT_REPO = "actions/github-script";

function workflowFiles() {
  if (!existsSync(WF) || !statSync(WF).isDirectory()) return [];
  return readdirSync(WF)
    .filter((f) => f.endsWith(".yml") || f.endsWith(".yaml"))
    .sort();
}

// `'x'` -> `x`; the lock quotes every key and value it writes.
function unquote(s) {
  return s.length > 1 && s.startsWith("'") && s.endsWith("'") ? s.slice(1, -1) : s;
}

// A YAML plain or quoted scalar -> its string value (matching quotes removed).
function decode(raw) {
  const q = raw[0];
  if ((q === "'" || q === '"') && raw.length > 1 && raw.endsWith(q)) {
    return raw.slice(1, -1);
  }
  return raw;
}

// Line-based read of the two sections of actions.lock that matter:
//   workflows:    "<path>": [ "<ref>", ... ]
//   dependencies: "<ref>":  { commit: "sha1-..." , ... }
// Keys and refs are lower-cased: action refs are case-insensitive.
function parseLock(text) {
  const workflows = new Map(); // path -> Set of refs
  const deps = new Map(); // ref -> commit string ("" when absent)
  let section = "";
  let key = "";
  for (const line of text.split("\n")) {
    const body = line.trim();
    if (body === "" || body.startsWith("#")) continue;
    const indent = line.length - line.trimStart().length;
    if (indent === 0) {
      section = body.endsWith(":") ? body.slice(0, -1) : "";
      key = "";
    } else if (indent === 4 && body.endsWith(":")) {
      key = unquote(body.slice(0, -1)).toLowerCase();
      if (section === "workflows" && !workflows.has(key)) workflows.set(key, new Set());
      if (section === "dependencies" && !deps.has(key)) deps.set(key, "");
    } else if (indent === 8 && key !== "") {
      if (section === "workflows" && body.startsWith("- ")) {
        workflows.get(key).add(unquote(body.slice(2).trim()).toLowerCase());
      } else if (section === "dependencies" && body.startsWith("commit:")) {
        deps.set(key, unquote(body.slice("commit:".length).trim()));
      }
    }
  }
  return { workflows, deps };
}

function main() {
  if (!existsSync(WF)) {
    console.log("no .github/workflows — nothing to check");
    return 0;
  }

  let lock = null;
  if (existsSync(LOCK)) {
    lock = parseLock(readFileSync(LOCK, "utf8"));
    console.log(
      `lockfile present: ${lock.workflows.size} workflow(s), ${lock.deps.size} resolved ref(s)`,
    );
  } else {
    console.log("no lockfile — every ref must be an inline 40-character SHA");
  }

  const bad = [];
  for (const file of workflowFiles()) {
    const wf = join(WF, file);
    const lockKey = `${WF}/${file}`.toLowerCase();
    readFileSync(wf, "utf8")
      .split("\n")
      .forEach((line, i) => {
        for (const m of line.matchAll(USES)) {
          const ref = decode(m[1]);
          const fail = (why) => bad.push(`${wf}:${i + 1}: ${ref} (${why})`);
          if (EXEMPT_PREFIX.some((p) => ref.startsWith(p))) continue;
          const at = ref.lastIndexOf("@");
          const name = at === -1 ? ref : ref.slice(0, at);
          const tag = at === -1 ? "" : ref.slice(at + 1);
          if (name.toLowerCase() === EXEMPT_REPO) continue;
          if (SHA.test(ref)) continue;
          if (lock === null) {
            fail("not an inline SHA and there is no lockfile");
            continue;
          }
          const entry = lock.workflows.get(lockKey);
          if (entry === undefined) {
            fail("this workflow has no entry in actions.lock");
            continue;
          }
          // subpath actions key by repo root: github/codeql-action/init -> github/codeql-action
          const root = name.split("/").slice(0, 2).join("/");
          const candidates = [ref, `${root}@${tag}`].map((c) => c.toLowerCase());
          const locked = candidates.find((c) => entry.has(c));
          if (locked === undefined) {
            fail("not listed under this workflow in actions.lock");
          } else if (!LOCK_COMMIT.test(lock.deps.get(locked) ?? "")) {
            fail("actions.lock has no resolved sha1 commit for it");
          }
        }
      });
  }

  if (bad.length) {
    console.log("\nERROR: these action refs are neither SHA-pinned nor resolved by the lockfile:");
    for (const b of bad) console.log(`  ${b}`);
    console.log("\nEither pin to a full commit SHA, or run `gh actions-lock` so the");
    console.log("lockfile resolves the ref for that workflow.");
    return 1;
  }
  console.log("all action refs are pinned");
  return 0;
}

process.exit(main());
