---
name: aem-init
description: Bootstrap the agentic-engineering-max build system in the current git repo (sets core.hooksPath; optionally scaffolds a planning slug).
argument-hint: "[--slug <name>] [--force]"
allowed-tools: ["Bash(*)"]
---

Bootstrap the **agentic-engineering-max** build system in the current repository.

**When to invoke:** once, right after installing the plugin, from inside a Claude Code session whose working directory is the git repository you want to enable. The command must run inside a git repo and inside the plugin runtime (so `${CLAUDE_PLUGIN_ROOT}` resolves).

**What it does:**
1. Confirms the current directory is a git repository.
2. Sets `git config core.hooksPath` to the plugin's hooks directory under `${CLAUDE_PLUGIN_ROOT}/hooks`, which wires up the pre-commit state-mirror enforcement hook. No files are copied into `.git/hooks/`.
3. Optionally scaffolds a new planning slug at `planning/<slug>/` with stub `plan-state.md` + `plan-ledger.md` state surfaces when `--slug <name>` is passed.
4. Prints a next-action summary.

**Flags:**
- `--slug <name>` — also scaffold `planning/<name>/` with stub state-surface files. The `<name>` should be a single kebab-case token (no spaces). Omit to configure hooks only.
- `--force` — overwrite an existing non-default `core.hooksPath` (see safety note below). Without it, a conflicting value is left untouched.

The slash command translates `--slug` to the backing script's `-Slug` parameter and `--force` to `-Force`, then runs `${CLAUDE_PLUGIN_ROOT}/scripts/aem-init.ps1`.

**Invariant-1 safety (no silent clobber):** if `core.hooksPath` is already set to a non-default value that is not the plugin's hooks directory, `/aem-init` **refuses** and exits without writing. The existing value is echoed so you can decide. Re-run with `--force` to overwrite it deliberately. A value of `.git/hooks` (the git default) or one already pointing at the plugin is not treated as a conflict and is overwritten/confirmed normally.

**On success (exit 0):** the script prints `core.hooksPath set to: <plugin>/hooks`, lists any scaffolded files, and tells you the next action — run the plan-interviewer on the slug to reach 100% understanding (or pass `--slug <name>` if you configured hooks only). The SessionStart auto-nudge ("Run `/aem-init` ...") clears on the next session once hooks are configured.

**On failure — what each exit code means:**
- **1 — not inside a git repository.** Run the command from your repo root, or `git init` first.
- **2 — `core.hooksPath` conflict.** An existing non-default value is set and `--force` was not passed. The conflicting value is printed; re-run with `--force` to overwrite it.
- **3 — plugin hooks directory unavailable.** Either `${CLAUDE_PLUGIN_ROOT}` is unset (you are not inside the plugin runtime) or `${CLAUDE_PLUGIN_ROOT}/hooks` does not exist on disk. Invoke from inside an installed Claude Code session.
- **4 — unexpected internal error.** `git config` failed to write, or another error was caught. The error message is printed to stderr.
- **5 — PowerShell 7+ (`pwsh`) not available.** The pre-config availability probe could not resolve `pwsh` on PATH, or it reported a version below 7. No `core.hooksPath` change was made. Install pwsh 7 per the Prerequisite hint above and re-run.

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

SCRIPT="$CLAUDE_PLUGIN_ROOT/scripts/aem-init.ps1"
pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$SCRIPT' $PS_ARGS"
CODE=$?

case "$CODE" in
  0) ;;
  1) echo "[aem-init] not a git repository -- run from your repo root or 'git init' first." >&2 ;;
  2) echo "[aem-init] core.hooksPath conflict -- re-run with --force to overwrite the existing value." >&2 ;;
  3) echo "[aem-init] plugin hooks dir unavailable -- run from inside an installed Claude Code session." >&2 ;;
  4) echo "[aem-init] internal error -- see the message above." >&2 ;;
  5) echo "[aem-init] PowerShell 7+ (pwsh) not available -- install pwsh 7 per the Prerequisite hint and re-run." >&2 ;;
  *) echo "[aem-init] exited with code $CODE." >&2 ;;
esac

exit $CODE
```
