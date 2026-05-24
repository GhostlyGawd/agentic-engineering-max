# bin/headless-reviewer-loop.ps1
#
# Purpose:
#   Run `claude -p /reviewer <slug>` on a self-paced loop. Each tick is a
#   fresh, headless Claude session. Reviewer claims any task in
#   `in_review` status, spawns the 4-stance epistemic panel, synthesizes
#   a verdict, and either marks the task `done` (CLEAN) or sends it
#   back as `needs_fixing` (up to 3 iterations before automatic
#   escalation).
#
# Usage:
#   .\bin\headless-reviewer-loop.ps1 <slug> [-ReviewerId <id>] [-SleepSeconds <int>] [-MaxTicks <int>]
#
# Stop:
#   Option A: close this window (kills the loop immediately).
#   Option B: from anywhere (including mobile), push a commit creating
#             planning/<slug>/.locks/<reviewer-id>.headless-stop.
#             The loop git pulls between ticks and exits on next tick.
#
# Rate-limit consumption (Claude Max subscription):
#   Each reviewer tick spawns 4 sub-agents (pragmatist + falsificationist
#   + hermeneut + bayesian) so it consumes ~5 message slots per tick
#   (1 outer + 4 sub-agents) vs ~1 for a worker tick. On Claude Max 20x
#   a 38-task build is achievable but heavy reviewer parallelism can
#   approach the 5-hour cap. Stagger or throttle if you see rate-limit
#   warnings. Set -MaxTicks to bound the loop independently.
#
# Pair with:
#   bin/headless-worker-loop.ps1 -- workers produce in_review tasks,
#   reviewers consume them. Run both in parallel terminal windows for
#   a continuously-draining build pipeline.

param(
    [Parameter(Mandatory, Position = 0)][string]$Slug,
    [string]$ReviewerId = 'reviewer-headless',
    [int]$SleepSeconds = 60,
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

# Heartbeat stamp (spec D-S1/D-S2). Write/refresh planning/<slug>/.locks/
# heartbeats/<id>.beat at the TOP of each tick, pre-LLM, in pure pwsh. The
# controller (T-003) reads these .beat mtimes for an atomic live-agent count and
# reaps any older than heartbeat_ttl_seconds. OpenOrCreate (not CreateNew)
# because the file legitimately persists across ticks; FileShare='None' still
# serializes concurrent writers, and two stamps of an agent's own uniquely-named
# file never collide. The mtime is bumped explicitly so the controller's TTL
# reap keys on a guaranteed-fresh timestamp regardless of filesystem write-time
# granularity. Advisory: a failure here must never abort the tick (mirrors the
# sweep call's try/catch).
function Write-Heartbeat {
    param([string]$HeartbeatDir, [string]$Id)
    try {
        if (-not (Test-Path $HeartbeatDir)) {
            New-Item -ItemType Directory -Path $HeartbeatDir -Force | Out-Null
        }
        $beatPath = Join-Path $HeartbeatDir ($Id + '.beat')
        $body = $Id + ' ' + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') + [Environment]::NewLine
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($body)
        $fs = [IO.File]::Open($beatPath, 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            $fs.SetLength(0)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush()
        } finally {
            $fs.Dispose()
        }
        (Get-Item $beatPath).LastWriteTimeUtc = [DateTime]::UtcNow
    } catch {
        # Advisory only -- never fatal to the tick.
    }
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
    [Console]::Error.WriteLine('headless-reviewer-loop: could not locate repo root (no .git found in cwd ancestors or script-dir ancestor).')
    exit 1
}
Set-Location $repoRoot

$env:REVIEWER_ID = $ReviewerId

$planningDir = Join-Path (Join-Path $repoRoot 'planning') $Slug
$locksDir    = Join-Path $planningDir '.locks'
$heartbeatDir = Join-Path $locksDir 'heartbeats'
$stopFile    = Join-Path $locksDir ($ReviewerId + '.headless-stop')
$logDir      = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir ("headless-reviewer-" + $ReviewerId + "-" + (Get-Date -Format 'yyyyMMddHHmmss') + ".log")

$bar = '=' * 64
Write-Host $bar -ForegroundColor Magenta
Write-Host "  Headless reviewer loop: $ReviewerId on $Slug" -ForegroundColor Magenta
Write-Host $bar -ForegroundColor Magenta
Write-Host "  log:        $logFile" -ForegroundColor White
Write-Host "  stop-from-mobile: push a commit creating" -ForegroundColor Yellow
Write-Host "                    $stopFile" -ForegroundColor Yellow
Write-Host "  stop-locally:    close this window" -ForegroundColor Yellow
Write-Host "  sleep:      ${SleepSeconds}s between ticks" -ForegroundColor White
Write-Host "  max ticks:  $MaxTicks (safety bound)" -ForegroundColor White
Write-Host $bar -ForegroundColor Magenta

$tick = 0
$emptyStreak = 0
$exitReason = 'unknown'

# Sibling sweep for per-tick orphan recovery (see worker loop rationale).
$sweepScript = Join-Path (Split-Path -Parent $PSCommandPath) 'sweep-stale-locks.ps1'

while ($tick -lt $MaxTicks) {
    $tick++

    if (-not $NoPull) {
        & git pull --ff-only --quiet 2>$null
    }

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

    # Pre-LLM heartbeat stamp (D-S2): refresh this agent's .beat at the top of
    # the tick, before the blocking claude -p call, so the controller sees a
    # fresh live-count for the whole duration of the tick.
    Write-Heartbeat -HeartbeatDir $heartbeatDir -Id $ReviewerId

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
        $output = $null | & claude -p "/reviewer $Slug" --dangerously-skip-permissions 2>&1 | Out-String
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    $tickElapsed = [int]((Get-Date) - $tickStart).TotalSeconds

    Add-Content -Path $logFile -Value "===== Tick $tick at $ts (${tickElapsed}s) ====="
    Add-Content -Path $logFile -Value $output
    Add-Content -Path $logFile -Value ''

    $tail = ($output -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 5) -join "`n"
    Write-Host $tail

    if ($output -match 'ALL TASKS DONE') {
        $exitReason = 'all tasks done sentinel emitted'
        break
    }
    # Retry on a momentarily-empty review queue (workers may not have produced
    # an in_review task yet); exit only after MaxEmptyTicks consecutive empties.
    if ($output -match 'no claimable tasks') {
        $emptyStreak++
        Write-Host "  (no in_review tasks; empty streak $emptyStreak/$MaxEmptyTicks)" -ForegroundColor DarkGray
        if ($emptyStreak -ge $MaxEmptyTicks) {
            $exitReason = "no in_review tasks for $MaxEmptyTicks consecutive ticks"
            break
        }
    } else {
        $emptyStreak = 0
    }

    Start-Sleep -Seconds $SleepSeconds
}

if ($tick -ge $MaxTicks) { $exitReason = "max-ticks ($MaxTicks) safety cap reached" }

Write-Host ''
Write-Host $bar -ForegroundColor Magenta
Write-Host "  Loop exit: $exitReason" -ForegroundColor Magenta
Write-Host "  Total ticks: $tick" -ForegroundColor Magenta
Write-Host "  Full log: $logFile" -ForegroundColor Magenta
Write-Host $bar -ForegroundColor Magenta
exit 0
