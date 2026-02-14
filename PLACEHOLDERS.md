# Template Placeholders

All placeholders in this template follow the `{{PLACEHOLDER}}` pattern.
After cloning, replace them with your project-specific values.

## Quick Replace

```bash
# Required replacements (run from repo root)
sed -i 's/{{PROJECT_NAME}}/my-project/g' $(grep -rl '{{PROJECT_NAME}}' .)
sed -i 's/{{PROJECT}}/MY_PROJECT/g' $(grep -rl '{{PROJECT}}' .)
sed -i 's/{{project}}/my_project/g' $(grep -rl '{{project}}' .)
sed -i 's/{{OWNER}}/hyperpolymath/g' $(grep -rl '{{OWNER}}' .)
sed -i 's/{{REPO}}/my-project/g' $(grep -rl '{{REPO}}' .)
sed -i 's/{{FORGE}}/github.com/g' $(grep -rl '{{FORGE}}' .)
sed -i "s/{{CURRENT_YEAR}}/$(date +%Y)/g" $(grep -rl '{{CURRENT_YEAR}}' .)
sed -i "s/{{CURRENT_DATE}}/$(date +%Y-%m-%d)/g" $(grep -rl '{{CURRENT_DATE}}' .)
```

## Placeholder Reference

### Project Identity

| Placeholder | Description | Example | Files |
|---|---|---|---|
| `{{PROJECT_NAME}}` | Human-readable project name | `My Project` | SECURITY.md, CODE_OF_CONDUCT.md, TOPOLOGY.md, STATE.scm, justfile |
| `{{PROJECT}}` | Uppercase identifier (for Idris2 modules, C macros) | `MY_PROJECT` | ABI-FFI-README.md, src/abi/*.idr, ffi/zig/*.zig |
| `{{project}}` | Lowercase identifier (for C symbols, filenames) | `my_project` | ABI-FFI-README.md, ffi/zig/*.zig |
| `{{REPO}}` | Repository name (slug) | `my-project` | CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md |
| `{{OWNER}}` | GitHub/GitLab org or username | `hyperpolymath` | CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md |
| `{{FORGE}}` | Git forge domain | `github.com` | CONTRIBUTING.md |

### Dates

| Placeholder | Description | Example | Files |
|---|---|---|---|
| `{{CURRENT_YEAR}}` | Current year | `2026` | SECURITY.md, CODE_OF_CONDUCT.md |
| `{{CURRENT_DATE}}` | Current date (ISO) | `2026-02-14` | STATE.scm |
| `{{DATE}}` | Last updated date | `2026-02-14` | TOPOLOGY.md |

### Contact & Security

| Placeholder | Description | Example | Files |
|---|---|---|---|
| `{{SECURITY_EMAIL}}` | Security contact email | `security@example.org` | SECURITY.md |
| `{{PGP_FINGERPRINT}}` | 40-char PGP fingerprint | `ABCD 1234 ...` | SECURITY.md |
| `{{PGP_KEY_URL}}` | URL to public PGP key | `https://keys.openpgp.org/...` | SECURITY.md |
| `{{WEBSITE}}` | Project website | `https://example.org` | SECURITY.md |
| `{{CONDUCT_EMAIL}}` | Conduct reports email | `conduct@example.org` | CODE_OF_CONDUCT.md |
| `{{CONDUCT_TEAM}}` | Conduct committee name | `Code of Conduct Committee` | CODE_OF_CONDUCT.md |
| `{{RESPONSE_TIME}}` | SLA for initial response | `48 hours` | CODE_OF_CONDUCT.md |

### Git

| Placeholder | Description | Example | Files |
|---|---|---|---|
| `{{MAIN_BRANCH}}` | Main branch name | `main` | CONTRIBUTING.md |

### Build

| Placeholder | Description | Example | Files |
|---|---|---|---|
| `{{LICENSE}}` | License name | `PMPL-1.0-or-later` | ABI-FFI-README.md |
| `{{PROJECT_PURPOSE}}` | One-line project description | `FFI bridges between languages` | STATE.scm |

### AI Manifest

| Placeholder | Description | Example | Files |
|---|---|---|---|
| `[YOUR-REPO-NAME]` | Repository name | `my-project` | 0-AI-MANIFEST.a2ml |
| `[DATE]` | Creation date | `2026-02-14` | 0-AI-MANIFEST.a2ml |
| `[YOUR-NAME/ORG]` | Maintainer name | `hyperpolymath` | 0-AI-MANIFEST.a2ml |

## Deletion Markers

Some files contain deletion instructions:

| Marker | Meaning | File |
|---|---|---|
| `{{~ ... ~}}` | Delete this entire line after reading | ABI-FFI-README.md (line 1) |

## Verification

After replacing all placeholders, verify none remain:

```bash
grep -rn '{{' . --include='*.md' --include='*.adoc' --include='*.scm' \
  --include='*.idr' --include='*.zig' --include='*.res' --include='justfile' \
  --include='*.a2ml' | grep -v 'PLACEHOLDERS.md' | grep -v 'node_modules'
```

If the above command produces no output, all placeholders have been replaced.
