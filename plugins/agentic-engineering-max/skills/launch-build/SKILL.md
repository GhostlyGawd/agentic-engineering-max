---
name: launch-build
description: Launch the 3-department headless build (controller + optional PM + optional auto-pusher) yourself as detached background loops. Use when the user wants to START an implementation build whose spec/tasks are already seeded under planning/<slug>/. Replaces "open three terminals and run /loop" instructions.
tools: Bash
---

# /launch-build -- spawn the headless build yourself

Launch the agentic-engineering-max headless build as detached background loops.
The user wants you to **start the build yourself**, not delegate the launch
back to them.

> **Why this is a skill, not a slash command.** The launcher is `scripts/launch-build.ps1`
> inside the plugin install path. The `CLAUDE_PLUGIN_ROOT` substitution variable
> is resolved inline in **skill content** but NOT in slash-command content (per
> the Claude Code plugins reference). Shipping this as a command would arrive
> with an empty `${CLAUDE_PLUGIN_ROOT}` -- the v2.0.0 footgun. As a skill, the
> variable resolves before the bash block runs.

## Hard rules

- **DO NOT tell the user to open terminals, open new windows, or run `/loop` themselves.** That is the exact behavior this skill exists to replace.
- **DO NOT run `/pm`, `/worker`, or `/reviewer` in this session.** Those are for the spawned headless loops, not for you.
- You launch the loops as detached OS processes by running the bash block below, report the launch table, then **end your turn**. The loops run independently (walk-away); you do not babysit or poll them.

## What gets launched (default)

1. ONE detached `orchestrator-loop.ps1` controller. The controller auto-sizes the worker + reviewer fleets each tick from the claimable-queue widths, capped by `<slug>/.build-config.json` (`max_workers` / `max_reviewers`).
2. (Default on; suppress with `-NoPm`) ONE optional `/pm` escalation-narrator loop. The controller owns board regen + stale-lock sweep itself; PM is purely a narrator.
3. (Default on; suppress with `-NoPush`) ONE auto-pusher loop (`headless-pusher-loop.ps1`) that runs `git push origin HEAD` every ~45s so the build's local commits surface on GitHub live -- progress + phone notifications while you walk away. The pusher never commits (no index contention) and self-exits when all tasks are done.

## Exit codes (from the launcher)

- **0** -- launched (or `-DryRun` printed) successfully.
- **2** -- not inside a git repository (cwd-walk found no `.git` ancestor), OR `planning/<slug>/` not found.
- **3** -- no `task-*.md` under `planning/<slug>/tasks/` (the spec has not been seeded yet -- the build is not ready to launch).
- **4** -- a required loop script is missing (the controller, or the PM loop when PM is requested, or the pusher loop when push is requested).

## What you do

1. **Parse `$ARGUMENTS`.** First whitespace-separated token is the `<slug>` (required). Remaining tokens (if any) are passed through to the launcher unchanged -- typical extras are `-NoPm`, `-NoPush`, `-SleepSeconds <int>`, `-MaxTicks <int>`, `-DryRun`. If no slug is given, ask the user for the slug (one question via AskUserQuestion) and stop.

2. **Run the bash block below.** It resolves `${CLAUDE_PLUGIN_ROOT}` to the plugin install path, locates `scripts/launch-build.ps1`, and invokes it under `pwsh`. The launcher self-locates the user's repo via cwd-walk; from a Claude Code session the cwd is the user's repo root by default, which is correct.

3. **Relay the launch table verbatim**, then tell the user how to operate the now-running build:
   - **Watch:** `/board <slug>` from any session, GitHub commit notifications, or the per-loop logs under `<repo>/logs/headless-*.log`.
   - **Stop the controller:** push a commit creating `planning/<slug>/.locks/controller.headless-stop`, or kill its pid.

4. **End your turn.** Do not poll, do not loop, do not invoke `/pm`/`/worker`/`/reviewer`.

```!
ARGS="$ARGUMENTS"
if [ -z "$ARGS" ]; then
  echo "[launch-build] missing slug -- usage: /launch-build <slug> [flags]" >&2
  exit 2
fi

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
if [ -z "$PLUGIN_ROOT" ]; then
  echo "[launch-build] plugin root did not resolve -- run from inside an installed plugin." >&2
  exit 3
fi

SCRIPT="$PLUGIN_ROOT/scripts/launch-build.ps1"
if [ ! -f "$SCRIPT" ]; then
  echo "[launch-build] launcher not found at $SCRIPT" >&2
  exit 4
fi

if ! command -v pwsh >/dev/null 2>&1; then
  echo "[launch-build] pwsh 7 not found on PATH -- install PowerShell 7 to spawn the loops." >&2
  exit 4
fi

# Pass-through: -File handles the quoted path; $ARGS positional unsplit is fine
# because the launcher's first positional is the slug and subsequent are flags.
exec pwsh -NoProfile -File "$SCRIPT" $ARGS
```
