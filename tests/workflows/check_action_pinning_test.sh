#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
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
# PINNING_SCRIPT overrides the script under test (used to confirm the mutants
# are caught by the new script and missed by the old one).
set -euo pipefail

SCRIPT="${PINNING_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/check-action-pinning.js}"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

SHA40="0123456789abcdef0123456789abcdef01234567"
pass=0
fail=0
n=0

# lock_entry WORKFLOW REF...  -> a `workflows:` item
lock_wf() {
  local w="$1"; shift
  printf "    '.github/workflows/%s':\n" "$w"
  local r
  for r in "$@"; do printf "        - '%s'\n" "$r"; done
}
# lock_dep REF COMMIT -> a `dependencies:` item
lock_dep() {
  printf "    '%s':\n        ref: 'x'\n        commit: '%s'\n        owner_id: 1\n" "$1" "$2"
}

# case_dir -> prints a fresh fixture directory with an empty workflows dir
case_dir() {
  n=$((n + 1))
  local d="$FIXTURE/case$n"
  mkdir -p "$d/.github/workflows"
  printf '%s\n' "$d"
}

# workflow DIR NAME BODY
workflow() {
  printf '# SPDX-License-Identifier: MPL-2.0\nname: t\non: push\njobs:\n  a:\n    runs-on: ubuntu-24.04\n    steps:\n%s\n' "$3" \
    > "$1/.github/workflows/$2"
}

# lockfile DIR WORKFLOWS-BODY DEPENDENCIES-BODY
lockfile() {
  printf "version: 'v0.0.3'\nworkflows:\n%s\ndependencies:\n%s\n" "$2" "$3" > "$1/.github/workflows/actions.lock"
}

# expect DESCRIPTION WANT DIR
expect() {
  local desc="$1" want="$2" d="$3" got out
  set +e
  out=$(cd "$d" && bun "$SCRIPT" 2>&1)
  got=$?
  set -e
  if [ "$got" -eq "$want" ]; then
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

d=$(case_dir); workflow "$d" a.yml "      - uses: actions/checkout@v7.0.1"
lockfile "$d" "$(lock_wf a.yml 'actions/checkout@v7.0.1')" "$(lock_dep 'actions/checkout@v7.0.1' "$GOOD_DEP")"
expect "control: tag ref locked for its own workflow" 0 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: SonarSource/sonarcloud-github-action@v5.0.0"
lockfile "$d" "$(lock_wf a.yml 'sonarsource/sonarcloud-github-action@v5.0.0')" "$(lock_dep 'sonarsource/sonarcloud-github-action@v5.0.0' "$GOOD_DEP")"
expect "control: lock case differs from workflow case" 0 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: github/codeql-action/init@v4.38.2"
lockfile "$d" "$(lock_wf a.yml 'github/codeql-action@v4.38.2')" "$(lock_dep 'github/codeql-action@v4.38.2' "$GOOD_DEP")"
expect "control: subpath action locked under its repo root" 0 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: 'actions/checkout@v7.0.1'
      - uses: \"actions/checkout@v7.0.1\" # trailing comment"
lockfile "$d" "$(lock_wf a.yml 'actions/checkout@v7.0.1')" "$(lock_dep 'actions/checkout@v7.0.1' "$GOOD_DEP")"
expect "control: quoted locked refs decode to the lock entry" 0 "$d"

d=$(case_dir); workflow "$d" a.yml "      - { uses: actions/checkout@v7.0.1, with: { fetch-depth: 0 } }
      - { name: n, uses: actions/checkout@$SHA40 }"
lockfile "$d" "$(lock_wf a.yml 'actions/checkout@v7.0.1')" "$(lock_dep 'actions/checkout@v7.0.1' "$GOOD_DEP")"
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

d=$(case_dir); workflow "$d" a.yml "      - uses: actions/checkout@v7.0.1
      - uses: evil/act@v1"
lockfile "$d" "$(lock_wf a.yml 'actions/checkout@v7.0.1')" "$(lock_dep 'actions/checkout@v7.0.1' "$GOOD_DEP")"
expect "mutant: ref absent from the lock" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: evil-actions/github-script@main"
expect "mutant: look-alike repo containing actions/github-script" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: actions/github-script-evil@main"
expect "mutant: repo whose name starts with actions/github-script" 1 "$d"

d=$(case_dir)
workflow "$d" a.yml "      - uses: actions/checkout@v7.0.1"
workflow "$d" b.yml "      - uses: actions/checkout@v7.0.1"
lockfile "$d" "$(lock_wf a.yml 'actions/checkout@v7.0.1')" "$(lock_dep 'actions/checkout@v7.0.1' "$GOOD_DEP")"
expect "mutant: ref locked for another workflow only (no entry for this one)" 1 "$d"

d=$(case_dir)
workflow "$d" a.yml "      - uses: actions/checkout@v7.0.1"
workflow "$d" b.yml "      - uses: actions/setup-node@v6.0.0"
lockfile "$d" "$(lock_wf a.yml 'actions/checkout@v7.0.1')
$(lock_wf b.yml 'actions/setup-node@v6.0.0')" "$(lock_dep 'actions/checkout@v7.0.1' "$GOOD_DEP")
$(lock_dep 'actions/setup-node@v6.0.0' "$GOOD_DEP")"
expect "control: two workflows each locked for their own ref" 0 "$d"

d=$(case_dir)
workflow "$d" a.yml "      - uses: actions/checkout@v7.0.1"
workflow "$d" b.yml "      - uses: actions/checkout@v7.0.1"
lockfile "$d" "$(lock_wf a.yml 'actions/checkout@v7.0.1')
$(lock_wf b.yml 'actions/setup-node@v6.0.0')" "$(lock_dep 'actions/checkout@v7.0.1' "$GOOD_DEP")"
expect "mutant: ref locked for another workflow only (entry exists, ref not in it)" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - { uses: evil/act@v1 }"
expect "mutant: unpinned ref in a flow mapping" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - { name: n, uses: evil/act@v1, with: { x: y } }"
expect "mutant: unpinned ref after a comma in a flow mapping" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: 'evil/act@v1'"
expect "mutant: unpinned quoted ref" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: \"evil/act@v1\" # why not"
expect "mutant: unpinned double-quoted ref with a comment" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: actions/checkout@v7.0.1"
lockfile "$d" "$(lock_wf a.yml 'actions/checkout@v7.0.1')" ""
expect "mutant: listed under the workflow but no dependencies record" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: actions/checkout@v7.0.1"
lockfile "$d" "$(lock_wf a.yml 'actions/checkout@v7.0.1')" "$(lock_dep 'actions/checkout@v7.0.1' 'sha1-nothex')"
expect "mutant: dependencies commit is not sha1-<40 hex>" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: actions/checkout@v7.0.1"
lockfile "$d" "$(lock_wf a.yml 'actions/checkout@v7.0.1')" "$(lock_dep 'actions/checkout@v7.0.1' "sha1-${SHA40}00")"
expect "mutant: dependencies commit has 42 hex digits" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: actions/checkout@v7.0.1"
lockfile "$d" "$(lock_wf a.yml 'actions/checkout@v7.0.1')" "    'actions/checkout@v7.0.1':
        ref: 'v7.0.1'"
expect "mutant: dependencies record without a commit" 1 "$d"

d=$(case_dir); workflow "$d" a.yml "      - uses: actions/checkout@v7.0.1"
printf 'garbage\n' > "$d/.github/workflows/actions.lock"
expect "mutant: unparseable lockfile resolves nothing" 1 "$d"

echo
echo "check-action-pinning: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
