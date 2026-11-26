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
//   step as the block form. On a line that opens a flow mapping the key is also
//   recognised after `{` or `,`, and the value stops at `,` or `}`. In block form
//   the scalar runs to the end of the line (or a ` #` comment): a `,` is part of
//   it, so `x@<sha>,mutable` is a mutable tag, not a pinned SHA. `{ uses: ... }`
//   inside a comment or a quoted shell argument is not a step. A flow
//   collection left open at the end of a line continues on the deeper-indented
//   lines after it, and is read as one collection, so a step split across lines
//   is neither missed nor misread.
//
//   Quoted values. `uses: 'x@v1'` and `uses: x@v1` are the same YAML scalar; the
//   quotes are removed before the ref is compared, and a quoted scalar is read
//   to its real closing quote (`''` is an escaped `'`, not the end).
//
//   List dashes. `-` may be followed by a tab as well as a space.
//
//   Case. Workflows write `SonarSource/...`; the lockfile records
//   `sonarsource/...`, so the owner/repository part is compared case-
//   insensitively. The tag is compared exactly (git ref names are case-
//   sensitive), and so is the workflow path (ci.yml and CI.yml can coexist).
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
// The `uses` key of a block-form line as YAML may spell it: bare, single- or
// double-quoted, with optional blanks before the colon. The flow form decodes
// its keys in flowRefs, so a quoted key cannot skip the check in either.
const BLOCK_USES = /^(?:uses|'uses'|"uses")[ \t]*:/;
const FLOW_INDICATOR = "{}[],";
const DASH = /^-[ \t]+/;
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

// A YAML plain or quoted scalar -> its string value (matching quotes removed;
// `''` in a single-quoted scalar is one `'`). Double-quoted escapes are left as
// written: a `\` can never be part of a 40-hex SHA, so an escaped ref fails
// closed rather than open.
function decode(raw) {
  const q = raw[0];
  if ((q === "'" || q === '"') && raw.length > 1 && raw.endsWith(q)) {
    const body = raw.slice(1, -1);
    return q === "'" ? body.replaceAll("''", "'") : body;
  }
  return raw;
}

// A line with its leading blanks and list dashes removed. YAML separates a `-`
// from its entry with spaces or tabs, so `-<TAB>uses: x` is a list item too.
function stripDashes(line) {
  let s = line.trimStart();
  while (DASH.test(s)) s = s.replace(DASH, "");
  return s;
}

// Action refs are case-insensitive in the owner/repository part and case-
// sensitive in the tag (git ref names are), so lower-case only the former.
function normRef(ref) {
  const at = ref.lastIndexOf("@");
  return at === -1 ? ref.toLowerCase() : ref.slice(0, at).toLowerCase() + ref.slice(at);
}

// The value of a block-form `uses:` line, or null: the key sits at the start of
// the line after any list dashes; the scalar runs to a ` #` comment or the end
// of the line, so a `,` or `}` in it is part of the value, not a delimiter.
function blockUses(line) {
  const s = stripDashes(line);
  const key = BLOCK_USES.exec(s);
  if (key === null) return null;
  const rest = s.slice(key[0].length).trim();
  if (rest[0] === "'" || rest[0] === '"') {
    // quoteEnd reads past `''` and `\"`, so `'x@<sha>''tag'` is read whole.
    const end = quoteEnd(rest, 0);
    if (end < rest.length) return rest.slice(0, end + 1);
  }
  const hash = rest.search(/\s#/);
  return (hash === -1 ? rest : rest.slice(0, hash)).trim();
}

// Where a line's flow collection starts, or -1. A flow collection opens only
// where a value begins with `{` or `[`: at the start of the line (after any list
// dashes, or as a `,` continuation), or straight after a `key:`. A `{` later in
// a plain or quoted scalar (`run: echo '{ uses: x }'`) or in a comment is text.
function flowStart(line) {
  const s = stripDashes(line);
  if (s === "" || s[0] === "#") return -1;
  const base = line.length - s.length;
  if ("{[,".includes(s[0])) return base;
  let end;
  if (s[0] === "'" || s[0] === '"') {
    end = s.indexOf(s[0], 1);
    if (end === -1) return -1;
    end = s.slice(end + 1).search(/^[ \t]*:/) === 0 ? s.indexOf(":", end + 1) : -1;
  } else {
    end = s.search(/:(\s|$)/);
  }
  if (end === -1) return -1;
  const value = s.slice(end + 1).trimStart();
  return value[0] === "{" || value[0] === "[" ? line.length - value.length : -1;
}

// One flow token at t[i]: an indicator, a `:`, or a scalar (quoted or plain).
// A plain scalar stops at a flow indicator, at `: ` (a `:` before a blank, an
// indicator or the end), or at ` #`; a `#` with no blank before it is part of
// the value (YAML starts a comment only at ` #`), so `x@<sha>#tag` is read whole.
// Returns [token, next index]; a token is { p: indicator } or { v: raw scalar }.
function flowToken(t, i, afterQuoted) {
  const c = t[i];
  if (FLOW_INDICATOR.includes(c)) return [{ p: c }, i + 1];
  if (c === ":" && (afterQuoted || colonEnds(t, i))) return [{ p: ":" }, i + 1];
  if (c === "'" || c === '"') return quotedToken(t, i);
  return plainToken(t, i);
}

// A `:` that ends a key: followed by a blank, a flow indicator or the end.
function colonEnds(t, j) {
  if (t[j] !== ":") return false;
  return j + 1 >= t.length || /\s/.test(t[j + 1]) || FLOW_INDICATOR.includes(t[j + 1]);
}

// Index of the closing quote of the scalar opened at t[i] (or t.length):
// `\x` escapes in double quotes, `''` in single quotes.
function quoteEnd(t, i) {
  const c = t[i];
  let j = i + 1;
  while (j < t.length && t[j] !== c) {
    j += c === '"' && t[j] === "\\" ? 2 : 1;
  }
  if (c === "'" && t[j + 1] === "'") return quoteEnd(t, j + 1);
  return j;
}

function quotedToken(t, i) {
  const j = quoteEnd(t, i);
  return [{ v: t.slice(i, j + 1), q: true }, j + 1];
}

function plainEnds(t, j) {
  return FLOW_INDICATOR.includes(t[j]) || colonEnds(t, j) || (t[j] === "#" && /\s/.test(t[j - 1]));
}

function plainToken(t, i) {
  let j = i;
  while (j < t.length && !plainEnds(t, j)) j += 1;
  return [{ v: t.slice(i, j).trimEnd() }, j];
}

// The tokens of a flow collection, which may span lines; a ` #` comment runs to
// the end of its line.
function flowTokens(t) {
  const toks = [];
  let i = 0;
  while (i < t.length) {
    if (/\s/.test(t[i])) {
      i += 1;
      continue;
    }
    if (t[i] === "#" && (i === 0 || /\s/.test(t[i - 1]))) {
      const eol = t.indexOf("\n", i);
      if (eol === -1) break;
      i = eol;
      continue;
    }
    const [tok, next] = flowToken(t, i, toks.at(-1)?.q === true);
    toks.push(tok);
    i = next;
  }
  return toks;
}

// Whether toks[k] opens a `uses: <scalar>` pair: a scalar decoding to `uses`,
// after `{`, `[` or `,` (or first), then `:`, then a non-empty scalar.
function isUsesPair(toks, k) {
  const before = k === 0 ? "{" : toks[k - 1].p;
  if (toks[k].v === undefined || decode(toks[k].v) !== "uses") return false;
  if (!"{[,".includes(before ?? "x") || toks[k + 1].p !== ":") return false;
  return toks[k + 2].v !== undefined && toks[k + 2].v !== "";
}

// The refs of every `uses` key in a flow collection's tokens.
function flowRefs(toks) {
  const refs = [];
  for (let k = 0; k + 2 < toks.length; k += 1) {
    if (isUsesPair(toks, k)) refs.push(decode(toks[k + 2].v));
  }
  return refs;
}

// How many flow collections the tokens leave open.
function flowDepth(toks) {
  let depth = 0;
  for (const { p } of toks) {
    if (p === "{" || p === "[") depth += 1;
    else if (p === "}" || p === "]") depth -= 1;
  }
  return depth;
}

function indentOf(line) {
  return line.length - line.trimStart().length;
}

// The text of the flow collection that lines[i] opens at column `at`, and the
// index of the first line after it. A collection left open continues on the
// next lines, but only on lines indented deeper than lines[i] (or blank):
// YAML requires that of a flow continuation, and it keeps an unbalanced `{` in
// a block scalar from swallowing the steps that follow it. Stopping early
// loses nothing: the lines after the stop are read on their own.
function flowSpan(lines, i, at) {
  const head = lines[i].slice(at);
  const text = (end) => [head, ...lines.slice(i + 1, end)].join("\n");
  const deeper = (l) => l.trim() === "" || indentOf(l) > indentOf(lines[i]);
  let j = i + 1;
  while (j < lines.length && deeper(lines[j]) && flowDepth(flowTokens(text(j))) > 0) j += 1;
  return [text(j), j];
}

// The action refs declared from lines[i], and the index of the next line to
// read: a block-form `uses:` value, or every `uses` key in a flow collection
// the line opens (see flowStart), read with its continuation lines (flowSpan).
// `{ uses: ... }` inside a comment or a quoted shell argument is not a step.
function refsAt(lines, i) {
  const block = blockUses(lines[i]);
  if (block !== null) return [block === "" ? [] : [decode(block)], i + 1];
  const at = flowStart(lines[i]);
  if (at === -1) return [[], i + 1];
  const [text, next] = flowSpan(lines, i, at);
  return [flowRefs(flowTokens(text)), next];
}

// Every action ref in a workflow, as [line index, ref].
function declaredRefs(lines) {
  const out = [];
  let i = 0;
  while (i < lines.length) {
    const [refs, next] = refsAt(lines, i);
    for (const ref of refs) out.push([i, ref]);
    i = next;
  }
  return out;
}

// Line-based read of the two sections of actions.lock that matter:
//   workflows:    "<path>": [ "<ref>", ... ]
//   dependencies: "<ref>":  { commit: "sha1-..." , ... }
// Workflow paths keep their case (a Linux checkout can hold ci.yml and CI.yml);
// action refs are normalised by normRef.
function parseLock(text) {
  const st = { workflows: new Map(), deps: new Map(), section: "", key: "" };
  for (const line of text.split("\n")) lockLine(st, line);
  return { workflows: st.workflows, deps: st.deps };
}

// workflows: path -> Set of refs; deps: ref -> commit string ("" when absent).
function lockLine(st, line) {
  const body = line.trim();
  if (body === "" || body.startsWith("#")) return;
  const indent = line.length - line.trimStart().length;
  if (indent === 0) {
    st.section = body.endsWith(":") ? body.slice(0, -1) : "";
    st.key = "";
  } else if (indent === 4 && body.endsWith(":")) {
    lockEntry(st, unquote(body.slice(0, -1)));
  } else if (indent === 8 && st.key !== "") {
    lockField(st.section, st.key, body, st.workflows, st.deps);
  }
}

function lockEntry(st, name) {
  st.key = lockKey(st.section, name);
  if (st.section === "workflows" && !st.workflows.has(st.key)) st.workflows.set(st.key, new Set());
  if (st.section === "dependencies" && !st.deps.has(st.key)) st.deps.set(st.key, "");
}

function lockKey(section, name) {
  return section === "workflows" ? name : normRef(name);
}

function lockField(section, key, body, workflows, deps) {
  if (section === "workflows" && body.startsWith("- ")) {
    workflows.get(key).add(normRef(unquote(body.slice(2).trim())));
  } else if (section === "dependencies" && body.startsWith("commit:")) {
    deps.set(key, unquote(body.slice("commit:".length).trim()));
  }
}

// Why `ref` (declared in workflow `wfPath`) is not pinned, or null when it is.
function unpinnedReason(ref, wfPath, lock) {
  if (EXEMPT_PREFIX.some((p) => ref.startsWith(p))) return null;
  const at = ref.lastIndexOf("@");
  const name = at === -1 ? ref : ref.slice(0, at);
  const tag = at === -1 ? "" : ref.slice(at + 1);
  if (name.toLowerCase() === EXEMPT_REPO || SHA.test(ref)) return null;
  if (lock === null) return "not an inline SHA and there is no lockfile";
  const entry = lock.workflows.get(wfPath);
  if (entry === undefined) return "this workflow has no entry in actions.lock";
  // subpath actions key by repo root: github/codeql-action/init -> github/codeql-action
  const root = name.split("/").slice(0, 2).join("/");
  // Either key may resolve it: a candidate counts only when this workflow lists
  // it AND the lock holds a resolved commit for it.
  const listed = [normRef(ref), normRef(`${root}@${tag}`)].filter((c) => entry.has(c));
  if (listed.length === 0) return "not listed under this workflow in actions.lock";
  if (!listed.some((c) => LOCK_COMMIT.test(lock.deps.get(c) ?? ""))) {
    return "actions.lock has no resolved sha1 commit for it";
  }
  return null;
}

function loadLock() {
  if (!existsSync(LOCK)) {
    console.log("no lockfile — every ref must be an inline 40-character SHA");
    return null;
  }
  const lock = parseLock(readFileSync(LOCK, "utf8"));
  console.log(
    `lockfile present: ${lock.workflows.size} workflow(s), ${lock.deps.size} resolved ref(s)`,
  );
  return lock;
}

// Every unpinned ref in one workflow file, as `file:line: ref (reason)`.
function unpinnedIn(file, lock) {
  const wf = join(WF, file);
  const bad = [];
  for (const [i, ref] of declaredRefs(readFileSync(wf, "utf8").split("\n"))) {
    const why = unpinnedReason(ref, `${WF}/${file}`, lock);
    if (why !== null) bad.push(`${wf}:${i + 1}: ${ref} (${why})`);
  }
  return bad;
}

function main() {
  if (!existsSync(WF)) {
    console.log("no .github/workflows — nothing to check");
    return 0;
  }
  const lock = loadLock();
  const bad = workflowFiles().flatMap((file) => unpinnedIn(file, lock));
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
