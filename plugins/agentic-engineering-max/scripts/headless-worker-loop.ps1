# bin/headless-worker-loop.ps1
#
# Purpose:
#   Run `claude -p /worker <slug>` on a self-paced loop. Each tick is a
#   fresh, headless Claude session, so this avoids the chat-context-
#   window burn that the in-session /loop pattern incurs. Designed for
#   mobile-driven workflows: start the loop on a desktop, walk away,
#   monitor progress from GitHub notifications on your phone, stop it
#   from anywhere by pushing a stop-sentinel commit.
#
# Usage:
#   .\bin\headless-worker-loop.ps1 <slug> [-WorkerId <id>] [-SleepSeconds <int>] [-MaxTicks <int>]
#
# Stop:
#   Option A: close this window (kills the loop immediately).
#   Option B: from anywhere (including mobile), push a commit that
#             creates planning/<slug>/.locks/<worker-id>.headless-stop.
#             The loop git pulls between ticks and exits on next tick.
#
# Rate-limit consumption (Claude Max subscription):
#   Each tick is a full `claude -p` invocation, which consumes one
#   message slot in the 5-hour rate-limit window. Sub-agents spawned
#   during the tick also consume slots (worker tasks rarely spawn
#   sub-agents). On Claude Max 20x a 38-task build is well within
#   capacity. Set -MaxTicks to bound the loop independently of
#   rate-limit behavior.

param(
    [Parameter(Mandatory, Position = 0)][string]$Slug,
    [string]$WorkerId = 'worker-headless',
    [int]$SleepSeconds = 30,
    [int]$MaxTicks = 100,
    [int]$MaxEmptyTicks = 5,
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
# Fallback: anchor to this script's own location (bin/.. = repo root) so
# the loop works regardless of where the operator launches it from. Same
# pattern as bin/build-board.ps1. Without this fallback, running the
# script via absolute path from outside the repo fails with "could not
# locate repo root."
if (-not $repoRoot) {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $candidate = Split-Path -Parent $scriptDir
    if ($candidate -and (Test-Path (Join-Path $candidate '.git'))) {
        $repoRoot = $candidate
    }
}
if (-not $repoRoot) {
    [Console]::Error.WriteLine('headless-worker-loop: could not locate repo root (no .git found in cwd ancestors or script-dir ancestor).')
    exit 1
}
Set-Location $repoRoot

$env:WORKER_ID = $WorkerId

$planningDir = Join-Path (Join-Path $repoRoot 'planning') $Slug
$locksDir    = Join-Path $planningDir '.locks'
$stopFile    = Join-Path $locksDir ($WorkerId + '.headless-stop')
$boardPath   = Join-Path $planningDir 'task-board.md'
$logDir      = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir ("headless-worker-" + $WorkerId + "-" + (Get-Date -Format 'yyyyMMddHHmmss') + ".log")

# Banner
$bar = '=' * 64
Write-Host $bar -ForegroundColor Green
Write-Host "  Headless worker loop: $WorkerId on $Slug" -ForegroundColor Green
Write-Host $bar -ForegroundColor Green
Write-Host "  log:        $logFile" -ForegroundColor White
Write-Host "  stop-from-mobile: push a commit creating" -ForegroundColor Yellow
Write-Host "                    $stopFile" -ForegroundColor Yellow
Write-Host "  stop-locally:    close this window" -ForegroundColor Yellow
Write-Host "  sleep:      ${SleepSeconds}s between ticks" -ForegroundColor White
Write-Host "  max ticks:  $MaxTicks (safety bound)" -ForegroundColor White
Write-Host $bar -ForegroundColor Green

$tick = 0
$emptyStreak = 0
$exitReason = 'unknown'

# Locate sweep-stale-locks.ps1 (sibling of this script) for per-tick orphan
# recovery. A worker that claimed a task then died leaves an abandoned
# in_progress claim that no other actor recovers; running the sweep at the top
# of each tick self-heals those so a walk-away pipeline does not wedge.
$sweepScript = Join-Path (Split-Path -Parent $PSCommandPath) 'sweep-stale-locks.ps1'

while ($tick -lt $MaxTicks) {
    $tick++

    # git pull so a mobile-pushed stop sentinel becomes visible
    if (-not $NoPull) {
        & git pull --ff-only --quiet 2>$null
        # ignore exit code -- if fetch fails (offline, etc.) we continue
        # with whatever we have locally and try again next tick
    }

    # Self-heal abandoned claims before claiming (advisory; never fatal).
    if (Test-Path $sweepScript) {
        try { & $sweepScript $Slug | Out-Null } catch { }
    }

    if (Test-Path $stopFile) {
        $exitReason = 'stop sentinel found'
        break
    }

    Write-Host ''
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "===== Tick $tick at $ts =====" -ForegroundColor Cyan

    # Run claude -p with the worker prompt
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
        $output = $null | & claude -p "/worker $Slug" --dangerously-skip-permissions 2>&1 | Out-String
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    $tickElapsed = [int]((Get-Date) - $tickStart).TotalSeconds

    # Log everything (file)
    Add-Content -Path $logFile -Value "===== Tick $tick at $ts (${tickElapsed}s) ====="
    Add-Content -Path $logFile -Value $output
    Add-Content -Path $logFile -Value ''

    # Stream a 5-line tail to the console so the operator can monitor
    $tail = ($output -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 5) -join "`n"
    Write-Host $tail

    # Exit conditions based on output content.
    if ($output -match 'ALL TASKS DONE') {
        $exitReason = 'all tasks done sentinel emitted'
        break
    }
    # A momentarily-empty board is NOT a reason to quit a walk-away loop -- the
    # next dependency wave may unblock after a peer's commit/review lands. Only
    # exit after MaxEmptyTicks CONSECUTIVE empty ticks; any tick that does work
    # resets the streak.
    if ($output -match 'no claimable tasks') {
        $emptyStreak++
        Write-Host "  (no claimable tasks; empty streak $emptyStreak/$MaxEmptyTicks)" -ForegroundColor DarkGray
        if ($emptyStreak -ge $MaxEmptyTicks) {
            $exitReason = "no claimable tasks for $MaxEmptyTicks consecutive ticks"
            break
        }
    } else {
        $emptyStreak = 0
    }

    Start-Sleep -Seconds $SleepSeconds
}

if ($tick -ge $MaxTicks) { $exitReason = "max-ticks ($MaxTicks) safety cap reached" }

Write-Host ''
Write-Host $bar -ForegroundColor Green
Write-Host "  Loop exit: $exitReason" -ForegroundColor Green
Write-Host "  Total ticks: $tick" -ForegroundColor Green
Write-Host "  Full log: $logFile" -ForegroundColor Green
Write-Host $bar -ForegroundColor Green
exit 0
