;; SPDX-License-Identifier: PMPL-1.0-or-later
;;
;; Root Hygiene Rules — enforced by Hypatia scan + gitbot-fleet
;;
;; These rules define what files ARE and ARE NOT allowed in the repo root.
;; Bots enrolled in the fleet will flag violations during Hypatia scans.
;; Repos can exclude specific rules via (exclude-rules ...) in their
;; own bot_directives/ override.
;;
;; Designed to keep roots clean and RSR-template-compliant.
;; Reference: rsr-template-repo root layout as of 2026-03-15.

(root-hygiene-rules
  (version "1.0.0")
  (last-updated "2026-03-15")
  (enforced-by ("hypatia" "rhodibot" "finishbot"))

  ;; =========================================================================
  ;; ALLOWED root files — these belong here
  ;; =========================================================================
  (allowed-root-files
    ;; AI/Machine manifest
    "0-AI-MANIFEST.a2ml"
    ;; Standard docs
    "README.adoc" "README.md"
    "CHANGELOG.md"
    "CONTRIBUTING.md"          ;; .md required for GitHub community health
    "CODE_OF_CONDUCT.md"
    "SECURITY.md"
    "ROADMAP.adoc" "ROADMAP.md"
    "TOPOLOGY.md"
    "MAINTAINERS.adoc"
    "NOTICE"
    "AUTHORS"
    ;; License
    "LICENSE" "LICENSE.md" "LICENSE.txt"
    ;; Build/config
    "Justfile" "justfile"
    "contractile.just"
    "Containerfile"
    "Mustfile"
    "Makefile"                 ;; legacy, tolerated
    "flake.nix" "flake.lock"
    "guix.scm"
    ;; Dotfiles
    ".editorconfig"
    ".envrc"
    ".gitattributes"
    ".gitignore"
    ".gitmodules"
    ".gitlab-ci.yml"
    ".guix-channel"
    ".tool-versions"
    ;; Language-specific build files (if project root IS the source)
    "Cargo.toml" "Cargo.lock"
    "deno.json" "deno.lock"
    "rescript.json"
    "mix.exs" "mix.lock"
    "gleam.toml"
    "build.zig" "build.zig.zon"
    "*.ipkg"                   ;; Idris2
    "*.cabal" "stack.yaml"     ;; Haskell
    "Project.toml"             ;; Julia
    )

  ;; =========================================================================
  ;; BANNED root patterns — these should NEVER be in root
  ;; =========================================================================
  (banned-root-patterns
    ;; Stale status snapshots with dates in filename
    (pattern "*-STATUS-*.md" (action "delete") (reason "Point-in-time snapshots belong in git history, not as files"))
    (pattern "*-COMPLETION-*.md" (action "delete") (reason "Completion snapshots are ephemeral"))
    (pattern "*-VERIFIED-*.md" (action "delete") (reason "Verification reports belong in docs/reports/"))

    ;; Executed plans and done announcements
    (pattern "*-COMPLETE.md" (action "delete") (reason "Done announcements have no ongoing value"))
    (pattern "*-PLAN.md" (action "move" "docs/design/") (reason "Plans with value move to docs/design/, stale ones delete"))

    ;; Migration artifacts
    (pattern "MIGRATION-*.md" (action "delete-or-move" "docs/design/") (reason "Migration docs are transient"))
    (pattern "*-BLOCKED.md" (action "delete") (reason "Blocker notes are transient — use issues instead"))

    ;; Superseded files
    (pattern "CLAUDE-INSTRUCTIONS.md" (action "delete") (reason "Superseded by .claude/CLAUDE.md"))
    (pattern "AI.a2ml" (action "rename" "0-AI-MANIFEST.a2ml") (reason "RSR standard name is 0-AI-MANIFEST.a2ml"))
    (pattern "AI.djot" (action "keep") (reason "Valid if project uses Djot format"))
    (pattern "MANIFEST.md" (action "delete") (reason "Superseded by 0-AI-MANIFEST.a2ml"))

    ;; Duplicate format files
    (pattern "CONTRIBUTING.adoc" (action "delete") (reason "GitHub requires .md for community health; keep CONTRIBUTING.md"))

    ;; License redundancy
    (pattern "PALIMPSEST.adoc" (action "delete") (reason "Redundant with LICENSE + LICENSES/ directory"))

    ;; Language-specific design docs that belong in docs/
    (pattern "*-ARCHITECTURE.md" (action "move" "docs/design/") (reason "Architecture docs belong in docs/design/"))
    (pattern "*-ARCHITECTURE.adoc" (action "move" "docs/design/") (reason "Architecture docs belong in docs/design/"))
    (pattern "*-NEXT-STEPS.md" (action "move" "docs/design/") (reason "Next steps docs belong in docs/design/ or delete"))
    (pattern "*-QUICKSTART.adoc" (action "move" "docs/") (reason "Quickstart guides belong in docs/"))
    (pattern "*-INTEGRATION.md" (action "move" "docs/design/") (reason "Integration docs belong in docs/design/"))

    ;; Superseded format files
    (pattern "AI.djot" (action "delete") (reason "Superseded by 0-AI-MANIFEST.a2ml — AI.djot was the predecessor format"))

    ;; General catch-all for non-standard root docs
    (pattern "NEXT_STEPS.md" (action "delete") (reason "Superseded by ROADMAP"))
    (pattern "TODO.md" (action "delete") (reason "Use issues, ROADMAP, or STATE.scm"))
    (pattern "NOTES.md" (action "delete") (reason "Notes are ephemeral — commit message or docs/"))
    (pattern "TASKS.md" (action "delete") (reason "Use issues or STATE.scm"))
    )

  ;; =========================================================================
  ;; MIGRATION ADVISORIES — flag but don't auto-fix
  ;; =========================================================================
  (migration-advisories
    ;; SCM → A2ML migration
    ;; The RSR template has moved to .a2ml format for all machine-readable
    ;; state files. Repos still using .scm should migrate.
    (advisory "scm-to-a2ml"
      (severity "info")
      (description "Machine-readable state files should migrate from .scm to .a2ml")
      (affected-files
        ".machine_readable/STATE.scm"
        ".machine_readable/META.scm"
        ".machine_readable/ECOSYSTEM.scm")
      (target-format ".a2ml")
      (reason "A2ML is the project standard format with IANA registration pending. SCM requires Guile; A2ML has dedicated parsers and Pandoc adapters in development.")
      (action "flag-for-manual-migration")
      (notes "Content converts from s-expression to A2ML directive syntax. Both formats are structured — automated conversion is feasible but should be reviewed."))

    ;; AI.djot → 0-AI-MANIFEST.a2ml
    (advisory "djot-to-a2ml"
      (severity "warning")
      (description "AI.djot is superseded by 0-AI-MANIFEST.a2ml")
      (affected-files "AI.djot")
      (action "delete-after-content-merged")
      (reason "AI.djot was the transitional format. All content should be in 0-AI-MANIFEST.a2ml now.")))

  ;; =========================================================================
  ;; REQUIRED root files — must exist for RSR compliance
  ;; =========================================================================
  (required-root-files
    (file "0-AI-MANIFEST.a2ml" (severity "error") (reason "Every RSR repo needs an AI manifest"))
    (file "README.adoc" (severity "error") (alternates ("README.md")) (reason "Every repo needs a README"))
    (file "LICENSE" (severity "error") (alternates ("LICENSE.md" "LICENSE.txt")) (reason "Every repo needs a license"))
    (file "SECURITY.md" (severity "error") (reason "Security policy required"))
    (file "CONTRIBUTING.md" (severity "warning") (reason "Community health file"))
    (file "ROADMAP.adoc" (severity "warning") (alternates ("ROADMAP.md")) (reason "Future direction should be documented"))
    (file "TOPOLOGY.md" (severity "warning") (reason "Repository structure documentation"))
    (file ".editorconfig" (severity "warning") (reason "Editor consistency"))
    (file "Justfile" (severity "warning") (alternates ("justfile")) (reason "Build recipes")))

  ;; =========================================================================
  ;; RSR template sync — watch for template changes
  ;; =========================================================================
  (template-sync
    (source "hyperpolymath/rsr-template-repo")
    (watch-branch "main")
    (sync-mode "advisory")    ;; "advisory" = flag differences, "enforce" = auto-PR
    (sync-files
      ".github/workflows/"    ;; Workflow updates
      ".machine_readable/bot_directives/"  ;; Bot directive updates
      ".well-known/"          ;; Well-known files
      ".editorconfig"         ;; Editor config
      ".gitattributes")       ;; Git attributes
    (notes "Hypatia compares enrolled repos against rsr-template-repo on each scan. Differences are flagged as advisory suggestions, not auto-applied. Repos can pin to a template version via (template-pin \"v2.5.0\") to defer updates.")))
