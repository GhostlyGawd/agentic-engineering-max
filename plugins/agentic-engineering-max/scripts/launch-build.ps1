# scripts/launch-build.ps1 (plugin port of Dev_006 bin/launch-build.ps1)
#
# Plugin-port note: this file is a near-byte-equivalent copy of the workspace
# bin/launch-build.ps1. The ONE intentional difference: the workspace fallback
# that anchors repo-root to `<scriptDir>/..` (correct for bin/.. = repo root)
# is removed -- in the plugin install context, <scriptDir>/.. is the plugin
# install dir, not the user's repo. cwd-walk remains the only repo-root source.
# Original header preserved below for context.
#
# Purpose:
#   Thin launcher for the adaptive headless build. The DEFAULT launch path
#   starts exactly ONE detached `orchestrator-loop.ps1` (the deterministic
#   controller, spec T-003). The controller then auto-sizes the worker +
#   reviewer fleets each tick from the claimable-queue widths, capped by
#   `.build-config.json` (max_workers / max_reviewers). This launcher no longer
#   spawns a STATIC `-Workers N -Reviewers M` fleet -- the static-sizing footgun
#   (over- or under-provisioning a fixed fleet that ignores the live queue) is
#   removed. Caps live in config; the controller reads them itself.
#
#   Optionally (default on, suppress with -NoPm) a `/pm` escalation-narrator
#   observer loop is also launched. PM is OPTIONAL: the controller owns board
#   regen and stale-lock sweeping itself, so the build runs to completion with
#   or without PM. -NoPm just means "no narrator."
#
#   Also default-on (suppress with -NoPush) a VISIBILITY pusher loop is
#   launched: a single push-only loop (bin/headless-pusher-loop.ps1) that runs
#   `git push origin HEAD` every ~45s so the build's LOCAL commits surface on
#   GitHub live -- progress + phone notifications while you walk away. Workers
#   and reviewers only commit locally, so without this the build is invisible
#   on GitHub until something pushes. The pusher never commits (no index
#   contention with the workers) and self-exits when all tasks are done.
#
# Walk-away semantics:
#   Each loop is launched via Start-Process as an independent detached process
#   that keeps running after this launcher returns. The launcher prints a launch
#   table (role / id / pid) and exits immediately. Monitor from GitHub commit
#   notifications, `/board <slug>`, or the per-loop logs under logs/. Stop the
#   controller by pushing a commit that creates
#   planning/<slug>/.locks/controller.headless-stop, or by stopping its pid.
#
# Why clear the parent session env vars:
#   When Claude launches this script, the process tree inherits the parent
#   Claude Code session env (CLAUDECODE, CLAUDE_CODE_SESSION_ID, the SSE
#   port, the entrypoint). If a nested `claude -p` inherited
#   CLAUDE_CODE_SESSION_ID, every agent would stamp the ORCHESTRATOR's session
#   id into its `Claude-Session-ID:` commit trailer, collapsing the
#   worker-id <-> session-id hard link the build relies on for traceability.
#   So we strip them here; every spawned loop's nested claude then gets its own
#   fresh session id, exactly as if launched from a clean terminal. (The
#   controller strips the same set again before ITS spawns -- belt and braces.)
#
# Usage (preferred, from a Claude Code session with the plugin installed):
#   /launch-build <slug> [-NoPm] [-NoPush] [-SleepSeconds <int>] [-MaxTicks <int>] [-DryRun]
#
# Usage (direct, from any shell with the plugin scripts on disk):
#   pwsh ${CLAUDE_PLUGIN_ROOT}/scripts/launch-build.ps1 <slug> [-NoPm] [-NoPush] [-SleepSeconds <int>]
#                                                              [-MaxTicks <int>] [-DryRun]
#
# Examples:
#   /launch-build my-build
#   /launch-build my-build -NoPm
#   /launch-build my-build -DryRun        # print plan, spawn nothing
#
# Exit codes:
#   0  launched (or dry-run printed) successfully
#   2  planning/<slug> directory not found
#   3  no task files under planning/<slug>/tasks (spec not seeded yet)
#   4  a required loop script is missing (orchestrator-loop.ps1, or the PM loop
#      when PM is requested)

param(
    [Parameter(Mandatory, Position = 0)][string]$Slug,
    [switch]$NoPm,
    [switch]$NoPush,
    [int]$SleepSeconds = 0,
    [int]$MaxTicks = 0,
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
# Plugin port: NO scriptDir-parent fallback. The plugin script lives outside
# the user's repo (under the Claude Code plugin install dir), so anchoring to
# <scriptDir>/.. would resolve to the plugin install path, not the user's
# repo. cwd-walk is the only source.
if (-not $repoRoot) {
    [Console]::Error.WriteLine('launch-build: not inside a git repo (cwd-walk found no .git ancestor). Run /launch-build from the repo root.')
    exit 2
}
Set-Location $repoRoot

# Return the leftover stop-sentinel files in a build's .locks dir. ANY
# *.headless-stop present at launch time is stale by definition: it is a
# leftover from a previous (non-clean) stop, and a fresh loop that finds it
# would exit on tick 1 -- the silent-no-op-on-resume footgun (plan-ledger v1.10
# finding #1). The controller stops on controller.headless-stop; workers and
# reviewers on <id>.headless-stop; the *.headless-stop glob covers all of them.
function Get-StaleStopSentinels {
    param([string]$LocksDir)
    if (-not (Test-Path $LocksDir)) { return @() }
    return @(Get-ChildItem -Path $LocksDir -Filter '*.headless-stop' -File -ErrorAction SilentlyContinue)
}

# --- Validate the build is launchable -------------------------------------
$planningDir = Join-Path (Join-Path $repoRoot 'planning') $Slug
if (-not (Test-Path $planningDir)) {
    [Console]::Error.WriteLine("launch-build: planning/$Slug not found. Is the slug correct?")
    exit 2
}
# Detect leftover stop sentinels up front so both the dry-run summary and the
# live launch can act on them. (.locks/*.headless-stop are local-only, untracked
# per .gitignore, so a plain Remove-Item below is sufficient -- a subsequent
# `git pull --ff-only` in a loop will not resurrect them.)
$locksDir       = Join-Path $planningDir '.locks'
$staleSentinels = Get-StaleStopSentinels -LocksDir $locksDir
$tasksDir  = Join-Path $planningDir 'tasks'
$taskFiles = @()
if (Test-Path $tasksDir) {
    $taskFiles = @(Get-ChildItem -Path $tasksDir -Filter 'task-*.md' -File -ErrorAction SilentlyContinue)
}
if ($taskFiles.Count -eq 0) {
    [Console]::Error.WriteLine("launch-build: no task-*.md under planning/$Slug/tasks. Seed the spec before launching a build.")
    exit 3
}

# --- Resolve the loop scripts ---------------------------------------------
# The controller is required. The PM loop is required only when PM is requested.
$binDir              = Split-Path -Parent $PSCommandPath
$controllerScript    = Join-Path $binDir 'orchestrator-loop.ps1'
$pmScript            = Join-Path $binDir 'headless-pm-loop.ps1'
$pusherScript        = Join-Path $binDir 'headless-pusher-loop.ps1'
if (-not (Test-Path $controllerScript)) {
    [Console]::Error.WriteLine("launch-build: required controller script missing: $controllerScript")
    exit 4
}
if (-not $NoPm -and -not (Test-Path $pmScript)) {
    [Console]::Error.WriteLine("launch-build: required PM loop script missing: $pmScript (pass -NoPm to launch without PM)")
    exit 4
}
if (-not $NoPush -and -not (Test-Path $pusherScript)) {
    [Console]::Error.WriteLine("launch-build: required pusher loop script missing: $pusherScript (pass -NoPush to launch without the GitHub visibility pusher)")
    exit 4
}

# --- Resolve caps from .build-config.json (for the plan summary only) ------
# The controller reads these itself at runtime; we read them here purely so the
# launch table / dry-run summary reports what the controller will enforce.
# Defaults mirror orchestrator-loop.ps1's Get-OrchestratorCaps.
function Get-LaunchCaps {
    param([string]$PlanningDir)
    $maxW = 4; $maxR = 2
    $cfg = Join-Path $PlanningDir '.build-config.json'
    if (Test-Path $cfg) {
        try {
            $obj = Get-Content -Raw -Encoding utf8 $cfg | ConvertFrom-Json
            if ($obj.PSObject.Properties.Name -contains 'max_workers' -and $obj.max_workers) { $maxW = [int]$obj.max_workers }
            if ($obj.PSObject.Properties.Name -contains 'max_reviewers' -and $obj.max_reviewers) { $maxR = [int]$obj.max_reviewers }
        } catch { }
    }
    return [pscustomobject]@{ MaxWorkers = $maxW; MaxReviewers = $maxR }
}
$caps = Get-LaunchCaps -PlanningDir $planningDir

# --- Build the launch plan -------------------------------------------------
# controller (always) + pm (unless -NoPm). The controller spawns the
# worker/reviewer agents itself; this launcher does not enumerate a fleet.
$plan = New-Object System.Collections.Generic.List[object]
$plan.Add([pscustomobject]@{ Role = 'controller'; Id = 'controller'; Script = $controllerScript; IsController = $true })
if (-not $NoPm) {
    $plan.Add([pscustomobject]@{ Role = 'pm'; Id = 'pm'; Script = $pmScript; IsController = $false })
}
# Visibility pusher (default on): a single push-only loop that surfaces the
# build's local commits to GitHub every few ticks, so progress is visible +
# phone-notifiable while the build runs headless. -NoPush suppresses it.
if (-not $NoPush) {
    $plan.Add([pscustomobject]@{ Role = 'pusher'; Id = 'pusher'; Script = $pusherScript; IsController = $false })
}

$bar = '=' * 70
Write-Host $bar -ForegroundColor Green
Write-Host "  launch-build: $Slug" -ForegroundColor Green
Write-Host "  tasks on disk: $($taskFiles.Count)   plan: $($plan.Count) loop(s)" -ForegroundColor Green
Write-Host "  caps (from config): max_workers=$($caps.MaxWorkers) max_reviewers=$($caps.MaxReviewers)" -ForegroundColor Green
if ($DryRun) { Write-Host "  MODE: DRY RUN (no processes will be spawned)" -ForegroundColor Yellow }
Write-Host $bar -ForegroundColor Green

# Build the controller-only flag suffix shared by the dry-run plan line and the
# live spawn arg string. -MaxTicks is controller-only; -SleepSeconds applies to
# both the controller and the PM loop.
$sleepSuffix = if ($SleepSeconds -gt 0) { " -SleepSeconds $SleepSeconds" } else { '' }
$ticksSuffix = if ($MaxTicks -gt 0)     { " -MaxTicks $MaxTicks" }         else { '' }

# --- Dry-run: print a stable, parseable plan and exit ----------------------
if ($DryRun) {
    foreach ($p in $plan) {
        $extra = $sleepSuffix
        if ($p.IsController) { $extra += $ticksSuffix }
        # Machine-parseable line consumed by tests/test-launch-build.ps1.
        Write-Host ("PLAN role={0} id={1} script={2} slug={3}{4}" -f `
            $p.Role, $p.Id, (Split-Path -Leaf $p.Script), $Slug, $extra)
    }
    $pmFlag = if ($NoPm) { 'false' } else { 'true' }
    $pushFlag = if ($NoPush) { 'false' } else { 'true' }
    Write-Host ("PLAN-SUMMARY total={0} controller=1 pm={1} push={2} slug={3} max_workers={4} max_reviewers={5}" -f `
        $plan.Count, $pmFlag, $pushFlag, $Slug, $caps.MaxWorkers, $caps.MaxReviewers)
    # Report (do NOT clear -- dry-run mutates nothing) any stale stop sentinels a
    # live launch would clear. count=0 when clean so the line is always present.
    $sentinelNames = ($staleSentinels | ForEach-Object { $_.Name }) -join ','
    Write-Host ("PLAN-STALE-SENTINELS count={0} files={1}" -f $staleSentinels.Count, $sentinelNames)
    exit 0
}

# --- Clear stale stop sentinels before spawning (v1.10 finding #1) ----------
# A leftover *.headless-stop from a previous non-clean stop would make every
# freshly-spawned loop exit on tick 1 -- a silent no-op resume. Clear them with
# a LOUD warning so a resume actually resumes, and the operator knows why the
# previous run might have looked wedged.
if ($staleSentinels.Count -gt 0) {
    Write-Host ''
    Write-Host ("  WARNING: clearing {0} stale stop-sentinel(s) left in .locks/ by a previous run --" -f $staleSentinels.Count) -ForegroundColor Yellow
    Write-Host "           without this every spawned loop would exit on tick 1 (silent no-op resume)." -ForegroundColor Yellow
    foreach ($s in $staleSentinels) {
        try {
            Remove-Item $s.FullName -Force -ErrorAction Stop
            Write-Host ("           cleared: " + $s.Name) -ForegroundColor Yellow
        } catch {
            Write-Host ("           FAILED to clear " + $s.Name + ": " + $_.Exception.Message) -ForegroundColor Red
        }
    }
}

# --- Strip parent Claude session env so each nested claude gets its own id -
$clearVars = @('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SSE_PORT', 'CLAUDE_CODE_SESSION_ID')
foreach ($v in $clearVars) {
    if (Test-Path "env:$v") { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
}

# Resolve the pwsh executable running this script (cross-platform: full path
# on both Windows and Linux). Fall back to the PATH name.
$pwshExe = (Get-Process -Id $PID).Path
if (-not $pwshExe) { $pwshExe = 'pwsh' }

$logDir = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

$launchStamp = (Get-Date -Format 'yyyyMMddHHmmss')
$launched = New-Object System.Collections.Generic.List[object]
foreach ($p in $plan) {
    # Build a single argument STRING with the script path double-quoted.
    # The repo path can contain spaces (e.g. "D:\GitHub Projects\..."); passing
    # an ARRAY to Start-Process -ArgumentList splits a space-containing element
    # so the child pwsh receives "-File D:\GitHub" + "Projects\..." as separate
    # tokens, prints its usage banner, and exits -- the loop never starts
    # (symptom: all PIDs gone within seconds). A quoted single string parses
    # correctly on both OSes. Dogfooding find 2026-05-24 (do NOT regress).
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $p.Script + '" ' + $Slug + $sleepSuffix
    if ($p.IsController) { $argLine += $ticksSuffix }

    # Redirect the detached child's streams to files. The hidden window has no
    # visible console, so without this a mangled or crashing launch is silent;
    # with it the failure is captured for diagnosis. Distinct files required.
    $spawnOut = Join-Path $logDir ("spawn-" + $p.Id + "-" + $launchStamp + ".out.log")
    $spawnErr = Join-Path $logDir ("spawn-" + $p.Id + "-" + $launchStamp + ".err.log")
    # -WindowStyle is Windows-only; Linux/macOS pwsh throws "The parameter
    # '-WindowStyle' is not supported for the cmdlet 'Start-Process' on this
    # edition of PowerShell." A hidden window is a Windows nicety with no Linux
    # analog, so add it conditionally. Dogfooding find 2026-05-25 (Linux CI).
    $spArgs = @{
        FilePath               = $pwshExe
        ArgumentList           = $argLine
        PassThru               = $true
        RedirectStandardOutput = $spawnOut
        RedirectStandardError  = $spawnErr
    }
    if ($IsWindows) { $spArgs['WindowStyle'] = 'Hidden' }
    $proc = Start-Process @spArgs
    $launched.Add([pscustomobject]@{ Role = $p.Role; Id = $p.Id; Pid = $proc.Id })
    # Small stagger so the controller's first board regen settles before PM's.
    Start-Sleep -Milliseconds 400
}

Write-Host ''
Write-Host "  Launched (detached -- these survive this command returning):" -ForegroundColor Green
Write-Host ("  {0,-12} {1,-12} {2}" -f 'ROLE', 'ID', 'PID') -ForegroundColor White
foreach ($l in $launched) {
    Write-Host ("  {0,-12} {1,-12} {2}" -f $l.Role, $l.Id, $l.Pid)
}
Write-Host ''
Write-Host "  The controller auto-sizes worker/reviewer fleets each tick" -ForegroundColor White
Write-Host "  (capped at max_workers=$($caps.MaxWorkers) max_reviewers=$($caps.MaxReviewers) from .build-config.json)." -ForegroundColor White
Write-Host "  logs:  $logDir/spawn-*.log and orchestrator-*.log" -ForegroundColor White
if ($NoPush) {
    Write-Host "  watch: /board $Slug   (NOTE: -NoPush, so commits stay LOCAL -- push manually to see them on GitHub)" -ForegroundColor White
} else {
    Write-Host "  watch: GitHub -- the pusher auto-pushes commits live (~45s); also /board $Slug" -ForegroundColor White
}
Write-Host "  stop:  push a commit creating planning/$Slug/.locks/controller.headless-stop" -ForegroundColor Yellow
Write-Host "         (or: Stop-Process -Id <pid>)" -ForegroundColor Yellow
Write-Host $bar -ForegroundColor Green
exit 0
