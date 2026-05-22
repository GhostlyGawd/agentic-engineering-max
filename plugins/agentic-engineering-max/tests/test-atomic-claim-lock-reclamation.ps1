# tests/test-atomic-claim-lock-reclamation.ps1
#
# Regression test for invariant 4 (atomic-claim lock reclamation): a stale
# per-task .lock left behind by a crashed/exited worker MUST be reclaimed by
# the PM stale-lock sweep within the bounded window, and the task it guarded
# MUST be reset to open so it can be re-claimed.
#
# Run:    pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test-atomic-claim-lock-reclamation.ps1
# Exit:   0 = all pass, 1 = at least one failed.
#
# WHAT THIS TEST EXERCISES, AND WHY IT IS A SIMULATION
# ----------------------------------------------------
# The reclamation behavior under test is the TIME-ONLY PM stale-lock sweep
# defined in skills/pm/SKILL.md "Step 3 -- Stale-lock sweep (D-S1)". That sweep
# is the PM mechanism that, for a lock older than stale_lock_minutes (default
# 30, configurable via planning/<slug>/.build-config.json), (a) rewrites the
# guarded task's frontmatter to status: open with cleared owner/claimed_at, and
# (b) deletes the .lock. It applies regardless of task status -- including
# in_progress, which is the case invariant 4 cares about (a worker holding an
# in_progress lock that then crashes).
#
# This sweep has NO standalone script surface in v1: it lives as agent-executed
# prose inside the /pm skill, not in build-board.ps1 (which only regenerates the
# board) and not in a shipped helper. The only sweep SCRIPT in the wider repo,
# bin/sweep-stale-locks.ps1, is a DIFFERENT, status-aware orphan sweep (it
# releases done/in_review locks, never touches in_progress, and does not reset
# frontmatter) and is not shipped in this plugin (T-018 migrated 5 scripts;
# that one was not among them).
#
# PRD section 8 invariant 4 specifies the verification as "runs a PM tick
# simulation; asserts the lock was released." Accordingly this test transcribes
# the SKILL.md Step 3 contract into Invoke-PmStaleSweep below and asserts the
# documented end-state. The cases are built to be falsifiable: a fresh lock and
# an above-threshold config value must each leave the lock untouched, so a sweep
# that simply deleted every lock would fail this test rather than pass it.
#
# Convention (CLAUDE.md "Testing"): every invariant lands with an automated
# regression test that mirrors the documented production contract.

$ErrorActionPreference = 'Stop'

$script:passes   = 0
$script:failures = 0

function Fail {
    param([string]$Name, [string]$Detail)
    Write-Host ("FAIL: {0}" -f $Name)
    if ($Detail) { Write-Host ("  {0}" -f $Detail) }
    $script:failures++
}

function Pass {
    param([string]$Name)
    Write-Host ("PASS: {0}" -f $Name)
    $script:passes++
}

# --- The PM Step 3 stale-lock sweep, transcribed from skills/pm/SKILL.md ------
# Reads the per-project threshold (default 30), globs task-*.lock, and for any
# lock older than the threshold: resets the guarded task frontmatter to open
# (cleared owner/claimed_at, every other key + body preserved) THEN deletes the
# lock. A sharing-violation read means an active writer holds the lock; skip it.
function Invoke-PmStaleSweep {
    param([Parameter(Mandatory)][string]$PlanningDir)

    # 1. Resolve threshold from .build-config.json (default 30).
    $threshold = 30
    $cfgPath = Join-Path $PlanningDir '.build-config.json'
    if (Test-Path $cfgPath) {
        try {
            $cfg = (Get-Content -Raw -Path $cfgPath | ConvertFrom-Json)
            if ($null -ne $cfg.stale_lock_minutes) {
                $parsed = 0
                if ([int]::TryParse([string]$cfg.stale_lock_minutes, [ref]$parsed)) {
                    $threshold = $parsed
                }
            }
        } catch {
            $threshold = 30
        }
    }

    $tasksDir = Join-Path $PlanningDir 'tasks'
    if (-not (Test-Path $tasksDir)) { return }

    $nowUtc = [DateTime]::UtcNow

    Get-ChildItem (Join-Path $tasksDir 'task-*.lock') -ErrorAction SilentlyContinue | ForEach-Object {
        $lockPath = $_.FullName
        $taskPath = $lockPath -replace '\.lock$', '.md'

        # Read lock body; a sharing violation means an active writer holds it.
        $body = $null
        try { $body = Get-Content -Raw -ErrorAction Stop -Path $lockPath }
        catch { return }

        $claimedAt = $null
        if ($body -match 'claimed_at:\s*(\S+)') {
            try {
                $claimedAt = [DateTime]::Parse(
                    $Matches[1],
                    [Globalization.CultureInfo]::InvariantCulture,
                    ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
                )
            } catch { $claimedAt = $null }
        }
        if (-not $claimedAt) { return }

        $ageMin = ($nowUtc - $claimedAt).TotalMinutes
        if ($ageMin -le $threshold) { return }

        # First: reset the guarded task frontmatter (status open, clear owner +
        # claimed_at), preserving every other key and the body.
        if (Test-Path $taskPath) {
            $lines = @(Get-Content -Path $taskPath)
            $fenceCount = 0
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i].Trim() -eq '---') {
                    $fenceCount++
                    if ($fenceCount -ge 2) { break }
                    continue
                }
                if ($fenceCount -eq 1) {
                    if     ($lines[$i] -match '^status:')     { $lines[$i] = 'status: open' }
                    elseif ($lines[$i] -match '^owner:')      { $lines[$i] = 'owner: ' }
                    elseif ($lines[$i] -match '^claimed_at:') { $lines[$i] = 'claimed_at: ' }
                }
            }
            $utf8 = [Text.UTF8Encoding]::new($false)
            [IO.File]::WriteAllText($taskPath, ($lines -join "`n") + "`n", $utf8)
        }

        # Then: delete the lock.
        Remove-Item $lockPath -Force
    }
}

# --- Read one frontmatter field from a task file ------------------------------
function Get-Field {
    param([string]$Path, [string]$Field)
    $lines = @(Get-Content -Path $Path)
    $fenceCount = 0
    foreach ($line in $lines) {
        if ($line.Trim() -eq '---') {
            $fenceCount++
            if ($fenceCount -ge 2) { break }
            continue
        }
        if ($fenceCount -eq 1 -and $line -match ("^" + [regex]::Escape($Field) + ":\s*(.*)$")) {
            return $Matches[1].Trim()
        }
    }
    return $null
}

# --- One reclamation case -----------------------------------------------------
function Run-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$LockAgeMinutes,
        [int]$ConfigThreshold = -1,    # -1 => write no .build-config.json (default-30 path)
        [Parameter(Mandatory)][bool]$ExpectReleased
    )

    $testRoot    = Join-Path $env:TEMP ("reclaim-test-{0}" -f (Get-Random))
    $planningDir = Join-Path $testRoot 'planning/test-slug'
    $tasksDir    = Join-Path $planningDir 'tasks'
    New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null

    try {
        $utf8 = [Text.UTF8Encoding]::new($false)

        # Optional .build-config.json.
        if ($ConfigThreshold -ge 0) {
            $cfg = '{ "stale_lock_minutes": ' + $ConfigThreshold + ' }'
            [IO.File]::WriteAllText((Join-Path $planningDir '.build-config.json'), $cfg, $utf8)
        }

        # Back-dated claim timestamp shared by the task frontmatter and the lock.
        $claimedAt = [DateTime]::UtcNow.AddMinutes(-$LockAgeMinutes).ToString('yyyy-MM-ddTHH:mm:ssZ')

        # task-001.md: in_progress, owned by a test worker, claimed in the past.
        $taskMd = @"
---
id: T-001
title: mock in_progress task
status: in_progress
owner: test-worker
claimed_at: $claimedAt
review_iterations: 2
depends_on: [T-000]
unresolved_findings: []
---

# T-001 mock body

This body line must survive a frontmatter reset.
"@
        $taskPath = Join-Path $tasksDir 'task-001.md'
        [IO.File]::WriteAllText($taskPath, $taskMd, $utf8)

        # Sibling lock in the live build-system format (task-<id>.lock, the path
        # the worker writes: task file path with .md replaced by .lock).
        $lockBody = "worker_id: test-worker`nclaude_session_id: pid-test`nclaimed_at: $claimedAt`n"
        $lockPath = Join-Path $tasksDir 'task-001.lock'
        [IO.File]::WriteAllText($lockPath, $lockBody, $utf8)

        # Run the PM tick sweep simulation.
        Invoke-PmStaleSweep -PlanningDir $planningDir

        $lockExists = Test-Path $lockPath
        $wasReleased = -not $lockExists

        if ($wasReleased -ne $ExpectReleased) {
            Fail $Name ("expected released={0}, got released={1}" -f $ExpectReleased, $wasReleased)
            return
        }

        if ($ExpectReleased) {
            # Lock gone AND frontmatter reset to open with cleared owner/claimed_at.
            $status     = Get-Field -Path $taskPath -Field 'status'
            $owner      = Get-Field -Path $taskPath -Field 'owner'
            $claimed    = Get-Field -Path $taskPath -Field 'claimed_at'
            $id         = Get-Field -Path $taskPath -Field 'id'
            $depends    = Get-Field -Path $taskPath -Field 'depends_on'
            $bodyKept   = (Get-Content -Raw -Path $taskPath) -match 'This body line must survive'

            if ($status -ne 'open')                  { Fail $Name "status not reset to open (got '$status')"; return }
            if (-not [string]::IsNullOrWhiteSpace($owner))   { Fail $Name "owner not cleared (got '$owner')"; return }
            if (-not [string]::IsNullOrWhiteSpace($claimed)) { Fail $Name "claimed_at not cleared (got '$claimed')"; return }
            if ($id -ne 'T-001')                     { Fail $Name "id not preserved (got '$id')"; return }
            if ($depends -ne '[T-000]')              { Fail $Name "depends_on not preserved (got '$depends')"; return }
            if (-not $bodyKept)                       { Fail $Name 'task body not preserved'; return }
            Pass $Name
        }
        else {
            # Lock survived AND frontmatter untouched (still in_progress).
            $status = Get-Field -Path $taskPath -Field 'status'
            $owner  = Get-Field -Path $taskPath -Field 'owner'
            if ($status -ne 'in_progress') { Fail $Name "status should be unchanged in_progress (got '$status')"; return }
            if ($owner -ne 'test-worker')  { Fail $Name "owner should be unchanged test-worker (got '$owner')"; return }
            Pass $Name
        }
    }
    finally {
        Remove-Item -Recurse -Force $testRoot -ErrorAction SilentlyContinue
    }
}

# --- Cases --------------------------------------------------------------------
# Primary: stale in_progress lock (60 min) under default threshold -> reclaimed.
Run-Case -Name 'stale 60 min, default threshold -> RELEASED + reset to open' `
         -LockAgeMinutes 60 -ConfigThreshold -1 -ExpectReleased $true

# Primary with explicit config threshold of 30 -> reclaimed (60 > 30).
Run-Case -Name 'stale 60 min, config threshold 30 -> RELEASED + reset to open' `
         -LockAgeMinutes 60 -ConfigThreshold 30 -ExpectReleased $true

# Falsifiability control: a fresh lock must NOT be swept (0 < 30).
Run-Case -Name 'fresh 0 min, default threshold -> KEPT (frontmatter untouched)' `
         -LockAgeMinutes 0 -ConfigThreshold -1 -ExpectReleased $false

# Falsifiability control: config threshold is honored (60 < 90 -> KEPT).
Run-Case -Name 'lock 60 min, config threshold 90 -> KEPT (config honored)' `
         -LockAgeMinutes 60 -ConfigThreshold 90 -ExpectReleased $false

Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:passes, $script:failures)
if ($script:failures -gt 0) { exit 1 } else { exit 0 }
