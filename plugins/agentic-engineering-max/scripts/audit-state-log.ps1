<#
.SYNOPSIS
    Summarize .state-auto-log for a build slug.
.DESCRIPTION
    Reads planning/<slug>/.state-auto-log and prints:
    - Trigger counts (SessionEnd, SessionStart-sweep, SessionStart-sweep-noop, ERROR variants)
    - Total write events (non-error entries with files written)
    - Commit SHAs mapped from session IDs that appear in the log
    - Commit SHAs in the wave that have no matching log entry (suspected missed writes)

    Session IDs in log entries are mapped to commit SHAs via
    git log --grep=<session_id>.

    See spec.md T-W2-006 and PRD section 3.

.PARAMETER Slug
    The build slug, e.g. orchestrator-and-build-system.

.OUTPUTS
    Stdout: trigger counts, write events, mapped SHAs, missed commits, summary line.
    Stderr: error message on missing log file or bad invocation.

.EXAMPLE
    .\audit-state-log.ps1 orchestrator-and-build-system

.NOTES
    Exit codes: 0 = success, 1 = invocation error, 2 = log file missing.
#>

param(
    [Parameter(Position = 0)]
    [string]$Slug
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

if (-not $Slug) {
    [Console]::Error.WriteLine("Usage: audit-state-log.ps1 <slug>")
    exit 1
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$logPath = Join-Path (Join-Path (Join-Path $repoRoot "planning") $Slug) ".state-auto-log"

if (-not (Test-Path $logPath)) {
    [Console]::Error.WriteLine("Log file not found: $logPath")
    exit 2
}

Write-Host "audit-state-log: reading $logPath"
Write-Host ""

$lines = Get-Content $logPath -Encoding UTF8
$totalLines = $lines.Count

# Parse entries
$triggerCounts = @{}
$errorCount = 0
$writeEntries = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($line in $lines) {
    if (-not $line.Trim()) { continue }

    $isError = $line -match '\bERROR\b'
    $trigger = if ($line -match 'trigger=([A-Za-z\-]+)') { $Matches[1] } else { 'unknown' }
    $session = if ($line -match 'session=([^\s]+)') { $Matches[1] } else { $null }
    $files   = if ($line -match 'files=([^\s]+)') { $Matches[1] } else { $null }

    if ($isError) {
        $errorCount++
        $key = "ERROR-$trigger"
        $triggerCounts[$key] = ([int]($triggerCounts[$key]) + 1)
    } else {
        $triggerCounts[$trigger] = ([int]($triggerCounts[$trigger]) + 1)
        # Write event: non-error entry that recorded actual file writes
        if ($files -and $files -ne "(none)") {
            $writeEntries.Add([PSCustomObject]@{
                Trigger = $trigger
                Session = $session
                Files   = $files
            })
        }
    }
}

Write-Host "=== Trigger counts ==="
foreach ($k in ($triggerCounts.Keys | Sort-Object)) {
    Write-Host ("  {0,-40}  {1}" -f $k, $triggerCounts[$k])
}
Write-Host ("  {0,-40}  {1}" -f "Errors (total)", $errorCount)
Write-Host ("  {0,-40}  {1}" -f "Log lines (total)", $totalLines)
Write-Host ""
Write-Host "=== Write events (non-error, files written) ==="
Write-Host "  Count: $($writeEntries.Count)"
Write-Host ""

# Build set of session IDs that have log entries
$loggedSessions = [System.Collections.Generic.HashSet[string]]::new()
foreach ($e in $writeEntries) {
    if ($e.Session) { [void]$loggedSessions.Add($e.Session) }
}

# Map each logged session ID to commit SHAs
$sessionToShas = @{}
$allMappedShas  = [System.Collections.Generic.List[string]]::new()

foreach ($sid in $loggedSessions) {
    $shas = @(& git log --pretty=format:"%H" "--grep=$sid")
    if ($shas.Count -gt 0) {
        $sessionToShas[$sid] = $shas
        foreach ($sha in $shas) { $allMappedShas.Add($sha) }
    } else {
        $sessionToShas[$sid] = @()
    }
}

Write-Host "=== Commit SHAs mapped from log session IDs ==="
$uniqueMapped = @($allMappedShas | Select-Object -Unique)
if ($uniqueMapped.Count -eq 0) {
    Write-Host "  (none found)"
} else {
    foreach ($sha in $uniqueMapped) {
        $subj = (& git log --no-walk --pretty=format:"%s" $sha)
        Write-Host ("  {0}  {1}" -f $sha.Substring(0, 8), $subj)
    }
}
Write-Host ""

# Find wave commits without a matching log entry
Write-Host "=== Wave commits without a matching log entry (suspected missed writes) ==="
$waveShas = @(& git log --pretty=format:"%H" -- "planning/$Slug")
if ($waveShas.Count -eq 0) {
    Write-Host "  (no wave commits found)"
} else {
    $mappedSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($s in $uniqueMapped) { [void]$mappedSet.Add($s) }
    $missed = @($waveShas | Where-Object { -not $mappedSet.Contains($_) })
    if ($missed.Count -eq 0) {
        Write-Host "  (none -- all wave commits have a matching log entry)"
    } else {
        foreach ($sha in $missed) {
            $subj = (& git log --no-walk --pretty=format:"%s" $sha)
            Write-Host ("  {0}  {1}" -f $sha.Substring(0, 8), $subj)
        }
        Write-Host ""
        Write-Host "  NOTE: missed commits may indicate a missed SessionEnd write."
        Write-Host "  Cross-check against the SessionStart-sweep entries above."
    }
}
Write-Host ""
Write-Host "DONE: $($writeEntries.Count) write event(s); $errorCount error(s)."
exit 0
