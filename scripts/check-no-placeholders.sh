#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-no-placeholders.sh — no repo may ship an unfilled {{PLACEHOLDER}}.
#
# Estate rule (methodology.a2ml: reject-if-contains): a token that `just init`
# did not fill is debt, and in .github/settings.yml or SECURITY.md it is a
# defect with consequences — probot/settings applies settings.yml on every push,
# and a security policy that cites a key nobody holds is worse than one that
# says "email us".
#
# This is the single implementation of that rule, called from two places:
#   * .github/workflows/openssf-compliance.yml — on the repo as committed
#   * tests/e2e/template_instantiation_test.sh — on a freshly init'd repo,
#     which is where a leak is still cheap to fix
# It exists as a script rather than inline shell in each caller because the
# previous split — a workflow that checked a hand-listed set of files, and an
# e2e test that re-implemented substitution with its own token list — let the
# two drift until the test passed while real instantiation leaked.
#
# Scans every text file and allow-lists the few legitimate carriers, rather
# than checking a list of files someone must remember to extend. The old
# required-files list omitted .github/settings.yml and ANCHOR.a2ml, which is
# precisely where the leaks were.
#
# Matches upper-snake brace tokens only. Justfiles are skipped entirely: an
# ARGS token there is just's own interpolation syntax, not a template token.
# GitHub Actions expressions are ${{ dotted.lower }} and do not match.
#
# Exit codes:
#   0 — no unfilled tokens (or this is a template repo, where tokens are the product)
#   1 — unfilled tokens found
#   2 — usage / setup error

set -euo pipefail

REPO_ROOT="${1:-.}"

if [ ! -d "$REPO_ROOT" ]; then
    echo "usage: $0 [repo-root]" >&2
    exit 2
fi

# A template repo's placeholders ARE its product — they are what `just init`
# consumes. Any other repo is an instantiation and is checked in full.
REPO_NAME="${GITHUB_REPOSITORY:-$(cd "$REPO_ROOT" && basename "$(pwd)")}"
case "$REPO_NAME" in
    *-template-repo)
        echo "PASS: $REPO_NAME is a template repo — unfilled tokens are intentional"
        exit 0
        ;;
esac

# Files that legitimately contain tokens after instantiation.
ALLOWED=(
    ".machine_readable/ai/PLACEHOLDERS.adoc"   # the token vocabulary itself
    "EXPLAINME.adoc"                           # prose explaining that tokens exist
    "scripts/check-no-placeholders.sh"         # this file (the pattern above)
    "tests/e2e/template_instantiation_test.sh" # names tokens in its answer list
)

is_allowed() {
    local rel="$1"
    for a in "${ALLOWED[@]}"; do
        [ "$rel" = "$a" ] && return 0
    done
    # just owns brace tokens inside justfiles — an ARGS token there is
    # interpolation, not a placeholder. Justfiles are not only at the root:
    # the contractiles ship one too.
    case "$rel" in
        Justfile|justfile|*/Justfile|*/justfile|*.just) return 0 ;;
    esac
    return 1
}

# Metasyntactic tokens: prose *about* tokens, not tokens. "Replace all
# {{PLACEHOLDER}} values" names the concept — there is no PLACEHOLDER variable
# for init to fill, so these can never be a leak, and flagging them would only
# teach people that this gate cries wolf. Real tokens name a real init variable.
META_TOKENS='PLACEHOLDER|ANYTHING|TOKEN|UPPER_SNAKE'

LEAKS=()
while IFS= read -r hit; do
    rel="${hit#"$REPO_ROOT"/}"
    is_allowed "$rel" && continue
    # Re-check the file for at least one non-metasyntactic token.
    if grep -ohE '\{\{[A-Z][A-Z0-9_]*\}\}' "$hit" \
        | grep -qvE "^\{\{($META_TOKENS)\}\}$"; then
        LEAKS+=("$rel")
    fi
done < <(grep -rlE '\{\{[A-Z][A-Z0-9_]*\}\}' "$REPO_ROOT" \
             --exclude-dir=.git --binary-files=without-match 2>/dev/null | sort)

if [ ${#LEAKS[@]} -eq 0 ]; then
    echo "PASS: no unfilled {{PLACEHOLDER}} tokens"
    exit 0
fi

echo "FAIL: ${#LEAKS[@]} file(s) contain unfilled {{PLACEHOLDER}} tokens:" >&2
for leak in "${LEAKS[@]}"; do
    tokens=$(grep -ohE '\{\{[A-Z][A-Z0-9_]*\}\}' "$REPO_ROOT/$leak" \
             | grep -vE "^\{\{($META_TOKENS)\}\}$" | sort -u | tr '\n' ' ')
    echo "  - $leak: $tokens" >&2
done
echo "" >&2
echo "Each token must either be filled by build/just/init.just's SED_ARGS, or" >&2
echo "removed from the shipped file. A token with no possible value (a PGP key" >&2
echo "the estate does not hold) makes this gate unsatisfiable — delete the" >&2
echo "section instead of leaving the gate permanently red." >&2
exit 1
