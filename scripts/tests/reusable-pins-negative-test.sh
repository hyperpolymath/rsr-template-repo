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
run() { REUSABLE_RESOLVER="$t/stub.sh" bash "$here/check-reusable-pins.sh" "$t/$1" >/dev/null 2>&1; }
fail=0
run good && echo "ok   full resolvable SHA passes" || { echo "FAIL good pin rejected"; fail=1; }
run tag && { echo "FAIL tag-pinned call accepted"; fail=1; } || echo "ok   tag-pinned call rejected"
run ghost && { echo "FAIL unresolvable SHA accepted"; fail=1; } || echo "ok   unresolvable SHA rejected"
exit $fail
