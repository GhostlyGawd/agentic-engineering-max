---
name: task-create
description: Capture a chat insight as a GATED design task in a build slug. Invoke as `/task-create <text> [--slug <slug>]` (slug defaults to `inbox`). Writes a `kind: task` design task with `gate_decider: user` + `gate_action: spawn-next-stage` via `bin/task-create.ps1` and drops a wake-sentinel so the dormant controller picks it up. Use when the user wants to turn an idea raised in chat into a tracked, human-approved design task without leaving the conversation.
tools: Bash
---

# /task-create -- chat insight to gated design task

When invoked, you capture the user's text as a new GATED design task in a build
slug, then report the created task id. You do NOT design anything yourself --
you only file the task. A normal worker later writes the design plan; the user
approves; the gate spawns the spec-writer. This skill owns ONLY the first hop.

## The flow this skill starts (D-S8)

```
/task-create "<insight>"  ->  bin/task-create.ps1
        writes planning/<slug>/tasks/task-NNN.md
        (kind: task, status: open, gate_decider: user,
         gate_action: spawn-next-stage, gate_state: pending,
         source: task-create) + drops a wake-sentinel
                |
                v
   a normal worker claims it, writes the design plan at
   planning/<slug>/designs/<task-id>-design.md, sets
   status: awaiting_user_approval
                |
                v
   the task surfaces in the control-plane Gates queue; the user
   APPROVES -> the gate (D-S2 spawn-next-stage, bin/gate-apply.ps1)
   creates a downstream spec-writer task for <slug> and marks the
   design task done. DECLINE closes it.
```

## Arguments

`/task-create <text> [--slug <slug>]`

- `<text>` (required) -- the one-line insight to capture. Everything that is
  not the `--slug <slug>` flag is the text.
- `--slug <slug>` (optional) -- the target build slug. Defaults to `inbox`,
  the dedicated unsorted-capture slug. A non-existent slug is created on demand
  under `planning/<slug>/tasks/`.

If `<text>` is empty after stripping the flag, tell the user
`Usage: /task-create <text> [--slug <slug>]` and stop.

## Procedure

1. Parse the arguments into `$text` and `$slug` (default `inbox`).
2. Locate `bin/task-create.ps1` at the repo root (walk up from the working
   directory for a `.git`/`planning` marker if needed). This is the single
   writer; do NOT hand-roll the frontmatter -- the locked gate schema lives in
   the script (D-S8).
3. Run the writer, passing the text and slug verbatim:

   ```
   pwsh -NoProfile -File bin/task-create.ps1 -Text "<text>" -Slug "<slug>"
   ```

4. The writer prints three lines; the last is `task_id=T-NNN`. Read that id.
5. Report back to the user: the created task id, the slug it landed in, and the
   one-sentence next step ("a worker will write the design plan; you approve it
   in the Gates tab to spawn the spec-writer").

## What I do NOT do

- I do NOT write the design plan -- a worker does, after claiming the task.
- I do NOT hand-write the task frontmatter -- `bin/task-create.ps1` owns the
  locked schema so the gate wiring cannot drift.
- I do NOT approve the gate -- that is the user's decision in the control plane
  (or `bin/gate-apply.ps1` for a CLI/test caller).
- I do NOT edit `task-board.md` -- the controller regenerates it.
