# bin/claimable-width.ps1
#
# Purpose:
#   Single shared frontmatter-reading width helper. Exposes the two integers
#   the adaptive controller (spec D-S3) reasons about each tick:
#     - claimable width : how many tasks a worker could claim RIGHT NOW
#     - in-review width  : how many tasks are sitting in_review awaiting a
#                          reviewer.
#   Computing these from frontmatter (not by scraping task-board.md's
#   human-readable text) keeps claimable width one testable unit -- the
#   controller scales worker/reviewer fan-out off these numbers, so they must
#   be exact, not regex-scraped from a rendered board.
#
# Decisions:
#   D-S3 (controller reads claimable width to size fan-out)
#
# Claimability rule (mirrors /worker Step 3 priority filter):
#   claimable = status in {open, needs_fixing}
#               AND every depends_on entry resolves to a task whose status is
#                   'done'
#               AND (for status == open) no LIVE sibling task-<stem>.lock
#   A lock is LIVE when it exists and is either held by an active writer
#   (read throws a sharing violation) or its claimed_at is younger than the
#   stale-lock window (.build-config.json stale_lock_minutes, default 30). A
#   lock older than that window is an orphan PM will sweep, so it does NOT
#   block claimability. needs_fixing tasks belong to their original worker and
#   carry no claimable-blocking lock, so the lock check is open-only.
#
#   in-review width = count of tasks with status == in_review. (Sized so the
#   controller can decide whether to spin up reviewers.)
#
# Both functions are dot-sourceable (callable as Get-ClaimableWidth /
# Get-InReviewWidth returning [int]) AND the script is directly invokable
# (prints `worker=<n> reviewer=<m>`).
#
# Cross-task invariants honored:
#   - ASCII-only inside "..." literals.
#   - No 2>&1 on native exes (pure PS file reads; no native exes invoked).
#   - Paths built with Join-Path / forward slashes (no literal backslash).

param(
    [Parameter(Position = 0)]
    [string]$Slug
)

$ErrorActionPreference = 'Stop'

function Find-ClaimableRepoRoot {
    # Walk up from the current location looking for a repo marker. CWD-first
    # (not $PSScriptRoot-first) so a dot-sourcing test operating in a temp repo
    # resolves to THAT repo, not the real bin/.. the script lives in.
    $cur = (Get-Location).Path
    while ($cur -and $cur.Length -gt 3) {
        if ((Test-Path (Join-Path $cur '.git')) -or (Test-Path (Join-Path $cur 'planning'))) {
            return $cur
        }
        $parent = Split-Path $cur -Parent
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    # Fallback: the script's own location two dirs up (bin/.. = repo root).
    $scriptDir = Split-Path -Parent $PSCommandPath
    $candidate = Split-Path -Parent $scriptDir
    if ($candidate -and (Test-Path (Join-Path $candidate 'planning'))) { return $candidate }
    return $null
}

# Line-oriented frontmatter scan. PS has no native YAML parser; this mirrors
# the shape used by build-board.ps1 / sweep-stale-locks.ps1. We only need
# status + depends_on here, so the parser is intentionally narrow.
function Read-ClaimableFrontmatter {
    param([string]$Path)

    $raw = Get-Content -Raw -Encoding utf8 -Path $Path -ErrorAction SilentlyContinue
    if (-not $raw) { return $null }

    $lines = $raw -split "`r?`n"
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') { return $null }

    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') { $end = $i; break }
    }
    if ($end -lt 0) { return $null }

    $fm = [ordered]@{ status = ''; depends_on = @() }

    $inList = $null
    for ($i = 1; $i -lt $end; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$') {
            $inList = $null
            $key = $matches[1]
            $val = $matches[2].Trim()
            if ($val -match '^"(.*)"$' -or $val -match "^'(.*)'$") { $val = $matches[1] }
            switch ($key) {
                'status'     { $fm.status = $val.ToLowerInvariant() }
                'depends_on' {
                    if ($val -match '^\[(.*)\]$') {
                        $fm.depends_on = @($matches[1] -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
                    } elseif (-not $val) {
                        $inList = 'depends_on'
                    }
                }
                default { }
            }
        } elseif ($inList -eq 'depends_on' -and ($line -match '^\s*-\s*(.*)$')) {
            $item = $matches[1].Trim().Trim('"', "'")
            if ($item) { $fm.depends_on = @($fm.depends_on) + $item }
        }
    }
    return $fm
}

# A lock is LIVE if present and not provably stale. Provably stale = readable
# body whose claimed_at age exceeds the stale window (PM will sweep it). A
# sharing-violation read (active writer) or an unparseable timestamp is treated
# as LIVE -- present-and-unproven defaults to blocking, which is the safe side.
function Test-ClaimableLiveLock {
    param([string]$LockPath, [int]$StaleMinutes)
    if (-not (Test-Path $LockPath)) { return $false }
    $body = $null
    try { $body = Get-Content -Raw -ErrorAction Stop $LockPath }
    catch { return $true }  # active writer holds it
    if ($body -match 'claimed_at:\s*(\S+)') {
        try {
            $dt = [DateTime]::Parse(
                $matches[1],
                [Globalization.CultureInfo]::InvariantCulture,
                ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
            )
            $ageMin = ([DateTime]::UtcNow - $dt).TotalMinutes
            if ($ageMin -gt $StaleMinutes) { return $false }  # orphan -> PM sweep
        } catch { }
    }
    return $true
}

# Resolve stale_lock_minutes from .build-config.json (default 30 on any miss).
function Get-ClaimableStaleMinutes {
    param([string]$PlanningDir)
    $cfg = Join-Path $PlanningDir '.build-config.json'
    if (Test-Path $cfg) {
        try {
            $obj = Get-Content -Raw -Encoding utf8 $cfg | ConvertFrom-Json
            if ($obj.PSObject.Properties.Name -contains 'stale_lock_minutes' -and $obj.stale_lock_minutes) {
                return [int]$obj.stale_lock_minutes
            }
        } catch { }
    }
    return 30
}

# Scan every task once, returning a list of records with the fields the width
# functions need plus a status-by-id map for dependency resolution.
function Get-ClaimableTaskScan {
    param([string]$Slug)

    $repoRoot = Find-ClaimableRepoRoot
    if (-not $repoRoot) { return $null }
    $planningDir = Join-Path $repoRoot (Join-Path 'planning' $Slug)
    $tasksDir = Join-Path $planningDir 'tasks'
    if (-not (Test-Path $tasksDir)) { return $null }

    $staleMin = Get-ClaimableStaleMinutes -PlanningDir $planningDir
    $statusById = @{}
    $records = New-Object System.Collections.ArrayList

    foreach ($tf in @(Get-ChildItem -Path $tasksDir -Filter 'task-*.md' -File -ErrorAction SilentlyContinue)) {
        $fm = Read-ClaimableFrontmatter -Path $tf.FullName
        if (-not $fm) { continue }
        # Derive the frontmatter id key for dependency matching from the
        # filename stem (task-001 -> T-001, task-W1-003 -> T-W1-003), matching
        # build-board.ps1's id-derivation fallback.
        $id = $tf.BaseName
        if ($id -match '^task-(W\d+-\d+|\d+)$') { $id = 'T-' + $matches[1] }
        $lockPath = ($tf.FullName -replace '\.md$', '.lock')
        $rec = [pscustomobject]@{
            Id         = $id
            Status     = $fm.status
            DependsOn  = @($fm.depends_on)
            LockPath   = $lockPath
            StaleMin   = $staleMin
        }
        $statusById[$id] = $fm.status
        $null = $records.Add($rec)
    }

    return [pscustomobject]@{ Records = $records; StatusById = $statusById }
}

function Test-ClaimableDepsDone {
    param($DependsOn, $StatusById)
    foreach ($dep in @($DependsOn)) {
        if (-not $dep) { continue }
        $depStatus = $StatusById[$dep]
        # An unknown dep (no matching task file) is treated as NOT done -- a
        # task cannot be claimable if it names a dependency that does not exist.
        if ($depStatus -ne 'done') { return $false }
    }
    return $true
}

function Get-ClaimableWidth {
    param([Parameter(Mandatory)][string]$Slug)
    $scan = Get-ClaimableTaskScan -Slug $Slug
    if (-not $scan) { return [int]0 }
    $count = 0
    foreach ($r in $scan.Records) {
        if ($r.Status -eq 'open' -or $r.Status -eq 'needs_fixing') {
            if (-not (Test-ClaimableDepsDone -DependsOn $r.DependsOn -StatusById $scan.StatusById)) { continue }
            if ($r.Status -eq 'open') {
                if (Test-ClaimableLiveLock -LockPath $r.LockPath -StaleMinutes $r.StaleMin) { continue }
            }
            $count++
        }
    }
    return [int]$count
}

function Get-InReviewWidth {
    param([Parameter(Mandatory)][string]$Slug)
    $scan = Get-ClaimableTaskScan -Slug $Slug
    if (-not $scan) { return [int]0 }
    $count = 0
    foreach ($r in $scan.Records) {
        if ($r.Status -eq 'in_review') { $count++ }
    }
    return [int]$count
}

# Direct invocation: print the two integers. Dot-sourcing (InvocationName '.')
# defines the functions only and skips this block.
if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($Slug)) {
        [Console]::Error.WriteLine('claimable-width.ps1: missing slug. Usage: claimable-width.ps1 <project-slug>')
        exit 1
    }
    $worker   = Get-ClaimableWidth -Slug $Slug
    $reviewer = Get-InReviewWidth -Slug $Slug
    Write-Output ("worker={0} reviewer={1}" -f $worker, $reviewer)
    exit 0
}
