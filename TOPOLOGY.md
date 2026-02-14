<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- TOPOLOGY.md — Project architecture map and completion dashboard -->
<!-- Last updated: {{DATE}} -->

# {{PROJECT_NAME}} — Project Topology

## System Architecture

<!--
  Draw an ASCII diagram of the system as it will look when complete.
  Show all major components, their relationships, and data flow.

  Guidelines:
  - Use box-drawing characters: ┌ ┐ └ ┘ │ ─ ├ ┤ ┬ ┴ ┼
  - Use arrows for data flow: ▲ ▼ ◄ ► or → ← ↑ ↓
  - Use double lines for boundaries: ═ ║
  - Group related components in boxes
  - Show external services at the top, internal at the bottom
  - Label every box and connection
  - Keep lines aligned (monospace)
-->

```
                        ┌─────────────────────────────────────────┐
                        │              USERS / CLIENTS            │
                        └───────────────────┬─────────────────────┘
                                            │
                                            ▼
                        ┌─────────────────────────────────────────┐
                        │           EXTERNAL SERVICES             │
                        │  (CDN, DNS, gateway, load balancer)     │
                        └───────────────────┬─────────────────────┘
                                            │
                                            ▼
                        ┌─────────────────────────────────────────┐
                        │           APPLICATION LAYER             │
                        │                                         │
                        │  ┌───────────┐  ┌───────────────────┐  │
                        │  │ Component │  │    Component       │  │
                        │  │     A     │  │       B            │  │
                        │  └─────┬─────┘  └────────┬──────────┘  │
                        │        │                 │              │
                        │        └────────┬────────┘              │
                        │                 ▼                       │
                        │        ┌────────────────┐               │
                        │        │  Component C   │               │
                        │        └────────────────┘               │
                        └─────────────────────────────────────────┘

                        ┌─────────────────────────────────────────┐
                        │             DATA LAYER                  │
                        │  (databases, caches, storage)           │
                        └─────────────────────────────────────────┘

                        ┌─────────────────────────────────────────┐
                        │          REPO INFRASTRUCTURE            │
                        │  contractiles/  .machine_readable/      │
                        │  .github/workflows/  Justfile           │
                        └─────────────────────────────────────────┘
```

## Completion Dashboard

<!--
  List every component from the architecture diagram.
  Group by layer/concern.
  Use 10-char progress bars: █ (filled) and ░ (empty).
  Percentages in 10% increments.
  Add a short note explaining the status.
-->

```
COMPONENT                          STATUS              NOTES
─────────────────────────────────  ──────────────────  ─────────────────────────────────
LAYER 1
  Component A                       ██████████ 100%    Complete and tested
  Component B                       ██████░░░░  60%    Core done, integration pending
  Component C                       ░░░░░░░░░░   0%    Not started

LAYER 2
  Component D                       ████░░░░░░  40%    Blocked by Component C
  Component E                       █░░░░░░░░░  10%    Stub exists

REPO INFRASTRUCTURE
  .machine_readable/                ██████████ 100%    6 a2ml files present
  contractiles/                     ██████████ 100%    All contractile types present
  .github/workflows/                ██████████ 100%    Standard workflows
  Justfile                          ██████████ 100%    Build automation

─────────────────────────────────────────────────────────────────────────────
OVERALL:                            ████░░░░░░  ~40%   Summary sentence here
```

## Key Dependencies

<!--
  Show the critical path — what blocks what.
  Use ASCII arrows to show dependency chains.
-->

```
Component A ──────► Component B ──────► Component C
                                              │
                                    ┌─────────┼─────────┐
                                    ▼         ▼         ▼
                                Comp D     Comp E    Comp F
                                    │         │         │
                                    └─────────┼─────────┘
                                              ▼
                                         COMPLETE
```

## Update Protocol

This file is maintained by both humans and AI agents. When updating:

1. **After completing a component**: Change its bar and percentage
2. **After adding a component**: Add a new row in the appropriate section
3. **After architectural changes**: Update the ASCII diagram
4. **Date**: Update the `Last updated` comment at the top of this file

Progress bars use: `█` (filled) and `░` (empty), 10 characters wide.
Percentages: 0%, 10%, 20%, ... 100% (in 10% increments).
