#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# A tag-pinned reusable call must fail; an unresolvable SHA must fail; a good pin passes.
# The resolver is stubbed so this runs offline.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
good=a0760cea695a815a96b3944f3d03ee015da856d0; ghost=0123456789abcdef0123456789abcdef01234567
cat > "$t/stub.sh" <<RESOLVER_EOF
#!/usr/bin/env bash
[ "\$2" = "$good" ]
RESOLVER_EOF
chmod +x "$t/stub.sh"
mk() { mkdir -p "$t/$1"; printf 'name: x\non: push\njobs:\n  j:\n    uses: o/r/.github/workflows/w.yml@%s\n  k:\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: actions/checkout@v7\n' "$2" > "$t/$1/x.yml"; }
mk good $good; mk tag v1; mk ghost $ghost
# Flow-mapping and quoted-key spellings are read from the parsed document: a tag fails, a good SHA passes.
mkdir -p "$t/flow-tag" "$t/flow-good" "$t/quoted-tag" "$t/quoted-good"
printf 'name: x\non: push\njobs: {call: {uses: o/r/.github/workflows/w.yml@main}}\n' > "$t/flow-tag/x.yml"
printf 'name: x\non: push\njobs: {call: {uses: o/r/.github/workflows/w.yml@%s}}\n' "$good" > "$t/flow-good/x.yml"
printf 'name: x\non: push\njobs:\n  j:\n    "uses": o/r/.github/workflows/w.yml@v1\n' > "$t/quoted-tag/x.yml"
printf 'name: x\non: push\njobs:\n  j:\n    "uses": o/r/.github/workflows/w.yml@%s\n' "$good" > "$t/quoted-good/x.yml"
run() { REUSABLE_RESOLVER="$t/stub.sh" bash "$here/scripts/check-reusable-pins.sh" "$t/$1" >/dev/null 2>&1; }
fail=0
run good && echo "ok   full resolvable SHA passes" || { echo "FAIL good pin rejected"; fail=1; }
run tag && { echo "FAIL tag-pinned call accepted"; fail=1; } || echo "ok   tag-pinned call rejected"
run ghost && { echo "FAIL unresolvable SHA accepted"; fail=1; } || echo "ok   unresolvable SHA rejected"
run flow-tag && { echo "FAIL flow-mapping tag call accepted"; fail=1; } || echo "ok   flow-mapping tag call rejected"
run flow-good && echo "ok   flow-mapping SHA pin passes" || { echo "FAIL flow-mapping good pin rejected"; fail=1; }
run quoted-tag && { echo "FAIL quoted-key tag call accepted"; fail=1; } || echo "ok   quoted-key tag call rejected"
run quoted-good && echo "ok   quoted-key SHA pin passes" || { echo "FAIL quoted-key good pin rejected"; fail=1; }
exit $fail
