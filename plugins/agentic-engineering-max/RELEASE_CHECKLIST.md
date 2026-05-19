# Release Checklist

This checklist gates a release of `agentic-engineering-max`. The automated test suite (`tests/run-all-tests.ps1`) covers invariants 1-5. Invariants 6 and 7 require a manual smoke pass because they involve filesystem state across two separate git repos plus filesystem interactions outside the unit-test boundary. Walk every checkbox before tagging `vX.Y.Z`.

## Pre-flight

- [ ] On `main`, working tree clean: `git status` returns "nothing to commit, working tree clean".
- [ ] `tests/run-all-tests.ps1` exits 0 (all invariants 1-5 pass).
- [ ] `CHANGELOG.md` vX.Y.Z entry exists at the top; the `<release date YYYY-MM-DD>` placeholder has been replaced with today's date.
- [ ] `plugin.json` `version` and `marketplace.json` plugins[0].version both equal the vX.Y.Z you are about to tag.

## Invariant 6 -- Pattern A subtree-leak verification

Goal: confirm `git subtree split` produces a clean public-repo HEAD with NO internal Dev_006 files (no `planning/`, no `tasks/`, no internal handoffs, no `bin/`, no top-level `tests/` outside the plugin's own `plugins/agentic-engineering-max/tests/`).

Steps:

1. From the Dev_006 repo root, run the subtree split:

    ```powershell
    git subtree split --prefix=plugin/ -b release/vX.Y.Z
    ```

   Expected: prints the new commit SHA. No errors.

2. Confirm the `public` remote is configured, then push the release branch:

    ```powershell
    git remote -v | Select-String -Pattern '^public\s'
    ```

   Expected: at least one line beginning with `public` pointing at `github.com/GhostlyGawd/agentic-engineering-max`. If empty, configure first:

    ```powershell
    git remote add public https://github.com/GhostlyGawd/agentic-engineering-max.git
    ```

   Then push:

    ```powershell
    git push public release/vX.Y.Z:refs/heads/release/vX.Y.Z
    ```

3. Clone the public repo into a fresh temp dir:

    ```powershell
    $tmp = Join-Path $env:TEMP ("aem-release-smoke-" + (Get-Random))
    git clone --branch release/vX.Y.Z https://github.com/GhostlyGawd/agentic-engineering-max.git $tmp
    Set-Location $tmp
    ```

4. List the top-level directory. Verify NO `planning/`, NO `tasks/`, NO `handoffs/`, NO `bin/` are present:

    ```powershell
    Get-ChildItem -Force
    ```

   Expected presence (top-level): `.claude-plugin/`, `plugins/`, `README.md`, possibly `LICENSE` and other shipped artifacts. **Forbidden at the repo top-level:** `planning/`, `tasks/`, `handoffs/`, `bin/`, `tests/` (the workspace-only test dir; NOTE: the plugin's own `plugins/agentic-engineering-max/tests/` directory IS expected and is NOT what this check forbids). Also forbidden anywhere: `tests/test-pre-commit-hook.ps1` (workspace-only).

5. Directory + content leakage checks. Both must return empty.

   5a. Path-based check (catches any forbidden directory regardless of file contents):

    ```powershell
    Get-ChildItem -Recurse -Directory -Force | Where-Object { $_.Name -in @('planning','tasks','handoffs','bin') -and $_.FullName -notlike '*\plugins\agentic-engineering-max\*' }
    ```

   Expected output: empty. Any hit indicates a forbidden top-level directory leaked through the subtree split.

   5b. Content-based check (catches internal-tracking filenames anywhere in the tree):

    ```powershell
    Get-ChildItem -Recurse -File | Select-String -Pattern 'plan-ledger\.md|plan-state\.md|task-board\.md' -List
    ```

   Expected output: empty. Any hit indicates an internal file leaked through the subtree split.

6. Cleanup:

    ```powershell
    Set-Location ..
    Remove-Item -Recurse -Force $tmp
    git push public --delete release/vX.Y.Z
    git branch -D release/vX.Y.Z
    ```

Pass criteria: Step 4 shows no forbidden directories; Step 5a returns empty; Step 5b grep returns empty.

## Invariant 7 -- Uninstall cleanliness

Goal: confirm the plugin uninstall reverses every operator-side change without leaving stale config.

Steps:

1. Create a fresh temp project and initialize git:

    ```powershell
    $proj = Join-Path $env:TEMP ("aem-uninstall-smoke-" + (Get-Random))
    New-Item -ItemType Directory -Path $proj | Out-Null
    Set-Location $proj
    git init -q
    git config user.email 'release-smoke@example.com'
    git config user.name  'release-smoke'
    ```

2. Confirm there is no prior `core.hooksPath` set:

    ```powershell
    git config --get core.hooksPath
    ```

   Expected: empty output, exit code 1.

3. Launch Claude Code in this directory (`claude`), install the plugin:

    ```text
    /plugin marketplace add GhostlyGawd/agentic-engineering-max
    /plugin install agentic-engineering-max@agentic-engineering-max
    /aem-init
    ```

4. Confirm `/aem-init` set `core.hooksPath`:

    ```powershell
    git config --get core.hooksPath
    ```

   Expected: a path under `${CLAUDE_PLUGIN_ROOT}/hooks` (or its resolved absolute path).

5. Make a test commit to verify hooks fire:

    ```powershell
    Set-Content test.txt "hello" -Encoding UTF8
    git add test.txt
    git commit -q -m "smoke commit"
    ```

   Expected: commit succeeds (no hook blocks).

6. Uninstall the plugin (do NOT manually adjust `core.hooksPath` first -- the whole point of Step 7 is to detect whether `/plugin uninstall` left orphan git config behind):

    ```text
    /plugin uninstall agentic-engineering-max
    ```

7. Probe `core.hooksPath` directly (no remediation between Step 6 and this probe). This is the invariant-7 falsifier:

    ```powershell
    git config --get core.hooksPath
    ```

   Expected: empty output, exit code 1. **A non-empty value here is a RELEASE BLOCKER**: it proves `/plugin uninstall` did not unwind `core.hooksPath`, which means real operators will be left with a stale hook path after uninstall. Do NOT proceed to the tag/push step. Capture the observed value, file a bug against the uninstall flow, and re-run invariant 7 only after the uninstall is fixed. Manually running `git config --unset core.hooksPath` here would mask the bug; do not do it as part of release gating.

8. Confirm subsequent `git commit` still works (no orphan hook reference). Only meaningful if Step 7 returned empty; if Step 7 failed, this step is moot until the uninstall is fixed.

    ```powershell
    Set-Content test2.txt "world" -Encoding UTF8
    git add test2.txt
    git commit -q -m "post-uninstall smoke commit"
    ```

   Expected: commit succeeds.

9. Cleanup:

    ```powershell
    Set-Location ..
    Remove-Item -Recurse -Force $proj
    ```

Pass criteria: Step 7 returns empty (`core.hooksPath` correctly unwound by `/plugin uninstall` alone -- no manual remediation) AND Step 8 commits cleanly. Either criterion failing is a release blocker.

## Demo asset realness check (T-022 / T-033 final gate)

Per D-S7, the build inserts 1x1 placeholder assets at `assets/demo.gif` and `assets/screenshots/*.png` so the file-existence DoD criteria pass before the operator has recorded real demos. The real assets MUST land before the vX.Y.Z tag.

Steps:

1. Check `plugin/plugins/agentic-engineering-max/assets/demo.gif` file size:

    ```powershell
    (Get-Item 'plugin\plugins\agentic-engineering-max\assets\demo.gif').Length
    ```

   Pass criterion: `> 10000` bytes (real animated GIFs are at least a few tens of KB; the 1x1 placeholder is under 1 KB).

2. Check each screenshot under `plugin/plugins/agentic-engineering-max/assets/screenshots/`:

    ```powershell
    Get-ChildItem 'plugin\plugins\agentic-engineering-max\assets\screenshots\*.png' | Select-Object Name, Length
    ```

   Pass criterion: every PNG > 5000 bytes. The placeholders ship at well under 1 KB.

3. Open each asset and visually confirm against this concrete shot list (binary checks, not interpretive):
   - `demo.gif`: at minimum one frame visibly contains the literal text `Board snapshot --` (the `task-board.md` header signature) AND a later frame shows a status row transitioning into `in_review` or `done`. Length 30-90 seconds per D-S7.
   - `board.png`: frame contains the literal text `Board snapshot --` AND at least one task ID matching `T-\d+`.
   - `escalation.png`: frame contains the literal string `escalated` OR `BLOCKED` AND a worker_id label (e.g. `worker-A`).
   - `review-output.png`: frame contains the literal heading `Review iteration` AND a per-stance verdict line (e.g. `Pragmatist:`, `Falsificationist:`, `Hermeneut:`, or `Bayesian:`).

Pass criteria: every asset > size threshold AND every literal-text check above is visually confirmable.

## Tag and push

- [ ] `git tag vX.Y.Z`
- [ ] `git push public vX.Y.Z`
- [ ] Verify the GitHub release surface auto-creates a draft from the tag.
- [ ] Edit the GitHub release draft to paste the CHANGELOG.md vX.Y.Z entry as the release notes body.
- [ ] Publish the GitHub release.

## Post-release smoke

- [ ] Run the marketplace add+install flow once from a fresh test environment:

    ```text
    /plugin marketplace add GhostlyGawd/agentic-engineering-max
    /plugin install agentic-engineering-max@agentic-engineering-max
    /aem-init
    ```

  Expected: all three commands succeed; `/aem-init` prints its next-action summary.

- [ ] On the public repo, confirm the marketplace listing shows the new version at `https://github.com/GhostlyGawd/agentic-engineering-max`.

- [ ] Update the pinned `[v2-roadmap]` issue if the v2-adoption-threshold counts changed during this release cycle.
