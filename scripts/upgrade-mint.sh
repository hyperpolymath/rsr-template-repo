#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# upgrade-mint.sh — carry a minted repo from the template commit it came from
# to a newer one: the update half of the mint (docs/proposals/template-upgrade.adoc).
#
#   base   = replay of the repo's own mint   (template @ :template-commit, its answers)
#   theirs = the same mint at the new commit (template @ NEW,              its answers)
#   ours   = the repo as committed
#
# Per path, the one safety rule: a path changes only if the repo still equals
# the old mint there (a fast-forward), or git can merge the two edits without
# overlap (reported separately, MERGED, for review). Where both sides changed
# the same lines the file is written with conflict markers, never resolved. A
# repo that edited a file the template also deleted keeps it.
#
# It never touches (PROTECTED / OWNER-HELD / LICENCE-HELD, listed, not written):
#   * licence files (LICENSE*, LICENCE*, COPYING*, UNLICENSE*, LICENSES/**), and
#     any change that would alter an SPDX or copyright line of another file;
#   * the chora deed (identity) — except the three provenance pins below;
#   * status and proof state (docs/status/**, PROOF-STATUS/NEEDS, ROADMAP, receipts,
#     verification/proofs/**): the repo's own claims, never set by template equality;
#   * tool- and owner-owned files: actions.lock, CODEOWNERS, CITATION.cff,
#     .github/settings.yml, .github/rulesets/**;
#   * every path the repo declares in its deed's (variant (paths …)) as added,
#     removed, diverged or operational-state: the owner's content.
# The only deed edit is --apply recording the new pin: (provenance
# :template-commit / :template-tree) and (variant :parent-pin).
#
# Usage: upgrade-mint.sh --template DIR [--to REF] [--child DIR]
#                        [--apply [--branch NAME] [--no-commit]] [--report FILE]
#        upgrade-mint.sh --rollback [--child DIR]
#   --template DIR  a clone of the template with FULL history (contains the
#                   repo's :template-commit and REF)
#   --to REF        the template version to move to (default: HEAD of DIR)
#   --child DIR     the minted repo (default .); must be a git work tree
#   (default)       DRY RUN: computes and prints the plan; writes nothing to
#                   the repo (no file, no branch, no config, no object)
#   --apply         requires a clean tree; makes branch upgrade/rsr-<new12>,
#                   writes the plan, records the pin, commits (unsigned: the
#                   owner re-signs; a draft PR is the next step, never a push
#                   from here). Conflicts are committed WITH their markers.
#   --rollback      from the upgrade branch with the upgrade commit at its tip:
#                   back to the branch it was made from, upgrade branch deleted
#                   locally. A pushed branch is deleted by hand (printed).
# Needs what a mint needs (just, rustc, nickel, uuidgen); RSR_MINT_TOOL_CACHE.
# Exit: 0 plan printed / applied with no conflict; 3 applied or planned with
# conflicts or holds needing a human (also printed); 1 refused (reason on
# stderr, nothing written); 2 usage.
set -euo pipefail
export LC_ALL=C
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_NAMESPACE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READ="$HERE/deed-field.sh"
WRITE="$HERE/deed-clause.sh"
die() { echo "upgrade-mint: $*" >&2; exit 1; }
usage() { sed -n '/^# Usage:/,/^# Needs/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
# g — git with no user or system configuration and no hooks, for the replays
# and every read of the template (as check-mint-drift.sh's g()).
g() {
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=upgrade -c user.email=upgrade@example.invalid \
        -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

TDIR="" TO="HEAD" CDIR="." MODE=dry BRANCH="" NOCOMMIT=0 REPORT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --template) TDIR="${2:-}"; shift 2 ;;
        --to) TO="${2:-}"; shift 2 ;;
        --child) CDIR="${2:-}"; shift 2 ;;
        --apply) MODE=apply; shift ;;
        --dry-run) MODE=dry; shift ;;
        --rollback) MODE=rollback; shift ;;
        --branch) BRANCH="${2:-}"; shift 2 ;;
        --no-commit) NOCOMMIT=1; shift ;;
        --report) REPORT="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "upgrade-mint: unknown argument: $1" >&2; usage ;;
    esac
done
[ -d "$CDIR" ] || die "no such directory: $CDIR"
CDIR="$(cd "$CDIR" && pwd)"
git -C "$CDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$CDIR is not a git work tree"
[ "$(git -C "$CDIR" rev-parse --show-toplevel)" = "$CDIR" ] || die "$CDIR is not the top of its work tree"

# ── rollback ────────────────────────────────────────────────────────────────
if [ "$MODE" = rollback ]; then
    msg="$(git -C "$CDIR" log -1 --format=%B HEAD)"
    base="$(sed -n 's/^RSR-Upgrade-Base: \([0-9a-f]\{40\}\)$/\1/p' <<<"$msg" | head -1)"
    from="$(sed -n 's/^RSR-Upgrade-From-Branch: \(.*\)$/\1/p' <<<"$msg" | head -1)"
    [ -n "$base" ] || die "HEAD is not an upgrade commit (no RSR-Upgrade-Base trailer); nothing to roll back"
    [ "$(git -C "$CDIR" rev-parse HEAD~1)" = "$base" ] || die "HEAD's parent is not the recorded base $base; the branch has moved on, so it is not rolled back automatically"
    [ -z "$(git -C "$CDIR" --no-optional-locks status --porcelain)" ] || die "the work tree is not clean; commit or stash first"
    here_branch="$(git -C "$CDIR" rev-parse --abbrev-ref HEAD)"
    case "$here_branch" in upgrade/rsr-*) ;; *) die "HEAD is on '$here_branch', not an upgrade/rsr-* branch" ;; esac
    if [ -n "$from" ] && [ "$from" != HEAD ] && git -C "$CDIR" show-ref --verify --quiet "refs/heads/$from"; then
        [ "$(git -C "$CDIR" rev-parse "$from")" = "$base" ] || die "$from has moved since the upgrade (not at $base); switch by hand and delete $here_branch"
        git -C "$CDIR" switch -q "$from"
    else
        git -C "$CDIR" switch -q --detach "$base"
    fi
    git -C "$CDIR" branch -D -q "$here_branch"
    echo "upgrade-mint: rolled back to ${from:-$base}; local branch $here_branch deleted."
    echo "  if $here_branch was pushed: git push origin --delete $here_branch"
    exit 0
fi

[ -n "$TDIR" ] || { echo "upgrade-mint: --template DIR is required" >&2; usage; }
[ -d "$TDIR" ] || die "no such directory: $TDIR"
TDIR="$(cd "$TDIR" && pwd)"
[ "$(g -C "$TDIR" rev-parse --is-shallow-repository)" = false ] \
    || die "$TDIR is a shallow clone; the pinned base commit may be missing (git fetch --unshallow)"

# ── what the repo recorded ──────────────────────────────────────────────────
DEED="$(bash "$READ" --find "$CDIR")" || die "no single *_chora.deed in $CDIR"
DEEDREL="${DEED#"$CDIR"/}"
bash "$READ" --has "$DEED" mint-answers \
    || die "$DEEDREL has no (mint-answers) clause: this repo was minted before answers were recorded, so its mint cannot be replayed. It can still take the exact-stale refresh (scripts/survey-template-staleness.sh lists the files); a three-way upgrade is not possible without its answers"
PIN="$(bash "$READ" "$DEED" provenance template-commit 2>/dev/null || true)"
SLUG="$(bash "$READ" "$DEED" provenance template-repo 2>/dev/null || true)"
[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] || die "(provenance :template-commit) is '${PIN}', not a commit"
g -C "$TDIR" cat-file -e "${PIN}^{commit}" 2>/dev/null || die "$TDIR does not contain the pinned template commit $PIN"
NEW="$(g -C "$TDIR" rev-parse --verify -q "${TO}^{commit}")" || die "$TO is not a commit of $TDIR"
if [ "$NEW" = "$PIN" ]; then echo "upgrade-mint: already at ${PIN:0:12}; nothing to do"; exit 0; fi
g -C "$TDIR" merge-base --is-ancestor "$PIN" "$NEW" \
    || die "${PIN:0:12} is not an ancestor of ${NEW:0:12}: that is a downgrade or a different line of history, which an upgrade does not do"
NEWTREE="$(g -C "$TDIR" rev-parse "${NEW}^{tree}")"

# ── the repo must be in a state we can read exactly ────────────────────────
_sparse=0
while IFS= read -r -d '' e; do case "$e" in "S "*) _sparse=$((_sparse + 1)) ;; esac; done < <(git -C "$CDIR" ls-files -t -z)
[ "$_sparse" -eq 0 ] || die "this checkout is sparse ($_sparse tracked paths absent); run it from a full checkout"
[ -z "$(git -C "$CDIR" ls-files -u)" ] || die "this checkout has an unresolved merge; resolve it first"
DIRTY=0; [ -z "$(git -C "$CDIR" --no-optional-locks status --porcelain)" ] || DIRTY=1
if [ "$MODE" = apply ] && [ "$DIRTY" = 1 ]; then die "--apply needs a clean work tree (git status shows changes); nothing was written"; fi
# the commit is made as the repo's own configured identity: refuse now, before any replay or branch,
# when there is none (a CI runner has none), rather than after writing the plan
if [ "$MODE" = apply ] && [ "$NOCOMMIT" = 0 ] && ! git -C "$CDIR" var GIT_COMMITTER_IDENT >/dev/null 2>&1; then
    die "--apply commits as this repo's git identity and none is set (git config user.name / user.email); set one, or pass --no-commit to leave the plan staged. Nothing was written"
fi
# The owner's declarations decide what is never written: refuse before any replay when the deed
# cannot state them (an unreadable list is not an empty list).
bash "$READ" --has "$DEED" variant/paths \
    || die "$DEEDREL has no (variant (paths …)) clause, so what this repo owns cannot be known; nothing was written"
for _k in added removed diverged; do
    bash "$READ" --list "$DEED" variant/paths "$_k" >/dev/null 2>&1 \
        || die "(variant (paths :$_k …)) in $DEEDREL is missing or not a list; nothing was written"
done
ORIG_BRANCH="$(git -C "$CDIR" rev-parse --abbrev-ref HEAD)"
BASE_COMMIT="$(git -C "$CDIR" rev-parse HEAD)"
BRANCH="${BRANCH:-upgrade/rsr-${NEW:0:12}}"
if [ "$MODE" = apply ]; then
    git -C "$CDIR" check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || die "'$BRANCH' is not a branch name"
    case "$BRANCH" in upgrade/rsr-?*) ;; *) die "the branch must be named upgrade/rsr-<something> (--rollback only recognises that form); got '$BRANCH'" ;; esac
    ! git -C "$CDIR" show-ref --verify --quiet "refs/heads/$BRANCH" || die "branch $BRANCH already exists; roll it back or pass --branch"
fi

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
OLD_DIR="$SCRATCH/old"; NEW_DIR="$SCRATCH/new"
echo "upgrade-mint: ${SLUG:-template} ${PIN:0:12} -> ${NEW:0:12}  ($MODE)" >&2
[ "$DIRTY" = 0 ] || echo "upgrade-mint: the work tree is dirty; reading it as it stands (dry run only)" >&2
echo "upgrade-mint: replaying the mint at the old pin ..." >&2
bash "$HERE/replay-mint.sh" "$TDIR" "$PIN" "$OLD_DIR" --answers-from "$DEED" >/dev/null \
    || die "the replay at the old pin failed (above); nothing was compared"
echo "upgrade-mint: replaying the mint at the new commit ..." >&2
bash "$HERE/replay-mint.sh" "$TDIR" "$NEW" "$NEW_DIR" --answers-from "$DEED" >/dev/null \
    || die "the replay at the new commit failed (above) with this repo's recorded answers; nothing was compared"

# ── helpers (same notions as scripts/check-mint-drift.sh) ───────────────────
files() { # DIR [own] — the repository's own files, one per line
    local gx=g; [ "${2:-}" = own ] && gx=git
    "$gx" -C "$1" -c core.hooksPath=/dev/null ls-files -z --cached --others --exclude-standard \
        | while IFS= read -r -d '' f; do
            case "$f" in *$'\n'*|*$'\t'*) echo "upgrade-mint: cannot handle a path containing a newline or tab: $(printf '%q' "$f")" >&2; exit 2 ;; esac
            if [ -e "$1/$f" ] || [ -L "$1/$f" ]; then printf '%s\n' "$f"; fi
        done | sort -u
}
ux() { [ -n "$(find "$1" -prune -perm -0100 2>/dev/null)" ]; }
same() { # A B — identical as git would record them (content, owner exec bit, link target)
    if [ -L "$1" ] || [ -L "$2" ]; then
        [ -L "$1" ] && [ -L "$2" ] && [ "$(readlink "$1"; echo .)" = "$(readlink "$2"; echo .)" ]
        return
    fi
    { ux "$1" && ux "$2"; } || { ! ux "$1" && ! ux "$2"; } || return 1
    cmp -s "$1" "$2"
}
# The owner's declarations decide what is never written, so a deed that cannot state them
# is refused: an unreadable list is not an empty list. (paths :added :removed :diverged)
# are written by every mint; :diverged-pending-upstream and :operational-state are optional.
bash "$READ" --has "$DEED" variant/paths \
    || die "$DEEDREL has no (variant (paths …)) clause, so what this repo owns cannot be known; nothing was written"
section() { # KEY — the entries of (variant (paths :KEY …)); refuses an unreadable required list
    local out
    if out="$(bash "$READ" --list "$DEED" variant/paths "$1" 2>/dev/null)"; then printf '%s' "$out"
    else case "$1" in added|removed|diverged) die "(variant (paths :$1 …)) in $DEEDREL is missing or not a list; nothing was written" ;; esac; fi
}
ADDED="$(section added)"; REMOVED="$(section removed)"
DIVERGED="$(section diverged; echo; section diverged-pending-upstream)"; OPSTATE="$(section operational-state)"
covers() { # P LIST — 0 if an entry of LIST covers P (a trailing / covers a directory)
    local e
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        case "$e" in */) case "$1" in "$e"*) return 0 ;; esac ;; *) [ "$1" = "$e" ] && return 0 ;; esac
    done <<< "$2"
    return 1
}
owner_held() { # P -> reason, or nothing
    if covers "$1" "$ADDED"; then echo "declared (paths :added): the repo's own"
    elif covers "$1" "$REMOVED"; then echo "declared (paths :removed): not resurrected"
    elif covers "$1" "$DIVERGED"; then echo "declared (paths :diverged): the repo owns it"
    elif covers "$1" "$OPSTATE"; then echo "declared (paths :operational-state)"
    fi
}
protected() { # P -> reason, or nothing
    local b="${1##*/}" lb
    lb="$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')"
    case "$lb" in
        license*|licence*|copying*|unlicense*) echo "licence file"; return ;;
    esac
    case "/$1" in
        */LICENSES/*|*/LICENCES/*|*/licenses/*|*/licences/*) echo "licence directory"; return ;;
    esac
    # Status and proof state describe the repo's OWN state: never overwritten by
    # template equality (hub addendum, mathesis#126 db1f1c6). They change only after
    # being checked against that repo's proof receipts, by a human.
    case "/$1" in
        */docs/status/*|*/PROOF-STATUS*|*/PROOF-NEEDS*|*/TEST-NEEDS*|*/READINESS*|*/ROADMAP*|*/STATE.*|*/STATE-*|*/STATUS.*|*/receipts/*|*/.machine_readable/coaptation/*|*/verification/proofs/*|*receipt*)
            echo "status or proof state (the repo's own; checked against its receipts, never by template equality)"; return ;;
    esac
    case "$1" in
        *_chora.deed) echo "chora deed (identity); only the pins are recorded, by --apply"; return ;;
        .github/workflows/actions.lock) echo "tool-owned (actions lock)"; return ;;
        .github/CODEOWNERS|CODEOWNERS|CITATION.cff) echo "owner-owned"; return ;;
        .github/settings.yml|.github/settings.yaml|.github/rulesets/*) echo "repository rules (never edited by tooling)"; return ;;
    esac
}
# licence_lines FILE — the lines that ARE a licence or copyright claim: a comment
# leader, then SPDX-License-Identifier / SPDX-FileCopyrightText / SPDX-FileContributor
# or "Copyright (c)" at the start. A line that merely mentions SPDX (a script that
# checks for it) is code, not a claim.
LICENCE_RE='^[[:space:]]*([#;*/"'"'"'<!{%-]|//|--)*[[:space:]]*(SPDX-(License-Identifier|FileCopyrightText|FileContributor):|[Cc]opyright[[:space:]]+(\(c\)|©))'
licence_lines() { grep -a -E "$LICENCE_RE" "$1" 2>/dev/null || true; }
under_symlink() { # P — a tracked parent of P in the repo is a symlink
    local p="$1"
    while case "$p" in */*) p="${p%/*}"; true ;; *) false ;; esac; do [ ! -L "$CDIR/$p" ] || return 0; done
    return 1
}

PLAN="$SCRATCH/plan.tsv"; : > "$PLAN"
OUTF="$SCRATCH/result"; mkdir -p "$OUTF"
files "$OLD_DIR" > "$SCRATCH/old.files"; files "$NEW_DIR" > "$SCRATCH/new.files"; files "$CDIR" own > "$SCRATCH/own.files"
sort -u "$SCRATCH/old.files" "$SCRATCH/new.files" "$SCRATCH/own.files" > "$SCRATCH/all.files"
has() { grep -qxF -- "$2" "$SCRATCH/$1.files"; }
declare -A DELETING=()   # paths this plan deletes (a file may make way for a directory of the same name)
blocked_parent() { # P — a parent directory of P is a file or link in the repo that this plan does not delete
    local p="$1"
    while case "$p" in */*) p="${p%/*}"; true ;; *) false ;; esac; do
        if { [ -e "$CDIR/$p" ] || [ -L "$CDIR/$p" ]; } && [ ! -d "$CDIR/$p" ] && [ -z "${DELETING[$p]:-}" ]; then return 0; fi
    done
    return 1
}
mfile() { printf '%s/%s' "$OUTF" "$(printf '%s' "$1" | sha1sum | cut -d' ' -f1)"; }   # one result file per path, never shared
note() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$PLAN"; }

# the file's version in each tree, or absent: o=OLD, n=NEW, c=repo
while IFS= read -r p; do
    O="$OLD_DIR/$p"; N="$NEW_DIR/$p"; C="$CDIR/$p"
    ino=0; inn=0; inc=0
    has old "$p" && ino=1; has new "$p" && inn=1; has own "$p" && inc=1
    # nothing the template changed here: nothing to do (and nothing to guard)
    if [ $ino = 1 ] && [ $inn = 1 ]; then same "$O" "$N" && continue; fi
    [ $ino = 0 ] && [ $inn = 0 ] && continue
    why="$(protected "$p")"; [ -z "$why" ] || { note PROTECTED "$p" "$why"; continue; }
    why="$(owner_held "$p")"; [ -z "$why" ] || { note OWNER-HELD "$p" "$why"; continue; }
    under_symlink "$p" && { note PROTECTED "$p" "lies beneath a symlink in the repo"; continue; }
    # the repo vs the old mint
    c_eq_o=0; [ $ino = 1 ] && [ $inc = 1 ] && same "$C" "$O" && c_eq_o=1
    c_eq_n=0; [ $inn = 1 ] && [ $inc = 1 ] && same "$C" "$N" && c_eq_n=1
    [ $c_eq_n = 1 ] && continue   # already what the new mint has
    if [ $inn = 0 ]; then         # the template dropped it
        if [ $c_eq_o = 1 ]; then DELETING["$p"]=1; note DELETE "$p" "unchanged since the mint; the template removed it"
        elif [ $inc = 1 ]; then note MODIFY-DELETE "$p" "the repo edited it and the template removed it: kept, for a human"
        fi
        continue
    fi
    if [ $inc = 0 ]; then
        if [ $ino = 0 ]; then
            # the repo's file list leaves out ignored and untracked-ignored files: something may
            # still sit here (or on the way), and copying over it would destroy bytes git cannot restore
            if [ -e "$C" ] || [ -L "$C" ]; then
                note OCCUPIED "$p" "the template adds it but an ignored or untracked path is already here: left alone, for a human"
            elif blocked_parent "$p"; then
                note OCCUPIED "$p" "the template adds it but a parent of it is a file in the repo: left alone, for a human"
            else note ADD "$p" "new in the template"; fi
        else note CHILD-REMOVED "$p" "the repo deleted it and the template changed it: left deleted"; fi
        continue
    fi
    # licence lines may not change by automation, whatever else does
    if [ $c_eq_o = 1 ]; then
        if [ ! -L "$N" ] && [ "$(licence_lines "$C")" != "$(licence_lines "$N")" ]; then
            note LICENCE-HELD "$p" "the new version changes an SPDX or copyright line; not written"; continue
        fi
        note FAST-FORWARD "$p" "unchanged since the mint; the template changed it"; continue
    fi
    # both sides changed (or both added): a three-way merge, text only
    if [ -L "$C" ] || [ -L "$N" ] || { [ $ino = 1 ] && [ -L "$O" ]; } || ! { [ ! -s "$C" ] || grep -Iq . "$C"; } || ! { [ ! -s "$N" ] || grep -Iq . "$N"; }; then
        note CONFLICT-UNMERGED "$p" "both changed; a link or binary cannot carry markers: kept as the repo has it"; continue
    fi
    B="$O"; [ $ino = 1 ] || B=/dev/null
    M="$(mfile "$p")"
    rc=0; git merge-file -p -L "repo" -L "mint@${PIN:0:12}" -L "template@${NEW:0:12}" "$C" "$B" "$N" > "$M" 2>/dev/null || rc=$?
    if [ "$rc" -ge 128 ]; then note CONFLICT-UNMERGED "$p" "both changed; git could not merge it: kept as the repo has it"; continue; fi
    # a conflict may not carry a licence claim the template changed either: markers around two
    # versions of an SPDX line are still a licence edit made by automation
    if [ "$rc" -gt 0 ] && [ "$(licence_lines "$B")" != "$(licence_lines "$N")" ]; then
        note LICENCE-HELD "$p" "both changed and the template changes an SPDX or copyright line; not written"; continue
    fi
    if [ "$rc" -gt 0 ]; then note CONFLICT "$p" "$rc overlapping region(s), written with markers"; continue; fi
    if [ "$(licence_lines "$C")" != "$(licence_lines "$M")" ]; then
        note LICENCE-HELD "$p" "the merge would change an SPDX or copyright line; not written"; continue
    fi
    note MERGED "$p" "both changed, no overlap: merged (review it)"
done < "$SCRATCH/all.files"

# ── report ──────────────────────────────────────────────────────────────────
sort -t$'\t' -k1,1 -k2,2 "$PLAN" > "$SCRATCH/plan.sorted"
count() { awk -F'\t' -v s="$1" '$1 == s' "$SCRATCH/plan.sorted" | wc -l | tr -d ' '; }
{
    echo "# upgrade ${SLUG:-template} ${PIN:0:12} -> ${NEW:0:12} for $(basename "$CDIR")  [$MODE]"
    cat "$SCRATCH/plan.sorted"
    echo "# summary: fast-forward $(count FAST-FORWARD), add $(count ADD), delete $(count DELETE), merged $(count MERGED), conflict $(count CONFLICT), conflict-unmerged $(count CONFLICT-UNMERGED), modify-delete $(count MODIFY-DELETE), child-removed $(count CHILD-REMOVED), protected $(count PROTECTED), owner-held $(count OWNER-HELD), licence-held $(count LICENCE-HELD), occupied $(count OCCUPIED)"
} > "$SCRATCH/report.txt"
cat "$SCRATCH/report.txt"
[ -z "$REPORT" ] || cp "$SCRATCH/report.txt" "$REPORT"
NEEDS_HUMAN=$(( $(count CONFLICT) + $(count CONFLICT-UNMERGED) + $(count MODIFY-DELETE) + $(count LICENCE-HELD) + $(count OCCUPIED) ))

if [ "$MODE" = dry ]; then
    echo "upgrade-mint: dry run; nothing was written. Re-run with --apply to write branch $BRANCH." >&2
    [ "$NEEDS_HUMAN" -eq 0 ] || echo "upgrade-mint: $NEEDS_HUMAN item(s) would need a human (exit 3)." >&2
    [ "$NEEDS_HUMAN" -eq 0 ] || exit 3
    exit 0
fi

# ── apply ───────────────────────────────────────────────────────────────────
git -C "$CDIR" switch -q -c "$BRANCH"
# Two passes, in dependency order: removals first (a file may make way for a directory of the
# same name, and the reverse is refused at plan time), then everything that writes. Only files and
# links are ever removed, never a directory; a directory emptied by the removals is left for git.
while IFS=$'\t' read -r st p _; do
    [ "$st" = DELETE ] || continue
    if [ -f "$CDIR/$p" ] || [ -L "$CDIR/$p" ]; then rm -f "$CDIR/$p"; fi
done < "$SCRATCH/plan.sorted"
while IFS=$'\t' read -r st p _; do
    case "$st" in
        FAST-FORWARD|ADD)
            mkdir -p "$(dirname "$CDIR/$p")"
            if [ "$st" = FAST-FORWARD ]; then rm -f "$CDIR/$p"; fi   # an ADD never replaces: the plan refused an occupied path
            cp -P -p "$NEW_DIR/$p" "$CDIR/$p" ;;
        MERGED|CONFLICT)
            cat "$(mfile "$p")" > "$CDIR/$p" ;;      # keeps the repo file's own mode
    esac
done < "$SCRATCH/plan.sorted"
# the one deed edit: record the pin the repo now stands on
bash "$WRITE" set "$DEED" provenance template-commit "\"$NEW\"" >/dev/null
bash "$WRITE" set "$DEED" provenance template-tree "\"$NEWTREE\"" >/dev/null
if bash "$READ" --has "$DEED" variant 2>/dev/null && [ -n "$(bash "$READ" "$DEED" variant parent-pin 2>/dev/null || true)" ]; then
    bash "$WRITE" set "$DEED" variant parent-pin "\"$NEW\"" >/dev/null
fi
[ "$(bash "$READ" "$DEED" provenance template-commit)" = "$NEW" ] || die "the pin did not record; $BRANCH holds an uncommitted partial write. Discard it: git reset --hard && git switch $ORIG_BRANCH && git branch -D $BRANCH"
git -C "$CDIR" add -A
if [ "$NOCOMMIT" = 1 ]; then
    echo "upgrade-mint: written and staged on $BRANCH (--no-commit). Undo: git switch $ORIG_BRANCH && git branch -D $BRANCH (after git reset --hard)." >&2
else
    {
        echo "chore(template): upgrade ${PIN:0:12} -> ${NEW:0:12}$([ "$NEEDS_HUMAN" -gt 0 ] && echo " ($NEEDS_HUMAN need a human)")"
        echo
        echo "Three-way upgrade by scripts/upgrade-mint.sh: base = replay of this repo's mint at"
        echo "${PIN}, theirs = the same mint at ${NEW}, ours = this repo."
        echo
        sed -n 's/^# summary: /Summary: /p' "$SCRATCH/report.txt"
        awk -F'\t' '$1 ~ /^(CONFLICT|CONFLICT-UNMERGED|MODIFY-DELETE|LICENCE-HELD|OCCUPIED|MERGED)$/ { print "  " $1 ": " $2 }' "$SCRATCH/plan.sorted"
        echo
        echo "RSR-Upgrade-Base: $BASE_COMMIT"
        echo "RSR-Upgrade-From-Branch: $ORIG_BRANCH"
        echo "RSR-Upgrade-Template-Old: $PIN"
        echo "RSR-Upgrade-Template-New: $NEW"
        echo "RSR-Upgrade-Needs-Human: $NEEDS_HUMAN"
    } > "$SCRATCH/commit.msg"
    git -C "$CDIR" commit -q -F "$SCRATCH/commit.msg" --no-verify --no-gpg-sign \
        || die "could not commit (set user.name and user.email, or pass --no-commit); the changes are staged on $BRANCH"
    echo "upgrade-mint: committed on $BRANCH (unsigned: the owner re-signs before merge). Rollback: just upgrade --rollback" >&2
fi
echo "upgrade-mint: not pushed. Open it as a DRAFT PR; conflict markers, if any, are in the commit." >&2
[ "$NEEDS_HUMAN" -eq 0 ] || exit 3
exit 0
