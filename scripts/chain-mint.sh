#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# chain-mint.sh — mint a repository made from a MINTED repository.
#
# A minted repo has already filled its tokens and deleted build/templates, so
# minting it again rendered none of the new answers and skipped the identity
# splice: the grandchild inherited its parent's author, contacts and identity
# (Codex review of #251). The owner chose to support chains properly
# (2026-11-04). This is how, as a three-way merge that git performs:
#
#   base   = replay of the parent's own mint   (template @ pin, parent answers)
#   theirs = the parent as it stands           (base + the parent's own work)
#   ours   = the template @ pin minted with THIS repo's answers
#   result = merge-tree(base, ours, theirs)
#
# base -> theirs is exactly the parent's own work since its mint, and nothing
# else, so it is replayed onto a fresh mint for the new identity. Everything
# the template rendered is rendered afresh; the parent's own files and edits
# are carried; a conflict between the two stops before anything is written.
# Identity-bearing files (the deed, CLAUDE.md, the map, the roadmap) are never
# carried: they come from the new mint and are regenerated. Text the parent
# wrote about itself is renamed by the same rules repo-init uses: the bounded
# self-name rule and the narrow self-owner rule (repo-init defines each once
# and exports SELF_NAME_SED and SELF_OWNER_SED). What it inherits is declared
# by comparing the result with the fresh mint, as the drift gate does.
#
# Called by `just repo-init` from the root of the new repository, whose tree is
# the parent's ("Use this template" on a minted repo), after the prompts, with
# the new answers exported under the names repo-init reads, plus
# TEMPLATE_REPO/TEMPLATE_OWNER (the parent) and RSR_MINT_DATE.
# RSR_TEMPLATE_URL overrides where the template's history is read from.
# Exit: 0 minted; 1 refused (reason on stderr, tree untouched); 2 usage.
set -euo pipefail
# This script runs git against other repositories (-C does not override
# these), so an inherited location (a hook, another git caller) cannot redirect
# it (CodeRabbit review of #275).
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_NAMESPACE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READ="$HERE/deed-field.sh"
G="$(pwd)"
die() { echo "chain-mint: $*" >&2; exit 1; }
# g — git with no user or system configuration and no hooks, as the drift
# gate's (Codex review of #275): this machine's settings cannot change the
# merge, the commits or the file sets.
g() {
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=chain -c user.email=chain@example.invalid \
        -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

for v in REPO OWNER TEMPLATE_REPO TEMPLATE_OWNER RSR_MINT_DATE; do
    [ -n "${!v:-}" ] || { echo "chain-mint: $v is not set (run through just repo-init)" >&2; exit 2; }
done
# A sparse checkout lists paths it has not checked out; read as a tree, their
# absence is a deletion of most of the repository (Codex review of #277). A
# chain mint carries and rewrites the whole tree, so it needs all of it.
_sparse=0
while IFS= read -r -d '' e; do case "$e" in "S "*) _sparse=$((_sparse + 1)) ;; esac; done < <(g -C "$G" ls-files -t -z)
[ "$_sparse" -eq 0 ] || die "this checkout is sparse (${_sparse} tracked paths are not checked out); a chain mint carries the whole tree. Run it from a full checkout (git sparse-checkout disable); nothing was written"
# An unresolved merge: its stages would collapse into one ordinary blob, and
# conflict markers would be carried as the parent's work (Codex review of #277).
[ -z "$(g -C "$G" ls-files -u)" ] || die "this checkout has an unresolved merge (git ls-files -u); resolve it first; nothing was written"
# A tracked path beneath a symlink: reading it would read through the link,
# from wherever it points (Codex review of #277). Refused by name.
while IFS= read -r -d '' f; do
    p="$f"
    while case "$p" in */*) p="${p%/*}"; true ;; *) false ;; esac; do
        [ ! -L "$G/$p" ] || die "the tracked path $f lies beneath the symlink $p; restore the directory or untrack the path; nothing was written"
    done
done < <(g -C "$G" ls-files -z)
PDEED="$(bash "$READ" --find "$G")" || die "no single *_chora.deed in this tree"
PIN="$(bash "$READ" "$PDEED" provenance template-commit 2>/dev/null || true)"
TSLUG="$(bash "$READ" "$PDEED" provenance template-repo 2>/dev/null || true)"
[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] || die "the parent's (provenance :template-commit) is '${PIN}', not a commit"
P_ARCH="$(bash "$READ" "$PDEED" mint-answers archetype 2>/dev/null || true)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The root template's history, holding the parent's pin.
URL="${RSR_TEMPLATE_URL:-https://github.com/${TSLUG}.git}"
FILTER=(--filter=blob:none)
case "$URL" in *://*|*@*:*) ;; *) FILTER=() ;; esac
git clone -q --no-checkout "${FILTER[@]}" "$URL" "$WORK/template" 2>"$WORK/clone.err" \
    || { cat "$WORK/clone.err" >&2; die "cannot read ${TSLUG} from $URL (set RSR_TEMPLATE_URL)"; }
git -C "$WORK/template" cat-file -e "${PIN}^{commit}" 2>/dev/null \
    || die "$URL does not contain the parent's template commit $PIN"

echo "  chain: replaying the parent's mint (${TSLUG}@${PIN:0:12}, its own answers)"
bash "$HERE/replay-mint.sh" "$WORK/template" "$PIN" "$WORK/base" --answers-from "$PDEED" \
    || die "the replay of the parent's mint failed (above); nothing was written"
echo "  chain: minting ${TSLUG}@${PIN:0:12} with this repo's answers"
ARCHETYPE="$P_ARCH" RSR_TEMPLATE_SLUG="$TSLUG" bash "$HERE/replay-mint.sh" "$WORK/template" "$PIN" "$WORK/new" \
    || die "the mint with the new answers failed (above); nothing was written"


# ── Trees, written by git ───────────────────────────────────────────────────
# Every tree below is written by git from a work tree, and the result is
# written back into this checkout by git. Git never follows a symlink in a work
# tree, and checks every path it would overwrite before it writes any (Codex
# review of #277: copying with tar followed a parent-controlled symlink,
# recursed into a path that had become a directory, and emptied the checkout
# before learning that an ignored entry was in the way).
M="$WORK/merge"
g init -q -b base "$M"
mkdir -p "$M/.git/objects/info"
# link_objects DIR — DIR's objects become readable from M.
link_objects() {
    local od
    od="$(g -C "$1" rev-parse --path-format=absolute --git-common-dir)/objects"
    grep -qxF "$od" "$M/.git/objects/info/alternates" 2>/dev/null || printf '%s\n' "$od" >> "$M/.git/objects/info/alternates"
}
# tree_of DIR NAME — the tree of DIR's own files, as `git add -A` commits them
# from DIR's index: tracked files (an ignore rule matching or not) and the
# untracked files no rule ignores. Written into M; DIR's .git is not written.
tree_of() {
    local d="$1" idx="$WORK/index.$2" gd
    link_objects "$d"
    gd="$(g -C "$d" rev-parse --path-format=absolute --git-dir)"
    rm -f "$idx"
    g -C "$d" ls-files -s -z | GIT_INDEX_FILE="$idx" g --git-dir="$M/.git" update-index -z --index-info
    ( cd "$d" && GIT_INDEX_FILE="$idx" g --git-dir="$M/.git" --work-tree=. \
        -c core.excludesFile="$gd/info/exclude" add -A . )
    GIT_INDEX_FILE="$idx" g --git-dir="$M/.git" write-tree
}
# with_index NAME CMD… — run git CMD in M against the scratch index NAME.
with_index() { local i="$WORK/index.$1"; shift; GIT_INDEX_FILE="$i" g --literal-pathspecs -C "$M" "$@"; }
P_DEED_NAME="$(basename "$PDEED")"
IDENTITY=("$P_DEED_NAME" CLAUDE.md docs/architecture/REPOSITORY-MAP.adoc docs/status/ROADMAP.adoc)

B="$(g -C "$M" commit-tree "$(tree_of "$WORK/base" base)" -m base)"
# theirs: the parent as it stands (uncommitted work included), with its
# identity files held at base, so they are never carried: they belong to the
# parent. Held in the index, never through the parent's work tree.
PARENT_TREE="$(tree_of "$G" parent)"
rm -f "$WORK/index.theirs"; with_index theirs read-tree "$PARENT_TREE"
for f in "${IDENTITY[@]}"; do
    with_index theirs rm -q --cached --ignore-unmatch -- "$f"
    entry="$(g -C "$M" ls-tree "$B" -- "$f")"
    [ -n "$entry" ] || continue
    read -r mode _ sha _ <<<"$entry"
    with_index theirs update-index --add --cacheinfo "$mode,$sha,$f" 2>/dev/null \
        || die "cannot hold $f at the template's version: the parent replaced a directory above it"
done
THEIRS="$(g -C "$M" commit-tree "$(with_index theirs write-tree)" -p "$B" -m theirs)"

# ours: the fresh mint, kept as its own commit (the drift gate replays exactly
# it, so the declarations are measured against it), then shaped by the
# parent's deletions and type changes. ours differs from base only by
# rendering, so a file the parent deleted stays deleted (else a modify/delete
# conflict: .machine_readable/ai/PLACEHOLDERS.adoc), and a path whose type the
# parent changed keeps base's version there, so the parent's change wins (else
# a "distinct types" conflict against a mere re-rendering).
NEW_T="$(tree_of "$WORK/new" new)"
g -C "$M" branch -q fresh "$(g -C "$M" commit-tree "$NEW_T" -p "$B" -m fresh)"
rm -f "$WORK/index.ours"; with_index ours read-tree "$NEW_T"
while IFS= read -r -d '' f; do
    with_index ours rm -q --cached --ignore-unmatch -- "$f"
done < <(g -C "$M" diff -z --no-renames --name-only --diff-filter=D "$B" "$THEIRS")
while IFS= read -r -d '' f; do
    with_index ours rm -q --cached --ignore-unmatch -- "$f"
    read -r mode _ sha _ <<<"$(g -C "$M" ls-tree "$B" -- "$f")"
    with_index ours update-index --add --cacheinfo "$mode,$sha,$f"
done < <(g -C "$M" diff -z --no-renames --name-only --diff-filter=T "$B" "$THEIRS")
OURS="$(g -C "$M" commit-tree "$(with_index ours write-tree)" -p fresh -m ours)"

if ! g -C "$M" merge-tree --write-tree --name-only --merge-base="$B" "$OURS" "$THEIRS" > "$WORK/merge.out" 2>&1; then
    echo "chain-mint: the parent's own changes conflict with this repo's fresh mint in:" >&2
    # --name-only: the merged tree, then the conflicted paths, a blank line,
    # then git's messages (CONFLICT …), which say what kind of conflict.
    sed -n '2,$p' "$WORK/merge.out" | sed '/^$/d; s/^/    /' | head -n 60 >&2
    die "nothing was written. Resolve those in the parent (or mint from the template), then retry."
fi
RESULT="$(head -n 1 "$WORK/merge.out")"

# Everything below is built and checked in a scratch copy, F; this checkout
# is written only once every step has succeeded, so a failure at any point (a
# carried placeholder, a failing gate) leaves it untouched (Codex review of #277).
F="$WORK/final"
g -C "$M" branch -q result "$(g -C "$M" commit-tree "$RESULT" -m result)"
g init -q -b main "$F"
g -C "$F" fetch -q "$M" fresh:refs/chain/fresh result:refs/chain/result
# F's index is the merged tree itself, and git writes its files (never
# through a symlink); a tracked file an ignore rule matches stays tracked.
g -C "$F" read-tree refs/chain/result
g -C "$F" checkout-index -a -f

# What this repo inherits is the merged result's difference from the fresh
# mint: exactly what the drift gate will compare. Measured on the result, not
# on the parent's diff, so a path the merge carried through an answer-dependent
# rename (src/<Old>.jl -> src/<New>.jl) is named where it now lives (Codex
# review of #277). The files the new mint owns (the deed, CLAUDE.md, the map,
# the roadmap) are declared already, and are regenerated below.
FRESH="$(g -C "$F" rev-parse refs/chain/fresh)"
OWNED=("${REPO}_chora.deed" CLAUDE.md docs/architecture/REPOSITORY-MAP.adoc docs/status/ROADMAP.adoc)
is_owned() { local o; for o in "${OWNED[@]}"; do [ "$1" = "$o" ] && return 0; done; return 1; }
# inherited — "STATUS\0PATH\0" for every path where F differs from the fresh mint.
inherited() { g -C "$F" add -A; g -C "$F" diff --cached -z --no-renames --name-status "$FRESH"; }

# Rename the parent where its own work names it, by the rules repo-init
# defined and exported, read as data: the bounded self-name rule
# (SELF_NAME_SED) and the narrow self-owner rule for identity settings
# (SELF_OWNER_SED: a carried sonar.organization or OWNER := line).
for v in SELF_NAME_SED SELF_OWNER_SED; do
    [ -n "${!v:-}" ] || { echo "chain-mint: $v is not set (run through just repo-init)" >&2; exit 2; }
done
TEMPLATE_SLUG="${TEMPLATE_OWNER}/${TEMPLATE_REPO}"
VERBATIM="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$F/.machine_readable/mint-verbatim.txt" | grep -v '^$' || true)"
while IFS= read -r -d '' st && IFS= read -r -d '' f; do
    [ "$st" != D ] || continue
    [ -f "$F/$f" ] && [ ! -L "$F/$f" ] || continue
    grep -qxF -- "$f" <<< "$VERBATIM" && continue
    if [ "$TEMPLATE_OWNER" != "$OWNER" ] && grep -qIF -- "$TEMPLATE_OWNER" "$F/$f" 2>/dev/null; then
        sed -i -E "$SELF_OWNER_SED" "$F/$f"
    fi
    if grep -qIF -- "$TEMPLATE_REPO" "$F/$f" 2>/dev/null; then
        sed -i -E "$SELF_NAME_SED" "$F/$f"
    fi
done < <(inherited)

# Every path this script writes from here on must be a real path inside F: a
# symlink the parent carried at one of them, or at a directory above one,
# would redirect the write (Codex review of #277). Refused by name.
DEED="$F/${REPO}_chora.deed"
for w in "${REPO}_chora.deed" CLAUDE.md docs/architecture/REPOSITORY-MAP.adoc \
         .machine_readable/arrival-pack/claude-md-data.json; do
    p="$w"
    while :; do
        [ ! -L "$F/$p" ] || die "the carried tree has a symlink at $p, where the mint writes $w; nothing was written"
        case "$p" in */*) p="${p%/*}" ;; *) break ;; esac
    done
done
[ -f "$DEED" ] || die "the new mint produced no ${REPO}_chora.deed"
cp "$DEED" "$WORK/deed.fresh"

# declare — the inherited paths, by kind, into the three lists. The deed's
# (paths) lists are line-based: a path holding a newline is refused by name.
declare_paths() {
    : > "$WORK/added.list"; : > "$WORK/removed.list"; : > "$WORK/diverged.list"
    N_A=0 N_D=0 N_M=0
    while IFS= read -r -d '' st && IFS= read -r -d '' f; do
        is_owned "$f" && continue
        case "$f" in *$'\n'*) die "cannot declare a carried path containing a newline: $(printf '%q' "$f"); nothing was written" ;; esac
        case "$st" in
            A) printf '%s\n' "$f" >> "$WORK/added.list"; N_A=$((N_A + 1)) ;;
            D) printf '%s\n' "$f" >> "$WORK/removed.list"; N_D=$((N_D + 1)) ;;
            *) printf '%s\n' "$f" >> "$WORK/diverged.list"; N_M=$((N_M + 1)) ;;
        esac
    done < <(inherited)
    cat "$WORK/added.list" "$WORK/removed.list" "$WORK/diverged.list" > "$WORK/declared.now"
}
# write_deed — the fresh deed, plus the lineage and the declared lists. Paths
# are written as deed strings (\ and " escaped) by awk, which takes them as
# data: a path holding &, |, " or \ cannot corrupt the clause or the command.
write_deed() {
    awk -v slug="$TEMPLATE_SLUG" -v ptree="$PARENT_TREE" \
        -v fa="$WORK/added.list" -v fr="$WORK/removed.list" -v fd="$WORK/diverged.list" '
        function load(file,    s, p) {
            s = ""
            while ((getline p < file) > 0) {
                if (p == "") continue
                gsub(/\\/, "\\\\", p); gsub(/"/, "\\\"", p)
                s = s " \"" p "\""
            }
            close(file); return s
        }
        # insert EXTRA before the first ")" that closes the list opened at "(",
        # skipping parentheses inside strings.
        function extend(line, extra,    i, c, q, open, out) {
            open = index(line, "("); q = 0
            for (i = open + 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (q && c == "\\") { i++; continue }
                if (c == "\"") q = !q
                else if (!q && c == ")") {
                    out = substr(line, 1, i - 1) extra substr(line, i)
                    sub(/\( "/, "(\"", out)
                    return out
                }
            }
            return line
        }
        BEGIN { A = load(fa); R = load(fr); D = load(fd) }
        /^      :added \(/    { $0 = extend($0, A) }
        /^      :removed \(/  { $0 = extend($0, R) }
        /^      :diverged \(/ { $0 = extend($0, D) }
        { print }
        /^    :template-tree "[^"]*"$/ {
            print "    ; minted from a minted repo: its own work since its mint was carried across"
            print "    :derived-from \"" slug "\""
            print "    :derived-from-tree \"" ptree "\""
        }
    ' "$WORK/deed.fresh" > "$WORK/deed.new"
    cat "$WORK/deed.new" > "$DEED"
    grep -q ':derived-from "' "$DEED" || die "could not record :derived-from in $(basename "$DEED")"
}
# regenerate — the derived files follow the merged tree and the new deed.
# They run the CARRIED generators, so what they write is measured afterwards.
regenerate() {
    ( cd "$F" && bash .machine_readable/arrival-pack/generate.sh >/dev/null ) \
        || die "the arrival pack could not be regenerated; nothing was written"
    ( cd "$F" && bash scripts/gen-repo-map.sh --worktree . >/dev/null ) \
        || die "the repository map could not be regenerated; nothing was written"
}
# Declared, written and regenerated until the declaration is stable: a carried
# generator that writes another file is measured, not missed (Codex review of
# #277). Twice settles any generator that is a function of the tree.
declare_paths; write_deed; regenerate
cp "$WORK/declared.now" "$WORK/declared.before"
declare_paths
if ! cmp -s "$WORK/declared.before" "$WORK/declared.now"; then
    write_deed; regenerate
    cp "$WORK/declared.now" "$WORK/declared.before"
    declare_paths
    cmp -s "$WORK/declared.before" "$WORK/declared.now" \
        || die "the carried generators keep changing the tree (the declaration does not settle); nothing was written"
fi

# The gates a mint enforces on a child, run on the result before this checkout
# is written: a chain mint must not finish with a tree its own CI rejects
# (Codex review of #277).
gate() { local name="$1"; shift; ( cd "$F" && "$@" ) > "$WORK/gate.log" 2>&1 \
    || { tail -n 40 "$WORK/gate.log" >&2; die "the result fails $name (above); nothing was written"; }; }
gate "the placeholder gate" env -u GITHUB_REPOSITORY bash scripts/check-no-placeholders.sh .
for _gate in check-spdx-headers check-mise-language check-container-pins; do
    [ -f "$F/scripts/${_gate}.sh" ] && gate "${_gate}" bash "scripts/${_gate}.sh" --root .
done
[ ! -f "$F/www/tests/run-all.sh" ] || gate "the www/ suite" bash www/tests/run-all.sh
gate "just verify" just verify

# Every check passed: write the result into this checkout, by git. The scratch
# index starts as the parent snapshot (which is what the work tree holds), and
# a two-tree read-tree moves it to the result: git refuses, before writing
# anything, any path where an untracked or ignored file would be overwritten.
rm -f "$F/.machine_readable/arrival-pack/claude-md-data.json"
FINAL_T="$(g -C "$F" add -A && g -C "$F" write-tree)"
link_objects "$F"
GIDX="$WORK/index.write"
rm -f "$GIDX"
if ! ( cd "$G" && export GIT_INDEX_FILE="$GIDX" \
        && g --git-dir="$M/.git" --work-tree=. read-tree "$PARENT_TREE" \
        && g --git-dir="$M/.git" --work-tree=. update-index -q --refresh \
        && g --git-dir="$M/.git" --work-tree=. read-tree -m -u "$PARENT_TREE" "$FINAL_T" ) 2> "$WORK/write.err"; then
    sed 's/^/    /' "$WORK/write.err" >&2
    die "this checkout cannot take the result without overwriting a file it does not track (above); nothing was written"
fi
echo "  chain: carried the parent's own work: ${N_M} edited, ${N_A} added, ${N_D} removed (declared in (variant (paths)))"
echo "  chain: ${REPO} minted from ${TEMPLATE_SLUG} (template ${TSLUG}@${PIN:0:12})"
