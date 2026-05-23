---
name: aem-init
description: Bootstrap the agentic-engineering-max build system in the current git repo. Invoke explicitly as `/aem-init [--slug <name>] [--force]`, once, right after installing the plugin, from inside the git repository you want to enable. Sets core.hooksPath to the plugin's hooks directory and optionally scaffolds a planning slug. Use only when the user explicitly asks to initialize / bootstrap / set up the build system in a repo.
tools: Bash
---

# /aem-init -- bootstrap the build system in this repo

Bootstrap the **agentic-engineering-max** build system in the current
repository.

> **Why this is a skill, not a slash command.** This logic needs the plugin's
> own install path (to find `scripts/aem-init.ps1` and the `hooks/` directory).
> The `CLAUDE_PLUGIN_ROOT` substitution variable is resolved inline in **skill
> content** but NOT in slash-command content (per the Claude Code plugins
> reference). Shipping this as a command is exactly what caused the v2.0.0
> "`CLAUDE_PLUGIN_ROOT` came through empty" failure. As a skill, the variable
> resolves to the real path before the bash block runs.

**What it does:**
1. Confirms the current directory is a git repository.
2. Sets `git config core.hooksPath` to the plugin's hooks directory, which
   wires up the pre-commit state-mirror enforcement hook. No files are copied
   into `.git/hooks/`.
3. Optionally scaffolds a new planning slug at `planning/<slug>/` with stub
   `plan-state.md` + `plan-ledger.md` state surfaces when `--slug <name>` is
   passed.
4. Prints a next-action summary.

**Flags:**
- `--slug <name>` -- also scaffold `planning/<name>/` with stub state-surface
  files. The `<name>` should be a single kebab-case token (no spaces). Omit to
  configure hooks only.
- `--force` -- overwrite an existing non-default `core.hooksPath`. Without it, a
  conflicting value is left untouched.

**Invariant-1 safety (no silent clobber):** if `core.hooksPath` is already set
to a non-default value that is not the plugin's hooks directory, `/aem-init`
**refuses** and exits without writing. Re-run with `--force` to overwrite it
deliberately.

**Exit codes:**
- **1** -- not inside a git repository. Run from your repo root, or `git init`
  first.
- **2** -- `core.hooksPath` conflict. An existing non-default value is set and
  `--force` was not passed.
- **3** -- plugin root could not be resolved (not running inside the plugin
  runtime) or the plugin hooks directory does not exist on disk.
- **4** -- unexpected internal error, or the backing script was not found on
  disk where the resolved plugin root pointed.
- **5** -- PowerShell 7+ (`pwsh`) not resolvable on PATH, or version below 7.

**Uninstall / reverse:** the only persistent change to your repo is the git
config key. Undo it with `git config --unset core.hooksPath`.

**Prerequisite:** this build system runs on Windows OR Linux and requires
PowerShell 7 (`pwsh`) and git, both resolvable on PATH.

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

# The token on the right-hand side below is substituted inline by Claude Code
# before this block runs, because this is SKILL content (not command content).
# That is the whole fix: in a slash command it would arrive empty.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
if [ -z "$PLUGIN_ROOT" ]; then
  echo "[aem-init] error: plugin root did not resolve -- run from inside an installed plugin." >&2
  exit 3
fi

SCRIPT="$PLUGIN_ROOT/scripts/aem-init.ps1"
if [ ! -f "$SCRIPT" ]; then
  # Distinct from exit 1: a missing script means the plugin root mis-resolved,
  # NOT that the user is outside a git repo. The v2.0.0 bug collided these two
  # (pwsh's own file-not-found exit 1 was mislabeled "not a git repository").
  echo "[aem-init] internal error: backing script not found at $SCRIPT" >&2
  exit 4
fi

# Preflight: pwsh must resolve on PATH. A missing pwsh otherwise makes bash
# return 127, which would fall through to the generic arm and never report the
# documented exit-5 contract.
if ! command -v pwsh >/dev/null 2>&1; then
  echo "[aem-init] PowerShell 7+ (pwsh) not available -- install pwsh 7 per the Prerequisite section and re-run." >&2
  exit 5
fi

# Pass the resolved root explicitly via -PluginRoot (the script's preferred
# input; it falls back to $env:CLAUDE_PLUGIN_ROOT only when the param is
# omitted). Explicit passing avoids relying on env export into the subprocess.
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
