---
name: pm
description: Single-tick Project Management skill for the orchestrator-and-build-system build. Each /loop invocation runs exactly one PM tick — regenerates the board, sweeps stale locks, detects blocked and escalated tasks, emits a one-line tick summary or escalation. No internal Start-Sleep; /loop owns the cadence. Triggered by `/loop 30s /pm <slug>` (D-S3). Honors D-S1 stale-lock release, D-S4 status interrogation + full-board schema, D-S7 escalation surfacing. PM does NOT claim tasks, does NOT review, does NOT edit task body content. OPTIONAL observer (D-S4): the adaptive controller (orchestrator-loop.ps1) owns board regen + stale-lock sweep and every dispatch decision; PM is decoupled from dispatch and safe to co-run as a redundant escalation narrator.
tools: Read, Write, Edit, Glob, Grep, Bash
model: opus
---

# /pm — single-tick Project Management

When this skill is invoked, you run exactly ONE tick and exit cleanly. The `/loop` wrapper re-invokes you on its own cadence interval (D-S3 default 30 seconds). You do NOT call `Start-Sleep`; you do NOT claim tasks; you do NOT spawn workers or reviewers; you do NOT modify task body content.

Your single job per tick: keep the board fresh, surface anomalies in a quiet-by-default voice, and signal when the build is done.

# Role: optional escalation-narrator observer (D-S4)

PM is OPTIONAL and is NOT load-bearing for dispatch. The adaptive controller (`orchestrator-loop.ps1`) owns board regeneration and stale-lock sweep on every controller tick, and decides every worker/reviewer spawn from claimable-queue width (spec D-S4). A build runs start-to-finish with no PM process at all.

When you ARE run, your role is a redundant escalation narrator co-running alongside the controller: you produce a live board view (the `status` interrogation below) and surface blocked/escalated tasks in a quiet-by-default voice. The board regen (Step 1) and stale-lock sweep (Step 3) you perform DUPLICATE work the controller already does — that overlap is intentional and idempotent. The per-task `.lock` is the only race-protection mechanism, so a second sweep finding nothing (or releasing a lock the controller would have released anyway) is a no-op safety net, not a conflict. You do NOT decide spawns, you are NOT a prerequisite for dispatch, and stopping you never stalls the build.

# Invocation

`/loop 30s /pm <slug>` is the canonical user invocation per D-S3.

The slug is positional and required. Without a slug, emit to stderr `Usage: /loop 30s /pm <slug>` and exit 1. PM does not auto-detect the slug from cwd — the user is responsible for naming it.

# User interjection: the literal word `status`

If the user's prompt for the current invocation is the literal word `status` (lowercase, no slash, no punctuation, optional surrounding whitespace), do this and return:

1. Create the sentinel file `planning/<slug>/.status-request` (UTF-8, empty or one-byte content is fine).
2. Reply with one line: `status request queued; next /pm tick will print the full board`.
3. Exit. Do NOT run the normal tick this turn.

The next `/loop` re-fire runs the normal tick below, detects the sentinel, prints the full board, deletes the sentinel.

# One tick — procedure

Run these steps in order. Each step is a finite operation. The whole tick should complete in seconds when nothing is wrong.

## Step 1 — Regenerate the board

Bash:
`pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/build-board.ps1" <slug>`

This rewrites `planning/<slug>/task-board.md` from current task frontmatter. If the script exits non-zero, emit `[HH:MM:SS] !! BOARD GEN FAILED: <first stderr line>` and exit 0. Never crash the loop — a broken board generator should not stop PM from observing other state.

## Step 2 — Status interrogation (D-S4)

If `planning/<slug>/.status-request` exists:

- Bash: `pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/board-print.ps1" <slug>`. Print its stdout verbatim — this is the full D-S4-schema board.
- Delete the sentinel: `Remove-Item "planning/<slug>/.status-request" -Force`.
- Continue with the rest of the tick (still emit the tick summary at the end).

## Step 3 — Stale-lock sweep (D-S1)

1. Read `planning/<slug>/.build-config.json` if it exists. Parse the integer `stale_lock_minutes`. Default 30 if the file is absent, the key is missing, or parsing fails.
2. Glob `planning/<slug>/tasks/task-*.lock`. For each match:
   - Read the lock body (use `Get-Content -Raw -ErrorAction SilentlyContinue`; if a sharing-violation IOException fires the lock is freshly held by an active writer — skip this entry). The body contains `key: value` lines like `worker_id: <id>` (or `reviewer_id: <id>` for reviewer-held locks), `claude_session_id: <id>`, `claimed_at: <ISO 8601 UTC>`.
   - Compute age in minutes between `claimed_at` and now (UTC). If age > threshold:
     - **First:** read the sibling `task-<id>.md`, surgically rewrite its frontmatter so `status: open`, `owner:` is blank, `claimed_at:` is blank. Preserve every other key, the body, and the dependency list. Use `Edit` for the three line-level swaps.
     - **Then:** delete the `.lock` file. Wrap in try/catch — if `Remove-Item` throws (handle held by AV / explorer / etc.), emit `[HH:MM:SS] !! STALE LOCK RELEASE FAILED: T-NNN frontmatter reset but lock delete error: <err>`. The next PM tick will retry the delete (frontmatter is already reset, so the second attempt is a no-op on the frontmatter side and just removes the orphan lock).
     - **Then:** emit `[HH:MM:SS] !! STALE LOCK: <worker_id> on T-NNN held N min; releasing` (substitute the actor's actual field name — `worker_id` or `reviewer_id` — in the line).
   - **Ordering rationale.** Cross-task invariant 6 says frontmatter rewrites happen only while the `.lock` is held. PM is the cleanup actor (D-S1) and the original lock holder is stale by definition, but honoring the invariant by sequence (rewrite first, then release) keeps PM consistent with worker/reviewer rewrite semantics and avoids a carveout in the invariant.

## Step 4 — Blocked-task detection (tick-count gated)

1. Open `planning/<slug>/.pm-tick-state.json`. If absent, create with `{"blocked_tick_count": {}, "emitted_blocks": {}, "emitted_escalations": {}}`.
2. From the regenerated `task-board.md`, read the `blocked (N) -- informational subset of open:` section header. The double-hyphen is literal ASCII `--`. `build-board.ps1` emits ASCII `--` here per cross-task invariant 1 (em-dash banned inside PS `"..."` literals), even though the D-S4 spec schema example renders it with a unicode em-dash. Match the bytes the generator actually writes. Each row has shape `T-NNN  <title>  waiting on: T-MMM (status)`.
3. For each currently-blocked T-NNN:
   - Increment `blocked_tick_count[T-NNN]` by 1 (initialize to 1 on first observation).
   - If `blocked_tick_count[T-NNN] >= 2` AND T-NNN is NOT in `emitted_blocks`: emit `[HH:MM:SS] !! BLOCKED: T-NNN depends on T-MMM which is not yet done` (use the first unmet dep ID for T-MMM). Set `emitted_blocks[T-NNN] = <ISO now>`.
4. For any T-NNN currently in `blocked_tick_count` or `emitted_blocks` but NO LONGER in the board's blocked section, remove both entries (the task got unblocked).
5. Save `.pm-tick-state.json` (`Set-Content -Encoding utf8`).

Rationale: per spec T-W1-004 Notes ("at least 2 ticks") the gate is tick-count, not wall-clock. Counting ticks rather than seconds keeps the semantics correct under any `/loop` cadence (default 30s, but `/loop 10s` or `/loop 2m` are both valid invocations per D-S3). Iter-2 bayesian flagged the wall-clock substitution as cadence-fragile; iter-3 fix uses an explicit tick counter.

## Step 5 — Escalated-task surfacing (D-S7)

1. Glob `planning/<slug>/tasks/task-*.md`. For each whose frontmatter `status: escalated`:
   - Read the `unresolved_findings:` list from the same frontmatter (first entry only).
   - If T-NNN is NOT in `emitted_escalations` (from `.pm-tick-state.json`): emit `[HH:MM:SS] !! ESCALATED: T-NNN hit 3-iter review cap; needs human eye. Reviewer's last feedback: <first unresolved_findings entry>`. Set `emitted_escalations[T-NNN] = <ISO now>` and save the state file.
2. If a task has transitioned out of `escalated` (e.g., via /unblock), the entry in `emitted_escalations` can stay — it's not load-bearing once cleared off the board. Optional: clean it on a future tick.

## Step 6 — Tick summary or all-done

1. **Empty-board gate.** Read `task-board.md`. If it contains the literal text `(no tasks yet)` (build-board.ps1's empty-board sentinel — emitted when `tasks/` has no `task-*.md` files), emit `[HH:MM:SS] tick: 0 open, 0 in_progress, 0 in_review, 0 done` and exit 0. Do NOT emit `*** ALL TASKS DONE` — an empty board is not a done board. (False-positive ALL TASKS DONE on an unpopulated build was the falsificationist's loud-failure case in Group B iter 1.)
2. **Parse the section counts.** Header lines look like `open (N):`, `in_progress (N):`, etc. Pull the integer in parens from each of the six standard sections (`open`, `in_progress`, `in_review`, `needs_fixing`, `escalated`, `done`).
3. **Parse-failure gate.** If NONE of the six section-header regexes match any line in the board file (board is malformed for some reason other than empty `tasks/`), emit `[HH:MM:SS] !! BOARD PARSE FAILED: missing section headers` and exit 0. Do NOT emit a tick summary or ALL TASKS DONE on parse failure.
4. Let `active = open + in_progress + in_review + needs_fixing + escalated`.
5. If `active == 0` AND `done > 0`: emit `*** ALL TASKS DONE` and exit 0.
6. Otherwise: emit `[HH:MM:SS] tick: N open, N in_progress, N in_review, N done` (use the done count from the board).
7. Exit 0.

# Escalation line vocabulary

These are the only loud lines a quiet PM tick emits. Format `[HH:MM:SS] <prefix>: <body>`:

- `tick: N open, N in_progress, N in_review, N done` — quiet-tick summary (no `!!` prefix).
- `!! STALE LOCK: <worker_id> on T-NNN held N min; releasing` — D-S1 sweep release.
- `!! BLOCKED: T-NNN depends on T-MMM which is not yet done` — only after >=2 consecutive blocked ticks (Step 4 tick-count gate).
- `!! ESCALATED: T-NNN hit 3-iter review cap; needs human eye. Reviewer's last feedback: <one-line>` — D-S7 surfacing.
- `!! BOARD GEN FAILED: <stderr-line>` — build-board.ps1 non-zero exit.
- `!! BOARD PARSE FAILED: missing section headers` — the board file exists but no expected section headers parsed (Step 6 gate). Distinguishes a malformed-but-present board from a generator failure. This line is reachable only via external tampering (manual edit, partial write, encoding corruption); the canonical `build-board.ps1` always emits either the six section headers or the `(no tasks yet)` sentinel.
- `!! STALE LOCK RELEASE FAILED: T-NNN frontmatter reset but lock delete error: <err>` — Step 3 partial-failure path (frontmatter reset succeeded, `Remove-Item` on the `.lock` failed, likely due to a transient handle holder). Next PM tick retries the delete; the frontmatter is already reset so the second attempt only removes the orphan lock.
- `*** ALL TASKS DONE` — terminal sentinel; PM exits cleanly after this. Only emitted when the board parsed cleanly AND `active == 0 AND done > 0` (never on empty boards).

If you find yourself wanting to emit any line not in this list, that is a design drift — the spec gives PM a fixed vocabulary on purpose so the operator can pattern-match the PM terminal at a glance.

# State file schema

`planning/<slug>/.pm-tick-state.json` is PM-owned. PM is the only writer. Schema:

```json
{
  "blocked_tick_count": {"T-NNN": 0},
  "emitted_blocks": {"T-NNN": "ISO 8601 UTC"},
  "emitted_escalations": {"T-NNN": "ISO 8601 UTC"}
}
```

`blocked_tick_count` is integer (per-task PM tick count while continuously blocked); `emitted_blocks` and `emitted_escalations` are ISO timestamps of the emit moment, used to suppress repeat emissions. Created on first tick that needs it. Deleted manually if the operator wants a clean PM state.

# What I do NOT do

- PM does NOT claim tasks. Only `/worker` and `/reviewer` claim. PM never creates a `.lock` file.
- PM does NOT modify task body content. PM touches task frontmatter ONLY via the stale-lock release path (resetting `status`, `owner`, `claimed_at`).
- PM does NOT spawn `/reviewer` or run any review panel.
- PM does NOT edit `task-board.md` directly. `build-board.ps1` is the sole writer.
- PM has NO loop cap (PRD D12). The 5-completed cap applies only to `/worker` and `/reviewer`. PM runs as long as `/loop` keeps re-firing it.
- PM does NOT touch `.state-auto-log` or any state-writer artifact. SessionEnd writer and SessionStart sweep own that channel.

# Cross-task invariants honored

1. ASCII-only inside any executable code snippet shown in this skill body (em-dash, smart quotes, right-arrow banned).
2. Per-task `.lock` is the only race-protection mechanism (cross-task invariant 6). PM respects it — PM never deletes a lock except via the stale-sweep release path, and even then only after confirming age > threshold.
3. PM is read-mostly: it regenerates the board (a derived artifact), writes its own state file, and only rewrites task frontmatter under the stale-sweep path.
