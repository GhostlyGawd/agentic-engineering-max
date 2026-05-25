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
- **0** -- success. Hooks wired (`core.hooksPath` set); optional `--slug`
  scaffolded; health check ran.
- **1** -- not inside a git repository. Run from your repo root, or `git init`
  first. Decided by `git rev-parse` before any change is written.
- **2** -- `core.hooksPath` conflict. An existing non-default value is set and
  `--force` was not passed.
- **3** -- plugin root could not be resolved (not running inside the plugin
  runtime) or the plugin hooks directory does not exist on disk.
- **4** -- internal error, or (when `--slug` was passed) the scaffolding step
  failed. Any nonzero exit from the scaffold step maps to 4.

The core action -- wiring `core.hooksPath` -- is **plain git**: it needs no
PowerShell, so PowerShell presence is no longer a precondition for setup and is
no longer surfaced as an exit code. The health check reports whether `pwsh 7`
is present; `--slug` scaffolding is the only step that needs it.

**Uninstall / reverse:** the only persistent change to your repo is the git
config key. Undo it with `git config --unset core.hooksPath`.

**Prerequisite:** git resolvable on PATH (the core action is pure git). The
optional `--slug` scaffolding step additionally needs PowerShell 7 (`pwsh`) on
PATH; without it, hooks are still wired and only the scaffold step is skipped.

```!
ARGS="$ARGUMENTS"
SLUG=""
FORCE=""

# Parse --slug <name> and --force from the argument string.
set -- $ARGS
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) shift; SLUG="$1" ;;
    --force) FORCE="1" ;;
    *) echo "[aem-init] warning: ignoring unrecognized argument '$1'" >&2 ;;
  esac
  shift
done

# 1. Confirm we are inside a git repository (exit 1). Plain git, no pwsh.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "[aem-init] not a git repository -- run from your repo root or 'git init' first." >&2
  exit 1
fi

# 2. Resolve the plugin root + hooks dir (exit 3). CLAUDE_PLUGIN_ROOT is
# substituted inline because this is SKILL content (it would arrive empty in a
# slash command -- the v2.0.0 bug).
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
if [ -z "$PLUGIN_ROOT" ]; then
  echo "[aem-init] plugin root did not resolve -- run from inside an installed plugin." >&2
  exit 3
fi
HOOKS_DIR="$PLUGIN_ROOT/hooks"
if [ ! -d "$HOOKS_DIR" ]; then
  echo "[aem-init] plugin hooks directory not found at $HOOKS_DIR" >&2
  exit 3
fi

# Forward-slash form for cross-OS git compatibility. tr's octal '\134' (a single
# backslash) is used instead of the literal '\\' SET, which GNU tr warns about
# as non-portable; the octal form converts identically with no stderr noise.
HOOKS_VALUE=$(printf '%s' "$HOOKS_DIR" | tr '\134' '/')

# 3. Inspect any existing core.hooksPath; refuse to clobber a foreign value
# without --force (Invariant-1 no silent clobber; exit 2). Normalize both sides
# (forward slashes, trimmed trailing separator, lower-cased) before comparing.
EXISTING=$(git config --get core.hooksPath 2>/dev/null || true)
norm() { printf '%s' "$1" | tr '\134' '/' | sed 's:/*$::' | tr 'A-Z' 'a-z'; }
EXISTING_NORM=$(norm "$EXISTING")
PLUGIN_NORM=$(norm "$HOOKS_VALUE")
DEFAULT_NORM=$(norm ".git/hooks")
if [ -n "$EXISTING_NORM" ] && [ "$EXISTING_NORM" != "$PLUGIN_NORM" ] \
   && [ "$EXISTING_NORM" != "$DEFAULT_NORM" ] && [ -z "$FORCE" ]; then
  echo "[aem-init] core.hooksPath conflict (currently '$EXISTING') -- re-run with --force to overwrite." >&2
  exit 2
fi

# 4. Wire the hook. This is the core action: a single plain-git command, no
# pwsh, no -ExecutionPolicy, nothing the auto-mode classifier denies.
if ! git config core.hooksPath "$HOOKS_VALUE"; then
  echo "[aem-init] internal error: failed to set core.hooksPath" >&2
  exit 4
fi
echo "[aem-init] core.hooksPath set to: $HOOKS_VALUE"

# 5. Optional --slug scaffolding via the backing script. This is the ONLY step
# that touches pwsh, and it runs with the plain -File shape and no policy
# override. Any nonzero scaffold exit maps to 4 (D-S1).
if [ -n "$SLUG" ]; then
  SCRIPT="$PLUGIN_ROOT/scripts/aem-init.ps1"
  if [ ! -f "$SCRIPT" ]; then
    echo "[aem-init] internal error: backing script not found at $SCRIPT" >&2
    exit 4
  fi
  if ! command -v pwsh >/dev/null 2>&1; then
    echo "[aem-init] cannot scaffold --slug: pwsh not found on PATH (hooks are wired; re-run with pwsh installed to scaffold)." >&2
    exit 4
  fi
  pwsh -NoProfile -File "$SCRIPT" -PluginRoot "$PLUGIN_ROOT" -Slug "$SLUG" -ScaffoldOnly
  SC=$?
  if [ "$SC" -ne 0 ]; then
    echo "[aem-init] scaffolding failed (scaffold step exit $SC)." >&2
    exit 4
  fi
fi

# 6. TODO(T-006): tail-call the shared 4-check health routine here. T-006
# creates scripts/aem-doctor.ps1 and REPLACES this TODO block with the real
# tail call -- the doctor script run plainly (same invocation shape as the
# scaffold call above, no policy-override flag), passing -PluginRoot
# "$PLUGIN_ROOT". Until then, print a plain summary so the skill stays usable
# standalone.

echo "[aem-init] done -- run /aem-doctor any time to re-check this repo's setup."
exit 0
```
