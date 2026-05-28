# bin/wake-sentinel.ps1
#
# Purpose:
#   The wake-sentinel primitive -- the symmetric twin of the shipped `.stop`
#   sentinel idiom (spec D-S4). The controller goes dormant on drain instead of
#   exiting; a wake-sentinel is the filesystem signal that pulls it out of
#   dormancy early (before its coarse safety timer fires) when new work appears.
#   Dropped by `/task-create`, gate-approval, and rehydrated findings; consumed
#   by the dormant controller (T-203).
#
# Decisions:
#   D-S4 (wake-sentinel is the symmetric twin of the `.stop` sentinel idiom)
#
# Mechanism (mirrors the heartbeat / `.stop` create idiom exactly):
#   New-WakeSentinel        -- atomic [IO.File]::Open(..., 'CreateNew',
#                              'ReadWrite', 'None') create of
#                              planning/<slug>/.locks/<controllerid>.wake, body =
#                              ISO-now. Creates .locks/ if absent. A CreateNew
#                              collision is NON-FATAL: the sentinel already
#                              exists, which is exactly the state we wanted, so
#                              no throw escapes the helper.
#   Test-AndClearWakeSentinel -- returns $true and deletes the file when
#                              present, $false when absent. This is the
#                              controller's consume-on-wake call.
#
# Both functions are dot-sourceable AND the script is directly invokable
# (drops a wake-sentinel and prints `wake <created|present>: <path>`).
#
# Cross-task invariants honored:
#   - ASCII-only inside "..." literals.
#   - No 2>&1 on native exes (pure PS file ops; no native exes invoked).
#   - Paths built with Join-Path / forward slashes (no literal backslash).
#   - UTF-8 (no BOM) for the sentinel body.

param(
    [Parameter(Position = 0)]
    [string]$Slug,

    [Parameter(Position = 1)]
    [string]$ControllerId = 'controller'
)

$ErrorActionPreference = 'Stop'

function Find-WakeRepoRoot {
    # Walk up from the current location looking for a repo marker. CWD-first
    # (not $PSScriptRoot-first) so a dot-sourcing test operating in a temp repo
    # resolves to THAT repo, not the real bin/.. the script lives in. Same
    # pattern as claimable-width.ps1's Find-ClaimableRepoRoot.
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

# Compute the wake-sentinel path for a slug + controller id. Pure path math;
# does not touch the filesystem. Returns $null when the repo root cannot be
# resolved.
function Get-WakeSentinelPath {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [string]$ControllerId = 'controller'
    )
    $repoRoot = Find-WakeRepoRoot
    if (-not $repoRoot) { return $null }
    $locksDir = Join-Path (Join-Path (Join-Path $repoRoot 'planning') $Slug) '.locks'
    return (Join-Path $locksDir ($ControllerId + '.wake'))
}

# Drop a wake-sentinel. Returns the sentinel path on success (whether freshly
# created or already present), $null when the repo root cannot be resolved. A
# CreateNew collision means the sentinel already exists -- exactly the desired
# end state -- so it is swallowed and no throw escapes.
function New-WakeSentinel {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [string]$ControllerId = 'controller'
    )

    $path = Get-WakeSentinelPath -Slug $Slug -ControllerId $ControllerId
    if (-not $path) { return $null }

    $locksDir = Split-Path -Parent $path
    if (-not (Test-Path $locksDir)) {
        # -Force is idempotent: concurrent droppers racing on the dir do not throw.
        New-Item -ItemType Directory -Path $locksDir -Force | Out-Null
    }

    $body  = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') + [Environment]::NewLine
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($body)
    try {
        $fs = [IO.File]::Open($path, 'CreateNew', 'ReadWrite', 'None')
        try {
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush()
        } finally {
            $fs.Dispose()
        }
    } catch [System.IO.IOException] {
        # CreateNew collision (file exists) OR a peer dropper holding it mid-write
        # with FileShare='None' (sharing violation). Either way the sentinel is
        # present, which is the state we wanted -- non-fatal. Re-throw only if the
        # path genuinely does not exist afterward (a real IO error, not a race).
        if (-not (Test-Path $path)) { throw }
    }
    return $path
}

# Consume a wake-sentinel: delete + return $true when present, $false when
# absent. The controller's wake-check calls this each dormant poll.
function Test-AndClearWakeSentinel {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [string]$ControllerId = 'controller'
    )

    $path = Get-WakeSentinelPath -Slug $Slug -ControllerId $ControllerId
    if (-not $path) { return $false }
    if (-not (Test-Path $path)) { return $false }
    Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
    return $true
}

# Direct invocation: drop a wake-sentinel and print a one-line summary.
# Dot-sourcing (InvocationName '.') defines the functions only and skips this.
if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($Slug)) {
        [Console]::Error.WriteLine('wake-sentinel.ps1: missing slug. Usage: wake-sentinel.ps1 <project-slug> [controller-id]')
        exit 1
    }
    $existedBefore = $false
    $probe = Get-WakeSentinelPath -Slug $Slug -ControllerId $ControllerId
    if ($probe) { $existedBefore = Test-Path $probe }
    $path = New-WakeSentinel -Slug $Slug -ControllerId $ControllerId
    if (-not $path) {
        [Console]::Error.WriteLine('wake-sentinel.ps1: could not locate repo root (no .git/planning in cwd ancestors or script-dir ancestor).')
        exit 1
    }
    $state = if ($existedBefore) { 'present' } else { 'created' }
    Write-Output ("wake {0}: {1}" -f $state, $path)
    exit 0
}
