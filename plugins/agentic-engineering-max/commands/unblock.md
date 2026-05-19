---
name: unblock
description: Inspect, reset, or force-done an escalated task in a build slug.
argument-hint: "<slug> T-NNN [--reset|--done]"
allowed-tools: ["Bash(*)"]
---

Inspect, reset, or force-done an escalated task.

**Usage:**
- `/unblock <slug> T-NNN` — inspect: print unresolved findings, suggest next step
- `/unblock <slug> T-NNN --reset` — reset to open (clears review_iterations, owner, claimed_at, unresolved_findings)
- `/unblock <slug> T-NNN --done` — force status to done (overrides panel; commits with "unblock --done"; push manually afterward)

**Safety:** `--reset` and `--done` only work when `status: escalated`. Any other status errors out.

```!
SLUG=$(echo "$ARGUMENTS" | awk '{print $1}')
TASK_ID=$(echo "$ARGUMENTS" | awk '{print $2}')
FLAG=$(echo "$ARGUMENTS" | awk '{print $3}')

if [[ -z "$SLUG" || -z "$TASK_ID" ]]; then
  echo "Usage: /unblock <slug> T-NNN [--reset|--done]" >&2
  echo "Example: /unblock orchestrator-and-build-system T-W2-005" >&2
  exit 1
fi

powershell -NoProfile -ExecutionPolicy Bypass -File "D:\GitHub Projects\Dev_006\bin\unblock.ps1" "$SLUG" "$TASK_ID" "$FLAG"
```
