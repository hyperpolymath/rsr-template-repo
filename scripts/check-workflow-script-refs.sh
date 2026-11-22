#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-workflow-script-refs.sh — every repo-local script a workflow INVOKES must exist.
#
# Usage: scripts/check-workflow-script-refs.sh [ROOT]     (ROOT defaults to .)
#
# A workflow copied out of this template into another repository keeps its
# `bash scripts/NAME.sh` lines, but the script does not come with it unless it
# is copied too. The job then fails at run time ("No such file or directory"),
# which is loud but late, is easy to misread as a scanner verdict, and was
# measured on phronesis#122: empty-linter.yml was synced without
# scripts/check-invisible-characters.sh. This check moves that failure to a
# cheap static pass with a message that names the cause.
#
# What counts as an invocation (deliberately conservative: a false alarm would
# teach people to ignore the gate, so only unambiguous forms are read):
#   bash|sh|bun|node [flags] scripts/NAME      ./scripts/NAME
#   if ! scripts/NAME                          run: scripts/NAME
# Each is only read when `scripts/` begins a word. A path that merely CONTAINS
# `scripts/` (`.standards-checkout/scripts/x.sh`, `"$d/scripts/x.sh"`,
# `fleet-src/scripts/x.sh`) belongs to another checkout and is out of scope, as
# are sparse-checkout lists, echoed messages and comments.
#
# Findings:
#   * the script does not exist under ROOT          -> error
#   * it is invoked DIRECTLY (./scripts/x, if ! scripts/x, run: scripts/x) and is
#     not executable                                -> error (an interpreter
#                                                       call needs no mode bit)
# Exemption: a script whose existence the SAME workflow tests (`-f|-e|-x|-r`
# followed by the path) is optional by design there and is not required.
#
# Exit: 0 clean (or no workflows to check), 1 findings, 2 usage error.
set -uo pipefail

root="${1:-.}"
[ "$#" -le 1 ] || { echo "usage: $0 [ROOT]" >&2; exit 2; }
[ -d "$root" ] || { echo "::error::check-workflow-script-refs: ROOT is not a directory: $root" >&2; exit 2; }
wfdir="$root/.github/workflows"
if [ ! -d "$wfdir" ]; then
  echo "check-workflow-script-refs: no .github/workflows under $root; nothing to check"
  exit 0
fi

# A word-initial `scripts/NAME`: start of line or one of these separators before it.
sep='(^|[[:space:];&|(`!"'"'"'])'
name='scripts/[A-Za-z0-9._-]+'
interp="${sep}(bash|sh|bun|node)[[:space:]]+(-[A-Za-z-]+[[:space:]]+)*[\"']?${name}"
direct_dot="${sep}\\./${name}"
direct_not="if[[:space:]]+![[:space:]]+${name}"
direct_run="run:[[:space:]]+${name}"

fail=0 seen=0 checked=0
shopt -s nullglob
files=("$wfdir"/*.yml "$wfdir"/*.yaml)
[ "${#files[@]}" -gt 0 ] || { echo "check-workflow-script-refs: no workflow files under $wfdir; nothing to check"; exit 0; }

for f in "${files[@]}"; do
  rel="${f#"$root"/}"
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in
      *[![:space:]]*) ;;
      *) continue ;;
    esac
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in '#'*) continue ;; esac
    # kind: i = interpreter call, d = direct call.
    for kind in i d; do
      if [ "$kind" = i ]; then
        hits=$(printf '%s\n' "$line" | grep -oE "$interp" || true)
      else
        hits=$( { printf '%s\n' "$line" | grep -oE "$direct_dot"
                  printf '%s\n' "$line" | grep -oE "$direct_not"
                  printf '%s\n' "$line" | grep -oE "$direct_run"; } 2>/dev/null || true)
      fi
      [ -n "$hits" ] || continue
      while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        path=$(printf '%s\n' "$hit" | grep -oE "$name" | head -n 1)
        [ -n "$path" ] || continue
        seen=$((seen + 1))
        # Optional-by-design: the same workflow tests whether it exists. Only a
        # real test counts ([ -f p ], [[ ! -x p ]], test -f p): `bash -e scripts/x`
        # has a `-e` too and must not exempt itself.
        if grep -qE -- "(\\[\\[?|test)[[:space:]]+(![[:space:]]+)?-[fexr][[:space:]]+\"?${path}([^A-Za-z0-9._-]|\$)" "$f"; then
          continue
        fi
        checked=$((checked + 1))
        if [ ! -f "$root/$path" ]; then
          echo "::error file=$rel,line=$n::$rel invokes $path but $path does not exist. A workflow copied from rsr-template-repo needs its companion script copied with it (and its test under tests/)." >&2
          fail=1
        elif [ "$kind" = d ] && [ ! -x "$root/$path" ]; then
          echo "::error file=$rel,line=$n::$rel runs $path directly but it is not executable (chmod +x, or call it through bash)." >&2
          fail=1
        fi
      done <<EOF
$hits
EOF
    done
  done < "$f"
done

if [ "$fail" -ne 0 ]; then
  echo "check-workflow-script-refs: FAILED ($checked invocation(s) checked, $seen found)" >&2
  exit 1
fi
echo "check-workflow-script-refs: OK ($checked invocation(s) checked across ${#files[@]} workflow file(s); $seen found, the rest guarded)"
