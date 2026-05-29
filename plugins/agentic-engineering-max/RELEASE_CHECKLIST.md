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

    ```pwsh
    git subtree split --prefix=plugin/ -b release/vX.Y.Z
    ```

   Expected: prints the new commit SHA. No errors.

2. Confirm the `public` remote is configured AND points at the correct repo, then push the release branch:

    ```pwsh
    git remote -v | Select-String -Pattern '^public\s+https://github\.com/GhostlyGawd/agentic-engineering-max(\.git)?\s'
    ```

   Expected: at least one matching line. The pattern requires both the remote NAME (`public`) and the expected URL on the same line, so a `public` remote pointed at the wrong repo will NOT match (returns empty). If empty, configure first:

    ```pwsh
    git remote add public https://github.com/GhostlyGawd/agentic-engineering-max.git
    ```

   Then push:

    ```pwsh
    git push public release/vX.Y.Z:refs/heads/release/vX.Y.Z
    ```

3. Clone the public repo into a fresh temp dir:

    ```pwsh
    $tmp = Join-Path $env:TEMP ("aem-release-smoke-" + (Get-Random))
    git clone --branch release/vX.Y.Z https://github.com/GhostlyGawd/agentic-engineering-max.git $tmp
    Set-Location $tmp
    ```

4. (Informational only -- the binary gate is Step 5.) Eyeball the top-level for orientation:

    ```pwsh
    Get-ChildItem -Force
    ```

   For the current subtree shape, top-level should contain only `.claude-plugin/` (holding `marketplace.json`), `plugins/`, and the clone's own `.git/`. The shipped `README.md`, `LICENSE`, `CHANGELOG.md`, etc. live UNDER `plugins/agentic-engineering-max/`, NOT at the subtree root. This step is a sanity glance; do NOT treat a clean-looking eyeball as the pass -- Step 5a is the authoritative gate.

5. Three leakage checks. All three must return empty.

   5a. Top-level allowlist check (AUTHORITATIVE gate -- catches ANY unexpected top-level entry, including future-renamed internal dirs the denylist below would miss):

    ```pwsh
    $expectedTop = @('.claude-plugin', 'plugins', '.git', 'README.md', 'LICENSE', 'CHANGELOG.md', 'CONTRIBUTING.md', '.gitignore')
    Get-ChildItem -Force | Where-Object { $_.Name -notin $expectedTop }
    ```

   Expected output: empty. Any hit is a leak OR a legitimately new top-level artifact. If the hit is a genuinely new shipped public-repo file (e.g. a newly added top-level `LICENSE`), extend `$expectedTop` and re-run; if it is an internal artifact (`planning/`, `tasks/`, `handoffs/`, `bin/`, top-level `tests/`), it leaked through the subtree split -- RELEASE BLOCKER.

   5b. Recursive forbidden-directory deep check (defense-in-depth; catches a forbidden dir nested anywhere outside the plugin's own tree):

    ```pwsh
    Get-ChildItem -Recurse -Directory -Force | Where-Object { $_.Name -in @('planning','tasks','handoffs','bin','tests') -and $_.FullName -notlike '*\plugins\agentic-engineering-max\*' }
    ```

   Expected output: empty. The `-notlike` carve-out excludes the plugin's own `plugins/agentic-engineering-max/tests/` directory, which IS expected and shipped. Any other hit indicates a forbidden directory leaked through the subtree split.

   5c. Content-based check (catches internal-tracking filenames anywhere in the tree):

    ```pwsh
    Get-ChildItem -Recurse -File | Select-String -Pattern 'plan-ledger\.md|plan-state\.md|task-board\.md' -List
    ```

   Expected output: empty. Any hit indicates an internal file leaked through the subtree split.

6. Cleanup:

    ```pwsh
    Set-Location ..
    Remove-Item -Recurse -Force $tmp
    git push public --delete release/vX.Y.Z
    git branch -D release/vX.Y.Z
    ```

Pass criteria (binary, authoritative): Step 5a allowlist check returns empty AND Step 5b deep denylist returns empty AND Step 5c content grep returns empty. Step 4 is informational orientation only and is not a gate.

## Invariant 7 -- Uninstall cleanliness

Goal: confirm the plugin's documented uninstall procedure reverses every operator-side change without leaving stale config. The shipped `README.md` ("Uninstall" section) documents uninstall as a deliberate TWO-step operation: (1) `/plugin uninstall agentic-engineering-max` removes the plugin, and (2) in each repo where `/aem-init` ran, the operator runs `git config --unset core.hooksPath` to reverse the per-repo hook wiring. `/plugin uninstall` is a Claude Code built-in that removes plugin files from `~/.claude`; it does NOT (and architecturally cannot) walk every repo where you set a per-repo `core.hooksPath`, so the manual unset is by design, not a bug. This invariant verifies that the full documented procedure leaves a clean repo, while still falsifying any case where the documented unset fails to clear the config or where a commit breaks afterward.

Steps:

1. Create a fresh temp project and initialize git:

    ```pwsh
    $proj = Join-Path $env:TEMP ("aem-uninstall-smoke-" + (Get-Random))
    New-Item -ItemType Directory -Path $proj | Out-Null
    Set-Location $proj
    git init -q
    git config user.email 'release-smoke@example.com'
    git config user.name  'release-smoke'
    ```

2. Confirm there is no prior `core.hooksPath` set:

    ```pwsh
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

    ```pwsh
    git config --get core.hooksPath
    ```

   Expected: a path under `${CLAUDE_PLUGIN_ROOT}/hooks` (or its resolved absolute path).

5. Make a test commit to verify hooks fire:

    ```pwsh
    Set-Content test.txt "hello" -Encoding UTF8
    git add test.txt
    git commit -q -m "smoke commit"
    ```

   Expected: commit succeeds (no hook blocks).

6. Step 1 of the documented uninstall -- remove the plugin (do NOT touch `core.hooksPath` yet; Step 7 must observe the genuine post-removal state before any remediation):

    ```text
    /plugin uninstall agentic-engineering-max
    ```

   (This command form matches the shipped `README.md` "Uninstall" section. The spec acceptance criterion writes it as `<name>@<marketplace>`; the bare-name form here is intentional, kept consistent with the operator-facing README so the checklist and the doc the operator actually follows never disagree.)

7. Diagnostic probe -- observe `core.hooksPath` with NO remediation between Step 6 and this probe. This records the true effect of `/plugin uninstall` alone:

    ```pwsh
    git config --get core.hooksPath
    ```

   Expected per the documented design: STILL SET to the hooks path (because `/plugin uninstall` does not walk per-repo git config -- the manual unset in Step 8 is the documented second step). Record the observed value.
   - If still set: this is the documented behavior; proceed to Step 8.
   - If EMPTY: `/plugin uninstall` has begun auto-unwinding `core.hooksPath` -- a behavior change from what the README documents. This is NOT a release blocker, but it means the README's manual-unset instruction is now redundant and should be updated. File a doc-drift note and continue.

8. Step 2 of the documented uninstall -- run the manual unset exactly as the shipped README instructs the operator to:

    ```pwsh
    git config --unset core.hooksPath
    ```

   This is the documented remediation, applied transparently AFTER the Step 7 observation -- not a silent mask of a hidden failure. If Step 7 already showed empty, this command is a harmless no-op (exit code 5, "key not present") and the procedure still passes.

9. Pass-gate probe -- confirm the FULL documented procedure left no stale config:

    ```pwsh
    git config --get core.hooksPath
    ```

   Expected: empty output, exit code 1. **A non-empty value here is a RELEASE BLOCKER**: it means the documented uninstall procedure (Steps 6 + 8 together) failed to clear `core.hooksPath` -- e.g. it was set at a scope the documented unset does not reach, or set under a different key. Do NOT proceed to the tag/push step. Capture the observed value and the scope (`git config --show-origin --get-all core.hooksPath`), file a bug against the uninstall procedure or `/aem-init`, and re-run invariant 7 only after it is fixed.

10. Confirm a subsequent `git commit` still works (no orphan hook reference left behind):

    ```pwsh
    Set-Content test2.txt "world" -Encoding UTF8
    git add test2.txt
    git commit -q -m "post-uninstall smoke commit"
    ```

   Expected: commit succeeds. A failure here means the documented uninstall left a dangling hook reference -- a release blocker even if Step 9 showed empty.

11. Cleanup:

    ```pwsh
    Set-Location ..
    Remove-Item -Recurse -Force $proj
    ```

Pass criteria: after the full documented two-step uninstall (Step 6 `/plugin uninstall` + Step 8 documented `git config --unset core.hooksPath`), Step 9 returns empty AND Step 10 commits cleanly. Either criterion failing is a release blocker. The Step 7 diagnostic is informational (records whether `/plugin uninstall` auto-unwinds); it never gates the release, but an EMPTY Step 7 result must be logged as a README doc-drift item.

## Demo asset realness check (T-022 / T-033 final gate)

Per decision D-S7 (anchored in `spec.md`, "D-S7 -- Demo GIF + screenshot deferral"; traces to PRD section 11 item 8), the build inserts 1x1 placeholder assets at `assets/demo.gif` and `assets/screenshots/*.png` so the file-existence DoD criteria pass before the operator has recorded real demos. The real assets MUST land before the vX.Y.Z tag.

Steps:

1. Check `plugin/plugins/agentic-engineering-max/assets/demo.gif` file size:

    ```pwsh
    (Get-Item 'plugin\plugins\agentic-engineering-max\assets\demo.gif').Length
    ```

   Pass criterion: `> 10000` bytes (real animated GIFs are at least a few tens of KB; the 1x1 placeholder is under 1 KB).

2. Check each screenshot under `plugin/plugins/agentic-engineering-max/assets/screenshots/`:

    ```pwsh
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

## Public hotfix (do NOT full-split while a future major is parked)

This section is for patching an ALREADY-RELEASED line on the public repo (e.g. a broken manifest that blocks install) WITHOUT cutting a new release -- and specifically without dragging in unreleased work-in-progress.

Why this exists: the `github`-source marketplace clones the public repo's DEFAULT BRANCH (`main`) HEAD, not the tag. So whatever sits on public `main` is what every installer gets. A full `git subtree split --prefix=plugin/` push to public `main` publishes the ENTIRE current `plugin/` tree -- including any unreleased next-major work (e.g. a cross-platform port) parked in the source tree behind an unmet gate. That would silently ship un-verified code to every installer under the frozen released-version banner.

Worked precedent: 2026-05-23, the v1.0.0 `plugin.json` `repository`-as-object install-blocker. A `released-tag -> fresh-split-tip` diff showed 26 files would move; only 3 were intended. The fix was applied surgically instead.

Procedure (surgical patch, NOT a subtree split):

1. Land the fix at source first (Dev_006 `plugin/`), with its regression test, merged to Dev_006 `main`.

2. Fresh-clone the public repo's release branch into a temp dir (a fresh clone has its own `.git` and no `core.hooksPath`, so the Dev_006 pre-commit hooks -- which reference a `bin/` absent from the flattened public tree -- do not interfere):

    ```pwsh
    $tmp = Join-Path $env:TEMP ("aem-public-hotfix-" + (Get-Random))
    git clone --quiet --branch main https://github.com/GhostlyGawd/agentic-engineering-max.git $tmp
    ```

3. For EACH intended file, confirm its diff vs the released base is exactly the intended change before copying it in. The authoritative check: the per-file `git diff <released-tag-or-base> <source-split-tip> -- <path>` (run in Dev_006) must contain ONLY the intended hunks -- no unreleased edits riding along. Then copy that file from the Dev_006 source tree into the matching path under `$tmp/plugins/agentic-engineering-max/`.

4. Stage and CONFIRM the staged diff is exactly the intended file set (this is the gate against accidental over-publish):

    ```pwsh
    git -C $tmp add -A
    git -C $tmp diff --cached --stat   # must list ONLY the intended files
    ```

5. Commit and push to public `main`:

    ```pwsh
    git -C $tmp commit -m "fix: <summary>"
    git -C $tmp push origin main
    ```

6. Verify the live public `main` HEAD now carries the fix, then clean up:

    ```pwsh
    git -C $tmp show HEAD:plugins/agentic-engineering-max/.claude-plugin/plugin.json
    Remove-Item -Recurse -Force $tmp
    ```

7. Tell installers to refresh their local marketplace clone before re-installing: `/plugin marketplace update agentic-engineering-max` (or remove + re-add), then `/plugin install ...`. A stale local marketplace clone still holds the pre-fix copy.

Consequence accepted: public `main` now diverges from the Dev_006 subtree history by this surgical commit. The next real `git subtree split` release reconciles it. This is the correct trade-off while a next-major is parked behind an unmet gate.

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
