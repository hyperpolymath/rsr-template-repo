#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-root-shape.sh — enforce the canonical root shape, in BOTH directions,
# against the repository root allowlist, under EITHER canonical spelling:
#   .machine_readable/root-allow.txt  (dotted, CANONICAL ESTATE-WIDE)
#   machine-readable/root-allow.txt   (hyphenated, accepted legacy)
#
# The dotted form is the standard (owner ruling 2026-09-17; estate census 48
# repos dotted vs 9 hyphenated). The hyphenated form is still RESOLVED, not
# rejected, because the checker is shared with repos that have not migrated.
# Removing this branch would turn 9 working gates into exit-2 setup errors.
#
#   * an entry at root that is not listed          -> drift (extra)
#   * a listed entry WITHOUT '?' that is missing   -> drift (missing)
#
# The second direction was absent until 2026-08, and its absence is why the
# allowlist rotted: it accumulated 19 permissions for files the April root
# cleanup had already moved into docs/, and nothing could ever notice. A
# one-directional allowlist only ratchets open, so over time it licenses
# exactly the drift it was written to prevent.
#
# '?' marks an entry that is legitimately absent in some conforming repo —
# template-only material removed at mint, or a capability-gated module.
#
# The allow set is DERIVED, not only listed (standards
# TEMPLATE-APPLICABILITY-POLICY: baseline ∪ { M : gate(M) ⊆ capabilities }):
# root-allow.txt is the baseline, and every root-level module that the vendored
# gate table (.machine_readable/template-capability-gates.toml) gates on a
# capability the repo profile declares is admitted as optional. With nothing
# declared the behaviour is exactly the static list. See the "Derived
# allowlist" block below for what is and is not derived.
#
# Companion to scripts/validate-template.sh: that script enforces required
# files; this one enforces the shape as a whole.
#
# Exit codes:
#   0 — root matches allowlist
#   1 — drift (extras at root, or required entries missing)
#   2 — usage / setup error (incl. two deeds, an unknown preset, or a vendored
#       gate table that is not the one the deed's (canon :gates-sha256) pins)

set -euo pipefail

REPO_ROOT="${1:-.}"
REPO_ROOT_DOTTED="${REPO_ROOT}/.machine_readable/root-allow.txt"
REPO_ROOT_HYPHEN="${REPO_ROOT}/machine-readable/root-allow.txt"

# Both spellings are estate contract. Resolve whichever exists; if BOTH exist
# that is itself drift (two sources of truth) and is refused.
if [ -f "$REPO_ROOT_DOTTED" ] && [ -f "$REPO_ROOT_HYPHEN" ]; then
    echo "ERROR: both .machine_readable/ and machine-readable/ carry a root-allow.txt;" >&2
    echo "       pick one spelling — two allowlists cannot both be canonical." >&2
    exit 2
elif [ -f "$REPO_ROOT_DOTTED" ]; then
    ALLOW_FILE="$REPO_ROOT_DOTTED"
elif [ -f "$REPO_ROOT_HYPHEN" ]; then
    ALLOW_FILE="$REPO_ROOT_HYPHEN"
else
    echo "ERROR: allowlist not found at either $REPO_ROOT_DOTTED or $REPO_ROOT_HYPHEN" >&2
    exit 2
fi

# Build the allow set: strip comments, trailing slashes, and blank lines.
# A leading '?' marks the entry optional; it is not part of the name.
mapfile -t ALLOW_RAW < <(
    sed -E 's/[[:space:]]*#.*$//' "$ALLOW_FILE" \
        | sed -E 's|/$||' \
        | awk 'NF' \
        | sed -E 's/[[:space:]]+$//'
)

declare -A ALLOW_SET=()
REQUIRED=()
ALLOW=()
for raw in "${ALLOW_RAW[@]}"; do
    if [[ "$raw" == '?'* ]]; then
        entry="${raw#\?}"
    else
        entry="$raw"
        REQUIRED+=("$entry")
    fi
    ALLOW_SET["$entry"]=1
    ALLOW+=("$entry")
done

# ─── Derived allowlist: baseline ∪ { M : gate(M) ⊆ capabilities } ────────────
# standards 0-canon/TEMPLATE-APPLICABILITY-POLICY.adoc defines
#   effective-allowlist(repo) = baseline ∪ { M : gate(M) ⊆ profile(repo).capabilities }
# and standards A5 G14 (Approved) makes the root allowlist DERIVED from the
# profile and the gate table. Before this block only the first term existed, so
# a repo whose root legitimately carried a capability-gated module (Cargo.toml
# in a declared-rust repo) had two bad options: allow-list it by hand, or move
# a file its own toolchain reads from the root only.
#
# baseline is root-allow.txt, read above. The second term comes from the gate
# table, vendored beside root-allow.txt as template-capability-gates.toml (a
# byte copy of standards' .machine_readable/template-capability-gates.toml),
# and from the profile's effective capability set, capabilities + preset + add
# - remove, read from the repo deed's (rsr-profile …) clause or, where no deed
# carries one, the legacy rsr-profile.a2ml. Same resolution order as standards
# scripts/check-rsr-profile.sh, the reference reader.
#
# What is derived, and what is not:
#   * only ROOT-LEVEL alternatives of a gate row (`Cargo.toml`, `test/`,
#     `abi.ipkg`). A nested alternative (`src/interface/ffi/`,
#     `docs/AUDIT.adoc`) says where a module lives INSIDE a root entry; it does
#     not license that entry. Deriving ancestors would let the row alternative
#     `0-canon/GOVERNANCE.adoc` admit a root 0-canon/ into every
#     governance-tier repo. Glob alternatives (`*/Cargo.toml`) are never
#     derived: membership is by exact name, so a pattern would admit only a
#     file literally named `*.zig` and would misreport the derived set.
#   * a derived entry is OPTIONAL, as if written with '?'. Whether a declared
#     module is PRESENT is check-rsr-profile.sh's MISSING verdict, taken over
#     all of a row's alternatives; this gate answers only what MAY sit at the
#     root. A derived entry never removes, or relaxes, a static one.
#
# Missing data only ever makes this gate STRICTER, never looser: with no
# profile, no declared capability, no gate table or no deed reader, the allow
# set is root-allow.txt alone, exactly as before this block existed.
# Contradictory data is a setup error (exit 2): more than one *_chora.deed, an
# unknown preset, or a vendored table whose sha256 is not the deed's
# (canon :gates-sha256) pin. That last one is the canon-spine lockstep: a table
# the repo has not adopted may not widen its root. Adopting a canon release is
# therefore "bump the pin AND re-vendor the table", in one commit.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATES_FILE="$(dirname "$ALLOW_FILE")/template-capability-gates.toml"
DEED_FIELD="$SCRIPT_DIR/deed-field.sh"
declare -A GATED_BY=()   # every root-level gated name -> the capability (or capabilities) that admit it
DERIVED=()               # names admitted by a declared capability and not already listed
CAP_NOTE=""              # one line for the PASS summary saying where the derived set came from

derive_note() { echo "::notice title=root-shape::$*" >&2; }

# Body lines of a [section] of the gate table, comments and blanks stripped.
gates_section() { awk -v s="[$1]" '$0==s{f=1;next} /^\[/{f=0} f && !/^[[:space:]]*#/ && NF' "$GATES_FILE"; }
# The quoted items of `key = [ … ]` in a section body on stdin. The array may
# span lines; a trailing `# …` comment is dropped first.
array_on_key() {
    awk -v k="$1" '
        on { sub(/#.*/, ""); print; if (/\]/) on = 0; next }
        $0 ~ "^[[:space:]]*\"?" k "\"?[[:space:]]*=" { sub(/#.*/, ""); sub(/^[^=]*=/, ""); print; if (!/\]/) on = 1 }
    ' | grep -oE '"[^"]+"' | tr -d '"' || true
}
# The first quoted value of `key = "…"` in a section body on stdin.
scalar_on_key() {
    grep -E "^[[:space:]]*$1[[:space:]]*=" | sed -n 's/^[^=]*=[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true
}

PROFILE_DIRECT="" PROFILE_PRESET="" PROFILE_ADD="" PROFILE_REMOVE="" GATES_PIN="" PROFILE_SOURCE=""
deeds=()
shopt -s nullglob
for d in "$REPO_ROOT"/*_chora.deed "$REPO_ROOT"/.*_chora.deed; do
    [ "$(basename "$d")" = "estate_chora.deed" ] || deeds+=("$d")
done
shopt -u nullglob
if [ "${#deeds[@]}" -gt 1 ]; then
    echo "ERROR: $REPO_ROOT carries ${#deeds[@]} *_chora.deed files; one deed per repo (D312) is needed to read the profile" >&2
    exit 2
elif [ "${#deeds[@]}" -eq 1 ]; then
    if [ ! -f "$DEED_FIELD" ]; then
        derive_note "${deeds[0]#"$REPO_ROOT"/} found but $DEED_FIELD is absent; no capabilities read, static allowlist only"
    elif bash "$DEED_FIELD" --has "${deeds[0]}" rsr-profile; then
        PROFILE_SOURCE="${deeds[0]#"$REPO_ROOT"/} (rsr-profile …)"
        PROFILE_DIRECT="$(bash "$DEED_FIELD" --list "${deeds[0]}" rsr-profile capabilities || true)"
        PROFILE_PRESET="$(bash "$DEED_FIELD" "${deeds[0]}" rsr-profile preset || true)"
        PROFILE_ADD="$(bash "$DEED_FIELD" --list "${deeds[0]}" rsr-profile add || true)"
        PROFILE_REMOVE="$(bash "$DEED_FIELD" --list "${deeds[0]}" rsr-profile remove || true)"
    fi
    # The pin is read whichever source carries the profile: it is the deed's
    # statement of which gate table this repo implements.
    [ -f "$DEED_FIELD" ] && GATES_PIN="$(bash "$DEED_FIELD" "${deeds[0]}" canon gates-sha256 || true)"
fi
if [ -z "$PROFILE_SOURCE" ]; then
    for p in "$REPO_ROOT/.machine_readable/rsr-profile.a2ml" "$REPO_ROOT/machine-readable/rsr-profile.a2ml"; do
        [ -f "$p" ] || continue
        body="$(awk '$0=="[rsr-profile]"||$0=="[profile]"{f=1;next} /^\[/{f=0} f && !/^[[:space:]]*#/ && NF' "$p")"
        PROFILE_SOURCE="${p#"$REPO_ROOT"/}"
        PROFILE_DIRECT="$(printf '%s\n' "$body" | array_on_key capabilities)"
        PROFILE_PRESET="$(printf '%s\n' "$body" | scalar_on_key preset)"
        PROFILE_ADD="$(printf '%s\n' "$body" | array_on_key add)"
        PROFILE_REMOVE="$(printf '%s\n' "$body" | array_on_key remove)"
        break
    done
fi

# [gates] rows as "alt|alt|…<TAB>capability". Read whenever the table is
# present, so that a failure can say which declaration would admit an entry
# even in a repo that declares nothing; deriving still needs a declaration.
GATE_ROWS=""
if [ -f "$GATES_FILE" ]; then
    GATE_ROWS="$(gates_section gates | sed -nE 's/^[[:space:]]*"([^"]*)"[[:space:]]*=[[:space:]]*"([^"]*)".*/\1\t\2/p')"
fi
# root_names_of <row key>: its root-level alternatives, one per line.
root_names_of() {
    local alt alts name
    IFS='|' read -r -a alts <<<"$1"
    for alt in "${alts[@]}"; do
        name="${alt%/}"
        case "$name" in ''|*/*|*[\*\?\[]*) continue ;; esac
        printf '%s\n' "$name"
    done
}
while IFS=$'\t' read -r key cap; do
    [ -n "$key" ] || continue
    while IFS= read -r name; do
        GATED_BY["$name"]="${GATED_BY[$name]:+${GATED_BY[$name]} or }'$cap'"
    done < <(root_names_of "$key")
done <<<"$GATE_ROWS"

if [ -z "$PROFILE_DIRECT$PROFILE_PRESET$PROFILE_ADD" ]; then
    CAP_NOTE="no capabilities declared${PROFILE_SOURCE:+ in $PROFILE_SOURCE}; static allowlist only"
elif [ ! -f "$GATES_FILE" ]; then
    derive_note "capabilities declared in $PROFILE_SOURCE but no gate table at ${GATES_FILE#"$REPO_ROOT"/}; static allowlist only"
    CAP_NOTE="capabilities declared but no gate table at ${GATES_FILE#"$REPO_ROOT"/}; static allowlist only"
else
    if [ -n "$GATES_PIN" ]; then
        have="$( (sha256sum "$GATES_FILE" 2>/dev/null || shasum -a 256 "$GATES_FILE") | awk '{print $1}')"
        if [ "$have" != "$GATES_PIN" ]; then
            echo "ERROR: ${GATES_FILE#"$REPO_ROOT"/} has sha256 $have," >&2
            echo "       but the deed's (canon :gates-sha256) pin is $GATES_PIN." >&2
            echo "       Re-vendor the gate table of the canon release you pin (or bump the pin" >&2
            echo "       to the table you vendored); an unpinned table may not widen the root." >&2
            exit 2
        fi
    fi
    PRESET_CAPS=""
    if [ -n "$PROFILE_PRESET" ]; then
        PRESET_CAPS="$(gates_section presets | array_on_key "$PROFILE_PRESET")"
        if [ -z "$PRESET_CAPS" ]; then
            echo "ERROR: $PROFILE_SOURCE names preset '$PROFILE_PRESET', which ${GATES_FILE#"$REPO_ROOT"/} [presets] does not define" >&2
            exit 2
        fi
    fi
    EFFECTIVE="$(printf '%s\n%s\n%s\n' "$PROFILE_DIRECT" "$PRESET_CAPS" "$PROFILE_ADD" | sed '/^$/d' | sort -u)"
    if [ -n "$PROFILE_REMOVE" ]; then
        EFFECTIVE="$(comm -23 <(printf '%s\n' "$EFFECTIVE") <(printf '%s\n' "$PROFILE_REMOVE" | sort -u))"
    fi
    declare -A HAS_CAP=()
    while IFS= read -r c; do [ -n "$c" ] && HAS_CAP["$c"]=1; done <<<"$EFFECTIVE"

    while IFS=$'\t' read -r key cap; do
        { [ -n "$key" ] && [ -n "${HAS_CAP[$cap]+x}" ]; } || continue
        while IFS= read -r name; do
            if [ -z "${ALLOW_SET[$name]+x}" ]; then
                ALLOW_SET["$name"]=1
                ALLOW+=("$name")
                DERIVED+=("$name")
            fi
        done < <(root_names_of "$key")
    done <<<"$GATE_ROWS"

    CAP_NOTE="capabilities from $PROFILE_SOURCE: $(printf '%s\n' "$EFFECTIVE" | paste -sd' ' -)"
    if [ "${#DERIVED[@]}" -gt 0 ]; then
        CAP_NOTE="$CAP_NOTE; derived: ${DERIVED[*]}"
    else
        CAP_NOTE="$CAP_NOTE; derived: nothing beyond the static list"
    fi
fi

# Enumerate everything at the repository root, EXCLUDING git-ignored entries.
#
# This was a bare `find`, which contradicted the contract root-allow.txt states
# ("Anything tracked at root that is not in this list is drift"): a plain
# filesystem scan also sees build output. Any repo with a root-level build
# directory -- `target/` for Cargo, `node_modules/`, `_build/` for Mix --
# therefore failed this gate the moment someone built before running it, and
# the tempting "fix" was to allowlist an artifact directory that must never be
# committed.
#
# Filtering through `git check-ignore` makes the check mean what it says. The
# fallback keeps the script working outside a git worktree.
mapfile -t ACTUAL < <(
    cd "$REPO_ROOT" && \
    find . -mindepth 1 -maxdepth 1 \
        ! -name '.' \
        -printf '%f\n' \
    | { if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            git check-ignore --stdin --non-matching --verbose 2>/dev/null \
                | sed -n 's/^::[[:space:]]//p'
        else
            cat
        fi; } \
    | sort
)

declare -A ACTUAL_SET=()
for entry in "${ACTUAL[@]}"; do
    ACTUAL_SET["$entry"]=1
done

# Direction 1 — present at root but not permitted.
EXTRAS=()
for entry in "${ACTUAL[@]}"; do
    if [ -z "${ALLOW_SET[$entry]+x}" ]; then
        EXTRAS+=("$entry")
    fi
done

# Direction 2 — required by the allowlist but not present.
MISSING=()
for entry in "${REQUIRED[@]}"; do
    if [ -z "${ACTUAL_SET[$entry]+x}" ]; then
        MISSING+=("$entry")
    fi
done

if [ ${#EXTRAS[@]} -eq 0 ] && [ ${#MISSING[@]} -eq 0 ]; then
    OPTIONAL_COUNT=$(( ${#ALLOW[@]} - ${#REQUIRED[@]} - ${#DERIVED[@]} ))
    echo "PASS: root matches allowlist (${#ACTUAL[@]} entries; ${#REQUIRED[@]} required, ${OPTIONAL_COUNT} optional, ${#DERIVED[@]} derived)"
    echo "      $CAP_NOTE"
    exit 0
fi

if [ ${#EXTRAS[@]} -gt 0 ]; then
    echo "FAIL: ${#EXTRAS[@]} root entries are not on the allowlist:" >&2
    for e in "${EXTRAS[@]}"; do
        # A name the gate table admits under a capability this profile does not
        # declare is said so: the honest fix may be the declaration, not a move.
        hint="${GATED_BY[$e]:+  (capability-gated: admitted when the profile declares ${GATED_BY[$e]})}"
        if [ -d "$REPO_ROOT/$e" ]; then
            echo "  - $e/  (directory)$hint" >&2
        else
            echo "  - $e$hint" >&2
        fi
    done
    echo "" >&2
    echo "Either move them into the appropriate subdirectory, declare the capability" >&2
    echo "that gates them (if the repo really has it), or add a justified entry to" >&2
    echo "${ALLOW_FILE#"$REPO_ROOT"/}." >&2
    echo "($CAP_NOTE)" >&2
fi

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "FAIL: ${#MISSING[@]} allowlist entries are required but absent:" >&2
    for e in "${MISSING[@]}"; do
        echo "  - $e" >&2
    done
    echo "" >&2
    echo "Either restore them, or - if they are legitimately absent in this repo -" >&2
    echo "mark the entry optional with a leading '?' in root-allow.txt and say why." >&2
    echo "Do not mark an entry optional merely to silence this." >&2
fi
exit 1
