# Skills reference

This document is the per-skill reference for the three build-system skills: `/pm`, `/worker`, and `/reviewer`. Each skill runs as a single-tick loop role invoked via `/loop` in its own Claude Code session. For the end-user launch procedure, see [RUN_BOOK.md](../../planning/orchestrator-and-build-system/RUN_BOOK.md). For architecture, see [overview.md](overview.md).

The canonical invocation bodies live in the installed SKILL.md files at `~/.claude/skills/<name>/SKILL.md`. This document cross-links and summarizes; it does not duplicate the full procedure.

---

## /pm

**Purpose:** Project Management. Regenerates the board, sweeps stale locks, audits anomalies, surfaces escalations.

### Invocation

```
/loop 30s /pm orchestrator-and-build-system
```

Fixed-interval mode (30s default). The PM terminal runs this continuously.

### Env-vars consumed

| Var | Required | Notes |
|---|---|---|
| None | — | PM reads no user-set env-vars. Session ID is not recorded by PM (no lock ownership). |

### Files read

- `planning/<slug>/tasks/task-*.md` — per-task frontmatter (status, owner, claimed_at, review_iterations, depends_on)
- `planning/<slug>/tasks/task-*.md.lock` — lock bodies (worker_id, claimed_at) for stale-lock detection
- `planning/<slug>/.build-config.json` — `stale_lock_minutes` threshold (default 30)
- `planning/<slug>/.status-request` — sentinel written by operator's `status` prompt; triggers full-board print

### Files written

- `planning/<slug>/task-board.md` — regenerated each tick from per-task frontmatter; never hand-edited
- Deletes stale `.lock` files when `now - claimed_at >= stale_lock_minutes`
- Deletes `.status-request` after printing full board

### Exit conditions

- Normal: PM ticks are stateless and never exit on their own (no loop cap). `/loop` re-fires every 30s.
- Clean stop: when zero `open`, `in_progress`, `in_review`, or `needs_fixing` tasks remain, PM emits `*** ALL TASKS DONE; build complete` and exits the tick cleanly.

### Loop-cap behavior

PM has **no loop cap**. It ticks indefinitely until the build is done or the operator stops it.

### Error paths and escalation output

PM emits formatted lines to stdout. Normal lines have no special prefix. Break-rhythm lines:

```
[HH:MM:SS] !! STALE LOCK: <worker_id> on T-NNN held N min; releasing
[HH:MM:SS] !! BLOCKED: T-NNN depends on T-MMM which is not yet done
[HH:MM:SS] !! ESCALATED: T-NNN hit 3-iter review cap; needs human eye. Reviewer's last feedback: <one-line>
[HH:MM:SS] *** ALL TASKS DONE; build complete
```

The absence of `!!` or `***` means all good.

---

## /worker

**Purpose:** Build Management. Atomic-claims an open or needs_fixing task, does the work, commits, sets in_review.

### Invocation

```
$env:WORKER_ID = 'worker-A'
/loop /worker orchestrator-and-build-system
```

Self-paced (no interval). Each tick runs the task to completion, then `/loop` re-fires immediately.

### Env-vars consumed

| Var | Required | Notes |
|---|---|---|
| `WORKER_ID` | YES | Human-readable label (e.g. `worker-A`). Set per terminal. Two terminals with the same ID trip the collision warning. |
| `CLAUDE_SESSION_ID` | No | Preferred session ID source. Falls back to `CLAUDECODE_SESSION_ID`, then `pid-<PID>`. Written to `.lock` body and git commit trailer. |
| `WORKER_LOOP_COUNT` | No | Managed by the skill itself. Increments each completed task; used to track running count. Durable stop gate is the `.stop` sentinel file, not this counter. |

### Files read

- `planning/<slug>/tasks/task-*.md` — scanned each tick for claimable tasks (priority: needs_fixing owned-by-me first, then open with deps done)
- `planning/<slug>/tasks/task-*.md.lock` — collision pre-check before atomic create
- `planning/<slug>/.build-config.json` — `stale_lock_minutes`

### Files written

- `planning/<slug>/tasks/task-<id>.md.lock` — atomic-claim sibling (CreateNew + body written before Dispose); released after commit
- `planning/<slug>/tasks/task-<id>.md` — frontmatter updated: `in_progress` on claim, `in_review` after work
- Deliverable files specified in the task body
- `planning/<slug>/handoffs/worker-<worker_id>-<ISO>.md` — written on loop-cap (5 completed tasks)
- `planning/<slug>/.locks/<worker_id>.stop` — loop-stop sentinel written after HANDOFF.md commit

### Exit conditions

- Normal: exits after each completed tick; `/loop` re-fires immediately.
- No-claim: if no claimable task is found, emits `[<worker_id>] no claimable tasks; exiting tick` and exits. Skip does NOT count toward the cap; `/loop` re-fires.
- Loop cap: after 5 completed tasks, writes HANDOFF.md, commits it, writes `.locks/<worker_id>.stop`, exits.
- Sentinel present: if `.locks/<worker_id>.stop` already exists at tick start, exits silently (previous run hit cap).

### Loop-cap behavior

Cap is 5 completed tasks per `/loop` invocation. Skipped claim attempts (lock contention, no claimable task) do NOT count. When cap fires:

1. Write `planning/<slug>/handoffs/worker-<worker_id>-<ISO>.md` (4-section format: what I worked on, board snapshot, what I learned, recommendation for next worker).
2. Release any held locks.
3. Commit HANDOFF.md.
4. Write `.locks/<worker_id>.stop` sentinel.
5. Exit.

To resume after cap: delete `planning/<slug>/.locks/<worker_id>.stop` and relaunch `/loop`.

### Error paths

- `WORKER_ID` unset: emits error to stderr and exits 1.
- Claim contention: `[IO.File]::Open(CreateNew)` returns non-zero; skip to next candidate. Skip does not count toward cap.
- Same-WORKER_ID collision: another terminal already holds a fresh lock with this worker_id; emits `WARNING: lock collision on T-NNN; re-tag your WORKER_ID env var`.
- Commit fails: lock stays held; PM stale-sweep reclaims after `stale_lock_minutes`.

---

## /reviewer

**Purpose:** Critical Review. Atomic-claims an in_review task, spawns a 4-stance epistemic panel in parallel, synthesizes findings, posts results to task body, transitions status.

### Invocation

```
$env:REVIEWER_ID = 'reviewer-A'
/loop /reviewer orchestrator-and-build-system
```

Self-paced. Each tick runs to completion, then `/loop` re-fires.

### Env-vars consumed

| Var | Required | Notes |
|---|---|---|
| `REVIEWER_ID` | YES | Human-readable label (e.g. `reviewer-A`). Set per terminal. |
| `CLAUDE_SESSION_ID` | No | Same fallback chain as `/worker`. Written to `.lock` body and git commit trailer. |
| `REVIEWER_LOOP_COUNT` | No | Managed by the skill. Same 5-completed-task cap as worker. |

### Files read

- `planning/<slug>/tasks/task-*.md` — scanned for `in_review` tasks to claim
- `planning/<slug>/tasks/task-*.md.lock` — collision pre-check
- Deliverable files referenced in the task body

### Files written

- `planning/<slug>/tasks/task-<id>.md.lock` — atomic-claim sibling; released after review commit
- `planning/<slug>/tasks/task-<id>.md` — frontmatter updated: `in_progress` on claim; `done`, `needs_fixing`, or `escalated` after synthesis. Body extended with `## Review iteration N` section.
- `planning/<slug>/handoffs/reviewer-<reviewer_id>-<ISO>.md` — written on loop-cap
- `planning/<slug>/.locks/<reviewer_id>.stop` — loop-stop sentinel

### Review panel

Four stances spawned in parallel per task:

| Stance | Focus |
|---|---|
| Pragmatist | Does it work in practice? Will the actual operator succeed? |
| Falsificationist | What would break this? What testable predictions does the deliverable make? |
| Hermeneut | What does the document mean in context? Ambiguities, implicit assumptions, omissions? |
| Bayesian | What are the load-bearing probability assumptions? Where is hidden tail risk? |

The `/reviewer` skill (not a separate synthesizer) deduplicates findings across stances, groups by severity (blocking / non-blocking), and writes the synthesis to the task body.

### Verdict logic

- **CLEAN** (all stances pass): set `status: done`. Build queue advances.
- **NEEDS FIXING** (blocking findings; iter < 3): set `status: needs_fixing`. The task's original `owner` (worker) re-claims it.
- **ESCALATED** (blocking findings; iter == 3): set `status: escalated`. PM emits escalation line. Only a human can unblock (via `/unblock` or manual frontmatter edit).

### Exit conditions

Same as `/worker`: normal per-tick exit, no-claim skip, loop-cap at 5 completed reviews.

### Loop-cap behavior

Identical cap and sentinel mechanism as `/worker` — 5 completed reviews, HANDOFF.md, `.locks/<reviewer_id>.stop`.

---

## Cross-skill invariants

These invariants hold across all three skills and are enforced by the atomic-lock mechanism:

1. **Only one skill modifies a task's frontmatter at a time.** The `.lock` sibling file, created with `[IO.File]::Open(CreateNew, ReadWrite, None)`, serializes all claim attempts. If two workers or a worker and reviewer race on the same task, exactly one wins; the other gets a filesystem error on `CreateNew` and skips. Observable failure signal: if two concurrent `claimed_at` timestamps appear in a task's frontmatter history (git log), the lock mechanism failed — investigate before resuming.

2. **`task-board.md` is generated only by `/pm` or the `/board` command.** No worker or reviewer writes to `task-board.md` directly. The board is always re-derivable from per-task frontmatter; no row in `task-board.md` is authoritative.

3. **`HANDOFF.md` is generated only by `/worker` or `/reviewer` at loop-cap.** The handoff file path is `planning/<slug>/handoffs/<role>-<worker_id>-<ISO>.md`. The file is committed before the loop-stop sentinel is written, guaranteeing the git log is the audit trail.

4. **`review_iterations` is incremented only by `/reviewer`.** Workers never touch this field. It increments once per review cycle (one tick = one increment), capped at 3 before escalation.

5. **The loop-stop sentinel path is per-worker-id.** `planning/<slug>/.locks/<worker_id>.stop` for workers; `planning/<slug>/.locks/<reviewer_id>.stop` for reviewers. One worker hitting the cap does not stop another.
