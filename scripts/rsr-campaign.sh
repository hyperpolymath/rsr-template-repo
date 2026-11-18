#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# rsr-campaign.sh — the RSR update mechanism.
#
# WHY THIS EXISTS
#
# ADR-0003 (Forge and Sustain) says a forged repository is *sustained* in four
# modes, of which one is:
#
#     adaptive — parent-pin bumps + fan-out campaigns
#
# The check half shipped: scripts/check-variant-drift.sh verifies a child is
# convergent with its parent at the pinned commit, modulo declared divergences.
# The *update* half never existed. That is the gap ADR-0001 lists as a negative
# consequence in one line ("Template updates need propagation mechanism to
# existing repos") while listing "fix once in template, propagate to all repos"
# as a positive one. Both statements were in the same document; only the
# pessimistic one was true.
#
# WHY IT IS A CAMPAIGN AND NOT A MERGE
#
# Measured 2026-09-18 against three representative estate repositories:
#
#     repo            tracked  shared with spine  byte-identical
#     Axiom.jl            328                 55               6
#     wokelang            447                 56               6
#     zotero-tools        959                 36               6
#
# and the spine has 546 files. So ~490 spine files are absent from a typical
# repository and only SIX agree exactly. "Converge the estate to the template"
# would therefore rewrite ~50 files and add ~490 in every one of 269 repos —
# roughly 130,000 file additions, against repositories that have legitimately
# spent years diverging. That is not an update mechanism; it is a re-mint, and
# it would destroy customisation at a scale nobody could review.
#
# The honest conclusion: the estate cannot be *converged*, only *updated along
# declared axes*. So a campaign declares exactly what travels. Everything else
# is left alone, by construction rather than by care.
#
# WHAT A CAMPAIGN IS
#
#   [meta]
#   name / description / why
#   [paths]
#   spine-relative paths to propagate ('dir/' means the whole directory)
#   [exclude]
#   paths never to touch, even inside a propagated directory
#   [promote]
#   per-repo MANIFEST files whose quarantine lines are promoted (see below)
#
# Per repository, per path:
#
#   declared diverged   -> SKIPPED   (the repo deed's (variant) clause says so)
#   retired VARIANT.a2ml -> BLOCKED  (whole repo; migrate it to the deed first)
#   absent in repo      -> ADDED
#   present, differs    -> UPDATED
#   present, identical  -> UNCHANGED
#
# With the known-version guard (`update-guard = known-versions` in [meta], or
# --known-versions), "present, differs" is split in two:
#
#   differs, byte-identical to SOME historical spine version of the path
#                       -> UPDATED   (an older, unedited copy)
#   differs, matches no historical version
#                       -> EDITED    (a local edit: reported, never touched)
#
# History comes from `git log` of the spine, with the spine name rewritten to
# the target's name exactly as for the current version, so an older mint
# qualifies. A shallow spine is deepened first; if that fails the run stops.
# Anything the guard cannot prove unedited is left alone: licence lines and
# local fixes are never clobbered.
#
# An optional [promote] section names per-repo MANIFEST files (spine-relative,
# format <root>|<module>|<status>|<note>). When a path the campaign UPDATED is
# listed there as `quarantine`, ONLY that line's status becomes `gated`, with a
# dated note, in the same commit. check-proofs.sh fails on an "unexpected pass"
# otherwise. No other line is touched and the file is never rewritten whole.
#
# SAFETY PROPERTIES, each deliberate:
#
#   * Dry-run by default. --push is required to write anything at all.
#   * Nothing is ever deleted. A campaign adds and converges; deletion is a
#     different operation with a different blast radius and needs its own gate.
#   * A repository that declares a path diverged is never touched there, so a
#     campaign cannot silently reverse a decision the repo already recorded.
#   * Files containing an unfilled {{TOKEN}} are REFUSED by default, because
#     propagating one plants a placeholder in a repo whose own placeholder gate
#     will then fail its every push. --allow-tokens overrides, deliberately
#     loudly.
#   * A repository with no changes is not committed to.
#   * The spine's own name is rewritten to the target's name, so the campaign
#     does not re-plant template identity (the ADR-0003 mint criterion).
#
# Usage:
#   rsr-campaign.sh --manifest FILE --repos-file FILE [options]
#
#   --manifest FILE     campaign manifest (required)
#   --repos-file FILE   repositories, one per line (required)
#   --spine DIR         spine checkout; default: the repo this script is in
#   --work-dir DIR      where to clone; default: a temp dir
#   --batch N           batch number, 1-based
#   --batch-size M      repositories per batch (default 25)
#   --push              commit and push; without it, --apply changes nothing
#   --apply             write changes into the checkout (still no push)
#   --base-ref REF      branch to stack on (default: the repo default branch).
#                       Set this when the campaign depends on work that is not
#                       merged yet — e.g. the stage-5 sweep branches.
#   --branch NAME       branch to push to (default: the campaign name)
#   --report FILE       write a TSV report
#   --known-versions    enable the known-version guard (also: [meta] update-guard)
#   --allow-tokens      permit propagating files with {{TOKEN}} placeholders
#   --no-substitute     do not rewrite the spine name to the repo name
#   --quiet             less per-repo output
#
# Exit: 0 = every targeted repo reached a terminal state; 1 = at least one failed.

set -euo pipefail

PROG="$(basename "$0")"

MANIFEST=""; REPOS_FILE=""; SPINE=""; WORK_DIR=""
# The deed reader ships beside this script, whatever --spine names.
CAMPAIGN_READ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deed-field.sh"
BATCH=""; BATCH_SIZE=25; PUSH=0; APPLY=0; BRANCH=""; REPORT=""; BASE_REF=""
ALLOW_TOKENS=0; SUBSTITUTE=1; QUIET=0; GUARD=0

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }
note() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
hr() { [ "$QUIET" -eq 1 ] || printf -- '------------------------------------------------------------\n'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --manifest)    MANIFEST="${2:?}"; shift 2 ;;
        --repos-file)  REPOS_FILE="${2:?}"; shift 2 ;;
        --spine)       SPINE="${2:?}"; shift 2 ;;
        --work-dir)    WORK_DIR="${2:?}"; shift 2 ;;
        --batch)       BATCH="${2:?}"; shift 2 ;;
        --batch-size)  BATCH_SIZE="${2:?}"; shift 2 ;;
        --branch)      BRANCH="${2:?}"; shift 2 ;;
        --base-ref)    BASE_REF="${2:?}"; shift 2 ;;
        --report)      REPORT="${2:?}"; shift 2 ;;
        --push)        PUSH=1; shift ;;
        --apply)       APPLY=1; shift ;;
        --known-versions) GUARD=1; shift ;;
        --allow-tokens) ALLOW_TOKENS=1; shift ;;
        --no-substitute) SUBSTITUTE=0; shift ;;
        --quiet|-q)    QUIET=1; shift ;;
        -h|--help)     sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             die "unknown argument: $1" ;;
    esac
done

[ -n "$MANIFEST" ]   || die "missing --manifest"
[ -n "$REPOS_FILE" ] || die "missing --repos-file"
[ -f "$MANIFEST" ]   || die "manifest not found: $MANIFEST"
[ -f "$REPOS_FILE" ] || die "repos file not found: $REPOS_FILE"

# The spine is the source of truth. Default to the checkout this script lives in.
if [ -z "$SPINE" ]; then
    SPINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
[ -d "$SPINE/.git" ] || die "spine is not a git checkout: $SPINE"

if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rsr-campaign.XXXXXX")"
fi
mkdir -p "$WORK_DIR"

# ---------------------------------------------------------------------------
# Manifest parsing
# ---------------------------------------------------------------------------
# Deliberately a tiny INI reader rather than a dependency: the manifest is a
# declaration, not a program, and a campaign that needs a parser installed is a
# campaign that cannot be run during an incident.
MANIFEST_SECTION=""
CAMP_NAME="${MANIFEST##*/}"; CAMP_NAME="${CAMP_NAME%.campaign}"
CAMP_DESC=""
PATHS=(); EXCLUDES=(); PROMOTES=()

while IFS= read -r line || [ -n "$line" ]; do
    # strip comments and surrounding space
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    case "$line" in
        \[*\]) MANIFEST_SECTION="$(printf '%s' "$line" | tr -d '[]')"; continue ;;
    esac
    case "$MANIFEST_SECTION" in
        meta)
            key="${line%%=*}"; val="${line#*=}"
            key="$(printf '%s' "$key" | tr -d '[:space:]')"
            val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            case "$key" in
                name)        [ -n "$val" ] && CAMP_NAME="$val" ;;
                description) CAMP_DESC="$val" ;;
                update-guard)
                    case "$val" in
                        known-versions) GUARD=1 ;;
                        none) ;;
                        *) die "unknown update-guard '$val' in $MANIFEST" ;;
                    esac ;;
            esac
            ;;
        paths)    PATHS+=("$line") ;;
        exclude)  EXCLUDES+=("$line") ;;
        promote)  PROMOTES+=("$line") ;;
        *)        die "line outside a known section in $MANIFEST: $line" ;;
    esac
done < "$MANIFEST"

[ "${#PATHS[@]}" -gt 0 ] || die "manifest declares no [paths]: $MANIFEST"
[ -n "$BRANCH" ] || BRANCH="$CAMP_NAME"

note "campaign: $CAMP_NAME"
[ -n "$CAMP_DESC" ] && note "  $CAMP_DESC"
note "  spine:    $SPINE"
note "  manifest: $MANIFEST"
note "  paths:    ${#PATHS[@]} declared, ${#EXCLUDES[@]} excluded"
note "  branch:   $BRANCH"
[ "$GUARD" -eq 1 ] && note "  guard:    known-versions (edited copies are left alone)"
[ -n "$BASE_REF" ] && note "  stacked on: $BASE_REF"
if [ "$PUSH" -eq 1 ]; then
    note "  mode:     PUSH (commit and push each repository)"
elif [ "$APPLY" -eq 1 ]; then
    note "  mode:     apply (write locally, do not push)"
else
    note "  mode:     dry-run (nothing written)"
fi
hr

# ---------------------------------------------------------------------------
# Known-version guard: the spine needs its history
# ---------------------------------------------------------------------------
if [ "$GUARD" -eq 1 ] && [ "$(git -C "$SPINE" rev-parse --is-shallow-repository)" = true ]; then
    git -C "$SPINE" fetch -q --unshallow 2>/dev/null \
        || die "known-version guard needs spine history and the shallow spine could not be deepened"
fi

# known_version DST REL REPO -> 0 if DST is byte-identical to some historical
# spine version of REL (spine name rewritten to REPO, as for the current one).
known_version() {
    local dst="$1" rel="$2" repo="$3" c t found=1
    t="$(mktemp)"
    while IFS= read -r c; do
        [ -z "$c" ] && continue
        git -C "$SPINE" cat-file blob "$c:$rel" > "$t.raw" 2>/dev/null || continue
        substitute "$t.raw" "$repo" > "$t"
        if cmp -s "$t" "$dst"; then found=0; break; fi
    done < <(git -C "$SPINE" log --format=%H -- "$rel")
    rm -f "$t" "$t.raw"
    return $found
}

# promote_manifest FILE REL-LIST... : quarantine -> gated for each updated
# path, that line only. Prints one PROMOTED line per change.
promote_manifest() {
    local mf="$1"; shift
    local rel line root mod st note out changed=0 tmpf
    [ -f "$mf" ] || return 0
    tmpf="$(mktemp)"; cp "$mf" "$tmpf"
    for rel in "$@"; do
        out="$(mktemp)"
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in '#'*|'') printf '%s\n' "$line" >> "$out"; continue ;; esac
            IFS='|' read -r root mod st note <<<"$line"
            # check-proofs.sh accepts trailing slashes on a source root, so
            # compare on the normalised root; the written line keeps the original.
            nroot="$root"; while [[ "$nroot" == */ ]]; do nroot="${nroot%/}"; done
            if [[ "$nroot/$mod" == "$rel" && "$st" == quarantine ]]; then
                printf '%s|%s|gated| promoted %s by campaign %s: compiles after the fix (was:%s)\n' \
                    "$root" "$mod" "$(date -u +%F)" "$CAMP_NAME" "$note" >> "$out"
                printf 'PROMOTED %s\n' "$rel"
            else
                printf '%s\n' "$line" >> "$out"
            fi
        done < "$tmpf"
        mv "$out" "$tmpf"
    done
    cp "$tmpf" "$mf"; rm -f "$tmpf"
}

# ---------------------------------------------------------------------------
# Repo selection — same batch arithmetic as the stage-5 sweep, so operators
# only have to know one set of flags.
# ---------------------------------------------------------------------------
mapfile -t ALL_REPOS < <(grep -vE '^\s*(#|$)' "$REPOS_FILE" | sed -e 's/[[:space:]]*$//')
TOTAL=${#ALL_REPOS[@]}
[ "$TOTAL" -gt 0 ] || die "no repositories in $REPOS_FILE"

if [ -n "$BATCH" ]; then
    start=$(( (BATCH - 1) * BATCH_SIZE ))
    end=$(( start + BATCH_SIZE ))
    [ "$start" -lt "$TOTAL" ] || die "batch $BATCH is past the end ($TOTAL repositories)"
    SELECTED=("${ALL_REPOS[@]:start:end-start}")
    note "batch $BATCH of size $BATCH_SIZE: ${#SELECTED[@]} of $TOTAL repositories"
else
    SELECTED=("${ALL_REPOS[@]}")
fi
hr

# ---------------------------------------------------------------------------
# Token safety
# ---------------------------------------------------------------------------
# {{TOKEN}} and friends are META tokens: they name a placeholder kind rather
# than being one, and the spine's own gate exempts them. A repository running an
# OLDER check-no-placeholders.sh has no such exemption, so a propagated comment
# mentioning the token would fail that repo's every push. Refusing is the safe
# default; the override exists for a deliberate decision, not a convenience.
META_TOKENS='PLACEHOLDER|ANYTHING|TOKEN|UPPER_SNAKE'

# ---------------------------------------------------------------------------
# Self-name substitution
# ---------------------------------------------------------------------------
# ADR-0003's mint criterion: no template identity survives in the child. The
# spine's own name is a literal, so propagating it verbatim would re-plant the
# identity the mint pass exists to remove.
SPINE_NAME="$(basename "$SPINE")"
substitute() { # src-file repo-name -> stdout
    local f="$1" repo="$2"
    if [ "$SUBSTITUTE" -eq 1 ] && [ "$repo" != "$SPINE_NAME" ]; then
        sed "s/\b${SPINE_NAME}\b/${repo}/g" "$f"
    else
        cat "$f"
    fi
}

# ---------------------------------------------------------------------------
# Divergence declarations
# ---------------------------------------------------------------------------
# If the repository's deed carries a (variant) clause, honour it: a path it declares
# diverged is a decision already made, and a campaign must not silently reverse
# a decision. Matches check-variant-drift.sh's in_list semantics, including the
# 'dir/' prefix form.
declared_diverged() { # repo-path path -> 0 if declared diverged
    local dir="$1" want="$2" deed e
    deed="$(bash "$CAMPAIGN_READ" --find "$dir" 2>/dev/null)" || return 1
    while IFS= read -r e; do
        [ -z "$e" ] && continue
        case "$e" in
            */) case "$want" in "$e"*) return 0 ;; esac ;;
            *)  [ "$want" = "$e" ] && return 0 ;;
        esac
    done < <(for k in diverged diverged-pending-upstream operational-state; do
                 bash "$CAMPAIGN_READ" --list "$deed" variant/paths "$k" 2>/dev/null || true
             done)
    return 1
}

excluded() { # path -> 0 if excluded by the manifest
    local want="$1" e
    for e in ${EXCLUDES+"${EXCLUDES[@]}"}; do
        case "$e" in
            */) case "$want" in "$e"*) return 0 ;; esac ;;
            *)  [ "$want" = "$e" ] && return 0 ;;
        esac
    done
    return 1
}

# ---------------------------------------------------------------------------
# The campaign itself
# ---------------------------------------------------------------------------
REPORT="${REPORT:-$WORK_DIR/campaign-report.tsv}"
printf 'repo\tpath\toutcome\tdetail\n' > "$REPORT"

ADDED=0; UPDATED=0; EDITED=0; PROMOTED=0; SKIPPED=0; REFUSED=0; NOCHANGE=0; FAILED=0

for repo in "${SELECTED[@]}"; do
    [ -z "$repo" ] && continue
    dir="$WORK_DIR/repos/$repo"
    rm -rf "$dir"
    mkdir -p "$WORK_DIR/repos"

    # A repos file normally lists bare names under one owner; owner/name is
    # accepted too, so a campaign can span owners without a second flag.
    case "$repo" in
        */*) slug="$repo" ;;
        *)   slug="${RSR_OWNER:-hyperpolymath}/$repo" ;;
    esac

    # --base-ref stacks the campaign on work that is not merged yet. Without it
    # the campaign branches from the default branch, which is the honest
    # default: a campaign should not silently depend on an unmerged branch.
    clone_args=(-q --depth 1)
    [ -n "$BASE_REF" ] && clone_args+=(-b "$BASE_REF")
    if ! git clone "${clone_args[@]}" "https://github.com/$slug.git" "$dir" 2>/dev/null; then
        if [ -n "$BASE_REF" ]; then
            printf '%s\t-\tCLONE-FAIL\tbase ref %s not found\n' "$repo" "$BASE_REF" >> "$REPORT"
            note "  $repo: CLONE-FAIL (no $BASE_REF)"
        else
            printf '%s\t-\tCLONE-FAIL\t-\n' "$repo" >> "$REPORT"
            note "  $repo: CLONE-FAIL"
        fi
        FAILED=$((FAILED+1)); continue
    fi

    # A repo still carrying the retired VARIANT.a2ml has divergence decisions
    # this script no longer reads. Treating it as "no contract" would let the
    # campaign overwrite paths the repo declared diverged, so it is refused.
    if [ -f "$dir/.machine_readable/descriptiles/VARIANT.a2ml" ]; then
        printf '%s\t-\tBLOCKED\tcarries retired VARIANT.a2ml; migrate it to the deed (variant) clause first\n' "$repo" >> "$REPORT"
        note "  $repo: BLOCKED (retired VARIANT.a2ml)"
        FAILED=$((FAILED+1)); continue
    fi

    repo_changed=0
    repo_added=0; repo_updated=0; repo_skipped=0; repo_refused=0; repo_edited=0
    updated_paths=()

    # Collect the spine's file list for the declared paths.
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        case "$rel" in
            *.gitkeep) continue ;;
        esac
        if excluded "$rel"; then
            printf '%s\t%s\tEXCLUDED\tmanifest exclude\n' "$repo" "$rel" >> "$REPORT"
            repo_skipped=$((repo_skipped+1)); continue
        fi
        if declared_diverged "$dir" "$rel"; then
            printf '%s\t%s\tDIVERGED\tdeclared in the deed (variant) clause\n' "$repo" "$rel" >> "$REPORT"
            repo_skipped=$((repo_skipped+1)); continue
        fi

        src="$SPINE/$rel"
        dst="$dir/$rel"
        [ -f "$src" ] || continue

        if [ "$ALLOW_TOKENS" -eq 0 ]; then
            # Name the actual tokens. A report that says "carries {{TOKEN}}"
            # whatever it found is a claim wider than its evidence, which is
            # the specific failure mode this estate keeps auditing itself for.
            # `|| true` on both greps: a file with no tokens (the usual case)
            # makes grep exit 1, which pipefail and set -e turned into an exit
            # of the whole campaign at the first ordinary file.
            toks="$({ grep -ohE '\{\{[A-Z_]+\}\}' "$src" 2>/dev/null || true; } \
                    | { grep -vE "^\{\{($META_TOKENS)\}\}$" || true; } | sort -u | tr '\n' ' ')"
            if [ -n "$toks" ]; then
                # shellcheck disable=SC2086  # deliberate word split for -n
                printf '%s\t%s\tREFUSED\tcarries unfilled token(s): %s\n' \
                    "$repo" "$rel" "${toks% }" >> "$REPORT"
                repo_refused=$((repo_refused+1)); continue
            fi
        fi

        tmp="$(mktemp)"
        substitute "$src" "${repo##*/}" > "$tmp"

        if [ ! -f "$dst" ]; then
            printf '%s\t%s\tADDED\t-\n' "$repo" "$rel" >> "$REPORT"
            repo_added=$((repo_added+1)); repo_changed=1
            if [ "$APPLY" -eq 1 ] || [ "$PUSH" -eq 1 ]; then
                mkdir -p "$(dirname "$dst")"; cp "$tmp" "$dst"
            fi
        elif cmp -s "$tmp" "$dst"; then
            printf '%s\t%s\tUNCHANGED\t-\n' "$repo" "$rel" >> "$REPORT"
        elif [ "$GUARD" -eq 1 ] && ! known_version "$dst" "$rel" "${repo##*/}"; then
            printf '%s\t%s\tEDITED\tmatches no historical template version; left alone\n' "$repo" "$rel" >> "$REPORT"
            repo_edited=$((repo_edited+1))
        else
            printf '%s\t%s\tUPDATED\t-\n' "$repo" "$rel" >> "$REPORT"
            repo_updated=$((repo_updated+1)); repo_changed=1
            updated_paths+=("$rel")
            if [ "$APPLY" -eq 1 ] || [ "$PUSH" -eq 1 ]; then
                cp "$tmp" "$dst"
            fi
        fi
        rm -f "$tmp"
    done < <(git -C "$SPINE" ls-files -- "${PATHS[@]}" 2>/dev/null | sort)

    # Promote quarantined MANIFEST lines for the modules just updated.
    repo_promoted=0
    if [ "${#updated_paths[@]}" -gt 0 ]; then
        for pm in ${PROMOTES+"${PROMOTES[@]}"}; do
            [ -f "$dir/$pm" ] || continue
            # A MANIFEST the repo declared diverged is its own decision: report, skip.
            if declared_diverged "$dir" "$pm"; then
                printf '%s\t%s\tDIVERGED\tMANIFEST declared in the deed (variant) clause; promotion skipped\n' "$repo" "$pm" >> "$REPORT"
                continue
            fi
            if [ "$APPLY" -eq 1 ] || [ "$PUSH" -eq 1 ]; then
                out="$(promote_manifest "$dir/$pm" "${updated_paths[@]}")"
            else
                cp "$dir/$pm" "$WORK_DIR/.mf.dry"
                out="$(promote_manifest "$WORK_DIR/.mf.dry" "${updated_paths[@]}")"
            fi
            while IFS= read -r l; do
                [ -z "$l" ] && continue
                printf '%s\t%s\tPROMOTED\t%s quarantine -> gated\n' "$repo" "${l#PROMOTED }" "$pm" >> "$REPORT"
                repo_promoted=$((repo_promoted+1)); repo_changed=1
            done <<<"$out"
        done
    fi
    PROMOTED=$((PROMOTED+repo_promoted)); EDITED=$((EDITED+repo_edited))
    ADDED=$((ADDED+repo_added)); UPDATED=$((UPDATED+repo_updated))
    SKIPPED=$((SKIPPED+repo_skipped)); REFUSED=$((REFUSED+repo_refused))

    if [ "$repo_changed" -eq 0 ]; then
        note "  $repo: no change ($repo_skipped skipped, $repo_refused refused, $repo_edited edited)"
        NOCHANGE=$((NOCHANGE+1))
        continue
    fi

    detail="+$repo_added ~$repo_updated promoted:$repo_promoted"
    if [ "$APPLY" -eq 0 ] && [ "$PUSH" -eq 0 ]; then
        note "  $repo: would change ($detail$([ "$repo_skipped" -gt 0 ] && printf ', %s skipped' "$repo_skipped"))"
        continue
    fi

    if [ "$PUSH" -eq 1 ]; then
        ( cd "$dir" \
          && git checkout -q -b "$BRANCH" \
          && git add -A -- . \
          && git -c user.name="${RSR_COMMIT_NAME:-rsr-campaign}" \
                 -c user.email="${RSR_COMMIT_EMAIL:-rsr-campaign@users.noreply.github.com}" \
                 commit -q -m "chore(rsr): campaign '$CAMP_NAME' — $detail" \
          && git push -q origin "$BRANCH" ) >/dev/null 2>&1 || {
            printf '%s\t-\tPUSH-FAIL\t-\n' "$repo" >> "$REPORT"
            note "  $repo: PUSH-FAIL"
            FAILED=$((FAILED+1)); continue
        }
        note "  $repo: pushed ($detail)"
    else
        note "  $repo: applied ($detail)"
    fi
done

hr
note "campaign '$CAMP_NAME' complete"
note "  paths ADDED:     $ADDED"
note "  paths UPDATED:   $UPDATED"
note "  paths EDITED:    $EDITED (guard: matched no template version; left alone)"
note "  lines PROMOTED:  $PROMOTED (MANIFEST quarantine -> gated)"
note "  paths SKIPPED:   $SKIPPED (declared diverged / excluded)"
note "  paths REFUSED:   $REFUSED (carried an unfilled placeholder)"
note "  repos unchanged: $NOCHANGE"
note "  repos failed:    $FAILED"
note "  report:          $REPORT"
[ "$FAILED" -eq 0 ] || exit 1
