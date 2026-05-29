# bin/headless-pusher-loop.ps1
#
# Purpose:
#   The VISIBILITY loop. Workers and reviewers commit their work LOCALLY as
#   they go but never push, so a headless build is invisible on GitHub until
#   something pushes. This single dedicated loop pushes the current branch to
#   origin every few ticks, so each task completion / review verdict lands on
#   GitHub within seconds -- giving live progress + phone notifications while
#   the build runs headless and the operator walks away.
#
#   PUSH-ONLY by design: this loop NEVER commits and never edits files. It only
#   runs `git push origin HEAD`. Because it is the single pusher (one process),
#   there are no concurrent-push races; because it never commits, it never
#   contends with the workers'/reviewers' shared git index. Dead simple, safe.
#
# Usage:
#   .\bin\headless-pusher-loop.ps1 <slug> [-SleepSeconds <int>] [-MaxTicks <int>] [-DryRun]
#
# Stop:
#   Option A: close this window / Stop-Process the pid.
#   Option B: a stop sentinel at planning/<slug>/.locks/pusher.headless-stop
#             OR planning/<slug>/.locks/controller.headless-stop (so stopping
#             the build's controller also stops the pusher).
#   Option C: automatic -- when every task is `done`, the pusher does one final
#             push and exits (the build is over; nothing more to surface).
#
# Rate-limit note:
#   This loop spawns NO `claude -p` and consumes ZERO message slots. It is pure
#   git. Run it freely alongside the build.

param(
    [Parameter(Mandatory, Position = 0)][string]$Slug,
    [int]$SleepSeconds = 45,
    [int]$MaxTicks = 480,
    [switch]$DryRun
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
# Fallback: anchor to this script's own location (bin/.. = repo root) so the
# loop works regardless of the caller's cwd. Same pattern as the other loops.
if (-not $repoRoot) {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $candidate = Split-Path -Parent $scriptDir
    if ($candidate -and (Test-Path (Join-Path $candidate '.git'))) {
        $repoRoot = $candidate
    }
}
if (-not $repoRoot) {
    [Console]::Error.WriteLine('headless-pusher-loop: could not locate repo root (no .git found in cwd ancestors or script-dir ancestor).')
    exit 1
}
Set-Location $repoRoot

$planningDir = Join-Path (Join-Path $repoRoot 'planning') $Slug
if (-not (Test-Path $planningDir)) {
    [Console]::Error.WriteLine("headless-pusher-loop: planning/$Slug not found.")
    exit 2
}
$locksDir       = Join-Path $planningDir '.locks'
$tasksDir       = Join-Path $planningDir 'tasks'
$stopFile       = Join-Path $locksDir 'pusher.headless-stop'
$controllerStop = Join-Path $locksDir 'controller.headless-stop'
$logDir         = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir ("headless-pusher-" + $Slug + "-" + (Get-Date -Format 'yyyyMMddHHmmss') + ".log")

# Count task statuses by reading frontmatter. Returns a hashtable of counts plus
# Total. Pure file read; never touches git. Used to auto-stop when all done.
function Get-TaskStatusCounts {
    param([string]$TasksDir)
    $counts = @{ done = 0; other = 0; total = 0 }
    if (-not (Test-Path $TasksDir)) { return $counts }
    foreach ($t in (Get-ChildItem -Path $TasksDir -Filter 'task-*.md' -File -ErrorAction SilentlyContinue)) {
        $counts.total++
        $line = Select-String -Path $t.FullName -Pattern '^status:\s*(\S+)' | Select-Object -First 1
        $s = if ($line) { $line.Matches[0].Groups[1].Value } else { '' }
        if ($s -eq 'done') { $counts.done++ } else { $counts.other++ }
    }
    return $counts
}

# Resolve the current branch name once (HEAD push targets origin/<this branch>).
$branch = (& git rev-parse --abbrev-ref HEAD 2>$null).Trim()
if (-not $branch -or $branch -eq 'HEAD') { $branch = 'HEAD' }

$bar = '=' * 64
Write-Host $bar -ForegroundColor Green
Write-Host "  Headless pusher loop on $Slug" -ForegroundColor Green
Write-Host "  branch:     $branch -> origin" -ForegroundColor White
Write-Host "  sleep:      ${SleepSeconds}s between pushes" -ForegroundColor White
Write-Host "  max ticks:  $MaxTicks (safety bound)" -ForegroundColor White
Write-Host "  stop:       push/create planning/$Slug/.locks/pusher.headless-stop" -ForegroundColor Yellow
Write-Host "  log:        $logFile" -ForegroundColor White
if ($DryRun) { Write-Host "  MODE: DRY RUN (no pushes will happen)" -ForegroundColor Yellow }
Write-Host $bar -ForegroundColor Green

# DryRun: print the push command that WOULD run, confirm the stop/auto-stop
# wiring, push nothing, exit. Consumed by tests/test-headless-pusher-loop.ps1.
if ($DryRun) {
    $c = Get-TaskStatusCounts -TasksDir $tasksDir
    Write-Host ("DRYRUN push-cmd: git push origin {0}" -f $branch)
    Write-Host ("DRYRUN status: {0}/{1} done" -f $c.done, $c.total)
    Write-Host ("DRYRUN stop-sentinels: {0} ; {1}" -f $stopFile, $controllerStop)
    exit 0
}

$tick = 0
$doneStreak = 0
$exitReason = 'unknown'

while ($tick -lt $MaxTicks) {
    $tick++

    if ((Test-Path $stopFile) -or (Test-Path $controllerStop)) {
        # One last push so the final state is surfaced, then stop.
        & git push origin HEAD 2>$null | Out-Null
        $exitReason = 'stop sentinel found (final push done)'
        break
    }

    $ts = Get-Date -Format 'HH:mm:ss'
    & git push origin HEAD 2>$null | Out-Null
    $pushExit = $LASTEXITCODE
    $result = if ($pushExit -eq 0) { 'ok' } else { "push exit $pushExit (will retry next tick)" }

    $c = Get-TaskStatusCounts -TasksDir $tasksDir
    $msg = "[$ts] tick $tick push=$result  status=$($c.done)/$($c.total) done"
    Write-Host $msg -ForegroundColor Cyan
    Add-Content -Path $logFile -Value $msg

    # Auto-stop: when every task is done, push once more and exit. Require two
    # consecutive all-done reads so a momentary board state mid-write does not
    # trip an early exit.
    if ($c.total -gt 0 -and $c.done -eq $c.total) {
        $doneStreak++
        if ($doneStreak -ge 2) {
            & git push origin HEAD 2>$null | Out-Null
            $exitReason = "all $($c.total) tasks done (final push done)"
            break
        }
    } else {
        $doneStreak = 0
    }

    Start-Sleep -Seconds $SleepSeconds
}

if ($tick -ge $MaxTicks) { $exitReason = "max-ticks ($MaxTicks) safety cap reached" }

Write-Host ''
Write-Host $bar -ForegroundColor Green
Write-Host "  Pusher loop exit: $exitReason" -ForegroundColor Green
Write-Host "  Total ticks: $tick" -ForegroundColor Green
Write-Host $bar -ForegroundColor Green
exit 0
