#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Controls for scripts/check-identity-matches-repo.sh and scripts/repo-slug.sh:
# a deed must name the repository it is checked out as. It passes for the
# repository's own name, owner, forge and birth-path id (either id domain, a
# legacy #u8 literal, a renamed repo that records its old name); it fails for a
# deed carried unrenamed from another repo, a wrong owner (a fork), a wrong
# file name, wrong forges, an id of another path, a transfer, and with no owner
# to recompute from.
#
# This test is carried into every minted child and run there, and the mint's
# self-name pass rewrites the template's own name: so that name is built from
# parts below, never written whole, as uuid_v8_test.sh and
# check_identity_test.sh do. Expected ids are computed with scripts/uuid-v8.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$ROOT/scripts/check-identity-matches-repo.sh"
SLUG="$ROOT/scripts/repo-slug.sh"
UUID8="$ROOT/scripts/uuid-v8.sh"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
# No user or system git config (insteadOf rewrites would change get-url).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE

TNAME="rsr-""template-repo"        # the template's own name, from parts
TOWNER="hyperpolymath"

fail() { echo "FAIL: $*" >&2; exit 1; }

# idof DOMAIN OWNER NAME -> #uuid"<id of github.com/OWNER/NAME in DOMAIN>"
idof() { printf '#uuid"%s"' "$(bash "$UUID8" "$1" "github.com/$2/$3")" || fail "uuid-v8.sh failed"; }

# newdir NAME -> a fresh directory ./NAME under a fresh case directory (mktemp: this
# runs in a command substitution, so a counter would not advance)
newdir() { local c; c="$(mktemp -d "$FIXTURE/case.XXXXXX")" && mkdir -p "$c/$1" && printf "%s" "$c/$1"; }
# gitdir DIR ORIGIN -> make DIR a git repo whose origin is ORIGIN
gitdir() { git -C "$1" init -q && git -C "$1" remote add origin "$2"; }

# mkdeed DIR FILEBASE CANON ID OWNER FORGE PREV -> path of DIR/FILEBASE_chora.deed
#   ID     the whole literal, e.g. #uuid"…"; empty leaves :repo-uuid out
#   OWNER  (identity :owner); empty leaves it out
#   FORGE  (forges :github); empty leaves the clause out
#   PREV   "" leaves (lineage) out; NONE is an empty list; else the list items
mkdeed() {
  local dir="$1" base="$2" canon="$3" id="$4" owner="$5" forge="$6" prev="$7"
  local f="$dir/${base}_chora.deed"
  {
    printf ';; SPDX-License-Identifier: CC-BY-SA-4.0\n(repo-deed :schema-version "1.0.0"'
    [[ -n "$canon" ]] && printf '\n  :canonical-name "%s"' "$canon"
    [[ -n "$id" ]] && printf '\n  :repo-uuid %s' "$id"
    printf '\n  (identity :primary-forge github'
    [[ -n "$owner" ]] && printf ' :owner "%s"' "$owner"
    printf ')'
    [[ -n "$forge" ]] && printf '\n  (forges :github "%s")' "$forge"
    if [[ -n "$prev" ]]; then
      [[ "$prev" = NONE ]] && prev=""
      printf '\n  (lineage :type standalone :previous-names (%s))' "$prev"
    fi
    printf ')\n'
  } > "$f"
  printf '%s' "$f"
}

# run GR ARGS... : GR empty unsets GITHUB_REPOSITORY, else sets it
run() {
  local gr="$1"; shift
  if [[ -n "$gr" ]]; then GITHUB_REPOSITORY="$gr" bash "$CHECKER" "$@"
  else env -u GITHUB_REPOSITORY bash "$CHECKER" "$@"; fi
}
# expect_pass WHAT GR DEED [ROOT]
expect_pass() {
  local what="$1"; shift
  run "$@" > "$FIXTURE/out" 2>&1 || { echo "FAIL: checker refused $what" >&2; cat "$FIXTURE/out" >&2; exit 1; }
}
# expect_fail WHAT GR DEED NEEDLE... : exit exactly 1 and every NEEDLE on stderr
expect_fail() {
  local what="$1" gr="$2" deed="$3" rc=0; shift 3
  run "$gr" "$deed" > "$FIXTURE/out" 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]] || { echo "FAIL: checker gave $rc, not 1, for $what" >&2; cat "$FIXTURE/out" >&2; exit 1; }
  local needle
  for needle in "$@"; do
    grep -qF -- "$needle" "$FIXTURE/out" || { echo "FAIL: checker did not say '$needle' for $what" >&2; cat "$FIXTURE/out" >&2; exit 1; }
  done
}
# expect_one WHAT GR DEED NEEDLE : fail with that finding and no other line
expect_one() {
  expect_fail "$@"
  [[ "$(wc -l < "$FIXTURE/out")" -eq 1 ]] || { echo "FAIL: more than one finding for $1" >&2; cat "$FIXTURE/out" >&2; exit 1; }
}

OW=ow; NM=widget
REG="$(idof chora-registry $OW $NM)"
GVC="$(idof gv-clade-index $OW $NM)"

# ── passes ──────────────────────────────────────────────────────────────────
d="$(newdir x)"; f="$(mkdeed "$d" $NM $NM "$REG" $OW "$OW/$NM" "")"
expect_pass "a matching deed through GITHUB_REPOSITORY" "$OW/$NM" "$f"

d="$(newdir other-dir)"; gitdir "$d" "https://github.com/$OW/$NM.git"
f="$(mkdeed "$d" $NM $NM "$REG" $OW "$OW/$NM" "")"
expect_pass "a matching deed through an https origin URL" "" "$f"
f="$(mkdeed "$d" $NM $NM "$REG" "" "" "")"
expect_pass "an https origin gives the owner when the deed names none" "" "$f"

d="$(newdir other-dir)"; gitdir "$d" "git@github.com:$OW/$NM.git"
f="$(mkdeed "$d" $NM $NM "$REG" $OW "$OW/$NM" "")"
expect_pass "a matching deed through an scp-like origin URL" "" "$f"

d="$(newdir x)"
expect_pass "an id of the gv-clade-index domain" "$OW/$NM" "$(mkdeed "$d" $NM $NM "$GVC" $OW "$OW/$NM" "")"
expect_pass "an id of the chora-registry domain" "$OW/$NM" "$(mkdeed "$d" $NM $NM "$REG" $OW "$OW/$NM" "")"
expect_pass "a #u8 literal naming this repository" "$OW/$NM" \
  "$(mkdeed "$d" $NM $NM "#u8\"chora-registry:github.com/$OW/$NM\"" $OW "$OW/$NM" "")"
expect_pass "a #u8 literal that is the bare path" "$OW/$NM" \
  "$(mkdeed "$d" $NM $NM "#u8\"github.com/$OW/$NM\"" $OW "$OW/$NM" "")"
expect_pass "no (forges) clause and no (lineage) clause" "$OW/$NM" "$(mkdeed "$d" $NM $NM "$REG" $OW "" "")"

# A rename: the new name everywhere, the old name recorded, the original id.
d="$(newdir x)"
expect_pass "a rename that records the old name" "$OW/gadget" \
  "$(mkdeed "$d" gadget gadget "$REG" $OW "$OW/gadget" "\"$NM\"")"
expect_pass "a rename after an earlier rename (several previous names)" "$OW/gizmo" \
  "$(mkdeed "$d" gizmo gizmo "$REG" $OW "$OW/gizmo" "\"gadget\" \"$NM\"")"
expect_fail "a rename that does not record the old name" "$OW/gadget" \
  "$(mkdeed "$d" gadget gadget "$REG" $OW "$OW/gadget" NONE)" ":repo-uuid" "(lineage :previous-names)"
expect_fail "a rename with no (lineage) clause" "$OW/gadget" \
  "$(mkdeed "$d" gadget gadget "$REG" $OW "$OW/gadget" "")" ":repo-uuid"

# ── the template's own deed in a repository of another name ────────────────
# Real deed in the template tree; elsewhere an equivalent one built from parts.
d="$(newdir other-repo)"
if bash "$ROOT/scripts/is-template-tree.sh" "$ROOT"; then
  cp "$ROOT/${TNAME}_chora.deed" "$d/"; f="$d/${TNAME}_chora.deed"
else
  f="$(mkdeed "$d" "$TNAME" "$TNAME" "$(idof gv-clade-index $TOWNER "$TNAME")" $TOWNER "$TOWNER/$TNAME" NONE)"
fi
expect_fail "the template's deed in a repository of another name" "$TOWNER/other-repo" "$f" \
  ":canonical-name" "deed file name" "(forges :github)" ":repo-uuid"

# ── wrong owner, file name, forges, ids ────────────────────────────────────
d="$(newdir x)"
expect_fail "a wrong owner (a fork)" "someone-else/$NM" "$(mkdeed "$d" $NM $NM "$REG" $OW "$OW/$NM" "")" \
  "(identity :owner)" "(forges :github)" ":repo-uuid"
expect_fail "a wrong canonical name" "$OW/$NM" "$(mkdeed "$d" $NM other "$REG" $OW "$OW/$NM" "")" ":canonical-name"
expect_fail "a missing canonical name" "$OW/$NM" "$(mkdeed "$d" $NM "" "$REG" $OW "$OW/$NM" "")" ":canonical-name is missing"
expect_one "a wrong file name" "$OW/$NM" "$(mkdeed "$d" other $NM "$REG" $OW "$OW/$NM" "")" "deed file name is other_chora.deed"
expect_one "wrong (forges :github)" "$OW/$NM" "$(mkdeed "$d" $NM $NM "$REG" $OW "$OW/other" "")" "(forges :github)"
expect_one "a (forges :github) of another owner" "$OW/$NM" "$(mkdeed "$d" $NM $NM "$REG" $OW "x/$NM" "")" "(forges :github)"
expect_fail "the id of a different path" "$OW/$NM" "$(mkdeed "$d" $NM $NM "$(idof chora-registry $OW other)" $OW "$OW/$NM" "")" ":repo-uuid"
expect_fail "a legacy #u5 literal naming another repo" "$OW/$NM" \
  "$(mkdeed "$d" $NM $NM "#u5\"github.com/$OW/other\"" $OW "$OW/$NM" "")" ":repo-uuid"
expect_fail "a #u8 literal naming another repo" "$OW/$NM" \
  "$(mkdeed "$d" $NM $NM "#u8\"chora-registry:github.com/$OW/other\"" $OW "$OW/$NM" "")" ":repo-uuid"
expect_fail "a #u8 body that only ends in the name" "$OW/$NM" \
  "$(mkdeed "$d" $NM $NM "#u8\"chora-registry:github.com/$OW/x$NM\"" $OW "$OW/$NM" "")" ":repo-uuid"
expect_fail "a missing :repo-uuid" "$OW/$NM" "$(mkdeed "$d" $NM $NM "" $OW "$OW/$NM" "")" ":repo-uuid is missing"
expect_fail "a :repo-uuid that is a plain string" "$OW/$NM" "$(mkdeed "$d" $NM $NM '"abc"' $OW "$OW/$NM" "")" "not a #uuid, #u8 or #u5 literal"
expect_fail "an upper-case id" "$OW/$NM" \
  "$(mkdeed "$d" $NM $NM "$(printf '%s' "$REG" | tr a-f A-F | sed 's/#UUID/#uuid/')" $OW "$OW/$NM" "")" ":repo-uuid"

# A transfer: the owner changed everywhere, the id still that of the old owner.
expect_fail "a transfer (the id of the old owner's path)" "newowner/$NM" \
  "$(mkdeed "$d" $NM $NM "$REG" newowner "newowner/$NM" "")" ":repo-uuid" "transferred repo"

# ── no origin, no GITHUB_REPOSITORY: the directory name; no owner: fail closed
d="$(newdir $NM)"
expect_pass "the directory name, with the owner from the deed" "" "$(mkdeed "$d" $NM $NM "$REG" $OW "$OW/$NM" "")"
d="$(newdir elsewhere)"
expect_fail "a deed in a directory of another name" "" "$(mkdeed "$d" $NM $NM "$REG" $OW "$OW/$NM" "")" \
  ":canonical-name" "deed file name"
d="$(newdir $NM)"
expect_fail "no owner anywhere fails closed" "" "$(mkdeed "$d" $NM $NM "$REG" "" "" "")" \
  "cannot be recomputed without an owner"
expect_fail "no owner anywhere fails closed for a #u8 literal" "" \
  "$(mkdeed "$d" $NM $NM "#u8\"github.com/$OW/$NM\"" "" "" "")" "cannot be recomputed without an owner"
# With the forges owner unknown the name segment is compared.
expect_fail "(forges :github) of another name with no owner known" "" \
  "$(mkdeed "$d" $NM $NM "$REG" "" "$OW/other" "")" "(forges :github)"

# A path-like origin (a local bare repo) yields a name and no owner.
bare="$FIXTURE/bare/parentdir/$NM.git"; mkdir -p "$bare"; git init -q --bare "$bare"
d="$(newdir elsewhere)"; gitdir "$d" "$bare"
expect_pass "a local bare origin: the name from its basename, the owner from the deed" "" \
  "$(mkdeed "$d" $NM $NM "$REG" $OW "$OW/$NM" "")"
expect_fail "a local bare origin gives no owner (its parent directory is not one)" "" \
  "$(mkdeed "$d" $NM $NM "$REG" "" "" "")" "cannot be recomputed without an owner"
expect_fail "a local bare origin: the parent directory is not taken as the owner" "" \
  "$(mkdeed "$d" $NM $NM "$(idof chora-registry parentdir $NM)" $OW "$OW/$NM" "")" ":repo-uuid"

# ── usage errors are 2, never a silent pass ────────────────────────────────
rc=0; bash "$CHECKER" >/dev/null 2>&1 || rc=$?; [[ "$rc" -eq 2 ]] || fail "no argument gave $rc, not 2"
rc=0; bash "$CHECKER" "$FIXTURE/none.deed" >/dev/null 2>&1 || rc=$?; [[ "$rc" -eq 2 ]] || fail "a missing deed gave $rc, not 2"
rc=0; bash "$CHECKER" a b c >/dev/null 2>&1 || rc=$?; [[ "$rc" -eq 2 ]] || fail "three arguments gave $rc, not 2"

# ── the template tree itself passes (it is not a carried-in control) ───────
if bash "$ROOT/scripts/is-template-tree.sh" "$ROOT"; then
  expect_pass "the template's own deed with GITHUB_REPOSITORY set" "$TOWNER/$TNAME" "$ROOT/${TNAME}_chora.deed" "$ROOT"
  # As the environment stands, only when it names the template's owner or none:
  # a fork's own CI (another owner) fails this gate by design.
  rc=0; as_is="$(env -u GITHUB_REPOSITORY bash "$SLUG" --owner "$ROOT" 2>/dev/null)" || rc=$?
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then as_is="${GITHUB_REPOSITORY%%/*}"; rc=0; fi
  if [[ "$rc" -ne 0 || "$as_is" = "$TOWNER" ]]; then
    if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
      bash "$CHECKER" "$ROOT/${TNAME}_chora.deed" "$ROOT" > "$FIXTURE/out" 2>&1 || { cat "$FIXTURE/out" >&2; fail "the template's own deed fails with the environment as it is"; }
    else
      expect_pass "the template's own deed with the environment as it is" "" "$ROOT/${TNAME}_chora.deed" "$ROOT"
    fi
  else
    echo "SKIP: the template's-own-deed control with the environment as-is (the checkout's owner is '$as_is', not $TOWNER: a fork fails by design)"
  fi
else
  echo "SKIP: the template's-own-deed controls (not the template tree; is-template-tree.sh says no)"
fi

# ── repo-slug.sh, directly ─────────────────────────────────────────────────
# slug WHAT GR ROOT WANT_NAME WANT_OWNER ("-" for an unknown owner: exit 1, nothing printed)
slug() {
  local what="$1" gr="$2" root="$3" wn="$4" wo="$5" got rc=0
  if [[ -n "$gr" ]]; then got="$(GITHUB_REPOSITORY="$gr" bash "$SLUG" --name "$root")" || rc=$?
  else got="$(env -u GITHUB_REPOSITORY bash "$SLUG" --name "$root")" || rc=$?; fi
  [[ "$rc" -eq 0 && "$got" = "$wn" ]] || fail "repo-slug --name for $what gave '$got' (exit $rc), not '$wn'"
  rc=0
  if [[ -n "$gr" ]]; then got="$(GITHUB_REPOSITORY="$gr" bash "$SLUG" --owner "$root")" || rc=$?
  else got="$(env -u GITHUB_REPOSITORY bash "$SLUG" --owner "$root")" || rc=$?; fi
  if [[ "$wo" = "-" ]]; then
    [[ "$rc" -eq 1 && -z "$got" ]] || fail "repo-slug --owner for $what gave '$got' (exit $rc), not unknown (1, nothing)"
  else
    [[ "$rc" -eq 0 && "$got" = "$wo" ]] || fail "repo-slug --owner for $what gave '$got' (exit $rc), not '$wo'"
  fi
}
# with_origin URL -> a git repo directory named "dirname" with that origin
with_origin() { local d; d="$(newdir dirname)"; gitdir "$d" "$1"; printf '%s' "$d"; }

d="$(newdir dirname)"
slug "GITHUB_REPOSITORY" "o/n" "$d" n o
slug "GITHUB_REPOSITORY with a longer path" "h/o/n" "$d" n h
slug "GITHUB_REPOSITORY with no owner" "n" "$d" n -
slug "the directory name" "" "$d" dirname -
slug "GITHUB_REPOSITORY over an origin" "o/n" "$(with_origin https://github.com/a/b.git)" n o
slug "an https origin" "" "$(with_origin https://github.com/o/n.git)" n o
slug "an https origin with a trailing slash" "" "$(with_origin https://github.com/o/n/)" n o
slug "an https origin without .git" "" "$(with_origin https://github.com/o/n)" n o
slug "a nested group, user and port" "" "$(with_origin ssh://git@host.example:2222/grp/sub/o/n.git)" n o
slug "an scp-like origin" "" "$(with_origin git@github.com:o/n.git)" n o
slug "an scp-like origin with a nested path" "" "$(with_origin git@host.example:grp/o/n.git)" n o
slug "an scp-like origin with no owner" "" "$(with_origin host.example:n.git)" n -
slug "a host with no owner" "" "$(with_origin https://host.example/n.git)" n -
slug "an absolute path origin" "" "$(with_origin /srv/git/box/n.git)" n -
slug "a ./ origin" "" "$(with_origin ./box/n.git)" n -
slug "a ../ origin" "" "$(with_origin ../box/n.git)" n -
slug "a file:// origin" "" "$(with_origin file:///srv/git/box/n.git)" n -
# shellcheck disable=SC2088 # the literal ~ is the case under test
slug "a ~ origin" "" "$(with_origin '~/box/n.git')" n -
slug "a relative path origin" "" "$(with_origin box/n.git)" n -

rc=0; bash "$SLUG" >/dev/null 2>&1 || rc=$?; [[ "$rc" -eq 2 ]] || fail "repo-slug with no argument gave $rc, not 2"
rc=0; bash "$SLUG" --bogus >/dev/null 2>&1 || rc=$?; [[ "$rc" -eq 2 ]] || fail "repo-slug --bogus gave $rc, not 2"
rc=0; bash "$SLUG" --name "$FIXTURE/none" >/dev/null 2>&1 || rc=$?; [[ "$rc" -eq 2 ]] || fail "repo-slug on a missing ROOT gave $rc, not 2"
rc=0; bash "$SLUG" --name a b c >/dev/null 2>&1 || rc=$?; [[ "$rc" -eq 2 ]] || fail "repo-slug with three arguments gave $rc, not 2"
# ROOT defaults to the current directory.
got="$(cd "$d" && env -u GITHUB_REPOSITORY bash "$SLUG" --name)"
[[ "$got" = dirname ]] || fail "repo-slug --name with no ROOT gave '$got'"

echo "PASS: check-identity-matches-repo controls (own name, owner, forge and birth-path id pass; a carried-in deed, a fork, a transfer, a wrong file name, wrong forges, another id and no owner fail; usage is 2) and repo-slug controls"
