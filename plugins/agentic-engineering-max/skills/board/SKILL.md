---
name: board
description: Print the full task board for a build slug to the current terminal. Invoke explicitly as `/board <slug>` (e.g. `/board orchestrator-and-build-system`). Use only when the user explicitly asks to see / print / show the task board for a slug.
tools: Bash
---

# /board -- print the task board

Print the full task board for a given slug.

> **Why this is a skill, not a slash command.** It needs the plugin's own
> install path to find `scripts/board-print.ps1`. The `CLAUDE_PLUGIN_ROOT`
> substitution variable resolves inline in skill content but not in
> slash-command content, so this logic must live in a skill.

```!
SLUG=$(echo "$ARGUMENTS" | tr -d '[:space:]')
if [ -z "$SLUG" ]; then
  echo "Usage: /board <slug>" >&2
  echo "Example: /board orchestrator-and-build-system" >&2
  exit 1
fi

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
if [ -z "$PLUGIN_ROOT" ]; then
  echo "[board] error: plugin root did not resolve -- run from inside an installed plugin." >&2
  exit 3
fi

SCRIPT="$PLUGIN_ROOT/scripts/board-print.ps1"
if [ ! -f "$SCRIPT" ]; then
  echo "[board] internal error: backing script not found at $SCRIPT" >&2
  exit 4
fi

if ! command -v pwsh >/dev/null 2>&1; then
  echo "[board] PowerShell 7+ (pwsh) not available -- install pwsh 7 and re-run." >&2
  exit 5
fi

pwsh -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT" "$SLUG"
```
