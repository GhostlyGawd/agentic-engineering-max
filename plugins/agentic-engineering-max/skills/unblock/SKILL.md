---
name: unblock
description: Inspect, reset, or force-done an escalated task in a build slug. Invoke explicitly as `/unblock <slug> T-NNN [--reset|--done]`. Use only when the user explicitly asks to inspect, reset, or force-complete an escalated task.
tools: Bash
---

# /unblock -- inspect / reset / force-done an escalated task

Inspect, reset, or force-done an escalated task.

> **Why this is a skill, not a slash command.** It needs the plugin's own
> install path to find `scripts/unblock.ps1`. The `CLAUDE_PLUGIN_ROOT`
> substitution variable resolves inline in skill content but not in
> slash-command content, so this logic must live in a skill.

**Usage:**
- `/unblock <slug> T-NNN` -- inspect: print unresolved findings, suggest next step
- `/unblock <slug> T-NNN --reset` -- reset to open (clears review_iterations, owner, claimed_at, unresolved_findings)
- `/unblock <slug> T-NNN --done` -- force status to done (overrides panel; commits with "unblock --done"; push manually afterward)

**Safety:** `--reset` and `--done` only work when `status: escalated`. Any other
status errors out.

```!
SLUG=$(echo "$ARGUMENTS" | awk '{print $1}')
TASK_ID=$(echo "$ARGUMENTS" | awk '{print $2}')
FLAG=$(echo "$ARGUMENTS" | awk '{print $3}')

if [ -z "$SLUG" ] || [ -z "$TASK_ID" ]; then
  echo "Usage: /unblock <slug> T-NNN [--reset|--done]" >&2
  echo "Example: /unblock orchestrator-and-build-system T-W2-005" >&2
  exit 1
fi

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
if [ -z "$PLUGIN_ROOT" ]; then
  echo "[unblock] error: plugin root did not resolve -- run from inside an installed plugin." >&2
  exit 3
fi

SCRIPT="$PLUGIN_ROOT/scripts/unblock.ps1"
if [ ! -f "$SCRIPT" ]; then
  echo "[unblock] internal error: backing script not found at $SCRIPT" >&2
  exit 4
fi

if ! command -v pwsh >/dev/null 2>&1; then
  echo "[unblock] PowerShell 7+ (pwsh) not available -- install pwsh 7 and re-run." >&2
  exit 5
fi

pwsh -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT" "$SLUG" "$TASK_ID" "$FLAG"
```
