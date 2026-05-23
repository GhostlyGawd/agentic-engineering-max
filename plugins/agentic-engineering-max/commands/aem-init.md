---
name: aem-init
description: Bootstrap the agentic-engineering-max build system in the current git repo (sets core.hooksPath; optionally scaffolds a planning slug).
argument-hint: "[--slug <name>] [--force]"
allowed-tools: ["Bash(*)"]
---

Bootstrap the **agentic-engineering-max** build system in the current repository.

**When to invoke:** once, right after installing the plugin, from inside a Claude Code session whose working directory is the git repository you want to enable. The command must run inside a git repo and inside the plugin runtime (so the plugin's install root resolves).

**What it does:**
1. Confirms the current directory is a git repository.
2. Sets `git config core.hooksPath` to the plugin's hooks directory under `${CLAUDE_PLUGIN_ROOT}/hooks`, which wires up the pre-commit state-mirror enforcement hook. No files are copied into `.git/hooks/`.
3. Optionally scaffolds a new planning slug at `planning/<slug>/` with stub `plan-state.md` + `plan-ledger.md` state surfaces when `--slug <name>` is passed.
4. Prints a next-action summary.

**Flags:**
- `--slug <name>` — also scaffold `planning/<name>/` with stub state-surface files. The `<name>` should be a single kebab-case token (no spaces). Omit to configure hooks only.
- `--force` — overwrite an existing non-default `core.hooksPath` (see safety note below). Without it, a conflicting value is left untouched.

The slash command translates `--slug` to the backing script's `-Slug` parameter and `--force` to `-Force`, resolves the plugin's install root (from `${CLAUDE_SKILL_DIR}`, falling back to `$CLAUDE_PLUGIN_ROOT`), and runs `<root>/scripts/aem-init.ps1`, passing the resolved root as `-PluginRoot`.

**Invariant-1 safety (no silent clobber):** if `core.hooksPath` is already set to a non-default value that is not the plugin's hooks directory, `/aem-init` **refuses** and exits without writing. The existing value is echoed so you can decide. Re-run with `--force` to overwrite it deliberately. A value of `.git/hooks` (the git default) or one already pointing at the plugin is not treated as a conflict and is overwritten/confirmed normally.

**On success (exit 0):** the script prints `core.hooksPath set to: <plugin>/hooks`, lists any scaffolded files, and tells you the next action — run the plan-interviewer on the slug to reach 100% understanding (or pass `--slug <name>` if you configured hooks only). The SessionStart auto-nudge ("Run `/aem-init` ...") clears on the next session once hooks are configured.

**On failure — what each exit code means:**
- **1 — not inside a git repository.** Run the command from your repo root, or `git init` first.
- **2 — `core.hooksPath` conflict.** An existing non-default value is set and `--force` was not passed. The conflicting value is printed; re-run with `--force` to overwrite it.
- **3 — plugin hooks directory unavailable.** The plugin install root could not be resolved (neither `${CLAUDE_SKILL_DIR}` nor `$CLAUDE_PLUGIN_ROOT` pointed at the bundled `aem-init.ps1`), or `<root>/hooks` does not exist on disk. Invoke from inside an installed Claude Code session.
- **4 — unexpected internal error.** `git config` failed to write, or another error was caught. The error message is printed to stderr.
- **5 — PowerShell 7+ (`pwsh`) not available.** The pre-config availability probe could not resolve `pwsh` on PATH, or it reported a version below 7. No `core.hooksPath` change was made. Install pwsh 7 per the Prerequisite section and re-run.

**Uninstall / reverse:** the only persistent change to your repo is the git config key. Undo it with:

```
git config --unset core.hooksPath
```

(or point it back at the default with `git config core.hooksPath .git/hooks`). Then remove the plugin with `/plugin uninstall agentic-engineering-max@agentic-engineering-max`. No residual files are left in your repo.

**Prerequisite:** this build system runs on Windows OR Linux and requires PowerShell 7 (`pwsh`) and git, both resolvable on PATH. The backing script and hooks are `.ps1` files invoked via `pwsh`. If `pwsh` is not installed, install it and re-run:

```
Linux:   wget -qO- https://aka.ms/install-powershell.sh | sudo bash
Windows: winget install --id Microsoft.PowerShell --source winget
```

```!
ARGS="$ARGUMENTS"
SLUG=""
FORCE=""

# Parse --slug <name> and --force from the argument string.
set -- $ARGS
while [ $# -gt 0 ]; do
  case "$1" in
    --slug)
      shift
      SLUG="$1"
      ;;
    --force)
      FORCE="1"
      ;;
    *)
      echo "[aem-init] warning: ignoring unrecognized argument '$1'" >&2
      ;;
  esac
  shift
done

PS_ARGS=""
if [ -n "$SLUG" ]; then
  PS_ARGS="-Slug \"$SLUG\""
fi
if [ -n "$FORCE" ]; then
  PS_ARGS="$PS_ARGS -Force"
fi

# Resolve the plugin install root. $CLAUDE_PLUGIN_ROOT is documented ONLY as an
# env var for hook / MCP / monitor subprocesses -- it is NOT reliably exported
# into a slash command's bash block. In real installs it arrived empty, which
# collapsed the path to /scripts/aem-init.ps1 and made pwsh fail with a
# misleading exit 1 ("not a git repository"). Resolve defensively from two
# sources -- the documented render-time template first -- and verify the script
# exists before invoking pwsh:
#   1. ${CLAUDE_SKILL_DIR} -- a render-time template substitution (the
#      documented way for a command to find its own bundled files). This command
#      lives in <root>/commands, so the plugin root is its parent. If the runtime
#      does not substitute it, it expands empty here and we fall through.
#   2. $CLAUDE_PLUGIN_ROOT -- used when the runtime does export it to the block.
PLUGIN_ROOT=""
if [ -n "${CLAUDE_SKILL_DIR}" ] && [ -f "${CLAUDE_SKILL_DIR}/../scripts/aem-init.ps1" ]; then
  PLUGIN_ROOT="${CLAUDE_SKILL_DIR}/.."
elif [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "$CLAUDE_PLUGIN_ROOT/scripts/aem-init.ps1" ]; then
  PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
fi

if [ -z "$PLUGIN_ROOT" ]; then
  echo "[aem-init] error: could not locate the plugin's aem-init.ps1 (neither CLAUDE_SKILL_DIR nor CLAUDE_PLUGIN_ROOT resolved to it). Reinstall the plugin, or run from inside an installed Claude Code session." >&2
  exit 3
fi
SCRIPT="$PLUGIN_ROOT/scripts/aem-init.ps1"

# Preflight: pwsh must resolve on PATH before we invoke it. Without this guard an
# absent pwsh makes bash return 127 (command-not-found), which falls through to the
# generic *) arm -- so the documented "exit 5 = pwsh not available" contract would
# never fire in the very case it describes. Guard here so a missing pwsh exits 5.
# (A pwsh present but below v7 is caught inside aem-init.ps1's probe, which also exits 5.)
if ! command -v pwsh >/dev/null 2>&1; then
  echo "[aem-init] PowerShell 7+ (pwsh) not available -- install pwsh 7 per the Prerequisite section and re-run." >&2
  exit 5
fi

# Pass the resolved root explicitly via -PluginRoot so the backing script does
# not have to re-resolve $env:CLAUDE_PLUGIN_ROOT (same export unreliability). The
# script still falls back to the env var when -PluginRoot is omitted, so direct
# invocation keeps working.
pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$SCRIPT' -PluginRoot '$PLUGIN_ROOT' $PS_ARGS"
CODE=$?

case "$CODE" in
  0) ;;
  1) echo "[aem-init] not a git repository -- run from your repo root or 'git init' first." >&2 ;;
  2) echo "[aem-init] core.hooksPath conflict -- re-run with --force to overwrite the existing value." >&2 ;;
  3) echo "[aem-init] plugin hooks dir unavailable -- run from inside an installed Claude Code session." >&2 ;;
  4) echo "[aem-init] internal error -- see the message above." >&2 ;;
  5) echo "[aem-init] PowerShell 7+ (pwsh) not available -- install pwsh 7 per the Prerequisite section and re-run." >&2 ;;
  *) echo "[aem-init] exited with code $CODE." >&2 ;;
esac

exit $CODE
```
