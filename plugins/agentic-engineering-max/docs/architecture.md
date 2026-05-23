# Overview

This document describes the architecture of the orchestrator-and-build-system: how the three-department build works, how state flows between components, and where every file lives. It is the authoritative reference for "how does this work?" — not a tutorial. To run the build, see [RUN_BOOK.md](../../planning/orchestrator-and-build-system/RUN_BOOK.md).

---

## Four architectural layers

The build composes four interlocking layers:

**1. Autonomous state-write layer**

A SessionEnd PowerShell hook (`~/.claude/hooks/state-writer.ps1`) fires at the end of every Claude Code session. It detects work done in the session (commits ahead of merge-base, file modifications, agent spawns), computes a state-update diff, writes `plan-state.md` + `README.md`, appends a forensic line to `.state-auto-log`, and commits. One commit per session. No agent involved; no confirmation required.

A SessionStart sweep (`~/.claude/hooks/state-writer-sweep.ps1`) covers hard-close exits (laptop-lid, process-kill, network drop) where SessionEnd may not fire. On next session open, if the prior session's work is not reflected in the state surfaces, the sweep runs the writer against the prior git range.

**2. Three-department implementation layer**

Three skills, each a single-tick role invoked via `/loop` in its own Claude Code session:

- `/pm <slug>` — Project Management. Regenerates `task-board.md` from per-task frontmatter, sweeps stale locks, audits status anomalies, detects and surfaces escalations. Runs on a fixed 30s cadence; no loop cap; no claim mechanic.
- `/worker <slug>` — Build Management. Atomic-claims an `open` or `needs_fixing` task, does the work, commits, sets `status: in_review`, releases the `.lock`. Self-paced. Loop cap: 5 completed tasks per invocation.
- `/reviewer <slug>` — Critical Review. Atomic-claims an `in_review` task, spawns a 4-stance epistemic panel (Pragmatist + Falsificationist + Hermeneut + Bayesian) in parallel, synthesizes findings, posts the synthesis to the task body, sets `status: done` or `status: needs_fixing` or `status: escalated`. Same 5-completed-task cap as worker.

Atomic claim is per-task via filesystem-level `.lock` sibling files created with `[IO.File]::Open(Create, ReadWrite, None)` (FileShare.None ensures exclusive hold during the claim window). The authoritative source of truth is per-task `task-NNN.md` frontmatter. The shared `task-board.md` is generated, never hand-edited.

**3. Iterate-until-clean Critical Review layer**

Each `/reviewer` tick spawns the 4-stance panel in parallel. The `/reviewer` skill synthesizes the four reports, deduplicates findings, groups by severity (blocking / non-blocking), and posts the synthesis under a `## Review iteration N` heading in the task body. The cycle iterates up to 3 times per task. On the 3rd failed pass the task flips to `status: escalated` and PM emits an escalation line for human intervention.

**4. Recovery layer**

The existing v1 UserPromptSubmit drift-check hook (`~/.claude/hooks/state-drift-check.ps1`) catches the case where SessionEnd misses an exit path. It surfaces state drift to the next session's first prompt via `hookSpecificOutput.additionalContext`. No changes to this hook are in scope; it is the documented fallback channel.

---

## Data flow

The claim -> work -> review -> done cycle runs concurrently across 2-4 worker/reviewer terminals plus one PM terminal:

```
                            +-----------------------+
                            | PM tick (every 30s)   |
                            | - regen task-board.md |
                            | - sweep stale locks   |
                            | - audit anomalies     |
                            | - print summary       |
                            +-----------+-----------+
                                        |
                                        v
   +-----------------------+    +-----------------------+   +-----------------------+
   | /worker tick          |    | task-NNN.md (truth)   |   | /reviewer tick        |
   | - claim open or       |<-->| frontmatter:          |<--| - claim in_review     |
   |   needs_fixing task   |    |   status              |   | - spawn 4 stances     |
   | - atomic .lock create |    |   owner               |   |   (P + F + H + B)     |
   | - do work             |    |   claimed_at          |   | - synthesize findings |
   | - commit              |    |   blocked_by          |   | - post to task body   |
   | - set in_review       |    |   review_iterations   |   | - set done OR         |
   | - release lock        |    +-----------+-----------+   |   needs_fixing OR     |
   +-----------------------+                |               |   escalated (3rd try) |
              ^                             v               | - release lock        |
              |                  +-----------+-----------+  +-----------+-----------+
              |                  | task-NNN.md.lock      |              |
              |                  | (atomic sibling)      |              |
              |                  | body:                 |              |
              |                  |   worker_id           |              |
              |                  |   claude_session_id   |              |
              |                  |   claimed_at          |              |
              |                  +-----------------------+              |
              |                                                         |
              +-------- if needs_fixing -> worker picks up again --------+

   ----------------------------------------------------------------------
   At end of every Claude Code session (any of the three terminals):

                            +-----------------------+
                            | SessionEnd hook fires |
                            | - detect session work |
                            | - compute state diff  |
                            | - write plan-state.md |
                            | - write README.md     |
                            | - append .state-auto- |
                            |   log entry           |
                            | - one commit          |
                            +-----------------------+
                                        |
                                        v
                            +-----------------------+
                            | SessionStart sweep    |
                            | on next session open: |
                            | if prior session work |
                            | not reflected ->      |
                            | run writer against    |
                            | prior git range       |
                            +-----------------------+
```

PM has no loop cap and no claim mechanic. Workers and reviewers atomic-claim via filesystem locks. The board is always derivable from per-task files; no row in `task-board.md` is authoritative.

---

## File and directory layout

### User-global files (`~/.claude/`)

```
~/.claude/
  hooks/
    state-writer.ps1          # SessionEnd hook: writes plan-state.md + README.md
    state-writer-sweep.ps1    # SessionStart sweep: catches missed SessionEnd fires
    state-drift-check.ps1     # (existing) UserPromptSubmit drift detector
  skills/
    plan-interviewer/SKILL.md # /plan-interviewer: scientific-method clarifying interview
    pm/SKILL.md               # /pm skill body
    worker/SKILL.md           # /worker skill body
    reviewer/SKILL.md         # /reviewer skill body
    aem-init/SKILL.md         # /aem-init: wire core.hooksPath + scaffold (pwsh-7 probe gate)
    board/SKILL.md            # /board <slug>
    unblock/SKILL.md          # /unblock <slug> T-NNN [--reset|--done]
  agents/                     # Build-system subagents (live mirror)
    epistemic-*.md            # 8 review/interview stances: bayesian, coherentist, empiricist,
                              #   falsificationist, hermeneut, phenomenologist, pragmatist, skeptic
    prd-writer.md             # Writes the PRD (spawned by the interviewer)
    spec-writer.md            # Writes the parallelization-maximized spec from the PRD
    wave-closer.md            # Closes an implementation wave; updates state surfaces
  settings.json               # Registers SessionEnd + SessionStart hooks
```

### In-repo files (development/source repo layout, `<dev-repo-root>/`)

These paths describe the development repository where the plugin is built and
dogfooded (historical layout); in an installed plugin the scripts live under
`${CLAUDE_PLUGIN_ROOT}/scripts/`.

```
<dev-repo-root>/
  bin/                        # Installed-plugin equivalent: ${CLAUDE_PLUGIN_ROOT}/scripts/
    build-board.ps1           # Regenerates task-board.md from per-task frontmatter
    board-print.ps1           # Stdout-print variant (used by /board command)
    audit-claim-events.ps1    # Scans worker commits for Worker-ID trailers; flags double-assigns
    audit-state-log.ps1       # Forensic analyzer for .state-auto-log (missed writer lines)
    sweep-stale-locks.ps1     # Status-aware orphan-lock recovery (run per worker/reviewer tick)
    spec-lint.ps1             # Planning-doc assertion-drift lint (char/task counts); pre-commit-wired
    crosscompat-lint.ps1      # Cross-platform Windows-ism lint (paths, pwsh, LF, ASCII); pre-commit-wired
    headless-worker-loop.ps1  # Drives `claude -p /worker <slug>` in a loop (walk-away builds)
    headless-reviewer-loop.ps1 # Drives `claude -p /reviewer <slug>` in a loop
    headless-pm-loop.ps1      # Drives `claude -p /pm <slug>` (singleton observer; optional)
    unblock.ps1               # Inspect / reset / force-done an escalated task (backs /unblock)
    gen-demo-assets.py        # Builds the plugin's demo GIF/screenshots (dev-only; not shipped)
  docs/
    build-system/
      overview.md             # This file
      skills.md               # Per-skill reference for /pm, /worker, /reviewer
      hooks.md                # Reference for state-writer.ps1 + sweep + recovery channel
  planning/
    orchestrator-and-build-system/
      spec.md                 # Implementation spec (authoritative task definitions)
      prd.md                  # Product requirements document
      plan-state.md           # Mutable state surface (overwritten each phase transition)
      plan-ledger.md          # Append-only ledger (strikethrough-versioned history)
      RUN_BOOK.md             # End-user run book (how to launch + operate the build)
      task-board.md           # Generated board (never hand-edited)
      .state-auto-log         # Forensic log (one line per autonomous state write)
      .build-config.json      # Build configuration (stale-lock threshold, etc.)
      tasks/
        task-W1-NNN.md        # Wave 1 per-task files
        task-W2-NNN.md        # Wave 2 per-task files
        task-NNN.md.lock      # Atomic-claim sibling (present = claimed)
      handoffs/
        worker-<id>-<ISO>.md  # Handoff docs written when loop cap fires
      .locks/
        <worker_id>.stop      # Loop-stop sentinel (presence = cap reached)
```

### Key schema reference

`task-NNN.md` frontmatter (authoritative per-task state):

```
status: open | in_progress | in_review | needs_fixing | escalated | done
owner: <worker_id>
claimed_at: <ISO 8601 UTC>
blocked_by: [T-MMM, ...]
review_iterations: <integer; 0 = not yet reviewed; escalated at 3>
depends_on: [T-MMM, ...]
unresolved_findings: []
```

`task-NNN.md.lock` body (atomic sibling; presence = claimed):

```
worker_id: <worker_id>
claude_session_id: <session_id>
claimed_at: <ISO 8601 UTC>
```

---

## Cross-references

| Document | Path | Purpose |
|---|---|---|
| RUN_BOOK.md | `planning/orchestrator-and-build-system/RUN_BOOK.md` | How to launch and operate the build (3-terminal setup, env vars, troubleshooting) |
| skills.md | `docs/build-system/skills.md` | Per-skill reference: /pm, /worker, /reviewer tick procedures |
| hooks.md | `docs/build-system/hooks.md` | Reference for state-writer.ps1, sweep counterpart, and recovery channel |
| plan-ledger.md | `planning/orchestrator-and-build-system/plan-ledger.md` | Append-only design-decision ledger; version history of all confirmed decisions |
| spec.md | `planning/orchestrator-and-build-system/spec.md` | Full task inventory with acceptance criteria and dependency graph |
| prd.md | `planning/orchestrator-and-build-system/prd.md` | Product requirements; original architectural intent |
