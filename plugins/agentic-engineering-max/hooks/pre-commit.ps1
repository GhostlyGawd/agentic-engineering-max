# hooks/pre-commit.ps1
#
# Purpose:
#   Pre-commit enforcement of the state-surface discipline. When any
#   planning/<slug>/plan-ledger.md is staged, require that the matching
#   planning/<slug>/plan-state.md is also staged. Blocks the commit with
#   an actionable message if the mirror is missing.
#
# Why this exists (failure mode this patches):
#   The UserPromptSubmit drift-check hook at
#   ~/.claude/hooks/state-drift-check.ps1 detects ledger > state mtime
#   drift, but only *after* the bad commit has already been made (often
#   already pushed). Phase-owning agents (interviewer, prd-writer,
#   spec-writer, wave-closer) carry the DoD obligation to bump both
#   surfaces, but ad-hoc operator-direct ledger edits (bug fixes,
#   typos, post-wave patches) bypass that path entirely. This hook
#   closes the gap at git's native enforcement point.
#
# Install (per-clone):
#   git config core.hooksPath hooks
#
# Escape hatch:
#   git commit --no-verify
#   (for genuine ledger-only edits like typos or formatting; requires
#    conscious operator choice.)

$ErrorActionPreference = 'Stop'

# Staged files: Added, Copied, Modified, Renamed. Excludes deletions
# (a deletion of plan-ledger.md alone is a different shape and not the
# target of this hook).
$stagedRaw = & git diff --cached --name-only --diff-filter=ACMR
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine('pre-commit: git diff failed; aborting hook to avoid false-pass.')
    exit 1
}
if (-not $stagedRaw) { exit 0 }

# Normalize to array of forward-slash paths (git already uses forward slashes).
$staged = @($stagedRaw | Where-Object { $_ })

# Find ledger edits, group by slug, check for matching state edit.
$violations = New-Object System.Collections.Generic.List[object]
foreach ($f in $staged) {
    if ($f -match '^planning/([^/]+)/plan-ledger\.md$') {
        $slug = $Matches[1]
        $statePath = "planning/$slug/plan-state.md"
        if ($staged -notcontains $statePath) {
            $violations.Add([pscustomobject]@{
                Slug   = $slug
                Ledger = $f
                State  = $statePath
            })
        }
    }
}

# spec-lint pass: scan any staged planning/**/*.md files for assertion
# drifts (char-count claims that don't match the quoted string; task-count
# claims that don't match the inventory). The script prints findings to
# stderr and exits 1 on any finding.
$plannedMd = @($staged | Where-Object { $_ -match '^planning/.*\.md$' })
$specLintExit = 0
if ($plannedMd.Count -gt 0) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $specLint = Join-Path $repoRoot 'bin\spec-lint.ps1'
    if (Test-Path $specLint) {
        & $specLint @plannedMd
        $specLintExit = $LASTEXITCODE
    }
}

# Wildcard-staging guard: a worker or reviewer tick touches exactly ONE
# task's frontmatter (its claimed task). A commit that stages 2+ distinct
# planning/<slug>/tasks/task-*.md files is the signature of `git add -A` /
# `git add .` sweeping in another concurrent worker's in-progress edits
# (the 2026-05-19 swarm incident where worker-C's T-016 commit swept in
# worker-A's mid-edit task-006.md). Block it. Legitimate multi-task
# commits (initial board seeding) use `git commit --no-verify`.
$stagedTaskFiles = @($staged | Where-Object { $_ -match '^planning/[^/]+/tasks/task-[^/]+\.md$' })
$wildcardStaging = ($stagedTaskFiles.Count -ge 2)

if ($violations.Count -eq 0 -and $specLintExit -eq 0 -and -not $wildcardStaging) { exit 0 }
if ($violations.Count -eq 0 -and $specLintExit -ne 0) { exit 1 }
if ($violations.Count -eq 0 -and $wildcardStaging) {
    $bar = '=' * 64
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine($bar)
    [Console]::Error.WriteLine('WILDCARD-STAGING GUARD (pre-commit hook)')
    [Console]::Error.WriteLine($bar)
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine(("This commit stages {0} task-*.md files:" -f $stagedTaskFiles.Count))
    foreach ($t in $stagedTaskFiles) { [Console]::Error.WriteLine(("  " + $t)) }
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine('A worker/reviewer tick touches exactly ONE task file. Staging 2+ is')
    [Console]::Error.WriteLine('the signature of git add -A / git add . sweeping in another')
    [Console]::Error.WriteLine('concurrent worker in-progress edits. Stage only your task files')
    [Console]::Error.WriteLine('by explicit path.')
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine('Bypass (legitimate multi-task commits, e.g. initial board seeding):')
    [Console]::Error.WriteLine('  git commit --no-verify')
    [Console]::Error.WriteLine($bar)
    exit 1
}

# Block the commit with an actionable message.
$bar = '=' * 64
[Console]::Error.WriteLine('')
[Console]::Error.WriteLine($bar)
[Console]::Error.WriteLine('STATE-SURFACE DISCIPLINE VIOLATION (pre-commit hook)')
[Console]::Error.WriteLine($bar)
foreach ($v in $violations) {
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine(("  slug:    {0}" -f $v.Slug))
    [Console]::Error.WriteLine(("  ledger:  {0}  (STAGED)" -f $v.Ledger))
    [Console]::Error.WriteLine(("  state:   {0}   (NOT STAGED)" -f $v.State))
}
[Console]::Error.WriteLine('')
[Console]::Error.WriteLine('plan-ledger.md was modified without bumping plan-state.md.')
[Console]::Error.WriteLine('Every ledger entry needs a one-line reference in plan-state.md')
[Console]::Error.WriteLine('(typically in the Status line or "Latest spec version" annotation).')
[Console]::Error.WriteLine('')
[Console]::Error.WriteLine('Fix: edit the mirror, then re-stage. Example:')
foreach ($v in $violations) {
    [Console]::Error.WriteLine(("  git add {0}" -f $v.State))
}
[Console]::Error.WriteLine('')
[Console]::Error.WriteLine('Bypass (rare; ledger-only typo or formatting):')
[Console]::Error.WriteLine('  git commit --no-verify')
[Console]::Error.WriteLine($bar)
exit 1
