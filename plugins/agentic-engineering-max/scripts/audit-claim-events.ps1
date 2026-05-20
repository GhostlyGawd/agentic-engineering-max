<#
.SYNOPSIS
    Audit atomic-claim events in the Wave 2 git log.
.DESCRIPTION
    Scans git log for worker commits (subject matching T-NNN: and containing a
    Worker-ID: trailer). Extracts (TaskID, WorkerID, commit-time) triples,
    groups by TaskID, and flags any task committed by more than one distinct
    WorkerID -- the observable signal of a missed atomic-claim lock.

    This is observational only; it does not run a synthetic race test.
    See spec.md T-W2-005 and PRD section 3 (non-goals).

.PARAMETER Slug
    The build slug, e.g. orchestrator-and-build-system.

.OUTPUTS
    Stdout: one line per claim event; summary table; final CLEAN or ERROR line.
    Stderr: error message if double-assign detected.

    Exit codes:
      0  CLEAN: candidates found, trailers parsed, no double-assigns
      1  Invocation error (missing slug, git log failed)
      2  DOUBLE-ASSIGN detected: same task committed by two distinct WorkerIDs
      3  Advisory: cannot confirm clean (zero candidates, or candidates without
         Worker-ID trailers). T-W2-012 callers must treat exit 3 as a non-fatal
         "audit inconclusive" signal distinct from exit 1 invocation errors.

.EXAMPLE
    .\audit-claim-events.ps1 orchestrator-and-build-system
#>

param(
    [Parameter(Position = 0)]
    [string]$Slug
)

# -Off intentional: git output vars may be null/scalar on empty repos; @() wraps
# at lines 42 and 75 handle the coercion explicitly. StrictMode would false-trip.
Set-StrictMode -Off
$ErrorActionPreference = "Stop"

if (-not $Slug) {
    [Console]::Error.WriteLine("Usage: audit-claim-events.ps1 <slug>")
    exit 1
}

Write-Host "audit-claim-events: scanning git log for slug=$Slug"
Write-Host ""

# Get all commit hashes, timestamps, and subjects in one pass.
# Format: 4 lines per commit -- hash, ISO time, subject, empty separator.
# Both filters required: --grep scopes by commit subject (T-NNN: prefix);
# -- "planning/$Slug" scopes by path so multi-slug repos don't cross-contaminate.
$logLines = @(& git log --pretty="tformat:%H%n%ai%n%s%n" --grep="^T-" -- "planning/$Slug")
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("git log failed; not inside a git repo?")
    exit 1
}

# Parse commits into structured records
$candidates = @()
$i = 0
while ($i -lt $logLines.Count) {
    $hash    = $logLines[$i]
    $time    = if (($i + 1) -lt $logLines.Count) { $logLines[$i + 1] } else { "" }
    $subject = if (($i + 2) -lt $logLines.Count) { $logLines[$i + 2] } else { "" }
    $i += 4

    # Keep only commits whose subject starts with T-<word>-<digits>:
    if ($subject -match "^(T-[A-Za-z0-9]+-\d+):") {
        $candidates += [PSCustomObject]@{
            Hash    = $hash
            Time    = $time
            TaskID  = $Matches[1]
            Subject = $subject
        }
    }
}

Write-Host "Found $($candidates.Count) task commit(s) in git log."
Write-Host ""

# Zero-candidates guard: a CLEAN exit on zero commits is vacuous; cannot
# distinguish a fresh repo, a wrong slug, or commits that never used the
# T-NNN: subject convention. Exit 3 (advisory: audit inconclusive).
if ($candidates.Count -eq 0) {
    [Console]::Error.WriteLine("WARNING: zero task commits found for slug '$Slug'; slug or path may be wrong, or no T-NNN: commits exist yet.")
    exit 3
}

# For each candidate, read the commit body to find Worker-ID trailer
# (Worker-ID trailer convention is defined in spec D-S1.)
$events = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($c in $candidates) {
    # @() wrap: git show returns $null on empty body or a scalar string on
    # single-line body; without the array coercion, foreach would silently
    # skip null bodies and misindex single-line bodies, dropping Worker-ID events.
    $body = @(& git show --no-patch --pretty=format:"%b" $c.Hash)
    $workerId = $null
    foreach ($bline in $body) {
        if ($bline -match "^Worker-ID:\s*(.+)") {
            $workerId = $Matches[1].Trim()
            break
        }
    }
    if ($workerId) {
        $events.Add([PSCustomObject]@{
            TaskID   = $c.TaskID
            WorkerID = $workerId
            Hash     = $c.Hash.Substring(0, 8)
            FullHash = $c.Hash
            Time     = $c.Time
        })
        Write-Host ("  {0,-12}  worker={1,-12}  hash={2}  time={3}" -f $c.TaskID, $workerId, $c.Hash.Substring(0, 8), $c.Time)
    }
}

if ($candidates.Count -gt 0 -and $events.Count -eq 0) {
    [Console]::Error.WriteLine("WARNING: $($candidates.Count) task commit(s) matched but none had Worker-ID trailers; cannot distinguish genuine clean from missing trailers.")
    exit 3
}

Write-Host ""
Write-Host "=== Claim event summary ==="

$grouped = $events | Group-Object TaskID | Sort-Object Name
$doubleAssigns = @()

foreach ($g in $grouped) {
    $uniqueWorkers = @($g.Group | Select-Object -ExpandProperty WorkerID -Unique)
    $flag = ""
    if ($uniqueWorkers.Count -gt 1) {
        $flag = "  !! DOUBLE-ASSIGN"
        $doubleAssigns += $g.Name
    }
    $workerList = $uniqueWorkers -join ", "
    Write-Host ("  {0,-12}  commits={1}  workers=[{2}]{3}" -f $g.Name, $g.Count, $workerList, $flag)
}

Write-Host ""

if ($doubleAssigns.Count -gt 0) {
    $taskList = $doubleAssigns -join ", "
    [Console]::Error.WriteLine("DOUBLE-ASSIGN detected on task(s): $taskList")
    [Console]::Error.WriteLine("Review git log for these task IDs to identify missed lock window.")
    exit 2
}

Write-Host "CLEAN: no double-assign events detected across $($grouped.Count) task(s)."
exit 0
