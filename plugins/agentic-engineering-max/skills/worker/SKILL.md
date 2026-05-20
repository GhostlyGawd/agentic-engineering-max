---
name: worker
description: Single-tick worker that atomic-claims a task, performs the work, commits, sets in_review, and releases the lock. Mechanism — [IO.File]::Open CreateNew on a per-task `.lock` sibling under `planning/<slug>/tasks/`, with body bytes written through the same FileStream before Dispose (closes the lock-create-vs-body-write race). Commits carry `Worker-ID:` and `Claude-Session-ID:` trailers. Invoked by `/loop /worker <slug>` (D-S3, self-paced). On 5 completed tasks per invocation, writes HANDOFF.md (D-S5), releases any held locks, writes a loop-stop sentinel, exits. Skipped claim attempts (lock contention, no claimable task) do NOT count toward the cap.
tools: Read, Write, Edit, Glob, Grep, Bash
model: opus
---

# /worker — single-tick task worker

When invoked, you run exactly ONE worker tick and exit. Each tick either claims and completes one task (counts toward the 5-cap), or finds nothing claimable and exits silently (does NOT count). `/loop` re-invokes you immediately when you exit; the cap is enforced via env-var counter + loop-stop sentinel.

You are the only one who modifies deliverable files. PM regenerates the board; /reviewer writes review iterations; you do the work.

# Terminology

Three identity tokens use different cases / spellings for different surfaces:

- `$env:WORKER_ID` (uppercase env var) — the user's chosen worker label, set by the user before launching `/loop`.
- `worker_id:` (lowercase YAML field) — the lock-body and frontmatter field that records the WORKER_ID value.
- `Worker-ID:` (Title-Case-with-hyphen) — the git commit trailer that records the same value.

Similarly for the session identifier:

- `$env:CLAUDE_SESSION_ID` / `$env:CLAUDECODE_SESSION_ID` — environment-surface candidates per D-S2.
- `$sessionId` — the in-memory PowerShell binding after the D-S2 priority chain resolves.
- `claude_session_id:` — the YAML field in lock bodies and frontmatter.
- `Claude-Session-ID:` — the git commit trailer.

"Loop cap" / "5-completed cap" / "WORKER_LOOP_COUNT >= 5" all refer to the same gate: 5 successful task completions per `/loop` invocation (PRD D12). The on-disk artifact that signals the cap is `planning/<slug>/.locks/<worker_id>.stop` — per-worker by filename so worker-A hitting the cap does not stop worker-B. Prose calls this the "loop-stop sentinel."

"Re-entry" is not supported. Any same-WORKER_ID-fresh lock is a collision (the same human-readable label being used in two terminals at once), not a worker resuming after a crash.

# Invocation

`/loop /worker <slug>` is the canonical user invocation per D-S3. Self-paced (no interval argument) — each tick runs to completion, then /loop re-fires.

The slug is positional and required. Without a slug, emit to stderr `Usage: /loop /worker <slug>` and exit 1.

# Environment variables

Set by the user before launching the loop; you read them every tick. Do NOT auto-generate (PRD D8 + cross-task invariant 12 — human-readable labels are the user's responsibility).

- `$env:WORKER_ID` — REQUIRED. Human-readable label like `worker-A`, `worker-B`. If unset, emit to stderr `Set $env:WORKER_ID before launching /loop /worker` and exit 1.
- `$env:CLAUDE_SESSION_ID` — preferred Claude Code session ID source. Falls back per D-S2: if unset, try `$env:CLAUDECODE_SESSION_ID`; if also unset, use the literal value `pid-<$PID>` (e.g., `pid-12345`). The `pid-` prefix makes the fallback case grep-distinguishable from a real session ID.
- `$env:WORKER_LOOP_COUNT` — managed by THIS skill. Initialized 0 if unset. Increments by 1 per completed task. At 5, the loop-cap branch fires.

# One tick — procedure

## Step 1 — Bail-fast checks

- If `$env:WORKER_ID` is unset → stderr error (above) + exit 1.
- If `planning/<slug>/.locks/<worker_id>.stop` exists → exit 0 silent. The previous tick hit the loop cap; /loop should NOT be re-firing you. Exiting silently lets the operator notice the loop is still running on a capped worker.

## Step 2 — Resolve session ID

Compute `$sessionId` from the D-S2 priority chain. Use this value verbatim in the `.lock` body and the commit trailer.

## Step 3 — Find the highest-priority claimable task

1. Glob `planning/<slug>/tasks/task-*.md`. Read each frontmatter (the YAML block between `---` fences at the top).
2. Build the candidate list by applying the priority filter in this exact order:
   - **Priority 1:** `status: needs_fixing` AND `owner == $env:WORKER_ID` AND `review_iterations < 3` AND every entry in `depends_on:` has `status: done` (read the named task files to check). Re-work belongs to the original worker.
   - **Priority 2:** `status: open` AND every entry in `depends_on:` has `status: done` AND no sibling `task-<id>.lock` file exists.
3. Within each priority band, lex-sort by task ID (`T-W1-001` < `T-W1-002` < `T-W2-001`) and take the lowest.
4. If no candidate matches: stdout `[<worker_id>] no claimable tasks; exiting tick` and exit 0. Skip does NOT count toward `$env:WORKER_LOOP_COUNT`.

## Step 4 — Collision pre-check (PRD §8 row 3)

Before attempting the atomic create, if a `.lock` ALREADY exists at the candidate's lock path:

- Attempt to read its body via `Get-Content -Raw -ErrorAction Stop` wrapped in `try/catch`:
  - If the read **throws an IOException with HResult 0x80070020 (`ERROR_SHARING_VIOLATION`)** or any other IOException: the lock is freshly held by an active writer (the holder's atomic-claim FileStream is still open with `FileShare='None'`). Treat as "lock held, fresh, in-progress" — skip to the next candidate. Skip does NOT count toward the cap.
  - If the read **succeeds** and `worker_id == $env:WORKER_ID` AND the lock is fresh (`now - claimed_at < stale_lock_minutes` from `.build-config.json`, default 30): this is a same-WORKER_ID collision, not re-entry. Emit to stderr `WARNING: lock collision on T-NNN; re-tag your WORKER_ID env var` and skip to the next candidate (Step 3 again from the next-lowest ID). Skip does NOT count toward the cap.
  - If the read **succeeds** and `worker_id != $env:WORKER_ID`, OR the lock is stale: skip. PM's stale-sweep will handle the stale case on its next tick — do NOT race PM.

The shared-read failure path is normal and expected: the active claimer holds the file with `FileShare='None'` (per Step 5's atomic-claim invocation), so peer reads will get sharing violations during the brief window between `CreateNew` and `Dispose`. Treating that as "fresh-held, skip" is the correct semantic.

## Step 5 — Atomic claim (single PowerShell invocation, body written before Dispose)

Lock path is the sibling of the task file: `planning/<slug>/tasks/task-<id>.lock`.

**Race-window closure.** A naive two-step pattern (`CreateNew` then `Set-Content`) leaves the lock file as zero bytes between the two calls — long enough for a peer reader (collision check, PM stale-sweep) to see an empty body and behave incorrectly. The correct pattern opens the file with `CreateNew`, writes the body through the same `FileStream`, flushes, then disposes — atomically present-and-populated from the perspective of any reader.

Issue this via Bash. The PowerShell expression must be ONE call:

```
powershell -NoProfile -Command "try { $fs = [IO.File]::Open('<lock-path>', 'CreateNew', 'ReadWrite', 'None'); $body = 'worker_id: <worker_id>' + [Environment]::NewLine + 'claude_session_id: <session_id>' + [Environment]::NewLine + 'claimed_at: <ISO 8601 UTC>' + [Environment]::NewLine; $bytes = [Text.UTF8Encoding]::new($false).GetBytes($body); $fs.Write($bytes, 0, $bytes.Length); $fs.Flush(); $fs.Dispose(); exit 0 } catch { exit 1 }"
```

(`UTF8Encoding($false)` = no BOM. This is the same encoding the rest of the build uses.)

- Exit code 0: lock is yours AND the body is on disk. Peer readers will see the populated lock as a single observation.
- Exit code 1: lock contention OR filesystem error OR write failure. Skip to the next candidate (Step 3 again). Skip does NOT count toward the cap. If the failure happened mid-write the file may exist as partial (0 to N bytes); do NOT attempt to clean it up from outside the lock owner — PM's stale-sweep is the cleanup actor (D-S1).

## Step 6 — Update task frontmatter to in_progress

Read `task-<id>.md`. Parse the YAML frontmatter. Rewrite so:

- `status: in_progress`
- `owner: <worker_id>`
- `claimed_at: <same ISO timestamp you wrote into the lock body>`

Atomic rewrite: write the full new file to `task-<id>.md.tmp` then `Move-Item -Force` over the original. You hold the `.lock` for the duration, so no other worker can interleave.

Preserve every other frontmatter key (id, title, depends_on, blocks, type, wave, complexity, review_iterations, unresolved_findings, etc.) and the entire body.

## Step 7 — Do the work (DO NOT commit yet)

Read the task body. Honor these sections:

- `## Goal` — what the task is trying to achieve.
- `## Deliverables` — the file(s) you MUST create or modify.
- `## Acceptance criteria` — bullet-by-bullet verifiable conditions. Validate each as you go.
- `## Notes` — implementation guidance, gotchas, encoding quirks.
- `## Review iteration <N>` sections (only present on `needs_fixing` claims) — these are the findings the previous review surfaced. Address each blocking finding specifically. Non-blocking findings are improvement opportunities, not gates.

Make the file changes. **Do NOT commit yet.** Steps 7-9 produce one consolidated commit at Step 9 so reviewers see a single atomic event ("T-NNN: done + ready for review") in `git log`.

## Step 8 — Flip status to in_review (atomic rewrite, lock still held, DO NOT commit yet)

Read `task-<id>.md` (it may have been edited during Step 7). Rewrite the frontmatter:

- `status: in_review`
- `owner: <worker_id>` (leave set — /reviewer needs to know who to credit)
- `claimed_at: <unchanged>` (leave the claim timestamp for forensic purposes)

Atomic rewrite: write the full new file to `task-<id>.md.tmp` then `Move-Item -Force` over the original. You hold the `.lock` for the duration, so no other worker or reviewer can interleave. **Still do NOT commit yet** — Step 9 stages the work + the flip together.

## Step 9 — Single commit (work + status flip)

Stage and commit the work and the in_review flip in ONE git commit. This is the canonical order; the alternative "commit work first, then flip + commit again" is explicitly discarded (the panel flagged the ambiguity in iter 1):

```
git add <paths of the files you actually changed in Step 7> planning/<slug>/tasks/task-<id>.md
git commit -m "T-NNN: <one-line title> (ready for review)" \
           -m "Worker-ID: <worker_id>" \
           -m "Claude-Session-ID: <session_id>"
```

**Do NOT add a `-m ""` blank-paragraph flag between the subject and the trailers.** On Windows PowerShell 5.1 the empty-string argument is silently dropped by native-command argument handling, which unpairs the trailing `-m` flags (git then treats `Worker-ID:`/`Claude-Session-ID:` values as pathspecs and the commit fails). git already inserts a blank line between each `-m` paragraph, so the empty flag is redundant anyway. (Foot-gun confirmed by two independent workers in the 2026-05-19/20 swarm.)

Constraints:

- Do NOT use `git add -A` or `git add .` (cross-project safety — could pick up unrelated dirty state).
- Do NOT skip a hook (no `--no-verify`).
- If the commit fails (pre-commit hook, etc.): investigate and fix the underlying issue. Do NOT amend prior commits. Do NOT proceed to Step 10 — the `.lock` stays held by you, so PM will eventually stale-sweep it (30 min default) and the task re-opens for re-claim by you or another worker.

## Step 10 — Release the lock

After the Step 9 commit returns exit code 0:

`Remove-Item "planning/<slug>/tasks/task-<id>.lock" -Force`.

The lock release is the signal to /reviewer that this task is available for review-claim. Do NOT leave the lock; PM's 30-minute stale-sweep is a safety net, not the primary release path.

## Step 11 — Increment counter and check cap

Increment `$env:WORKER_LOOP_COUNT` by 1. PowerShell expression that survives unset / empty-string / non-numeric initial state:

```
$prev = if ([string]::IsNullOrEmpty($env:WORKER_LOOP_COUNT)) { 0 } else { [int]$env:WORKER_LOOP_COUNT }
$env:WORKER_LOOP_COUNT = ($prev + 1).ToString()
```

This is the LOOP-LEVEL counter, scoped to this `/loop` invocation's shell environment. D-S3 rationale: `/loop` re-launches the skill in the same shell environment, so a Process-scope env var mutation here survives into the next tick. If you find yourself spawning a child PowerShell or Bash for the increment, the mutation will die with the child — stay in the host PS session for this step.

If the new value is `>= 5`:

1. **Write HANDOFF.md** to disk per D-S5 at:
   `planning/<slug>/handoffs/worker-<worker_id>-<YYYY-MM-DDTHHMMSSZ>.md`
   (ISO 8601 UTC with colons stripped — Windows-path-safe).

   Frontmatter (YAML):

   ```yaml
   ---
   role: worker
   worker_id: <worker_id>
   claude_session_id: <session_id>
   slug: <slug>
   wave: <integer, e.g., 1 or 2>
   loop_count_completed: 5
   created_at: <ISO 8601 UTC>
   tasks_completed: [T-NNN, T-NNN, T-NNN, T-NNN, T-NNN]
   ---
   ```

   Body (four sections, headings exactly as written):

   - `## What I worked on` — one paragraph per task or a bulleted log.
   - `## What's still open (board snapshot)` — copy/paste the current `task-board.md` contents or summarize counts per status.
   - `## What I learned` — non-obvious gotchas, encoding traps, lock contention observations, etc.
   - `## Recommendation for next worker` — concrete next steps (which task to claim first, which areas to be careful about).

2. **Release any held locks** (defensive — you should not hold any at this point, but check): Glob `planning/<slug>/tasks/*.lock`. For each whose body's `worker_id == $env:WORKER_ID`, delete it.

3. **Commit the HANDOFF.md FIRST** (before the loop-stop sentinel — see ordering rationale below):

   ```
   git add planning/<slug>/handoffs/worker-<worker_id>-*.md
   git commit -m "T-multi: worker <worker_id> loop cap (5 done)" \
              -m "Worker-ID: <worker_id>" \
              -m "Claude-Session-ID: <session_id>"
   ```

   **If the commit fails** (pre-commit hook, dirty index, signing failure): emit to stderr `[<worker_id>] HANDOFF commit failed; not writing loop-stop sentinel`, leave HANDOFF.md on disk untracked, exit 1. The next `/loop` tick re-fires, finds no sentinel, the cap-check fires again (`WORKER_LOOP_COUNT` is still >= 5), and the cap-completion sequence is re-attempted. This is idempotent — if the HANDOFF.md file already exists on disk, you may overwrite it with a fresh timestamp (path includes the ISO).

5. **Only if the Step 4 commit succeeds, write the loop-stop sentinel:**

   ```
   New-Item -ItemType Directory -Path planning/<slug>/.locks -Force | Out-Null
   Set-Content -Encoding utf8 -Path planning/<slug>/.locks/<worker_id>.stop -Value <ISO now>
   ```

6. Stdout: `[<worker_id>] loop cap reached (5 tasks completed); wrote HANDOFF.md; exiting`.

7. Exit 0.

**Ordering rationale.** The loop-stop sentinel is the bail-fast signal at Step 1 of the next tick — if it exists, the worker exits silent. We must guarantee the sentinel exists ONLY if the HANDOFF.md is committed; otherwise a failed commit would leave the sentinel on disk and the operator would never see why the loop went silent. Commit-then-sentinel makes the "did the worker actually finish cleanly?" question observable in `git log`.

If the new value is `< 5`: exit 0. /loop will re-fire you for the next tick.

# Catch-block discipline

Wrap Steps 5 through 10 in a try/finally. If ANY unexpected error fires after you've created the `.lock`, your finally block MUST delete the `.lock` before rethrowing or exiting. Orphan locks gate PM's stale-sweep and waste 30 minutes per occurrence.

Exemplar pattern in PowerShell:

```
$lockPath = "$tasksDir\task-$taskId.lock"
try {
    # Steps 5-10: atomic-claim+body-write, flip frontmatter to in_progress,
    # do the work, flip frontmatter to in_review, single commit, release lock.
    # ...
} finally {
    if (Test-Path $lockPath) {
        Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
    }
}
```

The exception: if the error happens AFTER Step 10 (the explicit `Remove-Item` already ran), `Test-Path` returns false in the finally and the cleanup is a clean no-op.

# What I do NOT do

- I do NOT modify another worker's `.lock` file. Even for a stale lock, PM is the cleanup actor (D-S1).
- I do NOT review my own work. After commit, I flip status to `in_review` and exit.
- I do NOT edit `task-board.md` directly. PM regenerates it from frontmatter (cross-task invariant 9).
- I do NOT change `review_iterations`. That field is /reviewer's exclusive write (D-S7 atomic-by-lock-ownership).
- I do NOT count skipped claim attempts (lock contention, no claimable task) toward the cap. Only completed tasks count (PRD D12 + cross-task invariant 11).
- I do NOT auto-generate my own WORKER_ID. The user sets it; I read it.
- I do NOT use `2>&1` on native executables (cross-task invariant 3). Use `2>$null` or capture stderr separately.

# Cross-task invariants honored

1. ASCII-only inside executable code snippets shown above (cross-task invariant 1).
2. All file writes use UTF-8 encoding (cross-task invariant 4).
3. The per-task `.lock` is the only race-protection mechanism (cross-task invariant 6). I never substitute filesystem renames, databases, or network locks.
4. Loop cap counts only completed tasks (cross-task invariant 11).
5. WORKER_ID is the user's responsibility (cross-task invariant 12).
