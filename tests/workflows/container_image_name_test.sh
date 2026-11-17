#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# container_image_name_test.sh — controls for the image reference the container
# recipes (build/just/container.just) tag, push and run.
#
# The recipes used the project name as written. An image reference is lower
# case, so a repo whose name has capitals (any Julia package:
# CoprocessorRuntime.jl) got an invalid one. They now use `image`: the project
# name by repo-init's default-service-name rule (lower case, "." and "_" to
# "-"). `just --dry-run` prints each recipe as it would run, with nothing run.
#
# Requires just. Exit: 0 all controls hold (or no container module); 1 otherwise.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ ! -f "$REPO_DIR/build/just/container.just" ]]; then
    echo "SKIP: no build/just/container.just (containerisation was removed from this repo)"
    exit 0
fi
command -v just >/dev/null 2>&1 || { echo "FAIL: just is required" >&2; exit 1; }
cd "$REPO_DIR" || exit 1

FAILED=0
CHECKS=0
# equal LABEL GOT WANT
equal() {
    CHECKS=$((CHECKS + 1))
    if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; else FAILED=$((FAILED + 1)); echo "  FAIL  $1"; echo "        want: $3"; echo "        got:  $2"; fi
}
# image NAME -> the image name the recipes use for a project called NAME
image() { just --set project "$1" --evaluate image 2>&1; }
# refs NAME RECIPE -> every "<name>:latest" reference the recipe would run, one per line
refs() { just --set project "$1" --dry-run "$2" 2>&1 | grep -oE '[^ ]+:latest' | sort -u; }

equal "a lower-case slug is unchanged"           "$(image my-project)"            "my-project"
equal "capitals are lowered, the dot becomes -"  "$(image CoprocessorRuntime.jl)" "coprocessorruntime-jl"
equal "underscores become -"                     "$(image My_Repo.Thing)"         "my-repo-thing"

# The rule is repo-init's: the same name must come out of its two lines.
RULE="$(grep -E '^[[:space:]]*DEFAULT_SERVICE_NAME=' build/just/repo-init.just)"
if [[ "$(grep -c . <<<"$RULE")" -eq 2 ]]; then
    for name in CoprocessorRuntime.jl My_Repo.Thing my-project; do
        # shellcheck disable=SC2034  # REPO is read by the rule evaluated below
        REPO="$name"; DEFAULT_SERVICE_NAME=""
        eval "$RULE"
        equal "matches repo-init's default service name for $name" "$(image "$name")" "$DEFAULT_SERVICE_NAME"
    done
else
    CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1))
    echo "  FAIL  repo-init.just no longer derives DEFAULT_SERVICE_NAME in two lines; update this control"
fi

for recipe in container-build container-push container-run; do
    equal "$recipe uses a valid reference for CoprocessorRuntime.jl" \
        "$(refs CoprocessorRuntime.jl "$recipe")" "coprocessorruntime-jl:latest"
done

echo "$CHECKS controls, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
