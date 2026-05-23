# Changelog

All notable changes to `agentic-engineering-max` are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-05-23

Cross-platform release. The plugin now runs on **Windows AND Linux** under a
single codebase. This is a behavior-preserving port of 1.0.0 -- no feature
changes; the skills, commands, agents, and hooks are the same.

### Changed

- **Runtime is now PowerShell 7+ (`pwsh`), on both Windows and Linux.** All
  hooks, scripts, the bash shims, and `hooks.json` invoke `pwsh` (no longer
  `powershell`). PowerShell 5.1 is no longer a target.
- Path construction is OS-neutral throughout (`Join-Path` / forward slashes,
  no literal-backslash separators, no hard-coded drive letters); bash shims are
  LF-only and carry the executable bit so Linux git runs them.
- `/aem-init` probes for `pwsh` 7+ on PATH and fails clearly (leaving
  `core.hooksPath` untouched) if it is absent.

### Added

- A 2-OS CI matrix (GitHub Actions: `ubuntu-latest` + `windows-latest`) runs
  both test suites under `pwsh` 7 on every push, plus a Linux clean-install
  probe -- so cross-platform behavior is enforced, not assumed.
- `crosscompat-lint.ps1`: flags Windows-only path/runtime constructions; wired
  into the pre-commit hook.

### Requirements

- **PowerShell 7+ (`pwsh`) on PATH.** No container artifact is shipped; install
  pwsh per your OS (e.g. Linux: `wget -qO- https://aka.ms/install-powershell.sh | sudo bash`).

### Note

- **1.0.0 remains the frozen PowerShell 5.1 release** (its tag and GitHub
  release are retained, unchanged). Upgrade to 2.0.0 only requires `pwsh` 7+.

## [1.0.0] - 2026-05-20

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
