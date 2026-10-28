#!/usr/bin/env node
"use strict";
// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Hermetic tests for scripts/governance-badge.js: the state -> badge table, the
// byte-equality no-op, the publication decisions, and the API-error
// classification. Nothing here talks to github.com.
//
// The GitHub REST API is replaced by an in-process mock (node:http) whose state
// is a branch name, an optional file, and a per-route script of injected HTTP
// statuses. The helper runs as a child process against `--api-url`, exactly as
// it does in the workflow, so the tests exercise the real fetch/status paths
// rather than a stubbed function.
//
// Runtime-agnostic on purpose: CommonJS + node: builtins only, so it runs under
// the estate's first-choice runtime (Bun) and under Node, which is what makes
// the suite runnable outside CI. Spawn as: bun <this file> | node <this file>.

const { spawn, spawnSync } = require("node:child_process");
const { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } = require("node:fs");
const http = require("node:http");
const { tmpdir } = require("node:os");
const { join, resolve } = require("node:path");

const REPO_DIR = resolve(__dirname, "..", "..");
const HELPER = join(REPO_DIR, "scripts", "governance-badge.js");
const RUNTIME = process.execPath;
const LABEL = "K9";
const BRANCH = "governance-badges";
const DEST = "badges/k9.json";

const SUCCESS_BADGE = '{"schemaVersion":1,"label":"K9","message":"success","color":"brightgreen"}\n';
const FAILURE_BADGE = '{"schemaVersion":1,"label":"K9","message":"failure","color":"red"}\n';
const SKIPPED_BADGE = '{"schemaVersion":1,"label":"K9","message":"skipped","color":"lightgrey"}\n';
const GREY_BADGE = '{"schemaVersion":1,"label":"K9","message":"unavailable","color":"lightgrey"}\n';

// ---------------------------------------------------------------------------
// Tiny test runner (the estate's Silence + Firing + Setup-error convention)
// ---------------------------------------------------------------------------

let passed = 0;
let failed = 0;
const failures = [];

async function test(name, fn) {
    try {
        await fn();
        passed += 1;
        console.log(`  PASS: ${name}`);
    } catch (err) {
        failed += 1;
        failures.push({ name, err });
        const detail = String(err && err.message ? err.message : err).replace(/\n/g, " ");
        console.log(`  FAIL: ${name}`);
        console.log(`        ${String(err && err.message ? err.message : err).replace(/\n/g, "\n        ")}`);
        // Surface the failing check through the run's annotations: the log
        // itself can be awkward to reach, and a bare "exit code 1" is not a
        // report.
        console.log(`::error::governance-badge test failed: ${name} - ${detail.slice(0, 400)}`);
    }
}

function section(title) {
    console.log(`\n=== ${title} ===`);
}

function check(condition, message) {
    if (!condition) throw new Error(message);
}

function equal(actual, expected, message) {
    if (actual !== expected) {
        throw new Error(`${message}\n  wanted: ${JSON.stringify(expected)}\n  got:    ${JSON.stringify(actual)}`);
    }
}

// ---------------------------------------------------------------------------
// Mock GitHub REST API
// ---------------------------------------------------------------------------

function wrapBase64(buffer) {
    // GitHub wraps base64 payloads at 60 characters with newlines; decoding must
    // tolerate that, so the mock reproduces it.
    return buffer.toString("base64").replace(/(.{60})/g, "$1\n");
}

function createApi(options = {}) {
    const state = {
        repo: options.repo || "example/template",
        defaultBranch: options.defaultBranch || "main",
        branchExists: Boolean(options.branchExists),
        file: options.fileBytes === undefined
            ? null
            : { sha: "sha-initial", bytes: Buffer.from(options.fileBytes, "utf8") },
        requests: [],
        script: new Map(),
        commitParents: options.commitParents || null,
        blobs: new Map(),
        trees: new Map(),
        commits: new Map(),
        counter: 0,
        hook: options.hook || null,
    };

    const nextSha = (prefix) => `${prefix}-${(state.counter += 1)}`;

    function routeOf(method, pathname) {
        if (pathname === `/repos/${state.repo}`) return "repo";
        if (pathname.includes("/contents/")) return method === "PUT" ? "contents-put" : "contents-get";
        if (/\/git\/ref\/heads\//.test(pathname)) return "ref-get";
        if (/\/git\/refs$/.test(pathname)) return "refs-post";
        if (/\/git\/blobs$/.test(pathname)) return "blobs-post";
        if (/\/git\/trees$/.test(pathname)) return "trees-post";
        if (/\/git\/commits$/.test(pathname)) return "commits-post";
        return "unknown";
    }

    function send(res, status, payload) {
        const body = JSON.stringify(payload);
        res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
        res.end(body);
    }

    function bytesForTree(treeSha) {
        const blobSha = state.trees.get(treeSha);
        return blobSha === undefined ? null : state.blobs.get(blobSha);
    }

    async function handle(req, res) {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const raw = Buffer.concat(chunks).toString("utf8");
        const url = new URL(req.url, "http://127.0.0.1");
        const route = routeOf(req.method, url.pathname);
        let body = null;
        if (raw) {
            try {
                body = JSON.parse(raw);
            } catch {
                body = raw;
            }
        }
        const entry = {
            method: req.method,
            route,
            path: url.pathname,
            query: url.search,
            body,
        };
        state.requests.push(entry);

        if (state.hook) state.hook(entry, state);

        const scripted = state.script.get(route);
        if (scripted && scripted.length) {
            const status = scripted.shift();
            if (status >= 400) return send(res, status, { message: `injected ${status}` });
        }

        switch (route) {
            case "repo":
                return send(res, 200, { full_name: state.repo, default_branch: state.defaultBranch });

            case "contents-get": {
                if (!state.branchExists) return send(res, 404, { message: "Not Found" });
                if (!state.file) return send(res, 404, { message: "Not Found" });
                return send(res, 200, {
                    name: DEST.split("/").pop(),
                    path: DEST,
                    sha: state.file.sha,
                    size: state.file.bytes.length,
                    encoding: "base64",
                    content: wrapBase64(state.file.bytes),
                });
            }

            case "ref-get": {
                if (!state.branchExists) return send(res, 404, { message: "Not Found" });
                return send(res, 200, {
                    ref: `refs/heads/${BRANCH}`,
                    object: { sha: state.file ? state.file.sha : "ref-only", type: "commit" },
                });
            }

            case "contents-put": {
                if (!state.branchExists) return send(res, 404, { message: "Not Found" });
                if (state.file && !body.sha) {
                    return send(res, 422, { message: "sha wasn't supplied" });
                }
                if (state.file && body.sha !== state.file.sha) {
                    return send(res, 409, { message: "sha does not match" });
                }
                const created = !state.file;
                state.file = { sha: nextSha("sha"), bytes: Buffer.from(body.content, "base64") };
                return send(res, created ? 201 : 200, {
                    content: { sha: state.file.sha },
                    commit: { sha: nextSha("commit") },
                });
            }

            case "blobs-post": {
                const sha = nextSha("blob");
                state.blobs.set(sha, Buffer.from(body.content, "base64"));
                return send(res, 201, { sha });
            }

            case "trees-post": {
                const sha = nextSha("tree");
                state.trees.set(sha, body.tree[0].sha);
                return send(res, 201, { sha, tree: body.tree });
            }

            case "commits-post": {
                const sha = nextSha("commit");
                state.commits.set(sha, body.tree);
                const parents = state.commitParents === null ? body.parents : state.commitParents;
                return send(res, 201, { sha, tree: { sha: body.tree }, parents });
            }

            case "refs-post": {
                if (body.ref !== `refs/heads/${BRANCH}`) {
                    return send(res, 422, { message: `unexpected ref ${body.ref}` });
                }
                if (state.branchExists) return send(res, 422, { message: "Reference already exists" });
                const bytes = bytesForTree(state.commits.get(body.sha));
                state.branchExists = true;
                state.file = { sha: nextSha("sha"), bytes: bytes || Buffer.alloc(0) };
                return send(res, 201, { ref: body.ref, object: { sha: body.sha } });
            }

            default:
                return send(res, 500, { message: `unmapped route for ${req.method} ${url.pathname}` });
        }
    }

    const server = http.createServer((req, res) => {
        handle(req, res).catch((err) => send(res, 500, { message: String(err && err.message) }));
    });

    return {
        state,
        listen: () => new Promise((r) => server.listen(0, "127.0.0.1", () => r(`http://127.0.0.1:${server.address().port}`))),
        close: () => new Promise((r) => server.close(() => r())),
        server,
        writes: () => state.requests.filter((r) => r.method !== "GET"),
        posts: () => state.requests.filter((r) => r.method === "POST"),
        puts: () => state.requests.filter((r) => r.route === "contents-put"),
    };
}

// ---------------------------------------------------------------------------
// Running the helper
// ---------------------------------------------------------------------------

function baseEnv(extra = {}) {
    const env = { ...process.env, NO_COLOR: "1", GOVERNANCE_BADGE_RETRY_DELAY_MS: "0" };
    // Never inherit a real credential or API endpoint. The suite passed on a
    // developer machine that had GH_TOKEN exported and failed in CI, where it
    // does not: tests must not depend on, or be able to use, either.
    delete env.GITHUB_API_URL;
    delete env.GITHUB_TOKEN;
    delete env.GH_TOKEN;
    Object.assign(env, extra);
    if (!("GITHUB_TOKEN" in env) && !("GH_TOKEN" in env)) {
        env.GITHUB_TOKEN = "governance-badge-test-token";
    }
    return env;
}

function runSync(args, extraEnv = {}) {
    const result = spawnSync(RUNTIME, [HELPER, ...args], {
        env: baseEnv(extraEnv),
        encoding: "utf8",
        timeout: 60000,
    });
    return { code: result.status, stdout: result.stdout || "", stderr: result.stderr || "" };
}

function runAsync(args, extraEnv = {}) {
    return new Promise((resolvePromise) => {
        const child = spawn(RUNTIME, [HELPER, ...args], { env: baseEnv(extraEnv) });
        let stdout = "";
        let stderr = "";
        // A hung helper must fail the test, not hang CI.
        const timer = setTimeout(() => child.kill("SIGKILL"), 60000);
        child.stdout.on("data", (d) => (stdout += d.toString()));
        child.stderr.on("data", (d) => (stderr += d.toString()));
        child.on("close", (code) => {
            clearTimeout(timer);
            resolvePromise({ code, stdout, stderr });
        });
    });
}

function publishArgs(apiUrl, artifact, extra = []) {
    return [
        "publish",
        "--label", LABEL,
        "--lane-result", "success",
        "--artifact", artifact,
        "--branch", BRANCH,
        "--path", DEST,
        "--repo", "example/template",
        "--api-url", apiUrl,
        "--source-sha", "0123456789abcdef0123456789abcdef01234567",
        ...extra,
    ];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

async function main() {
    const runtimeLabel = process.versions.bun ? `bun ${process.versions.bun}` : `node ${process.versions.node}`;
    console.log(`runtime: ${runtimeLabel} (${RUNTIME})`);
    console.log(`helper:  ${HELPER}`);
    const work = mkdtempSync(join(tmpdir(), "governance-badge-test-"));
    const artifactDir = join(work, "artifacts");
    mkdirSync(artifactDir, { recursive: true });

    const artifact = (name, text) => {
        const file = join(artifactDir, name);
        writeFileSync(file, text);
        return file;
    };
    const missingArtifact = join(artifactDir, "does-not-exist.json");
    const goodArtifact = artifact("success.json", SUCCESS_BADGE);
    const failureArtifact = artifact("failure.json", FAILURE_BADGE);

    try {
        // ---------------------------------------------------------------- 1
        section("1. State -> badge rendering is deterministic and total");

        await test("success renders brightgreen with the canonical bytes", () => {
            const out = runSync(["render", "--label", LABEL, "--state", "success"]);
            equal(out.code, 0, "render must exit 0");
            equal(out.stdout, SUCCESS_BADGE, "success badge bytes");
        });

        await test("failure renders red with the canonical bytes", () => {
            const out = runSync(["render", "--label", LABEL, "--state", "failure"]);
            equal(out.code, 0, "render must exit 0");
            equal(out.stdout, FAILURE_BADGE, "failure badge bytes");
        });

        for (const state of ["skipped", "cancelled", "unavailable", "unknown"]) {
            await test(`${state} renders lightgrey`, () => {
                const out = runSync(["render", "--label", LABEL, "--state", state]);
                equal(out.code, 0, "render must exit 0");
                const badge = JSON.parse(out.stdout);
                equal(badge.message, state, "message echoes the state");
                equal(badge.color, "lightgrey", `${state} must be lightgrey`);
                equal(badge.schemaVersion, 1, "schemaVersion is preserved");
                equal(badge.label, LABEL, "label is preserved");
            });
        }

        for (const raw of ["timed_out", "neutral", "action_required", "", "SUCCEEDED", "green"]) {
            await test(`unrecognised lane result ${JSON.stringify(raw)} becomes unknown/lightgrey`, () => {
                const out = runSync(["render", "--label", LABEL, "--state", raw]);
                equal(out.code, 0, "render must exit 0");
                const badge = JSON.parse(out.stdout);
                equal(badge.message, "unknown", "unrecognised states are never echoed as success");
                equal(badge.color, "lightgrey", "unrecognised states are grey");
            });
        }

        await test("rendering is byte-stable across invocations", () => {
            const a = runSync(["render", "--label", LABEL, "--state", "skipped"]);
            const b = runSync(["render", "--label", LABEL, "--state", "skipped"]);
            equal(a.stdout, b.stdout, "same input must produce the same bytes");
            equal(a.stdout, SKIPPED_BADGE, "skipped badge bytes");
        });

        // ---------------------------------------------------------------- 2
        section("2. Identical bytes publish nothing");

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            const url = await api.listen();
            await test("byte-identical badge makes no commit", async () => {
                const summary = join(work, "summary-noop.md");
                writeFileSync(summary, "");
                const out = await runAsync(publishArgs(url, goodArtifact), { GITHUB_STEP_SUMMARY: summary });
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                check(/unchanged/i.test(out.stdout), `stdout must say unchanged: ${out.stdout}`);
                equal(api.writes().length, 0, "no write request may be made");
                equal(api.state.file.bytes.toString(), SUCCESS_BADGE, "the file must be untouched");
                const text = readFileSync(summary, "utf8");
                check(text.includes("### Governance badge"), "step summary must record the decision");
                check(text.includes("unchanged"), "step summary must say unchanged");
            });
            await api.close();
        }

        // ---------------------------------------------------------------- 3
        section("3. Changed bytes publish exactly once");

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            const url = await api.listen();
            await test("a failure replaces a green badge with a red one", async () => {
                const out = await runAsync([
                    "publish",
                    "--label", LABEL,
                    "--lane-result", "failure",
                    "--artifact", failureArtifact,
                    "--branch", BRANCH,
                    "--path", DEST,
                    "--repo", "example/template",
                    "--api-url", url,
                ]);
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                const puts = api.puts();
                equal(puts.length, 1, "exactly one contents PUT");
                equal(puts[0].body.sha, "sha-initial", "the PUT carries the sha it compared against");
                equal(puts[0].body.branch, BRANCH, "the PUT targets the orphan branch");
                equal(Buffer.from(puts[0].body.content, "base64").toString(), FAILURE_BADGE, "the published bytes are the red badge");
                equal(api.state.file.bytes.toString(), FAILURE_BADGE, "the branch now carries the red badge");
                check(/published/.test(out.stdout), "stdout must report publication");
                check(/commit=commit-/.test(out.stdout), "stdout must report the commit");
            });
            await api.close();
        }

        {
            // Same JSON semantics, different key order: a byte comparison must
            // see a difference, because "do not canonicalise JSON to compare".
            const api = createApi({
                branchExists: true,
                fileBytes: '{"label":"K9","schemaVersion":1,"message":"success","color":"brightgreen"}\n',
            });
            const url = await api.listen();
            await test("a reordered but semantically equal file is REPLACED, not treated as a no-op", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                equal(api.puts().length, 1, "byte differences must publish even when the JSON means the same");
            });
            await api.close();
        }

        // ---------------------------------------------------------------- 4
        section("4. A missing branch is created as an orphan");

        {
            const api = createApi({ branchExists: false });
            const url = await api.listen();
            await test("first publication creates the branch with no parents", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                const posts = api.posts();
                equal(posts.map((p) => p.route).join(","), "blobs-post,trees-post,commits-post,refs-post", "blob -> tree -> commit -> ref");
                const commit = posts.find((p) => p.route === "commits-post");
                check(Array.isArray(commit.body.parents), "the commit body must carry a parents array");
                equal(commit.body.parents.length, 0, "the orphan commit must have NO parents (no main ancestry)");
                const ref = posts.find((p) => p.route === "refs-post");
                equal(ref.body.ref, `refs/heads/${BRANCH}`, "the ref is the badge branch, never main");
                const tree = posts.find((p) => p.route === "trees-post");
                check(!("base_tree" in tree.body), "the tree must not be based on another tree");
                equal(tree.body.tree[0].path, DEST, "the tree carries the badge file");
                equal(api.state.file.bytes.toString(), SUCCESS_BADGE, "the new branch carries the green badge");
                check(/created-orphan-branch/.test(out.stdout), "stdout must name the orphan creation");
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: true, fileBytes: undefined });
            const url = await api.listen();
            await test("a branch without the file gets the file, not a new branch", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                equal(api.posts().length, 0, "no blob/tree/commit/ref may be created");
                const puts = api.puts();
                equal(puts.length, 1, "one contents PUT creates the file");
                check(!puts[0].body.sha, "a create carries no sha");
                equal(api.state.file.bytes.toString(), SUCCESS_BADGE, "the file exists after the run");
            });
            await api.close();
        }

        // ---------------------------------------------------------------- 5
        section("5. Grey states for untrustworthy lanes");

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            const url = await api.listen();
            await test("a missing lane artifact publishes grey and fails the step", async () => {
                const out = await runAsync(publishArgs(url, missingArtifact));
                equal(out.code, 3, `expected exit 3 (grey published, lane evidence unusable), got ${out.code}: ${out.stderr}`);
                equal(api.puts().length, 1, "the grey badge must still be published");
                equal(api.state.file.bytes.toString(), GREY_BADGE, "a green badge must never survive a missing artifact");
                check(/::error::/.test(out.stdout), "the fault must be annotated");
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            const url = await api.listen();
            await test("a malformed artifact publishes grey and fails the step", async () => {
                const broken = artifact("broken.json", '{"schemaVersion":1,"label":"K9",');
                const out = await runAsync(publishArgs(url, broken));
                equal(out.code, 3, `expected exit 3, got ${out.code}: ${out.stderr}`);
                equal(api.state.file.bytes.toString(), GREY_BADGE, "malformed evidence cannot become green");
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            const url = await api.listen();
            await test("an artifact whose colour contradicts its message publishes grey", async () => {
                const tampered = artifact(
                    "tampered.json",
                    '{"schemaVersion":1,"label":"K9","message":"success","color":"red"}\n',
                );
                const out = await runAsync(publishArgs(url, tampered));
                equal(out.code, 3, `expected exit 3, got ${out.code}: ${out.stderr}`);
                equal(api.state.file.bytes.toString(), GREY_BADGE, "a contradictory artifact cannot become green");
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            const url = await api.listen();
            await test("a success job whose artifact records another state publishes grey", async () => {
                const out = await runAsync(publishArgs(url, artifact("skipped.json", SKIPPED_BADGE)));
                equal(out.code, 3, `expected exit 3, got ${out.code}: ${out.stderr}`);
                equal(api.state.file.bytes.toString(), GREY_BADGE, "inconsistent evidence cannot become green");
            });
            await api.close();
        }

        for (const laneResult of ["skipped", "cancelled", "timed_out", ""]) {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            const url = await api.listen();
            await test(`lane result ${JSON.stringify(laneResult)} replaces a green badge with grey`, async () => {
                const out = await runAsync(publishArgs(url, missingArtifact, ["--lane-result", laneResult]));
                equal(out.code, 0, `expected exit 0 (a known non-success state is not a fault), got ${out.code}: ${out.stderr}`);
                const bytes = api.state.file.bytes.toString();
                check(bytes.includes('"color":"lightgrey"'), `expected a grey badge, got ${bytes}`);
                check(!bytes.includes("brightgreen"), "a stale green must never survive");
            });
            await api.close();
        }

        // ---------------------------------------------------------------- 6
        section("6. Malformed existing content is refused, not overwritten");

        for (const [name, text] of [
            ["not JSON", "this is not json\n"],
            ["JSON array", "[]\n"],
            ["missing schemaVersion", '{"label":"K9","message":"failure","color":"red"}\n'],
            ["null message", '{"schemaVersion":1,"label":"K9","message":null,"color":"red"}\n'],
        ]) {
            const api = createApi({ branchExists: true, fileBytes: text });
            const url = await api.listen();
            await test(`existing file that is ${name} is rejected`, async () => {
                const out = await runAsync([
                    "publish",
                    "--label", LABEL,
                    "--lane-result", "failure",
                    "--artifact", failureArtifact,
                    "--branch", BRANCH,
                    "--path", DEST,
                    "--repo", "example/template",
                    "--api-url", url,
                ]);
                equal(out.code, 1, `expected exit 1, got ${out.code}: ${out.stderr}`);
                equal(api.writes().length, 0, "malformed existing content must not be overwritten");
                check(/refused/i.test(out.stderr), `stderr must say refused: ${out.stderr}`);
            });
            await api.close();
        }

        // ---------------------------------------------------------------- 7
        section("7. Missing is not the same as broken");

        {
            const api = createApi({ branchExists: false });
            api.state.script.set("contents-get", [503, 503, 503]);
            const url = await api.listen();
            await test("a 5xx contents read fails the run and creates nothing", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 1, `expected exit 1, got ${out.code}: ${out.stdout}`);
                equal(api.writes().length, 0, "an outage must never be treated as a missing branch");
                check(/503/.test(out.stderr), `stderr must name the status: ${out.stderr}`);
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: false });
            api.state.script.set("contents-get", [404]);
            api.state.script.set("ref-get", [500, 500, 500]);
            const url = await api.listen();
            await test("a 404 file with an unreadable ref fails the run and creates nothing", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 1, `expected exit 1, got ${out.code}: ${out.stdout}`);
                equal(api.posts().length, 0, "the branch must not be created when existence is unknown");
                check(/500/.test(out.stderr), `stderr must name the status: ${out.stderr}`);
            });
            await api.close();
        }

        {
            // A transient blip must not be read as "missing": retry, then honour
            // the definitive 404 that follows.
            const api = createApi({ branchExists: false });
            api.state.script.set("contents-get", [503]);
            const url = await api.listen();
            await test("a transient blip before a 404 is retried, not acted on", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                equal(api.state.branchExists, true, "the retry sees the real 404 and creates the orphan branch");
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            api.state.script.set("contents-get", [403]);
            const url = await api.listen();
            await test("a 403 fails the run without writing", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 1, `expected exit 1, got ${out.code}: ${out.stdout}`);
                equal(api.writes().length, 0, "an auth failure must not write");
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            const deadUrl = await api.listen();
            await api.close(); // nothing is listening on that port any more
            await test("an unreachable API fails the run without writing", async () => {
                const out = await runAsync(publishArgs(deadUrl, goodArtifact));
                equal(out.code, 1, `expected exit 1, got ${out.code}: ${out.stdout}`);
                check(/could not be reached|failed:/.test(out.stderr), `stderr must name the network failure: ${out.stderr}`);
            });
        }

        // ---------------------------------------------------------------- 8
        section("8. Concurrent publications reconcile instead of overwriting");

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            let injected = false;
            api.state.hook = (request, state) => {
                if (request.route === "contents-put" && !injected) {
                    injected = true;
                    // Another run wins the race and writes the same badge we want.
                    state.file = { sha: "sha-other", bytes: Buffer.from(FAILURE_BADGE, "utf8") };
                    state.script.set("contents-put", [409]);
                }
            };
            const url = await api.listen();
            await test("a lost race that already published the same bytes ends unchanged", async () => {
                const out = await runAsync([
                    "publish",
                    "--label", LABEL,
                    "--lane-result", "failure",
                    "--artifact", failureArtifact,
                    "--branch", BRANCH,
                    "--path", DEST,
                    "--repo", "example/template",
                    "--api-url", url,
                ]);
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                equal(api.puts().length, 1, "the second read shows identical bytes, so no second PUT");
                check(/unchanged/i.test(out.stdout), `stdout must say unchanged: ${out.stdout}`);
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            let injected = false;
            api.state.hook = (request, state) => {
                if (request.route === "contents-put" && !injected) {
                    injected = true;
                    state.file = { sha: "sha-other", bytes: Buffer.from(SKIPPED_BADGE, "utf8") };
                    state.script.set("contents-put", [409]);
                }
            };
            const url = await api.listen();
            await test("a lost race with different bytes re-reads and publishes against the new sha", async () => {
                const out = await runAsync([
                    "publish",
                    "--label", LABEL,
                    "--lane-result", "failure",
                    "--artifact", failureArtifact,
                    "--branch", BRANCH,
                    "--path", DEST,
                    "--repo", "example/template",
                    "--api-url", url,
                ]);
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                const puts = api.puts();
                equal(puts.length, 2, "conflict, re-read, publish");
                equal(puts[1].body.sha, "sha-other", "the retry uses the sha it re-read");
                equal(api.state.file.bytes.toString(), FAILURE_BADGE, "the final content is this run's badge");
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: false });
            api.state.hook = (request, state) => {
                if (request.route === "refs-post" && !state.script.get("refs-post")) {
                    // Another run creates the branch first.
                    state.branchExists = true;
                    state.file = { sha: "sha-other", bytes: Buffer.from(SUCCESS_BADGE, "utf8") };
                    state.script.set("refs-post", [422]);
                }
            };
            const url = await api.listen();
            await test("a lost race creating the branch re-reads instead of forcing the ref", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                equal(api.posts().filter((p) => p.route === "refs-post").length, 1, "the ref is attempted once");
                equal(api.puts().length, 0, "the winner already published our bytes");
                check(/unchanged/i.test(out.stdout), `stdout must say unchanged: ${out.stdout}`);
            });
            await api.close();
        }

        // ---------------------------------------------------------------- 9
        section("9. Guards: the badge never touches a source branch");

        for (const branch of ["main", "master", "HEAD"]) {
            await test(`--branch ${branch} is refused before any API call`, () => {
                const out = runSync(publishArgs("http://127.0.0.1:1", goodArtifact, ["--branch", branch]));
                equal(out.code, 2, `expected exit 2, got ${out.code}: ${out.stderr}`);
                check(/orphan branch/i.test(out.stderr), `stderr must explain why: ${out.stderr}`);
            });
        }

        await test("--path outside badges/ is refused", () => {
            const out = runSync(publishArgs("http://127.0.0.1:1", goodArtifact, ["--path", "src/k9.json"]));
            equal(out.code, 2, `expected exit 2, got ${out.code}: ${out.stderr}`);
        });

        await test("--path with traversal is refused", () => {
            const out = runSync(publishArgs("http://127.0.0.1:1", goodArtifact, ["--path", "badges/../k9.json"]));
            equal(out.code, 2, `expected exit 2, got ${out.code}: ${out.stderr}`);
        });

        {
            const api = createApi({ branchExists: false, defaultBranch: BRANCH });
            const url = await api.listen();
            await test("a repository whose default branch is the badge branch is refused", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 2, `expected exit 2, got ${out.code}: ${out.stderr}`);
                equal(api.writes().length, 0, "nothing may be written to a default branch");
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: false, commitParents: ["1111111111111111111111111111111111111111"] });
            const url = await api.listen();
            await test("a commit that comes back with a parent is refused", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 1, `expected exit 1, got ${out.code}: ${out.stderr}`);
                equal(api.posts().filter((p) => p.route === "refs-post").length, 0, "no ref may point at a non-orphan commit");
                check(/parents/i.test(out.stderr), `stderr must explain: ${out.stderr}`);
            });
            await api.close();
        }

        await test("publish refuses to run without a token, and writes nothing", () => {
            const result = spawnSync(RUNTIME, [HELPER, ...publishArgs("http://127.0.0.1:1", goodArtifact)], {
                env: { PATH: process.env.PATH, GOVERNANCE_BADGE_RETRY_DELAY_MS: "0" },
                encoding: "utf8",
                timeout: 60000,
            });
            equal(result.status, 2, `expected exit 2, got ${result.status}: ${result.stderr}`);
            check(/token/i.test(result.stderr), `stderr must name the missing token: ${result.stderr}`);
        });

        await test("a missing --artifact is a usage error, not a silent success", () => {
            const out = runSync([
                "publish",
                "--label", LABEL,
                "--lane-result", "success",
                "--branch", BRANCH,
                "--path", DEST,
                "--repo", "example/template",
                "--api-url", "http://127.0.0.1:1",
            ]);
            equal(out.code, 2, `expected exit 2, got ${out.code}: ${out.stderr}`);
        });

        // --------------------------------------------------------------- 10
        section("10. The helper is the only renderer; the workflow uses it");

        await test("the workflow's artifact producer would render the same bytes", () => {
            const out = runSync(["render", "--label", "K9", "--state", "success"]);
            equal(out.stdout, SUCCESS_BADGE, "artifact bytes and publisher bytes must agree");
        });

        await test("the previous jq renderer's success bytes are reproduced exactly", () => {
            // The rollout must not create a commit just because the renderer
            // changed. This is the jq output the workflow used to produce.
            const legacy = '{"schemaVersion":1,"label":"K9","message":"success","color":"brightgreen"}\n';
            equal(runSync(["render", "--label", LABEL, "--state", "success"]).stdout, legacy, "legacy green bytes");
        });
    } finally {
        rmSync(work, { recursive: true, force: true });
    }

    console.log("");
    console.log(`${passed} passed, ${failed} failed`);
    if (failed > 0) {
        for (const failure of failures) console.log(`  failed: ${failure.name}`);
        process.exit(1);
    }
}

main().catch((err) => {
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
});
