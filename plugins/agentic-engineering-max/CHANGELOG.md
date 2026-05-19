# Changelog

All notable changes to `agentic-engineering-max` are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - <release date YYYY-MM-DD>

### Added

- Initial public release of `agentic-engineering-max`.
- 4 skills: `/pm`, `/worker`, `/reviewer`, `/plan-interviewer`.
- 3 commands: `/aem-init` (bootstrap), `/board`, `/unblock`.
- 11 agents: 8-stance epistemic panel (`epistemic-bayesian`, `epistemic-coherentist`,
  `epistemic-empiricist`, `epistemic-falsificationist`, `epistemic-hermeneut`,
  `epistemic-phenomenologist`, `epistemic-pragmatist`, `epistemic-skeptic`) plus 3
  phase-owning agents (`prd-writer`, `spec-writer`, `wave-closer`).
- 6 hooks: SessionStart context injection + SessionStart state-writer sweep;
  SessionEnd state-writer; UserPromptSubmit state-drift-check; git pre-commit
  ledger-only-commit blocker. Registered via `hooks.json` (Claude Code hooks)
  and `git config core.hooksPath` (set by `/aem-init`).
- 5 tooling scripts: `audit-claim-events.ps1`, `audit-state-log.ps1`,
  `board-print.ps1`, `build-board.ps1`, `unblock.ps1`.
- 5 automated tests for invariants 1-5 + RELEASE_CHECKLIST.md manual smoke
  for invariants 6-7. Test runner: `run-all-tests.ps1`.
- Documentation: README.md (layered: quick install + concepts + troubleshooting),
  CONTRIBUTING.md, RELEASE_CHECKLIST.md, docs/architecture.md, docs/skills.md,
  docs/hooks.md, docs/CLAUDE-template.md (injected at SessionStart).
- Assets: demo.gif + screenshots (board, escalation, review-output).

### Known limitations

- Plugin targets Windows 10/11 + PowerShell 5.1 (or later) + Git for Windows.
  Cross-platform v2 is a roadmap item; see STAGED-ROADMAP.md and the pinned
  v2-roadmap tracking issue for the adoption threshold.

### License

- MIT. See LICENSE.
