# bin/sweep-stale-locks.ps1
#
# Purpose:
#   Status-aware orphan-lock sweep. Releases per-task .lock files left
#   behind when a worker/reviewer committed its work but the tick exited
#   before the lock-release step ran. Distinct from PM's time-only
#   30-minute stale sweep -- this one keys off task status, so it
#   recovers orphans in seconds rather than half an hour.
#
#   Failure mode this patches (observed 3x in the 2026-05-19 swarm):
#   a headless `claude -p` worker/reviewer process flips the task to
#   in_review (or done), commits the deliverable, then exits before the
#   final Remove-Item on its .lock. The lock orphans; the task cannot be
#   re-claimed until PM's 30-minute sweep clears it.
#
# Safety model (why this does not race an active worker):
#   - status: done       -> release unconditionally. A done task is
#                           terminal; no actor legitimately holds a lock
#                           on it.
#   - status: in_review  -> release only if lock age > InReviewMinutes
#                           (default 3). A worker flips to in_review,
#                           commits, then releases within seconds; a lock
#                           older than the threshold on an in_review task
#                           is orphaned. The grace window avoids racing
#                           the brief commit->release gap.
#   - status: open / in_progress / needs_fixing / escalated
#                        -> never touched here. Those are PM's time-only
#                           sweep territory (a worker may legitimately
#                           hold an in_progress lock for a long task).
#
# Usage:
#   sweep-stale-locks.ps1 <slug> [-InReviewMinutes <int>] [-WhatIf]
#
# Exit codes:
#   0 always (sweep is advisory; it never fails the caller). Emits one
#   line per released lock to stdout.

param(
    [Parameter(Mandatory, Position = 0)][string]$Slug,
    [int]$InReviewMinutes = 3,
    [int]$InProgressMinutes = 30,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

function Find-RepoRoot {
    $cur = (Get-Location).Path
    while ($cur -and $cur.Length -gt 3) {
        if (Test-Path (Join-Path $cur '.git')) { return $cur }
        $parent = Split-Path $cur -Parent
        if (-not $parent -or $parent -eq $cur) { return $null }
        $cur = $parent
    }
    return $null
}

$repoRoot = Find-RepoRoot
if (-not $repoRoot) {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $candidate = Split-Path -Parent $scriptDir
    if ($candidate -and (Test-Path (Join-Path $candidate '.git'))) { $repoRoot = $candidate }
}
if (-not $repoRoot) {
    [Console]::Error.WriteLine('sweep-stale-locks.ps1: could not locate repo root.')
    exit 0
}

$tasksDir = Join-Path (Join-Path (Join-Path $repoRoot 'planning') $Slug) 'tasks'
if (-not (Test-Path $tasksDir)) {
    [Console]::Error.WriteLine("sweep-stale-locks.ps1: tasks dir not found: $tasksDir")
    exit 0
}

# Read a single frontmatter field value from a task file.
function Get-FrontmatterField {
    param([string]$Path, [string]$Field)
    if (-not (Test-Path $Path)) { return $null }
    $lines = @(Get-Content $Path)
    foreach ($line in $lines) {
        if ($line -match ("^" + [regex]::Escape($Field) + ":\s*(.*)$")) {
            return $Matches[1].Trim()
        }
        # Stop at the closing frontmatter fence (second ---)
    }
    return $null
}

# Reset an abandoned-claim task back to claimable: status -> open, clear
# owner + claimed_at. Writes UTF-8 WITHOUT a BOM (the board frontmatter parser
# checks `$lines[0].Trim() -ne '---'`, and PS5.1's Trim() does NOT strip a
# U+FEFF BOM, so a BOM would silently break board parsing). The owner/claimed_at
# keys appear only in the frontmatter, so the anchored replaces are safe.
function Reset-TaskToOpen {
    param([string]$Path)
    $raw = [IO.File]::ReadAllText($Path)
    $raw = $raw -replace '(?m)^status:\s*in_progress\s*$', 'status: open'
    $raw = $raw -replace '(?m)^owner:\s*.*$', 'owner:'
    $raw = $raw -replace '(?m)^claimed_at:\s*.*$', 'claimed_at:'
    $enc = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($Path, $raw, $enc)
}

$nowUtc = [DateTime]::UtcNow
$released = 0

Get-ChildItem (Join-Path $tasksDir 'task-*.lock') -ErrorAction SilentlyContinue | ForEach-Object {
    $lockPath = $_.FullName
    $taskPath = $lockPath -replace '\.lock$', '.md'

    # Read lock body; if a sharing-violation fires the lock is freshly held
    # by an active writer -- skip it (do not race the holder).
    $lockBody = $null
    try { $lockBody = Get-Content -Raw -ErrorAction Stop $lockPath }
    catch { return }  # IOException = active writer holds it; leave alone

    $status = Get-FrontmatterField -Path $taskPath -Field 'status'
    if (-not $status) { return }

    $shouldRelease = $false
    $resetTask = $false
    $reason = ''

    if ($status -eq 'done') {
        $shouldRelease = $true
        $reason = 'task status is done (terminal)'
    }
    elseif ($status -eq 'in_progress') {
        # Abandoned-claim orphan: the lock persists through in_progress, so a
        # worker that claimed a task then died (its tick never flipped to
        # in_review) leaves a held lock on an in_progress task that NO other
        # sweep branch recovers -- done/in_review do not match it, and a live
        # worker never claims an in_progress task. Past the age threshold the
        # claim is abandoned: reset the task to open AND release the lock so a
        # live worker can re-claim. Age is read from the lock body's claimed_at
        # (same source as the in_review branch). Below threshold a worker may
        # legitimately be mid-task -- leave it. Threshold defaults to 30 min
        # (one claude tick is minutes, so a 30-min-old claim is almost
        # certainly a dead claimant).
        $claimedAt = $null
        if ($lockBody -match 'claimed_at:\s*(\S+)') {
            try { $claimedAt = [DateTime]::Parse($Matches[1]).ToUniversalTime() } catch { $claimedAt = $null }
        }
        if ($claimedAt) {
            $ageMin = ($nowUtc - $claimedAt).TotalMinutes
            if ($ageMin -gt $InProgressMinutes) {
                $shouldRelease = $true
                $resetTask = $true
                $reason = ("task in_progress and claim age {0:N1} min > {1} min threshold (abandoned claim -> reset to open)" -f $ageMin, $InProgressMinutes)
            }
        }
    }
    elseif ($status -eq 'in_review') {
        $claimedAt = $null
        if ($lockBody -match 'claimed_at:\s*(\S+)') {
            try { $claimedAt = [DateTime]::Parse($Matches[1]).ToUniversalTime() } catch { $claimedAt = $null }
        }
        if ($claimedAt) {
            $ageMin = ($nowUtc - $claimedAt).TotalMinutes
            if ($ageMin -gt $InReviewMinutes) {
                $shouldRelease = $true
                $reason = ("task in_review and lock age {0:N1} min > {1} min threshold" -f $ageMin, $InReviewMinutes)
            }
        }
    }

    if ($shouldRelease) {
        $taskId = (Split-Path $lockPath -Leaf) -replace '^task-', '' -replace '\.lock$', ''
        if ($WhatIf) {
            Write-Host ("[WhatIf] would release lock T-$taskId : $reason")
        } else {
            try {
                if ($resetTask) { Reset-TaskToOpen -Path $taskPath }
                Remove-Item $lockPath -Force
                Write-Host ("released orphan lock T-$taskId : $reason")
                $script:released++
            } catch {
                [Console]::Error.WriteLine("failed to release T-$taskId : $_")
            }
        }
    }
}

if ($released -eq 0 -and -not $WhatIf) { Write-Host "sweep-stale-locks: no orphan locks released" }
exit 0
