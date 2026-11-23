#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# The just recipes under build/just/ run under whatever bash the contributor
# has, and macOS ships Bash 3.2. The case-conversion expansions ${var,,} ${var^^}
# (and their single-character forms ${var,} ${var^}) are Bash 4 only and fail
# there with "bad substitution". Use `printf '%s' "$X" | tr '[:upper:]' '[:lower:]'`
# or a `case` pattern instead. This lint fails, naming file:line, if any
# build/just/*.just file uses one.
# Control: the same check run on a planted file containing ${X,,} must detect it,
# so the lint cannot pass because the grep stopped matching.
set -uo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

# Matches ${name,} ${name,,} ${name^} ${name^^}, optionally with a pattern.
pattern='\$\{[A-Za-z_][A-Za-z_0-9]*(\[[^]]*\])?(,,?|\^\^?)[^}]*\}'

# Prints file:line:text for each hit in the files given; returns 0 if any.
scan() { grep -nHE "$pattern" "$@"; }

# Negative control: a planted offender must be detected.
tmp=$(mktemp -d) || { echo "FAIL: mktemp" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
for planted in '${X,,}' '${X^^}' '${X,}' '${X^}' '${REPO,,}' '${a[0],,}'; do
    printf 'recipe:\n    #!/usr/bin/env bash\n    v="%s"\n' "$planted" > "$tmp/planted.just"
    if scan "$tmp/planted.just" >/dev/null; then echo "PASS: control: planted $planted is detected"
    else bad "control: planted $planted was NOT detected; the lint is broken"; fi
done
# Positive control: the portable forms must not be flagged.
printf 'r:\n    v="$(printf %%s "$X" | tr "[:upper:]" "[:lower:]")"\n    case "$a" in [yY]*) v=1 ;; esac\n    w="${X//[._]/-}"\n' > "$tmp/clean.just"
if scan "$tmp/clean.just" >/dev/null; then bad "control: portable forms were wrongly flagged"
else echo "PASS: control: portable forms are not flagged"; fi

shopt -s nullglob
files=(build/just/*.just)
[ "${#files[@]}" -gt 0 ] || { bad "no build/just/*.just files found; the lint would pass vacuously"; exit 1; }
if hits=$(scan "${files[@]}"); then
    while IFS= read -r l; do bad "Bash 4 case-conversion expansion (breaks Bash 3.2): $l"; done <<<"$hits"
else
    echo "PASS: no Bash 4 case-conversion expansion in ${#files[@]} build/just/*.just files"
fi
exit "$fail"
