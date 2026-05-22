# bin/headless-pm-loop.ps1
#
# Purpose:
#   Run `claude -p /pm <slug>` on a self-paced loop. PM is the
#   observation + housekeeping role: regenerates task-board.md, sweeps
#   stale .lock files (older than stale_lock_minutes from
#   .build-config.json, default 30), and surfaces blocked-task and
#   escalated-task warnings. PM does NOT claim tasks; it only watches.
#
# Usage:
#   .\bin\headless-pm-loop.ps1 <slug> [-SleepSeconds <int>] [-MaxTicks <int>]
#
# Stop:
#   Option A: close this window (kills the loop immediately).
#   Option B: from anywhere (including mobile), push a commit creating
#             planning/<slug>/.locks/pm.headless-stop.
#             The loop git pulls between ticks and exits on next tick.
#
# Rate-limit consumption (Claude Max subscription):
#   Each PM tick is a full `claude -p` invocation (~1 message slot)
#   doing light mechanical work (board regen + frontmatter reads).
#   PM has no sub-agents. PM is SINGLETON -- do not run multiple PM
#   loops on the same slug.
#
# When PM is optional:
#   In headless mode you can skip PM entirely if you do not need a
#   live board view. Workers and reviewers operate against task-file
#   frontmatter directly, not the board file -- so they continue
#   functioning even without PM running. Run PM when you want:
#     (a) Live board.md updates visible via `git pull` on mobile
#     (b) Automatic stale-lock recovery if a worker crashes mid-task
#     (c) Blocked-task and escalated-task warnings in the log

param(
    [Parameter(Mandatory, Position = 0)][string]$Slug,
    [int]$SleepSeconds = 30,
    [int]$MaxTicks = 200,
    [switch]$NoPull
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
    if ($candidate -and (Test-Path (Join-Path $candidate '.git'))) {
        $repoRoot = $candidate
    }
}
if (-not $repoRoot) {
    [Console]::Error.WriteLine('headless-pm-loop: could not locate repo root (no .git found in cwd ancestors or script-dir ancestor).')
    exit 1
}
Set-Location $repoRoot

# PM is singleton and has no actor-ID env var. The stop sentinel uses a
# fixed name 'pm' to make singleton enforcement implicit.
$planningDir = Join-Path (Join-Path $repoRoot 'planning') $Slug
$locksDir    = Join-Path $planningDir '.locks'
$stopFile    = Join-Path $locksDir 'pm.headless-stop'
$logDir      = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir ("headless-pm-" + $Slug + "-" + (Get-Date -Format 'yyyyMMddHHmmss') + ".log")

$bar = '=' * 64
Write-Host $bar -ForegroundColor Blue
Write-Host "  Headless PM loop on $Slug (singleton)" -ForegroundColor Blue
Write-Host $bar -ForegroundColor Blue
Write-Host "  log:        $logFile" -ForegroundColor White
Write-Host "  stop-from-mobile: push a commit creating" -ForegroundColor Yellow
Write-Host "                    $stopFile" -ForegroundColor Yellow
Write-Host "  stop-locally:    close this window" -ForegroundColor Yellow
Write-Host "  sleep:      ${SleepSeconds}s between ticks" -ForegroundColor White
Write-Host "  max ticks:  $MaxTicks (safety bound)" -ForegroundColor White
Write-Host $bar -ForegroundColor Blue

$tick = 0
$exitReason = 'unknown'

while ($tick -lt $MaxTicks) {
    $tick++

    if (-not $NoPull) {
        & git pull --ff-only --quiet 2>$null
    }

    if (Test-Path $stopFile) {
        $exitReason = 'stop sentinel found'
        break
    }

    Write-Host ''
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "===== Tick $tick at $ts =====" -ForegroundColor Cyan

    $tickStart = Get-Date
    # Headless launch has no TTY on stdin; feed empty stdin so `claude -p` does
    # not wait 3s / warn on absent piped input. Localize ErrorActionPreference
    # to Continue so a benign native-stderr line captured by 2>&1 (PS5.1 wraps
    # native stderr as a NativeCommandError) is not promoted to a terminating
    # error by the script-level 'Stop'. The 2>&1 | Out-String shape is kept
    # intact per spec invariant 6.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = $null | & claude -p "/pm $Slug" --dangerously-skip-permissions 2>&1 | Out-String
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    $tickElapsed = [int]((Get-Date) - $tickStart).TotalSeconds

    Add-Content -Path $logFile -Value "===== Tick $tick at $ts (${tickElapsed}s) ====="
    Add-Content -Path $logFile -Value $output
    Add-Content -Path $logFile -Value ''

    # PM emits compact tick lines; show the whole output (it is short by design)
    Write-Host ($output.TrimEnd())

    # Exit when the build is done (PM emits the *** ALL TASKS DONE sentinel)
    if ($output -match 'ALL TASKS DONE') {
        $exitReason = 'all tasks done sentinel emitted'
        break
    }

    Start-Sleep -Seconds $SleepSeconds
}

if ($tick -ge $MaxTicks) { $exitReason = "max-ticks ($MaxTicks) safety cap reached" }

Write-Host ''
Write-Host $bar -ForegroundColor Blue
Write-Host "  Loop exit: $exitReason" -ForegroundColor Blue
Write-Host "  Total ticks: $tick" -ForegroundColor Blue
Write-Host "  Full log: $logFile" -ForegroundColor Blue
Write-Host $bar -ForegroundColor Blue
exit 0
