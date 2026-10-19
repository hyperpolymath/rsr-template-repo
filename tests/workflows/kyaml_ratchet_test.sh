#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Unit tests of the actual KYAML workflow step bodies, with downloads and
# checksum commands replaced at the process boundary. No network is used.
# Usage: bash tests/workflows/kyaml_ratchet_test.sh
# Requires Mike Farah yq v4; all fixtures are deleted on exit.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
workflow="$repo/.github/workflows/estate-rules.yml"
fail() { echo "FAIL: $*" >&2; exit 1; }

install_name='Install verified yq 4.53.3 and kyaml-format.sh (standards 75bd599)'
gate_name='Converted YAML stays KYAML'
export install_name gate_name
for step_name in "$install_name" "$gate_name"; do
    export step_name
    count=$(yq '[.jobs.estate-rules.steps[] | select(.name == strenv(step_name))] | length' "$workflow")
    [ "$count" = 1 ] || fail "expected exactly one $step_name step"
    metadata=$(yq -o json -I 0 '.jobs.estate-rules.steps[] | select(.name == strenv(step_name)) | [.if, .continue-on-error]' "$workflow")
    [ "$metadata" = '[null,null]' ] || fail "$step_name may be skipped or allowed to fail"
done
indices=$(yq -o json -I 0 '.jobs.estate-rules.steps | to_entries | [.[] | select(.value.name == strenv(install_name) or .value.name == strenv(gate_name)) | .value.name]' "$workflow")
[ "$indices" = "[\"$install_name\",\"$gate_name\"]" ] || fail 'formatter installation must precede the ratchet'
yq -r '.jobs.estate-rules.steps[] | select(.name == strenv(install_name)) | .run' "$workflow" > "$scratch/install.sh"
yq -r '.jobs.estate-rules.steps[] | select(.name == strenv(gate_name)) | .run' "$workflow" > "$scratch/gate.sh"

mkdir -p "$scratch/bin" "$scratch/assets"
cat > "$scratch/assets/yq" <<'YQ'
#!/usr/bin/env bash
exit 0
YQ
cat > "$scratch/assets/kyaml-format.sh" <<'FORMATTER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$FORMATTER_ARGS"
exit "${FORMATTER_STATUS:-0}"
FORMATTER

# These mocks reject unexpected endpoints/flags and inspect the pinned digest
# manifests. Failure injection tests the runner's handling of both downloads
# and both checksum failures, independently of the upstream formatter.
cat > "$scratch/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
proto= redir= fail= silent= show= location= url= output=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --proto) proto=$2; shift 2 ;;
        --proto-redir) redir=$2; shift 2 ;;
        --fail) fail=yes; shift ;;
        --silent) silent=yes; shift ;;
        --show-error) show=yes; shift ;;
        --location) location=yes; shift ;;
        --output) output=$2; shift 2 ;;
        https://*) url=$1; shift ;;
        *) echo "unexpected curl argument: $1" >&2; exit 90 ;;
    esac
done
[ "$proto/$redir/$fail/$silent/$show/$location" = '=https/=https/yes/yes/yes/yes' ] || exit 91
case "$url" in
    https://github.com/mikefarah/yq/releases/download/v4.53.3/yq_linux_amd64)
        asset=yq
        [ "$output" = "$RUNNER_TEMP/yq-bin/yq" ] || exit 92 ;;
    https://raw.githubusercontent.com/hyperpolymath/standards/75bd5994470661a099df562d6d5ad2fe744dbd66/scripts/kyaml-format.sh)
        asset=kyaml-format.sh
        [ "$output" = "$RUNNER_TEMP/kyaml-format.sh" ] || exit 92 ;;
    *) echo "unexpected download: $url" >&2; exit 93 ;;
esac
echo "curl:$asset" >> "$EVENTS"
[ "${FAIL_AT:-}" != "curl:$asset" ] || exit 22
cp "$ASSETS/$asset" "$output"
CURL
cat > "$scratch/bin/sha256sum" <<'CHECKSUM'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 2 ] && [ "$1" = --check ] && [ "$2" = --strict ] || exit 94
IFS= read -r manifest
case "$manifest" in
    "fa52a4e758c63d38299163fbdd1edfb4c4963247918bf9c1c5d31d84789eded4  $RUNNER_TEMP/yq-bin/yq")
        asset=yq
        downloaded="$RUNNER_TEMP/yq-bin/yq"
        [ ! -x "$RUNNER_TEMP/yq-bin/yq" ] || exit 95 ;;
    "5fddd58fc8cbd2b68766ef5b4b5ba39f299da3f27252ae6cdcff0a641bbaef18  $RUNNER_TEMP/kyaml-format.sh")
        asset=kyaml-format.sh
        downloaded="$RUNNER_TEMP/kyaml-format.sh" ;;
    *) echo "unexpected checksum manifest: $manifest" >&2; exit 96 ;;
esac
echo "sha256:$asset" >> "$EVENTS"
[ -f "$downloaded" ] || exit 97
[ "${FAIL_AT:-}" != "sha256:$asset" ] || exit 1
CHECKSUM
chmod +x "$scratch/bin/curl" "$scratch/bin/sha256sum"

original_path=$PATH
export ASSETS="$scratch/assets"
export FORMATTER_ARGS="$scratch/formatter-args"
run_install() {
    local scenario=$1 expected_status=$2 expected_events=$3 status=0
    # Spaces in GitHub runner paths must survive every invocation/manifest.
    export RUNNER_TEMP="$scratch/$scenario/runner temp"
    export GITHUB_PATH="$scratch/$scenario/github path"
    export EVENTS="$scratch/$scenario/events"
    mkdir -p "$RUNNER_TEMP"
    : > "$GITHUB_PATH"
    : > "$EVENTS"
    FAIL_AT="$scenario" PATH="$scratch/bin:$original_path" \
        bash --noprofile --norc -e "$scratch/install.sh" > "$scratch/install.log" 2>&1 || status=$?
    [ "$status" -eq "$expected_status" ] || { cat "$scratch/install.log" >&2; fail "$scenario: expected exit $expected_status, got $status"; }
    [ "$(cat "$EVENTS")" = "$expected_events" ] || fail "$scenario: wrong download/verification sequence: $(cat "$EVENTS")"
}

all_events=$'curl:yq\nsha256:yq\ncurl:kyaml-format.sh\nsha256:kyaml-format.sh'
run_install success 0 "$all_events"
[ -x "$RUNNER_TEMP/yq-bin/yq" ] || fail 'verified yq was not made executable'
[ "$(cat "$GITHUB_PATH")" = "$RUNNER_TEMP/yq-bin" ] || fail 'verified yq directory was not added to the runner path'
cmp -s "$ASSETS/yq" "$RUNNER_TEMP/yq-bin/yq" || fail 'yq downloaded to the wrong path'
cmp -s "$ASSETS/kyaml-format.sh" "$RUNNER_TEMP/kyaml-format.sh" || fail 'formatter downloaded to the wrong path'

compose=build/container/compose.yaml
example=build/container/compose.example.yaml
policy=build/container/stapeln/.gatekeeper.yaml
# make_tree NAME ENTRY...: a fixture tree holding only the named files, plus
# archetypes/ (the template marker) when an entry is "archetypes".
make_tree() {
    local tree="$scratch/trees/$1" entry
    shift
    mkdir -p "$tree"
    for entry in "$@"; do
        if [ "$entry" = archetypes ]; then
            mkdir -p "$tree/archetypes"
        else
            mkdir -p "$tree/$(dirname "$entry")"
            : > "$tree/$entry"
        fi
    done
    printf '%s\n' "$tree"
}
# run_gate TREE FORMATTER_STATUS: sets gate_status and leaves the step's output
# in $scratch/gate.log. Always run the extracted body as a separate process:
# testing it in a shell conditional would suppress errexit inside it.
run_gate() {
    rm -f "$FORMATTER_ARGS"
    gate_status=0
    (cd "$1"; FORMATTER_STATUS=$2 bash --noprofile --norc -e "$scratch/gate.sh") > "$scratch/gate.log" 2>&1 || gate_status=$?
}
expect_args() {
    local expected
    expected=$(printf '%s\n' --check "$@")
    [ -f "$FORMATTER_ARGS" ] || fail "$label: formatter did not run"
    [ "$(cat "$FORMATTER_ARGS")" = "$expected" ] \
        || fail "$label: ratchet must check exactly the converted files present, with no workflow or bot-owned configs"
}
expect_log() { grep -Fq -- "$1" "$scratch/gate.log" || fail "$label: missing '$1' in: $(cat "$scratch/gate.log")"; }

label='template'
tree=$(make_tree template archetypes "$compose" "$example" "$policy")
for expected_status in 0 1 2; do
    run_gate "$tree" "$expected_status"
    [ "$gate_status" -eq "$expected_status" ] || fail "ratchet swallowed formatter exit $expected_status (got $gate_status)"
    expect_args "$compose" "$example" "$policy"
done
echo 'PASS: pinned HTTPS downloads are verified in order, runner paths with spaces work, and the ratchet propagates clean/drift/refusal statuses'

# The template must keep every converted file: losing one is an error there,
# and the formatter must not run on the rest as if nothing were wrong.
label='template missing a file'
tree=$(make_tree template-missing archetypes "$compose" "$example")
run_gate "$tree" 0
[ "$gate_status" -eq 1 ] || fail "$label: expected exit 1, got $gate_status"
[ ! -f "$FORMATTER_ARGS" ] || fail "$label: formatter ran on a template with a file missing"
expect_log "::error::$policy is missing from the template"

# Minted repositories, one per container.just narrowing: full container,
# no-stapeln, container-keep without portable, and no-container.
label='minted, full container'
tree=$(make_tree minted-full "$compose" "$example" "$policy")
run_gate "$tree" 1
[ "$gate_status" -eq 1 ] || fail "$label: ratchet swallowed formatter exit 1 (got $gate_status)"
expect_args "$compose" "$example" "$policy"

label='minted, no-stapeln'
tree=$(make_tree minted-no-stapeln "$compose" "$example")
run_gate "$tree" 0
[ "$gate_status" -eq 0 ] || fail "$label: expected exit 0, got $gate_status"
expect_args "$compose" "$example"
expect_log "::notice::$policy was removed at mint"

label='minted, not portable'
tree=$(make_tree minted-not-portable "$policy")
run_gate "$tree" 2
[ "$gate_status" -eq 2 ] || fail "$label: ratchet swallowed formatter exit 2 (got $gate_status)"
expect_args "$policy"
expect_log "::notice::$compose was removed at mint"
expect_log "::notice::$example was removed at mint"

label='minted, no-container'
tree=$(make_tree minted-no-container)
run_gate "$tree" 1
[ "$gate_status" -eq 0 ] || fail "$label: expected exit 0, got $gate_status"
[ ! -f "$FORMATTER_ARGS" ] || fail "$label: formatter ran with no files to check"
for file in "$compose" "$example" "$policy"; do expect_log "::notice::$file was removed at mint"; done
expect_log 'nothing to check'
echo 'PASS: the template requires every converted file; minted repositories check what narrowing kept and name what it removed'

run_install curl:yq 22 'curl:yq'
[ ! -s "$GITHUB_PATH" ] || fail 'failed yq download was added to PATH'
run_install sha256:yq 1 $'curl:yq\nsha256:yq'
[ ! -x "$RUNNER_TEMP/yq-bin/yq" ] || fail 'unverified yq became executable'
[ ! -s "$GITHUB_PATH" ] || fail 'unverified yq was added to PATH'
run_install curl:kyaml-format.sh 22 $'curl:yq\nsha256:yq\ncurl:kyaml-format.sh'
run_install sha256:kyaml-format.sh 1 "$all_events"
echo 'PASS: each failed download or checksum stops installation and cannot report success'
