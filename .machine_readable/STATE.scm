;; SPDX-License-Identifier: PMPL-1.0-or-later
;; Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>
;;
;; STATE.scm — Project state checkpoint
;; Replace {{PROJECT_NAME}} and customize sections below.
;; Reference: https://github.com/hyperpolymath/gitvisor/STATE.scm

(define state
  `((metadata
     (project . "{{PROJECT_NAME}}")
     (version . "0.1.0")
     (last-updated . "{{CURRENT_DATE}}")
     (status . active))               ; active | paused | archived

    (project-context
     (name . "{{PROJECT_NAME}}")
     (purpose . "{{PROJECT_PURPOSE}}")
     (completion-percentage . 0))

    (position
     (phase . design)                  ; design | implementation | testing | maintenance | archived
     (maturity . experimental))        ; experimental | alpha | beta | production | lts

    (route-to-mvp
     (milestone "Initial setup" 100)
     (milestone "Core implementation" 0)
     (milestone "Testing" 0)
     (milestone "Documentation" 0))

    (blockers-and-issues)

    (critical-next-actions
     (action "Customize template placeholders")
     (action "Implement core functionality")
     (action "Add tests"))

    (ecosystem
     (part-of . ("RSR Framework"))
     (depends-on . ()))))
