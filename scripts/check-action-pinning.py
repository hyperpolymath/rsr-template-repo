#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Assert every workflow action ref is pinned — inline SHA, or via actions.lock.

What counts as "pinned" changed when GitHub introduced workflow lockfiles. A ref
is pinned if EITHER it is an inline 40-hex SHA, OR .github/workflows/actions.lock
resolves it to one. The previous inline-only rule rejected all 40 of this repo's
own refs, so `Workflow Security Linter` was red on main permanently — and every
repo minted from this template inherited both the tag-form workflows and the gate
that rejects them.

Three details are load-bearing, each of them a defect found by testing:

  `-?` in the pattern. `- uses:` is the list-item form and by far the most
  common; a `\\s+uses:` pattern silently misses every one of them. Estate memory
  records this exact failure — "green linter != full SHA-pinning". A gate that
  cannot see the common case reads as coverage and enforces nothing.

  Case-insensitive comparison. Workflows write `SonarSource/...`; the lockfile
  records `sonarsource/...`. Action refs are case-insensitive in practice, so a
  case-sensitive match reports a false positive on a correctly-pinned action.

  Only *.yml / *.yaml, depth 1. A bare recursive grep also reads actions.lock
  (whose `uses:` keys are lockfile entries, not refs) and *.yml.template (whose
  tag ref is deliberate and resolved at mint time). Both were reported as
  unpinned, which made the gate unsatisfiable the moment a lockfile existed.

Exit 0 if every ref is pinned, 1 otherwise, listing file:line: ref.
"""
import re
import sys
from pathlib import Path

WF = Path(".github/workflows")
LOCK = WF / "actions.lock"
# `-?` matches the list-item form; see the module docstring.
USES = re.compile(r"^\s*-?\s*uses:\s*([^\s#]+)")
SHA = re.compile(r"@[a-f0-9]{40}$")
EXEMPT_PREFIX = ("./", "$", "docker://")


def main() -> int:
    if not WF.is_dir():
        print("no .github/workflows — nothing to check")
        return 0

    known: set[str] = set()
    if LOCK.is_file():
        known = {k.lower() for k in re.findall(r"'([^']+@[^']+)'", LOCK.read_text())}
        print(f"lockfile present: {len(known)} ref(s) resolvable through it")
    else:
        print("no lockfile — every ref must be an inline 40-character SHA")

    bad = []
    for wf in sorted(list(WF.glob("*.yml")) + list(WF.glob("*.yaml"))):
        for n, line in enumerate(wf.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            m = USES.match(line)
            if not m:
                continue
            ref = m.group(1)
            if ref.startswith(EXEMPT_PREFIX) or "actions/github-script" in ref:
                continue
            if SHA.search(ref):
                continue
            name, _, tag = ref.rpartition("@")
            root = "/".join(name.split("/")[:2])          # subpath actions key by repo root
            if ref.lower() in known or f"{root}@{tag}".lower() in known:
                continue
            bad.append(f"{wf}:{n}: {ref}")

    if bad:
        print("\nERROR: these action refs are neither SHA-pinned nor covered by the lockfile:")
        for b in bad:
            print(f"  {b}")
        print("\nEither pin to a full commit SHA, or run `gh actions-lock` so the")
        print("lockfile resolves the ref.")
        return 1
    print("all action refs are pinned")
    return 0


if __name__ == "__main__":
    sys.exit(main())
