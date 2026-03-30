# TEST-NEEDS: rsr-template-repo

## Current State

| Category | Count | Details |
|----------|-------|---------|
| **Source modules** | 6 | Template: 3 Idris2 ABI (Foreign, Layout, Types), 2 Zig FFI (build, main), 1 Zig integration test |
| **Unit tests** | 0 | None (expected -- this is a template) |
| **Integration tests** | 1 | integration_test.zig (template placeholder) |
| **E2E tests** | 0 | None |
| **Benchmarks** | 0 | None |
| **Fuzz tests** | 0 | README.adoc scaffold with harness instructions |

## What's Missing

### Template Validation Tests (CRITICAL for a template)
- [ ] No test that `just init` works on a fresh clone
- [ ] No test that placeholder replacement works
- [ ] No test that all 17 required workflows are present and valid
- [ ] No test that Idris2 ABI types compile
- [ ] No test that Zig FFI builds

### Self-Tests
- [ ] Template itself should have a validation script that verifies completeness

## FLAGGED ISSUES
- **Template repo used by ALL new repos has 0 validation tests** -- broken templates propagate everywhere
- **fuzz/placeholder.txt** -- FIXED: replaced with README.adoc containing real harness instructions

## Priority: P1 (HIGH) -- template quality controls everything downstream
