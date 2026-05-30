# Changelog

All notable changes to `agentic-engineering-max` are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.3.1] - 2026-05-30

### Fixed

- **Gates queue never drained** (`scripts/gate-schema.ps1`): `Get-GateQueue` filtered on `gate_decider == 'user'` alone, so a gate stayed in the control-plane web HUD's Gates tab forever even after approve/decline -- defeating the tab's purpose. Now also requires `gate_state == 'pending'`; decided gates (`approved`/`declined`) leave the queue and the tab drains as the user acts. (Shipped buggy since 2.2.0.)
- **Board mislabeled gate statuses** (`scripts/build-board.ps1`): the board generator predated the control-plane gate statuses and bucketed `proposed` / `awaiting_user_approval` / `closed` into `open` with an "unknown status" warning -- so a declined/closed finding masqueraded as an open task and proposed findings polluted the open/blocked view. Now mirrors `master-board.ps1` semantics: `closed` is terminal (like `done`); `proposed` + `awaiting_user_approval` are gate-pending (render in their own sections, keep the board active). The genuine-typo guard is preserved. (Shipped buggy since 2.2.0.)

Both were surfaced by dogfooding the control plane in the source workspace and are locked there by regression tests (`test-control-plane-schema.ps1` decided-gate-excluded case; new `test-build-board.ps1`, 12 cases).

## [2.3.0] - 2026-05-29

### Added

- **`/launch-build` skill** (`skills/launch-build/` + `scripts/launch-build.ps1`): launch the 3-department headless build as detached background loops without telling the user to open three terminals. The default plan is one controller + one PM narrator + one auto-pusher. Walks away. Mobile-friendly via GitHub commit notifications.
- **`headless-pusher-loop.ps1`** (`scripts/`): single push-only loop (`git push origin HEAD` every ~45s) that surfaces the build's local commits to GitHub live. Never commits, no index contention, self-exits when all tasks are done. Wired as a default-on plan member of `/launch-build` (`-NoPush` to suppress).

### Changed

- **State-writer is now render-deterministic** (`hooks/state-writer.ps1`): the embedded render timestamp is removed; regenerating an already-current `plan-state.md` is now a no-op, which lets the pre-commit hook regenerate-and-stage without churn. Matches the workspace version that has been deterministic since 2026-05-23.
- **`CONTRIBUTING.md`**: `Cross-platform v2 invitation` section rewritten as `Cross-platform notes` reflecting the now-shipped Windows + Linux pwsh 7 target. Test-suite invocation example updated to `pwsh -NoProfile -File tests/run-all-tests.ps1` (no `-ExecutionPolicy Bypass`, no Windows-only backslashes).
- **`RELEASE_CHECKLIST.md`**: markdown code-fence language tags switched from ` ```powershell ` to ` ```pwsh ` (25 fences) to accurately reflect the pwsh 7 runtime.
- **`STAGED-ROADMAP.md`** retired to a pointer stub. The cross-platform port shipped in v2.0.0; the document's premise was obsolete. Existing bookmarks still resolve to a short note pointing at CHANGELOG + the pinned v2-roadmap issue.

## [2.2.0] - 2026-05-28

### Added

- **Control plane**: `/task-create` skill + script for capturing tasks into a project's `inbox/` slug; `gate-schema` + `gate-apply` for approval/promotion gating; `wake-sentinel` primitive; `triage-intake` (deterministic, zero-LLM); `master-board` cross-slug rollup.
- **Web HUD** (`control-plane-web.ps1` + `webui/`): local HttpListener server with Loops / Board / Gates / Logs pages and a JSON API. Loopback-bound. Windows-first; Linux users get the controller + skills without the HUD.
- **Reviewer-emits-intake** (T-204): the reviewer can file an intake task into `inbox/` when it spots out-of-scope work. Graceful no-op when no `inbox/` slug exists.
- **`install-autostart`** script: opt-in HUD autostart.

### Changed

- **Orchestrator dormant-on-drain**: the controller now idles when the dependency graph is empty (and wakes on the wake-sentinel) instead of busy-looping. Existing headless invocations keep working; CPU drops between waves.
- **State-drift hook gains Check E**: a backtick-quoted branch named in `Next action:` / `Open-PR stack:` that resolves and is already merged into main now triggers a nudge. Past-tense mentions ("landed/merged") stay silent.

## [2.1.0] - 2026-05-25

### Added

- **`/aem-doctor` health-check skill** plus a shared health-check routine that
  `/aem-init` calls at the end of bootstrap. It verifies the environment
  (`pwsh` 7+, git repo, `core.hooksPath`, execution policy) and prints a
  plain-English line per check.
- **Restricted-policy detection.** When the machine's PowerShell execution
  policy would block the hooks, `/aem-doctor` surfaces ONE plain-English
  sentence plus a fix command (or "ask IT") instead of failing silently -- no
  string-exec / IEX evasion.
- **EBUSY first-run install note** on the marketplace surface and README, so a
  fresh `/aem-init` that races a file lock has a documented retry path.
- **`.md`-scan lint rule** in `crosscompat-lint.ps1`: the no-`powershell`-exe
  and no-`-ExecutionPolicy Bypass` checks now also scan plugin `.md` content,
  with matching regression cases in both test copies.

### Changed

- **`/aem-init` is now git-native** -- it bootstraps via git plumbing rather
  than the prior path, and ends by invoking the shared health check.
- **The classifier-facing skills (`/aem-init`, `/board`, `/unblock`,
  `/aem-doctor`), the `hooks.json` hook runners, and the bash pre-commit shims
  drop `-ExecutionPolicy Bypass`.** They invoke `pwsh -NoProfile -File ...` with
  no policy override, removing the malware-lookalike AMSI/EDR signature from the
  surfaces a user or scanner meets first. Hooks run with plain `-File`.
- **`/aem-init` exit-code surface simplified (D-S1):** exit codes are 0/1/2/3/4;
  exit 5 is no longer documented as a gate.

## [2.0.1] - 2026-05-23

### Fixed

- **`/aem-init`, `/board`, and `/unblock` now work when invoked.** They shipped
  as slash *commands*, but `${CLAUDE_PLUGIN_ROOT}` is only substituted in *skill*
  (and agent/hook/monitor/MCP) content -- never in command content -- so the
  variable arrived empty, the backing-script path collapsed, and `/aem-init`
  failed with a misleading "not a git repository". All three are now **skills**
  (where the variable resolves inline), so they locate their scripts correctly.
- **`pm`, `worker`, and `reviewer` no longer invoke the Windows-only
  `powershell` exe** in their instructions -- they use `pwsh`, so the board and
  the atomic-claim lock work on Linux as well as Windows.
- `/aem-init` now emits a distinct "backing script not found" error (exit 4)
  when the plugin root cannot be resolved, instead of mislabeling it exit-1
  "not a git repository".
- Regression test `tests/test-command-pluginroot.ps1` locks both contracts (no
  `CLAUDE_PLUGIN_ROOT` reference under `commands/`; no `powershell` invocation in
  any plugin `.md`) and runs in the 2-OS CI suite.

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
