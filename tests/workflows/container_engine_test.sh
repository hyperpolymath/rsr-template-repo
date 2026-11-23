#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# The container recipes support exactly podman, nerdctl and docker. An engine
# name outside that set (rokur and svalinn are stack components, not engines)
# must fail loudly: non-zero exit and a message naming the supported engines.
# Control: a supported name must NOT be refused for being unsupported, so the
# check cannot pass by refusing everything. Also: container.just must not use
# the Bash 4 lowercase expansion, which macOS's Bash 3.2 rejects.
set -uo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo"
command -v just >/dev/null || { echo "FAIL: just is required" >&2; exit 1; }
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

for e in rokur svalinn selur bogus; do
    out=$(CONTAINER_ENGINE="$e" just container-verify 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && grep -q 'unsupported container engine' <<<"$out" && grep -q 'podman, nerdctl, docker' <<<"$out"; then
        echo "PASS: CONTAINER_ENGINE=$e refused (exit $rc)"
    else
        bad "CONTAINER_ENGINE=$e was not refused loudly (exit $rc): $out"
    fi
done

out=$(CONTAINER_ENGINE=rokur bash build/container/stapeln/ct-build.sh 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grep -q 'unsupported container engine' <<<"$out"; then
    echo "PASS: ct-build.sh refuses CONTAINER_ENGINE=rokur"
else bad "ct-build.sh accepted an unsupported engine (exit $rc): $out"; fi

# Control: a supported engine is not refused as unsupported.
for e in podman nerdctl docker; do
    out=$(CONTAINER_ENGINE="$e" just container-verify 2>&1)
    if grep -q 'unsupported container engine' <<<"$out"; then bad "CONTAINER_ENGINE=$e wrongly refused"; else echo "PASS: control: CONTAINER_ENGINE=$e not refused as unsupported"; fi
done

if grep -nE '\$\{[A-Za-z_]+,,\}' build/just/container.just; then
    bad "build/just/container.just uses \${var,,} (Bash 4 only)"
else echo "PASS: container.just uses no Bash 4 lowercase expansion"; fi
exit "$fail"
