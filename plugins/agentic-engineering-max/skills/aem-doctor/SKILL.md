---
name: aem-doctor
description: Health-check the agentic-engineering-max build-system setup in the current git repo. Invoke explicitly as `/aem-doctor`, any time, from inside the repository you want to check. Runs four read-only checks (git repo, PowerShell 7 present, hooks wired, scripts can run) and prints a plain-English status line plus a concrete fix for anything that is off. Use when the user asks to check / diagnose / verify the build-system setup, or after /aem-init to confirm the repo is ready.
tools: Bash
---

# /aem-doctor -- check this repo's build-system setup

Run four read-only checks against the current repository and report, in plain
English, what is set up and what (if anything) needs fixing. This skill mutates
nothing -- it only inspects.

> **Why this is a skill, not a slash command.** It needs the plugin's own
> install path to find `scripts/aem-doctor.ps1` and to compute the expected
> `core.hooksPath`. The `CLAUDE_PLUGIN_ROOT` substitution variable resolves
> inline in skill content but NOT in slash-command content (the v2.0.0
> "`CLAUDE_PLUGIN_ROOT` came through empty" bug), so this logic must live in a
> skill.

**The four checks:**
1. **git repo?** -- are we inside a git repository?
2. **PowerShell 7 present?** -- is `pwsh` (version 7+) on PATH? The plugin hooks
   and scripts run under it.
3. **hooks wired?** -- does `core.hooksPath` point at the plugin's hooks
   directory? If not, the fix is `/aem-init`.
4. **can scripts run here?** -- is the execution policy permissive enough to run
   the plugin's `.ps1` scripts? Read via a benign inline policy probe that works
   even where running script files is blocked.

Each check prints one status line; anything that fails also prints one concrete
fix line. A final summary line says either "all good" or what to fix.

> **A nonzero exit is advisory, not an error.** The backing script exits 1 when
> it has fixes to suggest (and 0 when all four checks pass). That exit 1 means
> "here are things to fix", not "the health check itself failed" -- nothing was
> mutated either way.

> **If you see "running scripts is disabled" instead of the report.** This skill
> runs the doctor as a `.ps1` via `pwsh -NoProfile -File` with no
> policy-override flag (no Bypass) -- the same no-override invocation the rest of
> the plugin uses. So if your machine's execution policy blocks local scripts
> (Restricted / AllSigned), the host refuses to load the doctor and you get that
> error instead of the four-check report. That error IS the diagnosis check (d)
> would have printed: fix it with
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` (or ask your IT admin if
> the policy is locked at the machine scope) and re-run `/aem-doctor`.

```!
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
if [ -z "$PLUGIN_ROOT" ]; then
  echo "[aem-doctor] error: plugin root did not resolve -- run from inside an installed plugin." >&2
  exit 3
fi

SCRIPT="$PLUGIN_ROOT/scripts/aem-doctor.ps1"
if [ ! -f "$SCRIPT" ]; then
  echo "[aem-doctor] internal error: backing script not found at $SCRIPT" >&2
  exit 4
fi

if ! command -v pwsh >/dev/null 2>&1; then
  echo "[aem-doctor] PowerShell 7+ (pwsh) not available -- install pwsh 7 and re-run." >&2
  exit 5
fi

pwsh -NoProfile -File "$SCRIPT" -PluginRoot "$PLUGIN_ROOT"
```
