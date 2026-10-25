#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Silence + Firing + Setup-error test suite for scripts/check-ijson-jcs.sh
# (proven-tests-and-benches TEST-DOCTRINE 3-outcome contract).
#
# Proves check-ijson-jcs.sh CAN FAIL and classifies each input for the right
# reason across .json and .jsonl: canonical (exit 0), non-canonical (exit 1
# under --enforce), invalid RFC 7493 I-JSON including duplicate keys, unsafe
# integers > 2^53-1, lone surrogates, and Unicode noncharacters (INVALID,
# exit 1 under --enforce), JSONC carve-outs skipped, and setup errors (exit 2).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_DIR/scripts/check-ijson-jcs.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

expect() { # expect <wanted-exit> <label> [checker flags...]
  local want="$1" label="$2" got=0
  shift 2
  (cd "$WORK" && bash "$SCRIPT" "$@" t) >"$WORK/out" 2>&1 || got=$?
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    echo "  PASS: $label"
  else
    fail=$((fail + 1))
    echo "  FAIL: $label (wanted exit $want, got $got)"
    sed 's/^/        /' "$WORK/out"
  fi
}

fresh() {
  rm -rf "$WORK/t"
  mkdir -p "$WORK/t"
}

names() { # names <fixed-string> <label>
  if grep -qF -- "$1" "$WORK/out"; then
    pass=$((pass + 1))
    echo "  PASS: $2"
  else
    fail=$((fail + 1))
    echo "  FAIL: $2"
    sed 's/^/        /' "$WORK/out"
  fi
}

echo "=== Silence & Firing: .json ==="
fresh; printf '{"a":1,"b":[true,null]}\n' > "$WORK/t/a.json"
expect 0 "Silence: canonical .json passes --enforce" --enforce
names "1 canonical, 0 not canonical, 0 invalid" "Silence: counted canonical"

fresh; printf '{"b":1,"a":2}\n' > "$WORK/t/a.json"
expect 0 "Report-only: unsorted .json exits 0"
names "NOT CANONICAL t/a.json" "Firing: report names unsorted file"
expect 1 "Firing: unsorted .json fails --enforce" --enforce

fresh; printf '{\n  "a": 1\n}\n' > "$WORK/t/a.json"
expect 1 "Firing: pretty-printed .json fails --enforce" --enforce

fresh; printf '{"a":1}' > "$WORK/t/a.json"
expect 1 "Firing: .json without trailing newline fails --enforce" --enforce
names "NOT CANONICAL t/a.json" "Firing: missing newline classed non-canonical"

fresh; printf '{"a":1}\n\n' > "$WORK/t/a.json"
expect 1 "Firing: .json with double trailing newline fails --enforce" --enforce

fresh; printf '{"a":1,"a":2}\n' > "$WORK/t/a.json"
expect 1 "Firing (RFC 7493): duplicate-key .json fails --enforce" --enforce
names "INVALID t/a.json" "Firing: duplicate key classed INVALID"

fresh; printf '{"n":9007199254740992}\n' > "$WORK/t/a.json"
expect 1 "Firing (RFC 7493): integer > 2^53-1 fails --enforce" --enforce
names "INVALID t/a.json" "Firing: unsafe integer classed INVALID"

fresh; printf '{"s":"\\ud800"}\n' > "$WORK/t/a.json"
expect 1 "Firing (RFC 7493): lone UTF-16 surrogate fails --enforce" --enforce
names "INVALID t/a.json" "Firing: lone surrogate classed INVALID"

fresh; printf '{"s":"\\ufffe"}\n' > "$WORK/t/a.json"
expect 1 "Firing (RFC 7493): Unicode noncharacter U+FFFE fails --enforce" --enforce
names "INVALID t/a.json" "Firing: noncharacter classed INVALID"

echo "=== Silence & Firing: .jsonl ==="
fresh; printf '{"a":1}\n{"b":[1,2]}\n' > "$WORK/t/a.jsonl"
expect 0 "Silence: canonical .jsonl passes --enforce" --enforce
names "1 canonical" "Silence: .jsonl counted canonical"

fresh; printf '{"a":1}\n{"z":1,"b":2}\n' > "$WORK/t/a.jsonl"
expect 1 "Firing: .jsonl with unsorted second line fails --enforce" --enforce
names "NOT CANONICAL t/a.jsonl" "Firing: report names .jsonl"

fresh; printf '{"a":1}\n\n{"b":2}\n' > "$WORK/t/a.jsonl"
expect 1 "Firing: .jsonl with blank line fails --enforce" --enforce
names "INVALID t/a.jsonl" "Firing: blank line classed INVALID"

echo "=== Scope & JSONC carve-out ==="
fresh; mkdir -p "$WORK/t/.devcontainer" "$WORK/t/.vscode"
printf '// SPDX-License-Identifier: MPL-2.0\n{ "name": "x" }\n' > "$WORK/t/.devcontainer/devcontainer.json"
printf '// comment\n{ "b": 1, "a": 2 }\n' > "$WORK/t/.vscode/settings.json"
expect 0 "Silence: tool-demanded JSONC skipped under --enforce" --enforce
names "2 JSONC carve-out(s) skipped" "Silence: JSONC skips counted explicitly"

echo "=== Setup / cannot-look outcomes (exit 2) ==="
fresh
got=0; bash "$SCRIPT" "$WORK/does-not-exist" >"$WORK/out" 2>&1 || got=$?
if [ "$got" = 2 ]; then pass=$((pass + 1)); echo "  PASS: missing path exits 2"
else fail=$((fail + 1)); echo "  FAIL: missing path exits 2 (got $got)"; fi

got=0; IJSON_JCS=ijson-jcs-not-installed bash "$SCRIPT" "$WORK/t" >"$WORK/out" 2>&1 || got=$?
if [ "$got" = 2 ]; then pass=$((pass + 1)); echo "  PASS: missing explicit IJSON_JCS binary exits 2"
else fail=$((fail + 1)); echo "  FAIL: missing explicit IJSON_JCS binary exits 2 (got $got)"; fi

got=0; IJSON_JCS=ijson-jcs-not-installed IJSON_JCS_FORCE_JS=1 bash "$SCRIPT" "$WORK/t" >"$WORK/out" 2>&1 || got=$?
if [ "$got" = 2 ]; then pass=$((pass + 1)); echo "  PASS: explicit missing runner takes precedence over forced JS"
else fail=$((fail + 1)); echo "  FAIL: explicit missing runner with forced JS (got $got)"; fi

cat > "$WORK/explicit-runner" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RUNNER_LOG"
exit 0
SH
chmod +x "$WORK/explicit-runner"
fresh; printf '{}\n' > "$WORK/t/a.json"
IJSON_JCS="$WORK/explicit-runner" IJSON_JCS_FORCE_JS=1 RUNNER_LOG="$WORK/runner.log" \
  expect 0 "Silence: explicit runner selected with forced JS" --enforce
if grep -qF 'check t/a.json' "$WORK/runner.log"; then
  pass=$((pass + 1)); echo "  PASS: explicit runner receives file argument"
else
  fail=$((fail + 1)); echo "  FAIL: explicit runner was bypassed"
fi

echo "=== Canon stdout and dispatch ==="
bun run - "$REPO_DIR/scripts/ijson-jcs-cli.js" <<'JS'
import assert from "node:assert/strict";
const cli = process.argv[2];
const expected = JSON.stringify({ a: "x".repeat(2 * 1024 * 1024) });
const child = Bun.spawn(["bun", cli, "canon"], {
  stdin: new TextEncoder().encode(expected), stdout: "pipe", stderr: "pipe",
});
const chunks = [];
for await (const chunk of child.stdout) {
  chunks.push(Buffer.from(chunk));
  await Bun.sleep(1);
}
assert.equal(await child.exited, 0);
assert.equal(Buffer.concat(chunks).toString(), expected, "canon must drain stdout to a slow pipe");
assert.equal(await new Response(child.stderr).text(), "", "canon must not reach unknown-command handling");
for (const [command, input, diagnostic] of [
  ["canon", "{broken", "INVALID"], ["unknown", "{}", "unknown command"],
]) {
  const result = Bun.spawnSync(["bun", cli, command], { stdin: new TextEncoder().encode(input) });
  assert.equal(result.exitCode, 2);
  assert.equal(result.stdout.toString(), "");
  assert.ok(result.stderr.toString().includes(diagnostic));
}
console.log("PASS: canon drains large output and preserves dispatch error statuses");
JS

echo "check_ijson_jcs_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
