# Hooks reference

This document describes the three PowerShell hooks used in the build system. Hooks are registered in `~/.claude/settings.json` and executed synchronously by the Claude Code harness on the corresponding event. For the end-user launch procedure, see [RUN_BOOK.md](../../planning/orchestrator-and-build-system/RUN_BOOK.md). For architecture, see [overview.md](overview.md).

---

## How hooks are invoked (plain `pwsh -File`, no `-ExecutionPolicy Bypass`)

Every hook -- both the plugin's `hooks.json` entries (run by Claude Code's hook runner) and the git `pre-commit` shim (run by git) -- invokes its `.ps1` with the plain form:

```text
pwsh -NoProfile -File <hook>.ps1
```

There is no `-ExecutionPolicy Bypass` flag anywhere in the hook surface. That flag was only ever solving a **mark-of-the-web (MOTW)** problem -- the `Zone.Identifier` alternate-data-stream Windows attaches to files *downloaded from the internet*, which `RemoteSigned` then refuses to run without an override. But the plugin's files are not downloaded; Claude Code installs the plugin via a **clean git clone**, and git-written files carry **no MOTW stream**. Empirically verified: under the Windows default execution policy (`RemoteSigned`), a clean local `.ps1` runs with plain `-File` and exits 0 -- only an MOTW-tagged file is blocked.

So dropping `-ExecutionPolicy Bypass` costs **zero functionality** on a normal machine: the hooks run identically. What the flag *did* cost was a classifier-hostile command shape (`pwsh ... -ExecutionPolicy Bypass ... .ps1` reads like the evasion pattern malware uses) and a maintenance trap. Removing it is strictly better. The one machine where scripts genuinely will not run -- a `Restricted` / `AllSigned` box locked down by IT policy -- is handled at setup time by `/aem-doctor`, which detects the policy via a benign inline probe and prints the one-line fix rather than letting a hook fail with a raw "running scripts is disabled" wall. The plugin never circumvents a locked-down posture; it fails cleanly and legibly.

---

## state-writer.ps1 (SessionEnd)

**Path:** `~/.claude/hooks/state-writer.ps1`

**Trigger event:** `SessionEnd` — fires when a Claude Code session exits normally (user closes the session, session completes, etc.). Does NOT fire on hard kills (process termination, laptop-lid close, network drop); the SessionStart sweep covers that gap.

**Allowlist:** Scoped to specific project slugs listed inside the script. The hook no-ops silently outside the allowlist so unrelated projects are not affected.

**Meaningful-work heuristic:** Before writing anything, the hook checks whether the session did real work:

- Any commits ahead of the merge-base for the current branch (i.e., the session made at least one commit), OR
- Any unstaged or staged file modifications in the tracked paths, OR
- Any file under `planning/<slug>/tasks/` has mtime within the last 4 hours.

If none of these conditions are true, the hook exits without writing or committing — no noise commits for sessions that only read files.

**What it writes:**

- `planning/<slug>/plan-state.md` — overwrites with current state (phase, status, last updated).
- `README.md` — overwrites the `## Current state` and `## Next action` sections.
- `planning/<slug>/.state-auto-log` — appends one line: `<ISO UTC> | trigger=SessionEnd | pid=<PID> | files=plan-state.md,README.md | rationale=<one-line> | commit=<SHA>`.

**Output channel:** The hook runs synchronously. Any stdout/stderr is surfaced to the user in the Claude Code session transcript. On success, no output is expected (silent is normal). On error, the hook emits a diagnostic line.

**Error semantics:** If the hook fails (parse error, git failure, encoding issue), it exits non-zero. The harness captures the exit code and surfaces it in `hookSpecificOutput`. The session can still close; the hook failure does not block the exit. The `.state-auto-log` will have a gap for this session, observable on the next drift-check.

**Forensic log expectations:** Every session that does real work (per the heuristic above) should produce exactly one `.state-auto-log` entry with a non-empty `commit=` field. Sessions with no meaningful work produce no entry. A gap in the log (a session with commits but no log entry) indicates either a hook failure or a hard-exit path — the SessionStart sweep handles the latter.

---

## state-writer-sweep.ps1 (SessionStart)

**Path:** `~/.claude/hooks/state-writer-sweep.ps1`

**Trigger event:** `SessionStart` — fires when a Claude Code session opens.

**Allowlist:** Same slug-scoped allowlist as `state-writer.ps1`. No-ops outside it.

**Purpose:** Covers the hard-exit gap. When a session closes via process-kill, laptop-lid, or network drop, `SessionEnd` does not fire. On the next session open, the sweep checks whether the prior session's work was reflected in the state surfaces:

1. Reads the last entry in `.state-auto-log`.
2. Compares that entry's commit SHA against the current `git log` for the prior session's range.
3. If commits exist in that range that are NOT reflected in the log, the sweep runs the same writer logic as `state-writer.ps1` against that git range and commits.

If the prior session was already reflected (normal case), the sweep exits silently with no write.

**Output channel:** Same as `state-writer.ps1`. Silent on success; diagnostic on failure.

**Error semantics:** Same as `state-writer.ps1`. Non-zero exit does not block session open.

**Forensic log expectations:** When the sweep fires and writes state, it appends a `.state-auto-log` entry with `trigger=SessionStart-sweep` to distinguish it from a normal SessionEnd write.

---

## state-drift-check.ps1 (UserPromptSubmit)

**Path:** `${CLAUDE_PLUGIN_ROOT}/hooks/state-drift-check.ps1` (wired via `hooks/hooks.json`).

**Trigger event:** `UserPromptSubmit` — fires on every user prompt submission in a session.

**Activation:** Resolves the repo by walking up from the working directory to the nearest `.git`/`planning` root, and no-ops silently outside any repo (same convention as `state-writer.ps1`). Set the optional `STATE_DRIFT_CHECK_ALLOW_ROOT` environment variable to pin activation to a single checkout. (Before 2.4.0 the hook carried a hard-coded author-machine allowlist and therefore no-opped for every consumer; 2.4.0 genericized it.)

**Purpose:** Surfaces drift between a project's `planning/<slug>/` documents and ground truth, across seven checks:

| Check | Catches |
|---|---|
| A | `plan-ledger.md` newer than `plan-state.md` (a ledger edit not yet reflected in state) |
| B | version-pointer drift — `Latest PRD/spec version` in `plan-state.md` vs the `prd.md`/`spec.md` frontmatter |
| C | a referenced `agents/<name>.md` that exists in neither the consumer's `~/.claude/agents/` nor the plugin's `agents/` |
| E | a `Next action:` / `Open-PR stack:` branch token (backtick-quoted **or** plain-text slashy) that resolves to a ref already merged into `main` — with a past-tense gate so historical "landed/merged" mentions stay silent |
| F | a `build/`/`release/`/`publish/<slug>` branch merged into `main` while the slug's `Lifecycle stage:` is still non-terminal |
| G | a `Next action:` that still tells the operator to approve/decline gate findings after the gate queue has drained (all decided) |

Plus a wave-closure nudge: a `planning/<slug>/implementation/wave-N/` commit in the recent window with no matching `plan-state.md` update suggests the wave was closed without refreshing state.

**Mechanism:** Checks A–C/G read planning files directly; checks E/F resolve git refs locally (no network, no `gh`). Drift is surfaced via `hookSpecificOutput.additionalContext` — a string injected at the top of the next AI response as an amber warning. The hook never writes files and never commits.

**Output channel:** `hookSpecificOutput.additionalContext` (injected into the AI context, not terminal stdout). The hook does not write files and does not commit.

**Error semantics:** If the hook fails, the session prompt proceeds normally. The hook is advisory only; a failure means the drift check was skipped, not that the session is blocked.

**Forensic log expectations:** This hook writes nothing to `.state-auto-log`. Drift events are surfaced only in the AI session context.

---

## Why no Stop hook

The Stop event fires when the Claude Code process exits. It might seem natural to add a Stop hook as a belt-and-suspenders backup for SessionEnd — "if SessionEnd missed the exit, Stop will catch it."

**This is the wrong design.** The D-S10 decision record explicitly refuses a Stop hook fallback for the following reason:

A `state-writer.ps1` SessionEnd hook creates a falsifiable, observable contract: exactly one commit per session that does real work. The `.state-auto-log` makes this auditable. If a session's commit is missing, the gap is immediately visible.

Adding a Stop hook as a fallback converts that falsifiable contract into **unfalsifiable belt-and-suspenders**. If SessionEnd fires, great. If not, Stop fires. The system looks correct in both cases. But the SessionEnd channel failures are now permanently masked — you can never tell from the log whether SessionEnd fired or whether the Stop backup fired, because both produce the same output. The only observable consequence of a silent channel failure has been erased.

The SessionStart sweep (`state-writer-sweep.ps1`) is the correct recovery path. It fires on the NEXT session open, checks for unwritten prior work, and writes it with a `trigger=SessionStart-sweep` marker — making the missed SessionEnd visible in the log rather than hiding it. The existing `state-drift-check.ps1` (UserPromptSubmit) is the only documented recovery channel for plan-state-level drift.

**Rule:** do not add a Stop hook to this build. If SessionEnd has reliability issues, fix the SessionEnd channel. The sweep + drift-check is the recovery layer; belt-and-suspenders on the primary channel is not. This prohibition is codified as cross-task invariant 5.
