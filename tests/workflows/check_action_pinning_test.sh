#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Controls and mutants for scripts/check-action-pinning.js. Each hole the gate
# once had has a mutant that must FAIL (exit 1) and a control that must PASS
# (exit 0), so neither a gate that rejects everything nor one that accepts
# everything gets through:
#   - substring exemption for actions/github-script
#   - one global lock set instead of a per-workflow entry
#   - flow-mapping `uses:` not seen
#   - quoted refs not decoded
#   - lock entry with no resolved sha1 commit
#   - block-form value cut at a comma (a SHA-shaped prefix plus a mutable suffix)
#   - flow-mapping text in a comment or a quoted shell argument read as a step
#   - workflow path and tag compared case-insensitively
#   - quoted `uses` key (flow or block form) not recognised
#   - flow-mapping value cut at an adjacent `#` (a SHA-shaped prefix plus `#tag`)
#   - flow collection opened mid-line (`steps: [ { uses: x } ]`) not read
#   - tab after a list dash (`-<TAB>uses: x`) not read as a step
#   - quoted ref cut at a doubled apostrophe (`'x@<sha>''tag'`)
#   - flow step split across lines read line by line (missed or misread)
#   - an unbalanced `{` in a block scalar swallowing the steps after it
#   - subpath ref rejected when only its repository root is resolved
#   - node properties (`&anchor`, `!!tag`) hiding a step or a key from the scan
#   - an alias used as a key (`*u : x`), reported rather than dropped
#   - a `uses` key under env/with (not an action) rejected; the path decides
#   - a step placed by an alias, or an explicit `? uses` key, not seen
#   - a double-quoted escape spelling the `uses` key (`"u\x73es"`)
#   - a ref split over lines (next line, open quote, continuation) misread
# A missing bun is a setup error (exit 2), not a failed assertion (exit 1).
# PINNING_SCRIPT overrides the script under test (used to confirm the mutants
# are caught by the new script and missed by the old one).
set -euo pipefail

command -v bun >/dev/null 2>&1 || { echo "check-action-pinning: bun not found (setup error)" >&2; exit 2; }

SCRIPT="${PINNING_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/check-action-pinning.js}"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

SHA40="0123456789abcdef0123456789abcdef01234567"
pass=0
fail=0

CHECKOUT="actions/checkout@v7.0.1"
USES_CHECKOUT="      - uses: $CHECKOUT"

# lock_wf WORKFLOW REF...  -> a `workflows:` item
lock_wf() {
  local w="$1"
  shift
  printf "    '.github/workflows/%s':\n" "$w"
  local r
  for r in "$@"; do printf "        - '%s'\n" "$r"; done
}
# lock_dep REF COMMIT -> a `dependencies:` item
lock_dep() {
  local ref="$1" commit="$2"
  printf "    '%s':\n        ref: 'x'\n        commit: '%s'\n        owner_id: 1\n" "$ref" "$commit"
}

# lock_for DIR WORKFLOW REF [COMMIT] -> a lockfile with one workflow entry listing
# REF and its dependency record (COMMIT defaults to a valid sha1). The command
# substitutions are assigned first, not nested inside a quoted argument.
lock_for() {
  local dir="$1" wf="$2" ref="$3" commit="${4-$GOOD_DEP}" wfs deps
  wfs=$(lock_wf "$wf" "$ref")
  deps=$(lock_dep "$ref" "$commit")
  lockfile "$dir" "$wfs" "$deps"
}

# case_dir -> prints a fresh fixture directory with an empty workflows dir.
# mktemp, not a counter: callers run this in a subshell, so a counter would not
# advance and every case would share one directory.
case_dir() {
  local d
  d=$(mktemp -d "$FIXTURE/case.XXXXXX")
  mkdir -p "$d/.github/workflows"
  printf '%s\n' "$d"
}

# workflow DIR NAME BODY
workflow() {
  local dir="$1" name="$2" body="$3"
  printf '# SPDX-License-Identifier: MPL-2.0\nname: t\non: push\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    steps:\n%s\n' "$body" \
    > "$dir/.github/workflows/$name"
}

# job DIR NAME BODY -> as workflow, but BODY writes the job's own keys after
# runs-on (its `steps:` included), so a fixture never repeats a key.
job() {
  local dir="$1" name="$2" body="$3"
  printf '# SPDX-License-Identifier: MPL-2.0\nname: t\non: push\njobs:\n  a:\n    runs-on: ubuntu-24.04\n%s\n' "$body" \
    > "$dir/.github/workflows/$name"
}

# lockfile DIR WORKFLOWS-BODY DEPENDENCIES-BODY
lockfile() {
  local dir="$1" wfs="$2" deps="$3"
  printf "version: 'v0.0.3'\nworkflows:\n%s\ndependencies:\n%s\n" "$wfs" "$deps" > "$dir/.github/workflows/actions.lock"
}

# expect DESCRIPTION WANT DIR
expect() {
  local desc="$1" want="$2" d="$3" got out
  set +e
  out=$(cd "$d" && bun "$SCRIPT" 2>&1)
  got=$?
  set -e
  if [[ "$got" -eq "$want" ]]; then
    pass=$((pass + 1))
    echo "ok   $desc"
  else
    fail=$((fail + 1))
    echo "FAIL $desc: want exit $want, got $got"
    printf '%s\n' "$out" | sed 's/^/     | /'
  fi
}

GOOD_DEP="sha1-$SHA40"

# --- controls -------------------------------------------------------------
d=$(case_dir); workflow "$d" a.yml "      - uses: actions/checkout@$SHA40"
expect "control: inline SHA, no lockfile" 0 "$d"

d=$(case_dir); : # no workflows directory content at all
rm -rf "$d/.github"
expect "control: no .github/workflows" 0 "$d"

d=$(case_dir); workflow "$d" a.yml "$USES_CHECKOUT"
lock_for "$d" a.yml "$CHECKOUT"
expect "control: tag ref locked for its own workflow" 0 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: SonarSource/sonarcloud-github-action@v5.0.0"
lock_for "$d" a.yml 'sonarsource/sonarcloud-github-action@v5.0.0'
expect "control: lock case differs from workflow case" 0 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: github/codeql-action/init@v4.38.2"
lock_for "$d" a.yml 'github/codeql-action@v4.38.2'
expect "control: subpath action locked under its repo root" 0 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: '$CHECKOUT'
      - uses: \"$CHECKOUT\" # trailing comment"
lock_for "$d" a.yml "$CHECKOUT"
expect "control: quoted locked refs decode to the lock entry" 0 "$d"

d=$(case_dir)
body=$(printf '%s\n' "      - { uses: $CHECKOUT, with: { fetch-depth: 0 } }" "      - { name: n, uses: actions/checkout@$SHA40 }")
workflow "$d" a.yml "$body"
lock_for "$d" a.yml "$CHECKOUT"
expect "control: flow-mapping refs, locked and inline" 0 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: actions/github-script@v7
      - uses: ./local
      - uses: docker://alpine:3
      - run: echo \"  uses: evil/act@v1\"
      # uses: evil/act@v1"
expect "control: github-script exact repo, local, docker, echoed and commented text" 0 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: actions/checkout@$SHA40"
printf "name: x\njobs:\n  a:\n    steps:\n      - uses: evil/act@v1\n" > "$d/.github/workflows/a.yml.template"
printf "uses: evil/act@v1\n" > "$d/.github/workflows/notes.txt"
expect "control: only *.yml and *.yaml are read" 0 "$d"

# --- mutants: one per hole -------------------------------------------------
d=$(case_dir); workflow "$d" a.yml "      - uses: evil/act@v1"
expect "mutant: unpinned ref, no lockfile" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "$USES_CHECKOUT
      - uses: evil/act@v1"
lock_for "$d" a.yml "$CHECKOUT"
expect "mutant: ref absent from the lock" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: evil-actions/github-script@main"
expect "mutant: look-alike repo containing actions/github-script" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: actions/github-script-evil@main"
expect "mutant: repo whose name starts with actions/github-script" 1 "$d"

d=$(case_dir)
workflow "$d" a.yml "$USES_CHECKOUT"
workflow "$d" b.yml "$USES_CHECKOUT"
lock_for "$d" a.yml "$CHECKOUT"
expect "mutant: ref locked for another workflow only (no entry for this one)" 1 "$d"

d=$(case_dir)
workflow "$d" a.yml "$USES_CHECKOUT"
workflow "$d" b.yml "      - uses: actions/setup-node@v6.0.0"
wfs=$(lock_wf a.yml "$CHECKOUT"; lock_wf b.yml 'actions/setup-node@v6.0.0')
deps=$(lock_dep "$CHECKOUT" "$GOOD_DEP"; lock_dep 'actions/setup-node@v6.0.0' "$GOOD_DEP")
lockfile "$d" "$wfs" "$deps"
expect "control: two workflows each locked for their own ref" 0 "$d"

d=$(case_dir)
workflow "$d" a.yml "$USES_CHECKOUT"
workflow "$d" b.yml "$USES_CHECKOUT"
wfs=$(lock_wf a.yml "$CHECKOUT"; lock_wf b.yml 'actions/setup-node@v6.0.0')
deps=$(lock_dep "$CHECKOUT" "$GOOD_DEP")
lockfile "$d" "$wfs" "$deps"
expect "mutant: ref locked for another workflow only (entry exists, ref not in it)" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - { uses: evil/act@v1 }"
expect "mutant: unpinned ref in a flow mapping" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - { name: n, uses: evil/act@v1, with: { x: y } }"
expect "mutant: unpinned ref after a comma in a flow mapping" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: 'evil/act@v1'"
expect "mutant: unpinned quoted ref" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: \"evil/act@v1\" # why not"
expect "mutant: unpinned double-quoted ref with a comment" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "$USES_CHECKOUT"
wfs=$(lock_wf a.yml "$CHECKOUT")
lockfile "$d" "$wfs" ""
expect "mutant: listed under the workflow but no dependencies record" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "$USES_CHECKOUT"
lock_for "$d" a.yml "$CHECKOUT" 'sha1-nothex'
expect "mutant: dependencies commit is not sha1-<40 hex>" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "$USES_CHECKOUT"
lock_for "$d" a.yml "$CHECKOUT" "sha1-${SHA40}00"
expect "mutant: dependencies commit has 42 hex digits" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "$USES_CHECKOUT"
wfs=$(lock_wf a.yml "$CHECKOUT")
deps=$(printf "    '%s':\n        ref: 'v7.0.1'\n" "$CHECKOUT")
lockfile "$d" "$wfs" "$deps"
expect "mutant: dependencies record without a commit" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "$USES_CHECKOUT"
printf 'garbage\n' > "$d/.github/workflows/actions.lock"
expect "mutant: unparseable lockfile resolves nothing" 1 "$d"

# --- review findings: one control or mutant each ---------------------------
d=$(case_dir); workflow "$d" a.yml "      - uses: evil/act@$SHA40,mutable"
expect "mutant: block-form SHA-shaped prefix then comma and mutable suffix, no lockfile" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: evil/act@$SHA40,mutable"
lock_for "$d" a.yml 'actions/checkout@v7.0.1'
expect "mutant: block-form SHA-shaped prefix then comma, lockfile present" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      # Example: { uses: evil/act@v1 }
      - run: echo '{ uses: evil/act@v1 }'
      - run: echo \"a, uses: evil/act@v1\""
expect "control: flow-mapping text in a comment and in quoted shell is not a step" 0 "$d"

d=$(case_dir)
workflow "$d" ci.yml "$USES_CHECKOUT"
workflow "$d" CI.yml "$USES_CHECKOUT"
lock_for "$d" ci.yml "$CHECKOUT"
expect "mutant: ci.yml locked, CI.yml (same tag) has no entry" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: owner/act@Release"
lock_for "$d" a.yml 'owner/act@release'
expect "mutant: tag differs from the locked tag only in case" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: Owner/Act@Release"
lock_for "$d" a.yml 'owner/act@Release'
expect "control: owner/repo case may differ, the tag matches exactly" 0 "$d"

d=$(case_dir); workflow "$d" a.yml "      - { \"uses\": evil/act@v1 }"
expect "mutant: double-quoted uses key in a flow mapping" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - { name: n, 'uses' : evil/act@v1 }"
expect "mutant: single-quoted uses key, blank before colon, in a flow mapping" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - \"uses\": evil/act@v1"
expect "mutant: double-quoted uses key in block form" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses : evil/act@v1"
expect "mutant: blank before the colon in block form" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - { uses: evil/act@$SHA40#mutable }"
expect "mutant: flow-mapping SHA-shaped prefix then adjacent #tag, no lockfile" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - { \"uses\": actions/checkout@$SHA40 } # pinned
      - { 'uses': actions/checkout@$SHA40, with: { x: y } }"
expect "control: quoted uses keys with inline SHAs, comment after a blank" 0 "$d"

d=$(case_dir); job "$d" a.yml "    steps: [ { uses: evil/act@v1 } ]"
expect "mutant: flow collection opened after a key, mid-line" 1 "$d"

d=$(case_dir); job "$d" a.yml "    steps: [{\"uses\":evil/act@v1}]"
expect "mutant: JSON-style flow step, quoted key, no blank after the colon" 1 "$d"

d=$(case_dir); job "$d" a.yml "    steps: [ { uses: actions/checkout@$SHA40 } ]"
expect "control: mid-line flow step pinned" 0 "$d"

d=$(case_dir); workflow "$d" a.yml "      - run: echo { uses: evil/act@v1 }
      - uses: actions/checkout@$SHA40
        with: { note: '{ uses: evil/act@v1 }' }"
expect "control: braces in a plain or quoted scalar are text" 0 "$d"


d=$(case_dir); workflow "$d" a.yml "$(printf '      -\tuses: evil/act@v1')"
expect "mutant: tab after the list dash" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: 'evil/act@$SHA40''mutable'"
expect "mutant: quoted ref with a doubled apostrophe after a SHA-shaped prefix" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - { name: Checkout,
          name2: x, uses: evil/act@v1 }"
expect "mutant: flow step split across lines, uses after another key" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - run: |
          {
            echo unbalanced
      - uses: evil/act@v1"
expect "mutant: unbalanced { in a block scalar, then a mutable step" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - { name: Checkout, # first line
          uses: actions/checkout@$SHA40 }
      - uses: 'actions/checkout@$SHA40'"
expect "control: pinned flow step split across lines, comment inside" 0 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: github/codeql-action/init@v3"
wfs=$(lock_wf a.yml github/codeql-action/init@v3 github/codeql-action@v3)
deps=$(lock_dep github/codeql-action/init@v3 "")$'\n'$(lock_dep github/codeql-action@v3 "$GOOD_DEP")
lockfile "$d" "$wfs" "$deps"
expect "control: subpath ref resolved through its repository root only" 0 "$d"

# --- node properties, positions, escapes, explicit keys, split values -----
d=$(case_dir); workflow "$d" a.yml "      - &s { uses: evil/act@v1 }"
expect "mutant: anchored flow step" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - &s { uses: actions/checkout@$SHA40 }"
expect "control: anchored flow step, inline SHA" 0 "$d"

d=$(case_dir); workflow "$d" a.yml "      - !!map { uses: evil/act@v1 }"
expect "mutant: tagged flow step" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - &a uses: evil/act@v1"
expect "mutant: anchor before the uses key" 1 "$d"

d=$(case_dir); printf '# SPDX-License-Identifier: MPL-2.0\non: push\n&j jobs:\n  a:\n    runs-on: x\n    steps:\n      - uses: evil/act@v1\n' > "$d/.github/workflows/a.yml"
expect "mutant: anchor before the jobs key" 1 "$d"

d=$(case_dir); printf '# SPDX-License-Identifier: MPL-2.0\non: push\n&j jobs:\n  a:\n    runs-on: x\n    steps:\n      - uses: actions/checkout@%s\n' "$SHA40" > "$d/.github/workflows/a.yml"
expect "control: anchor before the jobs key, inline SHA" 0 "$d"

d=$(case_dir); job "$d" a.yml "    env:
      K: &u uses
    steps:
      - *u : evil/act@v1"
expect "mutant: alias as the step key, block form" 1 "$d"

d=$(case_dir); job "$d" a.yml "    env:
      K: &u uses
    steps:
      - { *u : evil/act@v1 }"
expect "mutant: alias as the step key, flow form" 1 "$d"

d=$(case_dir); printf '# SPDX-License-Identifier: MPL-2.0\non: push\nenv:\n  K: &u uses\njobs:\n  a:\n    *u : evil/repo/.github/workflows/w.yml@v1\n' > "$d/.github/workflows/a.yml"
expect "mutant: alias as a reusable-workflow key" 1 "$d"

d=$(case_dir); job "$d" a.yml "    env: { uses: hello }
    steps:
      - uses: actions/checkout@$SHA40"
expect "control: a uses key under env (flow) is not an action" 0 "$d"

d=$(case_dir); job "$d" a.yml "    env:
      uses: hello
    steps:
      - uses: actions/checkout@$SHA40
        with:
          uses: hello"
expect "control: a uses key under env or with (block) is not an action" 0 "$d"

d=$(case_dir); job "$d" a.yml "    x-step: &st
      uses: evil/act@v1
    steps:
      - *st"
expect "mutant: step placed by an alias" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - ? uses
        : evil/act@v1"
expect "mutant: explicit ? key" 1 "$d"

d=$(case_dir); workflow "$d" a.yml '      - "u\x73es": evil/act@v1'
expect "mutant: escaped uses key, block form" 1 "$d"

d=$(case_dir); workflow "$d" a.yml '      - { "u\x73es": evil/act@v1 }'
expect "mutant: escaped uses key, flow form" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses:
          evil/act@v1"
expect "mutant: ref on the line after the uses key" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: \"actions/checkout@$SHA40
          evil\""
expect "mutant: quoted ref left open across lines" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: actions/checkout@$SHA40
          evil"
expect "mutant: plain ref continued on the next line" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - { name: a,
      uses: evil/act@v1 }"
expect "mutant: flow step continued at no deeper indent" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: \"actions/checkout@$SHA40
          #evil\"
      - uses: actions/checkout@$SHA40"
expect "mutant: open quote whose next line reads as a comment" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - run: |
          f() {
          }
          uses: evil/act@v1
      - uses: actions/checkout@$SHA40
        with:
          uses: hello"
expect "control: braces and uses text in a run block are text" 0 "$d"

d=$(case_dir); job "$d" a.yml "    steps:
    - uses: evil/act@v1"
expect "mutant: indentless step list" 1 "$d"

d=$(case_dir); printf '# SPDX-License-Identifier: MPL-2.0\n--- { name: t, on: push, jobs: { a: { runs-on: x, steps: [ { uses: evil/act@v1 } ] } } }\n' > "$d/.github/workflows/a.yml"
expect "mutant: whole workflow in flow form after the --- marker" 1 "$d"

d=$(case_dir); printf '# SPDX-License-Identifier: MPL-2.0\n---\njobs:\n  a:\n    steps:\n      - uses: actions/checkout@%s\n---\n        uses: hello\n...\n---\nenv:\n  uses: hello\n' "$SHA40" > "$d/.github/workflows/a.yml"
expect "control: document markers end the jobs block" 0 "$d"

echo
echo "check-action-pinning: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
