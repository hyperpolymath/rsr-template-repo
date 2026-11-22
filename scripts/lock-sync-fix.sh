#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# lock-sync-fix.sh - bring .github/workflows/actions.lock back in sync with the
# workflow YAML after a Dependabot github-actions bump.
#
# Dependabot rewrites `uses:` refs in .github/workflows/*.yml and cannot touch
# actions.lock, so scripts/check-lock-sync.sh (the Lock Sync Gate) goes red, and
# an out-of-sync lock can make GitHub refuse to start runs. `gh actions-lock` is
# not assumed available. This script encodes the manual repair:
#
#   * every `uses:` is locked under its own workflow path (owner/repo lowercased,
#     subpaths collapsed to owner/repo, LC_ALL=C order);
#   * every ref with no dependencies: record is resolved to its commit
#     (`git ls-remote`, the PEELED commit for an annotated tag) and given a
#     record: key, ref:, commit: 'sha1-<40hex>', owner_id, repo_id;
#   * a SHA-pinned ref takes its tag from the trailing `# vX.Y.Z` comment, and
#     that tag must resolve to exactly that SHA;
#   * an old record is dropped only when it WAS referenced and now nothing
#     references it (pre-existing dead records are left alone).
#
# Fail loud, never silent: any ref that cannot be resolved, any SHA pin without
# a verifiable tag comment, any new action with nested external `uses:` (those
# need hand-made records) exits non-zero and leaves actions.lock UNTOUCHED. The
# result is validated with scripts/check-lock-sync.sh; on failure the original
# lock is restored. An already-synced lock is a no-op (idempotent).
#
# Usage: scripts/lock-sync-fix.sh [WORKFLOW_DIR]     (default .github/workflows)
#
# Resolver (swap for tests; no network needed): LOCK_SYNC_RESOLVER=/path/to/exe
# is called as
#   exe tag    OWNER/REPO REF   -> print the 40-hex commit of tag/branch REF
#   exe ids    OWNER/REPO       -> print "<owner_id> <repo_id>"
#   exe nested OWNER/REPO SHA [SUBPATH] -> print nested external uses (one per line)
#                                of the action manifest at SUBPATH (default: repository root)
# and exits non-zero when it cannot answer. The default resolver uses
# git ls-remote, gh api / curl (ids) and raw.githubusercontent.com (action.yml).

set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WF_DIR="${1:-.github/workflows}"
LOCK="$WF_DIR/actions.lock"
CHECK="${LOCK_SYNC_CHECK:-$SELF_DIR/check-lock-sync.sh}"
RESOLVER="${LOCK_SYNC_RESOLVER:-}"

die() { echo "lock-sync-fix: FAIL: $*" >&2; exit 1; }
note() { echo "lock-sync-fix: $*" >&2; }

[ -f "$LOCK" ] || die "no lockfile at $LOCK"
[ -x "$CHECK" ] || [ -f "$CHECK" ] || die "check-lock-sync.sh not found at $CHECK"

# Idempotence: nothing to do when the gate already passes.
if bash "$CHECK" "$WF_DIR" >/dev/null 2>&1; then
  note "actions.lock already in sync; nothing to do"
  exit 0
fi

AWK=""
for cand in gawk mawk awk; do
  command -v "$cand" >/dev/null 2>&1 && { AWK="$cand"; break; }
done
[ -n "$AWK" ] || die "no awk found on PATH"

# ---------------- resolver ----------------
default_resolver() {
  local op="$1" or="$2" arg="${3:-}" sub="${4:-}" out sha
  case "$op" in
    tag)
      out=$(git ls-remote "https://github.com/$or.git" "refs/tags/$arg" "refs/tags/$arg^{}" "refs/heads/$arg") \
        || return 1
      # peeled commit wins for an annotated tag, then the tag object, then a branch
      sha=$(printf '%s\n' "$out" | $AWK -v t="refs/tags/$arg" -v h="refs/heads/$arg" '
        $2 == t "^{}" { p = $1 } $2 == t { l = $1 } $2 == h { b = $1 }
        END { print (p != "" ? p : (l != "" ? l : b)) }')
      [ -n "$sha" ] || return 1
      printf '%s\n' "$sha" ;;
    ids)
      if command -v gh >/dev/null 2>&1; then
        gh api "repos/$or" --jq '"\(.owner.id) \(.id)"' && return 0
      fi
      out=$(curl -fsS "https://api.github.com/repos/$or") || return 1
      printf '%s\n' "$out" | tr -d '\n' | $AWK '{
        match($0, /"id": *[0-9]+/); r = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", r)
        o = $0; sub(/.*"owner": *\{[^}]*"id": */, "", o); sub(/[^0-9].*/, "", o)
        if (r == "" || o == "") exit 1; print o, r }' ;;
    nested)
      local f code body
      for f in action.yml action.yaml; do
        body=$(mktemp)
        code=$(curl -sS -o "$body" -w '%{http_code}' "https://raw.githubusercontent.com/$or/$arg/${sub:+$sub/}$f") \
          || { rm -f "$body"; return 1; }
        if [ "$code" = 200 ]; then
          # external uses: only (skip ./local and docker://)
          sed -E 's/[[:space:]]+#.*$//' "$body" \
            | sed -nE 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*["'\'']?([^"'\''[:space:]]+).*$/\1/p' \
            | grep -Ev '^(\./|docker://)' || true
          rm -f "$body"; return 0
        fi
        rm -f "$body"
        [ "$code" = 404 ] || return 1
      done
      return 0 ;;   # no root action.yml: a reusable workflow or subpath action; a leaf record
    *) return 1 ;;
  esac
}
resolve() {
  if [ -n "$RESOLVER" ]; then "$RESOLVER" "$@"; else default_resolver "$@"; fi
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cp "$LOCK" "$T/lock.orig"

shopt -s nullglob
mapfile -t WORKFLOWS < <(printf '%s\n' "$WF_DIR"/*.yml "$WF_DIR"/*.yaml | sort -u)
[ "${#WORKFLOWS[@]}" -gt 0 ] || die "no workflow files under $WF_DIR"

# ---------------- phase 1: uses: refs from the workflow YAML ----------------
# output: <path>\t<owner/repo@ref, owner/repo lowercased>\t<trailing # tag or empty>
"$AWK" '
function norm(r,   at, path, ref, n, parts) {
  at = 0
  for (n = length(r); n > 0; n--) { if (substr(r, n, 1) == "@") { at = n; break } }
  if (at == 0) return ""
  path = substr(r, 1, at - 1); ref = substr(r, at + 1)
  if (path == "" || ref == "") return ""
  if (substr(path, 1, 2) == "./" || substr(path, 1, 2) == "$/") return ""
  if (split(path, parts, "/") < 2) return ""
  return tolower(parts[1] "/" parts[2]) "@" ref
}
# subpath of owner/repo/sub/dir@ref ("" for the repository root)
function subof(r,   at, path, n, parts, k, s) {
  at = 0
  for (n = length(r); n > 0; n--) { if (substr(r, n, 1) == "@") { at = n; break } }
  path = substr(r, 1, at - 1)
  n = split(path, parts, "/"); s = ""
  for (k = 3; k <= n; k++) s = s (s == "" ? "" : "/") parts[k]
  return s
}
# Same-length copy of a line with the CONTENT of every quoted scalar blanked to
# "_" (kept in step with shape() in check-lock-sync.sh): `{uses: x}` inside
# `run: "echo {uses: x}"` is shell data, not a flow-mapping step. A quote only
# opens at a token boundary, so an apostrophe inside a word swallows nothing.
function shape(s,   out, i, c, q) {
  out = ""; q = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q != "") { if (c == q) { q = ""; out = out c } else out = out "_" }
    else if ((c == "\"" || c == "\047") && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:]{\[,:]/)) { q = c; out = out c }
    else out = out c
  }
  return out
}
FNR == 1 { p = FILENAME; sub(/.*\//, "", p); p = ".github/workflows/" p; stepind = -1; blkind = -1 }
{
  line = $0
  # block scalars (run: |) are data, not references
  if (blkind >= 0) {
    if (line !~ /[^[:space:]]/) next
    match(line, /^[[:space:]]*/)
    if (RLENGTH > blkind) next
    blkind = -1
  }
  if (line ~ /:[[:space:]]*[|>][-+0-9]*[[:space:]]*(#.*)?$/) {
    match(line, /^[[:space:]]*(-[[:space:]]+)?/)
    blkind = RLENGTH
  }
  cm = ""
  if (match(line, /[[:space:]]+#/)) { cm = substr(line, RSTART + RLENGTH); line = substr(line, 1, RSTART - 1) }
  if (line ~ /[^[:space:]]/) {
    match(line, /^[[:space:]]*/); ind = RLENGTH
    if (stepind >= 0 && ind <= stepind) stepind = -1
    if (line ~ /^[[:space:]]*steps:/) stepind = ind
  }
  raw = ""
  shp = shape(line)
  # flow-mapping step: matched on the quote-blanked shape, with an unquoted `{`
  # at or before the match, so `uses:` inside a quoted scalar stays data
  if (match(shp, /[{,][[:space:]]*uses:[[:space:]]*[^,}[:space:]]+/) && index(substr(shp, 1, RSTART), "{") > 0) {
    raw = substr(line, RSTART + 1)
    sub(/^[[:space:]]*uses:[[:space:]]*/, "", raw)
    sub(/[,}[:space:]].*$/, "", raw)
  } else if (line ~ /^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*.+$/) {
    raw = line
    sub(/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*/, "", raw)
  }
  if (raw != "") {
    gsub(/^["\047]|["\047]$/, "", raw)
    gsub(/[[:space:]]+$/, "", raw)
    n = norm(raw)
    if (n == "") next
    sub(/^[[:space:]]+/, "", cm); sub(/[[:space:]].*$/, "", cm)
    if (cm !~ /^[A-Za-z0-9._\/-]+$/) cm = ""
    # job-level reusable-workflow target (outside steps:, not a "- " item):
    # stays a SHA pin outside the lock, so it is never recorded
    if (stepind < 0 && line !~ /^[[:space:]]*-/ && raw ~ /\/\.github\/workflows\/[^\/@]+\.ya?ml@/) reuse[n] = 1
    else action[n] = 1
    cnt++; rp[cnt] = p; rn[cnt] = n; rc[cnt] = cm; rs[cnt] = subof(raw)
  }
}
END {
  for (i = 1; i <= cnt; i++) {
    if ((rn[i] in reuse) && !(rn[i] in action)) continue
    printf "%s\t%s\t%s\t%s\n", rp[i], rn[i], (rc[i] == "" ? "-" : rc[i]), (rs[i] == "" ? "-" : rs[i])
  }
}' "${WORKFLOWS[@]}" > "$T/uses.tsv"

# ---------------- phase 2: parse the existing lock ----------------
# W path entry | P path | R key field value | N key nestedref
"$AWK" '
# one-line flow sequence `[ 'a@v1', "b@v2" ]` -> prints "<tag>\t<cur>\t<item>" per item
function flow(tag, key, s,   n, parts, k, v) {
  sub(/^[^[]*\[/, "", s); sub(/\].*$/, "", s)
  n = split(s, parts, ",")
  for (k = 1; k <= n; k++) {
    v = parts[k]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); gsub(/^["\047]|["\047]$/, "", v)
    if (v != "") print tag "\t" key "\t" v
  }
}
/^version:/ { next }
/^workflows:[[:space:]]*$/ { inwf = 1; indep = 0; next }
/^dependencies:[[:space:]]*$/ { inwf = 0; indep = 1; next }
/^[a-z_]+:/ { inwf = 0; indep = 0; next }
inwf && /^    \047[^\047]+\047:/ { cur = $0; sub(/^    \047/, "", cur); sub(/\047:.*$/, "", cur); print "P\t" cur; if ($0 ~ /\047:[[:space:]]*\[[^]]/) flow("W", cur, $0); next }
inwf && /^        - \047[^\047]+\047/ { v = $0; sub(/^        - \047/, "", v); sub(/\047.*$/, "", v); print "W\t" cur "\t" v; next }
indep && /^    \047[^\047]+\047:/ { dk = $0; sub(/^    \047/, "", dk); sub(/\047:.*$/, "", dk); print "R\t" dk "\tkey\t"; next }
indep && /^        (ref|commit|owner_id|repo_id):/ { f = $0; sub(/^        /, "", f); k = f; sub(/:.*$/, "", k); sub(/^[a-z_]+:[[:space:]]*/, "", f); print "R\t" dk "\t" k "\t" f; next }
indep && /^            - \047[^\047]+\047/ { v = $0; sub(/^            - \047/, "", v); sub(/\047.*$/, "", v); print "N\t" dk "\t" v; next }
indep && /^        uses:[[:space:]]*\[/ && dk != "" { flow("N", dk, $0); next }
' "$LOCK" > "$T/lock.tsv"

lk() { local r="${1%%@*}"; printf '%s@%s' "${r,,}" "${1#*@}"; }

declare -A DKEY DREF DCOMMIT DOWNER DREPO DNEST OLDWF OLDWANT
declare -A REPOIDS
while IFS=$'\t' read -r kind a b c; do
  case "$kind" in
    R) l=$(lk "$a")
       case "$b" in
         key) DKEY[$l]="$a" ;;
         ref) DREF[$l]="$c" ;;
         commit) DCOMMIT[$l]="$c" ;;
         owner_id) DOWNER[$l]="$c" ;;
         repo_id) DREPO[$l]="$c"; REPOIDS[${l%%@*}]="${DOWNER[$l]:-} $c" ;;
       esac ;;
    N) l=$(lk "$a"); DNEST[$l]+="${DNEST[$l]:+$'\n'}$b"; OLDWANT[$(lk "$b")]=1 ;;
    W) OLDWF[$a]+="${OLDWF[$a]:+$'\n'}$b"; OLDWANT[$(lk "$b")]=1 ;;
    P) : ;;
  esac
done < "$T/lock.tsv"
# owner_id precedes repo_id in the lock, but be safe if the order was unusual
for l in "${!DKEY[@]}"; do
  [ -n "${DOWNER[$l]:-}" ] && [ -n "${DREPO[$l]:-}" ] && REPOIDS[${l%%@*}]="${DOWNER[$l]} ${DREPO[$l]}"
done

# ---------------- phase 3: new workflow sets, and records to resolve ----------------
declare -A NEWWF TAGHINT SUBS
while IFS=$'\t' read -r p ref cm sub; do
  [ -n "$ref" ] || continue
  [ "$cm" = "-" ] && cm=""
  [ "$sub" = "-" ] && sub=""
  NEWWF[$p]+="$ref"$'\n'
  [ -n "$cm" ] && TAGHINT[$ref]="$cm"
  # every distinct action path this ref is used at, one per line; the
  # repository root is recorded as "." (never a real subpath), so root use is
  # tracked explicitly and "sub-only" cannot be mistaken for "root + sub"
  key="${sub:-.}"
  case $'\n'"${SUBS[$ref]:-}" in *$'\n'"$key"$'\n'*) ;; *) SUBS[$ref]+="$key"$'\n' ;; esac
done < "$T/uses.tsv"

declare -A NEWREC_COMMIT NEWREC_REF NEWREC_IDS
declare -a NEWKEYS=()
for p in "${!NEWWF[@]}"; do
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    l=$(lk "$ref")
    [ -n "${DKEY[$l]:-}" ] && continue
    [ -n "${NEWREC_COMMIT[$l]:-}" ] && continue
    or="${ref%%@*}"; r="${ref#*@}"
    if [[ "$r" =~ ^[0-9a-fA-F]{40}$ ]]; then
      tag="${TAGHINT[$ref]:-}"
      [ -n "$tag" ] || die "$ref is SHA-pinned with no trailing '# <tag>' comment; cannot determine its ref: metadata. Add the tag comment (Dependabot normally does) or record it by hand."
      got=$(resolve tag "$or" "$tag") || die "cannot resolve tag '$tag' of $or (named by the comment on $ref)"
      [[ "$got" =~ ^[0-9a-fA-F]{40}$ ]] || die "resolver returned a non-SHA for $or $tag: '$got'"
      [ "${got,,}" = "${r,,}" ] || die "$or tag '$tag' resolves to $got, not the pinned $r; refusing to record a mismatched pin"
      commit="${r,,}"; mref="$tag"
    else
      commit=$(resolve tag "$or" "$r") || die "cannot resolve $or ref '$r' (tag or branch); is it published?"
      [[ "$commit" =~ ^[0-9a-fA-F]{40}$ ]] || die "resolver returned a non-SHA for $or $r: '$commit'"
      commit="${commit,,}"; mref="$r"
    fi
    # Probe the manifest of every action path this ref is used at: the root
    # action.yml for `o/r@ref`, `<sub>/action.yml` for `o/r/<sub>@ref`.
    nested=""
    subs="${SUBS[$ref]:-}"
    [ -n "$subs" ] || subs=$'.\n'
    while IFS= read -r sp; do
      [ -n "$sp" ] || continue
      [ "$sp" != "." ] || sp=""
      one=$(resolve nested "$or" "$commit" "$sp") || die "cannot inspect $or${sp:+/$sp}@$commit for nested uses:"
      [ -z "$one" ] || nested+="${nested:+$'\n'}$one"
    done < <(printf '%s' "$subs")
    [ -z "$nested" ] || die "$ref has nested external uses: (needs hand-made dependencies: records, then re-run): $(printf '%s' "$nested" | tr '\n' ' ')"
    ids="${REPOIDS[${or,,}]:-}"
    if [ -z "$ids" ]; then
      ids=$(resolve ids "$or") || die "cannot resolve owner_id/repo_id of $or"
    fi
    [[ "$ids" =~ ^[0-9]+\ [0-9]+$ ]] || die "bad owner_id/repo_id for $or: '$ids'"
    REPOIDS[${or,,}]="$ids"
    NEWREC_COMMIT[$l]="$commit"; NEWREC_REF[$l]="$mref"; NEWREC_IDS[$l]="$ids"
    DKEY[$l]="$ref"
    NEWKEYS+=("$l")
  done < <(printf '%s' "${NEWWF[$p]}" | LC_ALL=C sort -u)
done

# ---------------- phase 4: final workflow entries ----------------
declare -A FINALWF
folded() { while IFS= read -r x; do [ -n "$x" ] && lk "$x"; done | LC_ALL=C sort -u; }
declare -A WFPATH
for f in "${WORKFLOWS[@]}"; do
  [ "$f" = "$LOCK" ] && continue
  b="${f##*/}"; p=".github/workflows/$b"
  WFPATH[$p]=1
  new=$(printf '%s' "${NEWWF[$p]:-}" | LC_ALL=C sort -u)
  if [ "$(printf '%s\n' "${OLDWF[$p]:-}" | folded)" = "$(printf '%s\n' "$new" | folded)" ] \
     && grep -qF "'$p':" "$LOCK"; then
    FINALWF[$p]="${OLDWF[$p]:-}"        # unchanged: keep verbatim
  else
    FINALWF[$p]="$new"
  fi
done

# ---------------- phase 5: prune records that BECAME unreferenced ----------------
declare -A KEEP
for l in "${!DKEY[@]}"; do KEEP[$l]=1; done
while :; do
  declare -A NEWWANT=()
  for p in "${!FINALWF[@]}"; do
    while IFS= read -r e; do [ -n "$e" ] && NEWWANT[$(lk "$e")]=1; done <<< "${FINALWF[$p]}"
  done
  for l in "${!KEEP[@]}"; do
    while IFS= read -r e; do [ -n "$e" ] && NEWWANT[$(lk "$e")]=1; done <<< "${DNEST[$l]:-}"
  done
  changed=0
  for l in "${!KEEP[@]}"; do
    if [ -n "${OLDWANT[$l]:-}" ] && [ -z "${NEWWANT[$l]:-}" ]; then
      unset "KEEP[$l]"; changed=1; note "dropping record no longer referenced: ${DKEY[$l]}"
    fi
  done
  [ "$changed" = 1 ] || break
done

# ---------------- phase 6: write, validate, restore on failure ----------------
{
  "$AWK" '/^version:/ { exit } { print }' "$T/lock.orig"        # header comments only
  grep -m1 '^version:' "$T/lock.orig" || echo "version: 'v0.0.3'"
  echo "workflows:"
  for p in $(printf '%s\n' "${!WFPATH[@]}" | LC_ALL=C sort); do
    if [ -z "${FINALWF[$p]//[$'\n']/}" ]; then
      echo "    '$p': []"
    else
      echo "    '$p':"
      printf '%s\n' "${FINALWF[$p]}" | while IFS= read -r e; do [ -n "$e" ] && echo "        - '$e'"; done
    fi
  done
  echo "dependencies:"
  for k in $(for l in "${!KEEP[@]}"; do printf '%s\n' "${DKEY[$l]}"; done | LC_ALL=C sort); do
    l=$(lk "$k")
    echo "    '$k':"
    if [ -n "${NEWREC_COMMIT[$l]:-}" ]; then
      read -r oid rid <<< "${NEWREC_IDS[$l]}"
      echo "        ref: '${NEWREC_REF[$l]}'"
      echo "        commit: 'sha1-${NEWREC_COMMIT[$l]}'"
      echo "        owner_id: $oid"
      echo "        repo_id: $rid"
    else
      echo "        ref: ${DREF[$l]}"
      echo "        commit: ${DCOMMIT[$l]}"
      echo "        owner_id: ${DOWNER[$l]}"
      echo "        repo_id: ${DREPO[$l]}"
      if [ -n "${DNEST[$l]:-}" ]; then
        echo "        uses:"
        printf '%s\n' "${DNEST[$l]}" | while IFS= read -r e; do echo "            - '$e'"; done
      fi
    fi
  done
} > "$T/lock.new"

# Validate the CANDIDATE in a staging copy; the live lock is never written until
# the candidate has passed, and is then replaced by a same-directory rename, so a
# failure (or an interrupt) can never leave a half-written or invalid actions.lock.
mkdir "$T/stage"
for f in "${WORKFLOWS[@]}"; do [ "$f" = "$LOCK" ] || cp "$f" "$T/stage/"; done
cp "$T/lock.new" "$T/stage/actions.lock"
if ! bash "$CHECK" "$T/stage" > "$T/check.out" 2>&1; then
  cat "$T/check.out" >&2
  die "the repaired lock fails check-lock-sync.sh; the original actions.lock is untouched. Manual repair needed."
fi
cp "$T/lock.new" "$LOCK.tmp.$$"
mv -f "$LOCK.tmp.$$" "$LOCK"
note "actions.lock repaired and validated by check-lock-sync.sh"
for l in "${NEWKEYS[@]}"; do note "  recorded ${DKEY[$l]} -> sha1-${NEWREC_COMMIT[$l]}"; done
