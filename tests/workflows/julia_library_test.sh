#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Focused regressions for PR #240: package UUIDv8 minting and job timeouts.
# Executes the recipe's actual UUID block, with tool availability isolated
# from the host. No mint, network access, Bun or Julia installation is needed.
# Usage: bash tests/workflows/julia_library_test.sh
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
bash_bin=$(command -v bash)
python_bin=$(command -v python3) || { echo 'FAIL: python3 is needed to exercise the shipped fallback' >&2; exit 1; }
checks=0
# Print all arguments as a failure message to stderr and exit the test with status 1.
fail() { echo "FAIL: $*" >&2; exit 1; }
# Compare actual $1 with expected $2, using $3 as the diagnostic label.
# Increment checks on equality; otherwise report the mismatch and exit with status 1.
equal() {
  [ "$1" = "$2" ] || fail "$3: got '$1', expected '$2'"
  checks=$((checks + 1))
}

# Match the outer indentation so the nested if/elif/else remains intact.
# Stop after the first block: a later Julia block handles .in renames.
# Strip the recipe's four spaces as Just does, including inside Python.
awk '
  /^    if \[ "\$ARCHETYPE" = "julia-library" \]; then$/ { copying = 1 }
  copying { last = ($0 ~ /^    fi$/); sub(/^    /, ""); print; if (last) exit }
' "$repo/build/just/repo-init.just" > "$fixture/mint.sh"
[ -s "$fixture/mint.sh" ] || fail 'package UUID block not found in repo-init'

mkdir -p "$fixture/python" "$fixture/bun" "$fixture/bun-only" "$fixture/empty" "$fixture/broken"
ln -s "$python_bin" "$fixture/python/python3"
# An installed uuidgen must never restore the old v5 package mint.
printf '#!%s\nexit 91\n' "$bash_bin" > "$fixture/python/uuidgen"
chmod +x "$fixture/python/uuidgen"

# derive TOOL_DIR OWNER REPO [STANDARDS_SCRIPT [ARCHETYPE [REPO_UUID]]]
# Execute the shipped UUID rule with the supplied identity and isolated tools.
# Print PACKAGE_UUID and write NUL-separated substitutions to fixture/sed.args;
# return the subprocess status, including generator failures.
# env -i prevents host Bun/Python, user config and exported functions from
# accidentally satisfying a branch. The subprocess only needs Bash builtins
# and whichever generator this test explicitly places on PATH.
derive() {
  env -i PATH="$1" OWNER="$2" REPO="$3" \
    STANDARDS_UUID_V8_JS="${4:-}" ARCHETYPE="${5:-julia-library}" \
    REPO_UUID="${6:-UNASSIGNED}" BUN_LOG="$fixture/bun.args" \
    "$bash_bin" -c '
      set -euo pipefail
      LB="{{" RB="}}" PACKAGE_UUID=UNTOUCHED
      SED_ARGS=()
      source "$1" >/dev/null
      printf "%s\n" "$PACKAGE_UUID"
      if [ "${#SED_ARGS[@]}" -gt 0 ]; then
        printf "%s\0" "${SED_ARGS[@]}" > "$2"
      else
        : > "$2"
      fi
    ' _ "$fixture/mint.sh" "$fixture/sed.args"
}

# Fixed vectors independently calculated with Node crypto (SHA-256). These
# exercise version/variant replacement AND preservation of the remaining bits.
while read -r owner name expected; do
  equal "$(derive "$fixture/python" "$owner" "$name")" "$expected" "UUID for $owner/$name"
done <<'VECTORS'
hyperpolymath mintcheck b4839a75-05b9-8c83-a497-2aa751ab7f19
example-owner MintCheck.jl 9271df15-3174-8475-ac0b-136d649c1f76
other-owner MintCheck.jl a77b0d36-98a4-81aa-9457-25af7f040243
example-owner OtherPackage.jl 86fa698a-692e-88c1-82ad-c1a986e8700d
example-owner mint-check 88f60d1e-793d-8026-8c30-5ceb4c99a728
VECTORS
expected=9271df15-3174-8475-ac0b-136d649c1f76
equal "$(derive "$fixture/python" example-owner MintCheck.jl)" "$expected" 're-mint is deterministic'
equal "$(derive "$fixture/python" example-owner MintCheck.jl '' julia-library 00000000-0000-8000-8000-000000000000)" \
  "$expected" 'package identity is independent of the repository UUID'

# Verify the real substitution expression reaches Project.toml, including
# every occurrence of the token in the new explanatory comment.
mapfile -d '' -t sed_args < "$fixture/sed.args"
sed "${sed_args[@]}" "$repo/archetypes/julia-library/overlay/Project.toml.in" > "$fixture/Project.toml"
equal "$(sed -n 's/^uuid = "\([^"]*\)"$/\1/p' "$fixture/Project.toml")" "$expected" 'minted Project.toml UUID'
if grep -qF '{{PACKAGE_UUID}}' "$fixture/Project.toml"; then fail 'package UUID token survived substitution'; fi

# Bun is preferred only when the standards implementation exists. The stub
# checks the invocation contract; the real Python implementation above owns
# the digest assertions. A path with spaces must remain a single argument.
standards="$fixture/standards tools/uuid-v8.js"
mkdir -p "$(dirname "$standards")"
: > "$standards"
{
  printf '#!%s\n' "$bash_bin"
  cat <<'BUN'
set -euo pipefail
printf '%s\n' "$@" > "$BUN_LOG"
printf '%s\n' '9271df15-3174-8475-ac0b-136d649c1f76'
BUN
} > "$fixture/bun/bun"
printf '#!%s\nexit 92\n' "$bash_bin" > "$fixture/bun/python3"
chmod +x "$fixture/bun/bun" "$fixture/bun/python3"
equal "$(derive "$fixture/bun" example-owner MintCheck.jl "$standards")" "$expected" 'Bun takes precedence over Python'
equal "$(cat "$fixture/bun.args")" "$(printf '%s\n' "$standards" c julia-package-identity github.com/example-owner/MintCheck.jl)" \
  'Bun receives the standards path, profile, domain and preimage'

# Bun without a usable standards file falls back to Python, including when
# the setting names a missing file or a directory rather than a regular file.
ln -s "$fixture/bun/bun" "$fixture/python/bun"
for unavailable in '' "$fixture/missing.js" "$fixture/standards tools"; do
  rm -f "$fixture/bun.args"
  equal "$(derive "$fixture/python" example-owner MintCheck.jl "$unavailable")" "$expected" 'unavailable standards script uses Python'
  [ ! -e "$fixture/bun.args" ] || fail 'Bun ran without a standards file'
done

# A standards file on its own is insufficient when Bun is absent.
rm "$fixture/python/bun"
equal "$(derive "$fixture/python" example-owner MintCheck.jl "$standards")" "$expected" 'standards script without Bun uses Python'
equal "$(derive "$fixture/empty" example-owner MintCheck.jl)" UNASSIGNED 'no generator leaves identity unassigned'
mapfile -d '' -t sed_args < "$fixture/sed.args"
equal "$(sed "${sed_args[@]}" <<< 'uuid = "{{PACKAGE_UUID}}"')" 'uuid = "UNASSIGNED"' 'unassigned fallback reaches the package manifest'
ln -s "$fixture/bun/bun" "$fixture/bun-only/bun"
equal "$(derive "$fixture/bun-only" example-owner MintCheck.jl)" UNASSIGNED 'Bun without standards or Python leaves identity unassigned'
equal "$(derive "$fixture/bun" example-owner MintCheck.jl '' other-archetype)" UNTOUCHED 'other archetypes do not mint a package UUID'
[ ! -s "$fixture/sed.args" ] || fail 'other archetype gained a package UUID substitution'

# A failing generator must fail loudly rather than emitting a successful mint.
printf '#!%s\nexit 93\n' "$bash_bin" > "$fixture/broken/python3"
chmod +x "$fixture/broken/python3"
if derive "$fixture/broken" example-owner MintCheck.jl > /dev/null; then fail 'Python failure was ignored'; fi
printf '#!%s\nexit 94\n' "$bash_bin" > "$fixture/broken/bun"
chmod +x "$fixture/broken/bun"
if derive "$fixture/broken" example-owner MintCheck.jl "$standards" > /dev/null; then fail 'Bun failure was ignored'; fi

# Inspect only direct job fields: a timeout on another job or nested step
# must not satisfy a missing timeout. Duplicate timeout keys also fail.
workflow="$repo/archetypes/julia-library/overlay/.github/workflows/julia-ci.yml.in"
for job in fmt jet test; do
  minutes=10
  [ "$job" != test ] || minutes=15
  actual=$(awk -v job="$job" '
    /^  [A-Za-z0-9_-]+:/ { selected = ($0 == "  " job ":") }
    selected && /^    timeout-minutes:/ { print $2 }
  ' "$workflow")
  equal "$actual" "$minutes" "$job job timeout"
done
echo "PASS: $checks Julia library UUID and timeout checks; generator failures rejected"
