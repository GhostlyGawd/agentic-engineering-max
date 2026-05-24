# bin/orchestrator-loop.ps1
#
# Purpose:
#   The deterministic adaptive controller loop (spec T-003, PRD section 7.2).
#   ZERO LLM context: a pure pwsh while-loop that each ~30s tick auto-sizes the
#   worker + reviewer fleets to their claimable-queue widths and spawns fresh
#   single-tick agents to fill the deficit, reaping dead heartbeats so a crashed
#   agent's slot frees. The controller never modifies task state; it only
#   observes width + live count, then spawns or reaps.
#
# Per-tick data flow (PRD 7.2):
#   1. git pull --ff-only           (unless -NoPull)
#   2. build-board.ps1              (regen the board; also the ALL-DONE sentinel)
#   3. sweep-stale-locks.ps1        (D-S4, controller-owned housekeeping)
#   4. reap stale .beat files       (older than heartbeat_ttl_seconds, D-S1)
#   5. workerQueue   = Get-ClaimableWidth   (dot-sourced T-002 helper)
#      reviewerQueue = Get-InReviewWidth
#   6. liveWorkers / liveReviewers  = fresh .beat files by id prefix
#   7. effectiveLive = liveBeats + spawnedThisTick   (thrash guard)
#   8. spawnWorkers   = min(workerQueue,  max_workers)   - effectiveLiveWorkers
#      spawnReviewers = min(reviewerQueue, max_reviewers) - effectiveLiveReviewers
#   9. spawn the deficit (>=1) of detached loop agents, ~400ms staggered,
#      with parent CLAUDE_CODE_* stripped (mirrors launch-build.ps1 exactly)
#  10. exit on ALL TASKS DONE / stop sentinel / MaxTicks
#
# Decisions honored:
#   D-S1  reap stale heartbeats past heartbeat_ttl_seconds; controller-owned sweep
#   D-S2  long-tick busy agent is NOT false-reaped (it re-stamps within TTL)
#   D-S3  claimable width read from the shared frontmatter helper, not the board
#   D-S4  full-board regen + status-aware sweep each tick
#
# Why this script is dot-sourceable:
#   The pure functions (Get-SpawnCount, Invoke-HeartbeatReap, Get-AgentArgLine,
#   Get-OrchestratorCaps) are the unit-test surface (tests/test-orchestrator-loop.ps1).
#   Dot-sourcing defines them and SKIPS the loop (same guard idiom as
#   claimable-width.ps1: $MyInvocation.InvocationName -eq '.').
#
# Spawn-arg foot-gun (mirrors launch-build.ps1, dogfooding find 2026-05-24):
#   The repo path contains a space ("D:\GitHub Projects\..."). Passing an ARRAY
#   to Start-Process -ArgumentList splits the space-containing -File element so
#   the child pwsh prints its usage banner and dies. We pass a single argument
#   STRING with the script path double-quoted, and redirect both child streams
#   to per-agent files (a hidden window otherwise swallows spawn failures).
#
# Usage:
#   pwsh bin/orchestrator-loop.ps1 <slug> [-SleepSeconds 30] [-MaxTicks 200]
#                                         [-NoPull] [-DryRun] [-ControllerId controller]
#
# Exit codes:
#   0  loop exited cleanly (ALL DONE / stop sentinel / MaxTicks) or -DryRun
#   1  bad invocation (missing slug, repo root not found, missing dep script)
#
# Cross-task invariants honored:
#   - ASCII-only inside "..." literals.
#   - No 2>&1 on native exes (git pull uses 2>$null; sweep is a pwsh script).
#   - Paths built with Join-Path / forward slashes (no literal backslash).
#   - All file writes UTF-8.

param(
    [Parameter(Position = 0)][string]$Slug,
    [int]$SleepSeconds = 30,
    [int]$MaxTicks = 200,
    [switch]$NoPull,
    [switch]$DryRun,
    [string]$ControllerId = 'controller'
)

$ErrorActionPreference = 'Stop'

# The parent Claude session env vars stripped before every spawn so each nested
# claude -p gets its own fresh session id (preserves the worker-id <-> session-id
# commit-trailer hard link). Identical list to launch-build.ps1.
$script:ClearVars = @('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SSE_PORT', 'CLAUDE_CODE_SESSION_ID')

function Find-OrchestratorRepoRoot {
    # CWD-first so a test operating in a temp repo resolves to THAT repo, with a
    # fallback to the script's own location two dirs up (bin/.. = repo root).
    $cur = (Get-Location).Path
    while ($cur -and $cur.Length -gt 3) {
        if ((Test-Path (Join-Path $cur '.git')) -or (Test-Path (Join-Path $cur 'planning'))) {
            return $cur
        }
        $parent = Split-Path $cur -Parent
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    $scriptDir = Split-Path -Parent $PSCommandPath
    $candidate = Split-Path -Parent $scriptDir
    if ($candidate -and (Test-Path (Join-Path $candidate 'planning'))) { return $candidate }
    return $null
}

# Per-role spawn deficit. The single piece of arithmetic the whole controller
# turns on: spawn enough to reach min(queue, cap), minus what is already
# effectively live. Floored at 0 (a negative deficit means "spawn nothing").
function Get-SpawnCount {
    param([int]$Queue, [int]$Cap, [int]$EffectiveLive)
    $target  = [Math]::Min($Queue, $Cap)
    $deficit = $target - $EffectiveLive
    if ($deficit -lt 0) { return [int]0 }
    return [int]$deficit
}

# Reap stale heartbeats and count the live set by role prefix. A .beat is stale
# when its mtime age exceeds the TTL (keyed on `-gt`, so an exactly-at-TTL beat
# is kept LIVE). This controller ONLY reads freshness -- it does not stamp beats.
# The re-stamp is a worker/reviewer loop-script obligation (the T-001 contract:
# each agent rewrites its own .beat pre-LLM at the top of every tick). GIVEN that
# contract, a busy agent whose tick is shorter than the TTL stays fresh and is
# NOT false-reaped, which is the D-S2 behavior the reaper honors. With -WhatIf the
# count is read-only (no removal) -- used by -DryRun so a dry run mutates nothing.
function Invoke-HeartbeatReap {
    param([string]$HeartbeatDir, [int]$TtlSeconds, [switch]$WhatIf)
    $liveWorkers = 0; $liveReviewers = 0; $reaped = 0
    if (-not (Test-Path $HeartbeatDir)) {
        return [pscustomobject]@{ LiveWorkers = 0; LiveReviewers = 0; Reaped = 0 }
    }
    $now = [DateTime]::UtcNow
    foreach ($b in @(Get-ChildItem -Path $HeartbeatDir -Filter '*.beat' -File -ErrorAction SilentlyContinue)) {
        $ageSec = ($now - $b.LastWriteTimeUtc).TotalSeconds
        if ($ageSec -gt $TtlSeconds) {
            if (-not $WhatIf) {
                try { Remove-Item $b.FullName -Force; $reaped++ } catch { }
            } else {
                $reaped++
            }
            continue
        }
        $name = $b.BaseName
        if ($name.StartsWith('worker')) { $liveWorkers++ }
        elseif ($name.StartsWith('reviewer')) { $liveReviewers++ }
    }
    return [pscustomobject]@{ LiveWorkers = $liveWorkers; LiveReviewers = $liveReviewers; Reaped = $reaped }
}

# Build the single quoted-string argument line handed to Start-Process. The
# -File path is double-quoted so a spaces-containing repo path is not split into
# two tokens (the launch-build mangling regression). Pure string builder so the
# test can assert the exact shape without a live spawn.
function Get-AgentArgLine {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$Slug,
        [string]$IdParam,
        [string]$RoleId,
        [int]$SleepSeconds = 0
    )
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '" ' + $Slug
    if ($IdParam -and $RoleId) { $argLine += ' ' + $IdParam + ' ' + $RoleId }
    if ($SleepSeconds -gt 0) { $argLine += ' -SleepSeconds ' + $SleepSeconds }
    return $argLine
}

# Resolve caps + TTL from .build-config.json (defaults on any miss). The TTL is a
# DEDICATED key (heartbeat_ttl_seconds), NOT a reuse of stale_lock_minutes -- the
# D-S1 confusion the heartbeat work guards against.
function Get-OrchestratorCaps {
    param([string]$PlanningDir)
    $maxW = 4; $maxR = 2; $ttl = 180
    $cfg = Join-Path $PlanningDir '.build-config.json'
    if (Test-Path $cfg) {
        try {
            $obj = Get-Content -Raw -Encoding utf8 $cfg | ConvertFrom-Json
            if ($obj.PSObject.Properties.Name -contains 'max_workers' -and $obj.max_workers) { $maxW = [int]$obj.max_workers }
            if ($obj.PSObject.Properties.Name -contains 'max_reviewers' -and $obj.max_reviewers) { $maxR = [int]$obj.max_reviewers }
            if ($obj.PSObject.Properties.Name -contains 'heartbeat_ttl_seconds' -and $obj.heartbeat_ttl_seconds) { $ttl = [int]$obj.heartbeat_ttl_seconds }
        } catch { }
    }
    return [pscustomobject]@{ MaxWorkers = $maxW; MaxReviewers = $maxR; TtlSeconds = $ttl }
}

# ===========================================================================
# Dot-source guard: when this file is dot-sourced (InvocationName '.'), define
# the functions above and STOP -- the test consumes the pure functions without
# running the loop. Direct invocation runs the controller.
# ===========================================================================
if ($MyInvocation.InvocationName -eq '.') { return }

if ([string]::IsNullOrWhiteSpace($Slug)) {
    [Console]::Error.WriteLine('orchestrator-loop.ps1: missing slug. Usage: orchestrator-loop.ps1 <slug> [-SleepSeconds n] [-MaxTicks n] [-NoPull] [-DryRun]')
    exit 1
}

$repoRoot = Find-OrchestratorRepoRoot
if (-not $repoRoot) {
    [Console]::Error.WriteLine('orchestrator-loop.ps1: could not locate repo root (no .git or planning/ ancestor).')
    exit 1
}
Set-Location $repoRoot

$planningDir  = Join-Path (Join-Path $repoRoot 'planning') $Slug
if (-not (Test-Path $planningDir)) {
    [Console]::Error.WriteLine("orchestrator-loop.ps1: planning/$Slug not found.")
    exit 1
}
$locksDir     = Join-Path $planningDir '.locks'
$heartbeatDir = Join-Path $locksDir 'heartbeats'
$stopFile     = Join-Path $locksDir ($ControllerId + '.headless-stop')
$boardPath    = Join-Path $planningDir 'task-board.md'

$binDir         = Split-Path -Parent $PSCommandPath
$widthScript    = Join-Path $binDir 'claimable-width.ps1'
$boardScript    = Join-Path $binDir 'build-board.ps1'
$sweepScript    = Join-Path $binDir 'sweep-stale-locks.ps1'
$workerScript   = Join-Path $binDir 'headless-worker-loop.ps1'
$reviewerScript = Join-Path $binDir 'headless-reviewer-loop.ps1'
foreach ($s in @($widthScript, $workerScript, $reviewerScript)) {
    if (-not (Test-Path $s)) {
        [Console]::Error.WriteLine("orchestrator-loop.ps1: required script missing: $s")
        exit 1
    }
}

# Dot-source the shared width helper so Get-ClaimableWidth / Get-InReviewWidth
# are callable in-process (D-S3). The helper's own dot-source guard skips its
# print block, so this defines the functions only. NOTE: claimable-width.ps1
# has a `param($Slug)` block that re-executes in THIS scope on dot-source; it
# shares our variable name, so we pass our $Slug positionally to keep the value
# intact (an argless dot-source would silently reset $Slug to '').
. $widthScript $Slug

$caps = Get-OrchestratorCaps -PlanningDir $planningDir

$logDir = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir ("orchestrator-" + $ControllerId + "-" + (Get-Date -Format 'yyyyMMddHHmmss') + ".log")

$envStripStr = ($script:ClearVars -join ',')

# --- DryRun: one read-only arithmetic pass, parseable line, exit 0 ----------
# Mutates nothing: no pull, no board regen, no sweep, reap in -WhatIf (count
# only). Reports the env-strip set so the test can assert it without a spawn.
if ($DryRun) {
    $workerQueue   = [int](Get-ClaimableWidth -Slug $Slug)
    $reviewerQueue = [int](Get-InReviewWidth  -Slug $Slug)
    $live = Invoke-HeartbeatReap -HeartbeatDir $heartbeatDir -TtlSeconds $caps.TtlSeconds -WhatIf
    $spawnW = Get-SpawnCount -Queue $workerQueue   -Cap $caps.MaxWorkers   -EffectiveLive $live.LiveWorkers
    $spawnR = Get-SpawnCount -Queue $reviewerQueue -Cap $caps.MaxReviewers -EffectiveLive $live.LiveReviewers
    $line = ("TICK 1 workerQueue={0} reviewerQueue={1} liveWorkers={2} liveReviewers={3} spawnWorkers={4} spawnReviewers={5} maxWorkers={6} maxReviewers={7} ttl={8} envstrip={9}" -f `
        $workerQueue, $reviewerQueue, $live.LiveWorkers, $live.LiveReviewers, $spawnW, $spawnR, $caps.MaxWorkers, $caps.MaxReviewers, $caps.TtlSeconds, $envStripStr)
    Write-Output $line
    exit 0
}

# --- Banner -----------------------------------------------------------------
$bar = '=' * 64
Write-Host $bar -ForegroundColor Green
Write-Host "  Adaptive controller: $ControllerId on $Slug" -ForegroundColor Green
Write-Host $bar -ForegroundColor Green
Write-Host "  caps:   max_workers=$($caps.MaxWorkers) max_reviewers=$($caps.MaxReviewers) ttl=$($caps.TtlSeconds)s" -ForegroundColor White
Write-Host "  log:    $logFile" -ForegroundColor White
Write-Host "  stop:   push a commit creating $stopFile" -ForegroundColor Yellow
Write-Host "  sleep:  ${SleepSeconds}s between ticks   max ticks: $MaxTicks" -ForegroundColor White
Write-Host $bar -ForegroundColor Green

# --- Strip parent Claude session env once before the loop -------------------
foreach ($v in $script:ClearVars) {
    if (Test-Path "env:$v") { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
}

# Resolve the pwsh exe running this controller (full path, cross-OS).
$pwshExe = (Get-Process -Id $PID).Path
if (-not $pwshExe) { $pwshExe = 'pwsh' }

function Start-AgentLoop {
    param(
        [string]$PwshExe, [string]$Script, [string]$Slug,
        [string]$IdParam, [string]$RoleId, [int]$SleepSeconds,
        [string]$LogDir, [string]$Stamp
    )
    $argLine  = Get-AgentArgLine -Script $Script -Slug $Slug -IdParam $IdParam -RoleId $RoleId -SleepSeconds $SleepSeconds
    $spawnOut = Join-Path $LogDir ("spawn-" + $RoleId + "-" + $Stamp + ".out.log")
    $spawnErr = Join-Path $LogDir ("spawn-" + $RoleId + "-" + $Stamp + ".err.log")
    return Start-Process -FilePath $PwshExe -ArgumentList $argLine -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $spawnOut -RedirectStandardError $spawnErr
}

$tick = 0
$exitReason = 'unknown'

while ($tick -lt $MaxTicks) {
    $tick++

    if (-not $NoPull) {
        & git pull --ff-only --quiet 2>$null
        # ignore exit code -- offline or non-ff just means we run on local state
    }

    if (Test-Path $stopFile) { $exitReason = 'stop sentinel found'; break }

    # Regenerate the board (also writes the *** ALL TASKS DONE sentinel line).
    # A swallowed exception here would leave the ALL-DONE sentinel stale and the
    # loop running blind to MaxTicks, so the catch LOGS rather than silently
    # eating the error; an absent board script is warned once per tick too.
    if (Test-Path $boardScript) {
        try { & $boardScript $Slug | Out-Null }
        catch { Add-Content -Path $logFile -Value ("tick ${tick}: board regen error: " + $_.Exception.Message) }
    } else {
        Add-Content -Path $logFile -Value ("tick ${tick}: WARNING board script absent ($boardScript); ALL-DONE sentinel will not refresh")
    }

    # Status-aware orphan sweep (D-S4). Controller-owned; stdout into the log.
    if (Test-Path $sweepScript) {
        try {
            $sweepOut = & $sweepScript $Slug | Out-String
            Add-Content -Path $logFile -Value $sweepOut
        }
        catch { Add-Content -Path $logFile -Value ("tick ${tick}: sweep error: " + $_.Exception.Message) }
    }

    # ALL TASKS DONE: re-check the board's sentinel BEFORE the spawn block so a
    # terminal tick does not waste spawns on an already-finished board (the
    # board was just regenerated above, so this reads the current state).
    if (Test-Path $boardPath) {
        $boardRaw = Get-Content -Raw -Encoding utf8 -Path $boardPath -ErrorAction SilentlyContinue
        if ($boardRaw -match 'ALL TASKS DONE') { $exitReason = 'all tasks done sentinel'; break }
    }

    # Reap stale heartbeats and read the live set (D-S1/D-S2).
    $live = Invoke-HeartbeatReap -HeartbeatDir $heartbeatDir -TtlSeconds $caps.TtlSeconds

    $workerQueue   = [int](Get-ClaimableWidth -Slug $Slug)
    $reviewerQueue = [int](Get-InReviewWidth  -Slug $Slug)

    # effectiveLive = liveBeats + spawnedThisTick. Each role's deficit is computed
    # ONCE per tick here (spawnedThisTick is 0 at the single compute), then the
    # for-loop spawns exactly that deficit. The thrash guard is the +spawnedThisTick
    # term threaded into EffectiveLive: were the deficit ever recomputed mid-tick
    # (e.g. a future batch-spawn refactor), the already-spawned count would keep it
    # from exceeding the cap. That within-tick property is unit-tested in
    # tests/test-orchestrator-loop.ps1 Group 2; the post-spawn effLive values are
    # emitted on the TICK line below so the thrash term is observable in the log.
    $spawnedWorkers   = 0
    $spawnedReviewers = 0
    $stamp = (Get-Date -Format 'yyyyMMddHHmmss')

    $spawnWorkers = Get-SpawnCount -Queue $workerQueue -Cap $caps.MaxWorkers -EffectiveLive ($live.LiveWorkers + $spawnedWorkers)
    for ($i = 0; $i -lt $spawnWorkers; $i++) {
        $roleId = "worker-c$tick-$i"
        $null = Start-AgentLoop -PwshExe $pwshExe -Script $workerScript -Slug $Slug -IdParam '-WorkerId' -RoleId $roleId -SleepSeconds $SleepSeconds -LogDir $logDir -Stamp $stamp
        $spawnedWorkers++
        Start-Sleep -Milliseconds 400
    }

    $spawnReviewers = Get-SpawnCount -Queue $reviewerQueue -Cap $caps.MaxReviewers -EffectiveLive ($live.LiveReviewers + $spawnedReviewers)
    for ($i = 0; $i -lt $spawnReviewers; $i++) {
        $roleId = "reviewer-c$tick-$i"
        $null = Start-AgentLoop -PwshExe $pwshExe -Script $reviewerScript -Slug $Slug -IdParam '-ReviewerId' -RoleId $roleId -SleepSeconds $SleepSeconds -LogDir $logDir -Stamp $stamp
        $spawnedReviewers++
        Start-Sleep -Milliseconds 400
    }

    # One deterministic controller log line per tick. effLiveW/effLiveR are the
    # post-spawn effective-live counts (liveBeats + spawnedThisTick) so the thrash
    # term is observable, not just an internal arithmetic input.
    $line = ("TICK {0} workerQueue={1} reviewerQueue={2} liveWorkers={3} liveReviewers={4} spawnWorkers={5} spawnReviewers={6} effLiveW={7} effLiveR={8} reaped={9}" -f `
        $tick, $workerQueue, $reviewerQueue, $live.LiveWorkers, $live.LiveReviewers, $spawnWorkers, $spawnReviewers, ($live.LiveWorkers + $spawnedWorkers), ($live.LiveReviewers + $spawnedReviewers), $live.Reaped)
    Write-Host $line -ForegroundColor Cyan
    Add-Content -Path $logFile -Value $line

    Start-Sleep -Seconds $SleepSeconds
}

if ($tick -ge $MaxTicks) { $exitReason = "max-ticks ($MaxTicks) safety cap reached" }

# Machine-parseable exit signal on stdout (stream 1) so a parent / test can
# observe WHICH terminating condition fired without scraping the colored banner.
# The banner below is the human-facing echo of the same fact.
$exitLine = "CONTROLLER EXIT reason=$exitReason ticks=$tick"
Write-Output $exitLine
Add-Content -Path $logFile -Value $exitLine

Write-Host ''
Write-Host $bar -ForegroundColor Green
Write-Host "  Controller exit: $exitReason" -ForegroundColor Green
Write-Host "  Total ticks: $tick" -ForegroundColor Green
Write-Host "  Full log: $logFile" -ForegroundColor Green
Write-Host $bar -ForegroundColor Green
exit 0
