---
name: board
description: Print the full task board for a given slug to the current terminal.
argument-hint: "<slug>  project slug, e.g. orchestrator-and-build-system"
allowed-tools: ["Bash(*)"]
---

```!
SLUG=$(echo "$ARGUMENTS" | tr -d '[:space:]')
if [[ -z "$SLUG" ]]; then
  echo "Usage: /board <slug>" >&2
  echo "Example: /board orchestrator-and-build-system" >&2
  exit 1
fi

powershell -NoProfile -ExecutionPolicy Bypass -File "D:\GitHub Projects\Dev_006\bin\board-print.ps1" "$SLUG"
```
