# bin/install-autostart.ps1
#
# Purpose:
#   OPT-IN autostart registration for the control-plane controller (and,
#   optionally, the web HUD) so the build survives a reboot/login without a
#   human re-launching it (spec T-303, PRD section 3). This is a convenience,
#   never a correctness requirement: manual launch via launch-build.ps1 /
#   orchestrator-loop.ps1 always works whether or not autostart is installed.
#
#   The controller (orchestrator-loop.ps1) is the always-on piece and is always
#   registered. The web HUD (control-plane-web.ps1) is a SEPARATE opt-in behind
#   -WebApp -- the build drives to completion with the web app dead, so its
#   autostart is purely a nicety.
#
# Per-OS mechanism:
#   Windows : a Task Scheduler entry per unit (Register-ScheduledTask, AtLogOn
#             trigger). The scheduled-task cmdlets are Windows-only, gated behind
#             an $IsWindows branch and tagged '# crosscompat-ok'.
#   Linux   : a systemd-user unit under ~/.config/systemd/user/ (PREFERRED), or a
#             cron '@reboot' line (FALLBACK when systemd --user is unavailable).
#             Each cron line carries a '# <unit-name>' marker so -Remove can find
#             and strip exactly its own lines.
#
# Modes:
#   (default)   install the autostart entry/entries for this slug.
#   -Remove     unregister (idempotent: a missing entry is a clean no-op).
#   -DryRun     print the EXACT command/unit/cron line that WOULD be installed and
#               make ZERO changes (no scheduled task, no unit file, no crontab
#               edit). Works in both install and -Remove framing.
#
# Usage:
#   pwsh bin/install-autostart.ps1 -Slug <slug> [-WebApp] [-Remove] [-DryRun]
#     -Slug    : which planning/<slug> build to autostart (required)
#     -WebApp  : also register the web HUD (control-plane-web.ps1)
#     -Remove  : unregister instead of install
#     -DryRun  : print the plan, change nothing
#     -RepoRoot: operate on an alternate tree (tests); defaults to bin/.. (repo root)
#
# Why this script is dot-sourceable:
#   The pure plan builders (Get-AutostartSpec, Get-WindowsTaskPlan,
#   Get-SystemdUnit, Get-CronLine) are the unit-test surface. Dot-sourcing defines
#   them and SKIPS the main block (same guard idiom as orchestrator-loop.ps1:
#   $MyInvocation.InvocationName -eq '.').
#
# Exit codes:
#   0  installed / removed / dry-run printed cleanly
#   1  bad invocation (missing slug, repo root not found) or an install failure
#
# Cross-task invariants honored:
#   - ASCII-only inside "..." literals.
#   - No 2>&1 on native exes (systemd/crontab probes use 2>$null).
#   - Paths built with Join-Path / forward slashes (no literal backslash).
#   - All file writes UTF-8 (no BOM).

param(
    [Parameter(Position = 0)][string]$Slug,
    [switch]$WebApp,
    [switch]$Remove,
    [switch]$DryRun,
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }

# Resolve the pwsh executable running this script (full path on both Windows and
# Linux). Fall back to the PATH name. Identical idiom to launch-build.ps1.
function Get-PwshExe {
    $p = (Get-Process -Id $PID).Path
    if (-not $p) { $p = 'pwsh' }
    return $p
}

# Build the list of units to register. The controller is always present; the web
# app is appended only under -WebApp. Each spec is a pure descriptor (no I/O) so
# the plan builders and the install/remove paths share one source of truth.
function Get-AutostartSpec {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Slug,
        [switch]$WebApp
    )
    $bin = Join-Path $RepoRoot 'bin'
    $specs = @(
        [pscustomobject]@{
            Key         = 'controller'
            Name        = "control-plane-controller-$Slug"
            WinTask     = "ControlPlane-Controller-$Slug"
            Description = "Control-plane adaptive controller (slug: $Slug)"
            Script      = (Join-Path $bin 'orchestrator-loop.ps1')
            Args        = $Slug
        }
    )
    if ($WebApp) {
        $specs += [pscustomobject]@{
            Key         = 'webapp'
            Name        = "control-plane-webapp-$Slug"
            WinTask     = "ControlPlane-WebApp-$Slug"
            Description = "Control-plane web HUD (slug: $Slug)"
            Script      = (Join-Path $bin 'control-plane-web.ps1')
            Args        = "-Slug $Slug"
        }
    }
    return , $specs
}

# The argument string handed to pwsh by the scheduled action / unit / cron line.
function Get-LaunchArgString {
    param([Parameter(Mandatory)]$Spec, [switch]$WithExecutionPolicy)
    if ($WithExecutionPolicy) {
        return ('-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $Spec.Script, $Spec.Args)
    }
    return ('-NoProfile -File "{0}" {1}' -f $Spec.Script, $Spec.Args)
}

# Windows: a copy-pasteable Register-ScheduledTask plan. Names the target script
# (orchestrator-loop.ps1 / control-plane-web.ps1) so the dry-run is greppable.
function Get-WindowsTaskPlan {
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][string]$PwshExe)
    $argString = Get-LaunchArgString -Spec $Spec -WithExecutionPolicy
    $nl = [Environment]::NewLine
    $lines = @(
        "# Windows Task Scheduler entry: $($Spec.WinTask)",
        "Register-ScheduledTask -TaskName '$($Spec.WinTask)' -Force ``",
        "  -Description '$($Spec.Description)' ``",
        "  -Action (New-ScheduledTaskAction -Execute '$PwshExe' -Argument '$argString') ``",
        "  -Trigger (New-ScheduledTaskTrigger -AtLogOn) ``",
        "  -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries)"
    )
    return ($lines -join $nl)
}

# Linux PREFERRED: a systemd-user unit. ExecStart names the target script so the
# dry-run is greppable. Joined with LF (unit files are LF on Linux).
function Get-SystemdUnit {
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][string]$PwshExe)
    $argString = Get-LaunchArgString -Spec $Spec
    $lines = @(
        '[Unit]',
        "Description=$($Spec.Description)",
        'After=network.target',
        '',
        '[Service]',
        'Type=simple',
        "ExecStart=$PwshExe $argString",
        'Restart=on-failure',
        '',
        '[Install]',
        'WantedBy=default.target'
    )
    return ($lines -join "`n")
}

# Linux FALLBACK: a cron '@reboot' line. The trailing '# <name>' marker is how
# -Remove finds exactly this script's own lines without touching other crontab
# entries.
function Get-CronLine {
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][string]$PwshExe)
    $argString = Get-LaunchArgString -Spec $Spec
    return ('@reboot {0} {1}  # {2}' -f $PwshExe, $argString, $Spec.Name)
}

# Is the systemd --user manager reachable? Requires systemctl on PATH AND a live
# user bus (show-environment exits 0 only when the user manager is up). Any miss
# -> false, so the caller falls back to cron. Never throws.
function Test-SystemdUserAvailable {
    if ($IsWindows) { return $false }
    if (-not (Get-Command systemctl -ErrorAction SilentlyContinue)) { return $false }
    try {
        & systemctl --user show-environment 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# ---- install / remove primitives (each no-ops cleanly under DryRun upstream) --

function Install-WindowsTask {
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][string]$PwshExe)
    $argString = Get-LaunchArgString -Spec $Spec -WithExecutionPolicy
    # The scheduled-task cmdlets are a Windows-only module; the whole branch is
    # under an $IsWindows guard in Main. crosscompat-ok marks the unavoidable
    # Windows-only cmdlets so the lint does not chase them on Linux.
    $action   = New-ScheduledTaskAction -Execute $PwshExe -Argument $argString          # crosscompat-ok
    $trigger  = New-ScheduledTaskTrigger -AtLogOn                                        # crosscompat-ok
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries  # crosscompat-ok
    Register-ScheduledTask -TaskName $Spec.WinTask -Action $action -Trigger $trigger `
        -Settings $settings -Description $Spec.Description -Force | Out-Null            # crosscompat-ok
    Write-Host "  installed scheduled task: $($Spec.WinTask)"
}

function Remove-WindowsTask {
    param([Parameter(Mandatory)]$Spec)
    $existing = Get-ScheduledTask -TaskName $Spec.WinTask -ErrorAction SilentlyContinue  # crosscompat-ok
    if ($existing) {
        Unregister-ScheduledTask -TaskName $Spec.WinTask -Confirm:$false                 # crosscompat-ok
        Write-Host "  removed scheduled task: $($Spec.WinTask)"
    } else {
        Write-Host "  (no scheduled task to remove: $($Spec.WinTask))"
    }
}

function Get-SystemdUnitPath {
    param([Parameter(Mandatory)]$Spec)
    return (Join-Path (Join-Path $HOME '.config/systemd/user') ("$($Spec.Name).service"))
}

function Install-SystemdUnit {
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][string]$PwshExe)
    $unitDir = Join-Path $HOME '.config/systemd/user'
    if (-not (Test-Path $unitDir)) { New-Item -ItemType Directory -Path $unitDir -Force | Out-Null }
    $unitPath = Get-SystemdUnitPath -Spec $Spec
    $content  = (Get-SystemdUnit -Spec $Spec -PwshExe $PwshExe) + "`n"
    $bytes    = [Text.UTF8Encoding]::new($false).GetBytes($content)
    [IO.File]::WriteAllBytes($unitPath, $bytes)
    & systemctl --user daemon-reload 2>$null | Out-Null
    & systemctl --user enable ("$($Spec.Name).service") 2>$null | Out-Null
    Write-Host "  installed systemd-user unit: $unitPath"
}

function Remove-SystemdUnit {
    param([Parameter(Mandatory)]$Spec)
    $unitPath = Get-SystemdUnitPath -Spec $Spec
    & systemctl --user disable ("$($Spec.Name).service") 2>$null | Out-Null
    if (Test-Path $unitPath) {
        Remove-Item $unitPath -Force
        & systemctl --user daemon-reload 2>$null | Out-Null
        Write-Host "  removed systemd-user unit: $unitPath"
    } else {
        Write-Host "  (no systemd-user unit to remove: $($Spec.Name).service)"
    }
}

# Read the current crontab as an array of lines ('' when none / unreadable).
function Get-CrontabLines {
    $existing = & crontab -l 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $existing) { return @() }
    return @($existing)
}

function Set-CrontabLines {
    param([string[]]$Lines)
    $payload = (($Lines -join "`n") + "`n")
    $payload | & crontab -
}

function Install-CronLine {
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][string]$PwshExe)
    $marker = "# $($Spec.Name)"
    $kept   = @(Get-CrontabLines | Where-Object { $_ -notmatch [regex]::Escape($marker) })
    $kept  += (Get-CronLine -Spec $Spec -PwshExe $PwshExe)
    Set-CrontabLines -Lines $kept
    Write-Host "  installed cron @reboot line for: $($Spec.Name)"
}

function Remove-CronLine {
    param([Parameter(Mandatory)]$Spec)
    $marker = "# $($Spec.Name)"
    $all    = @(Get-CrontabLines)
    $kept   = @($all | Where-Object { $_ -notmatch [regex]::Escape($marker) })
    if ($kept.Count -ne $all.Count) {
        Set-CrontabLines -Lines $kept
        Write-Host "  removed cron @reboot line for: $($Spec.Name)"
    } else {
        Write-Host "  (no cron @reboot line to remove: $($Spec.Name))"
    }
}

# ---- main ---------------------------------------------------------------

function Invoke-Main {
    if (-not $Slug) {
        [Console]::Error.WriteLine('Usage: install-autostart.ps1 -Slug <slug> [-WebApp] [-Remove] [-DryRun]')
        return 1
    }
    if (-not $RepoRoot -or -not (Test-Path $RepoRoot)) {
        [Console]::Error.WriteLine("install-autostart: repo root not found ($RepoRoot)")
        return 1
    }

    $pwshExe = Get-PwshExe
    $specs   = Get-AutostartSpec -RepoRoot $RepoRoot -Slug $Slug -WebApp:$WebApp

    # ---- DryRun: print the platform-appropriate plan, change NOTHING ----
    if ($DryRun) {
        $verb = if ($Remove) { 'REMOVE' } else { 'INSTALL' }
        Write-Host "DRY RUN ($verb) -- no changes will be made. Plan for slug '$Slug':"
        Write-Host ''
        foreach ($spec in $specs) {
            Write-Host "=== unit: $($spec.Name) ==="
            if ($IsWindows) {
                Write-Host (Get-WindowsTaskPlan -Spec $spec -PwshExe $pwshExe)
            } elseif (Test-SystemdUserAvailable) {
                Write-Host "# systemd-user unit -> $(Get-SystemdUnitPath -Spec $spec)"
                Write-Host (Get-SystemdUnit -Spec $spec -PwshExe $pwshExe)
            } else {
                Write-Host '# cron @reboot line (systemd --user unavailable):'
                Write-Host (Get-CronLine -Spec $spec -PwshExe $pwshExe)
            }
            Write-Host ''
        }
        return 0
    }

    # ---- Remove ----
    if ($Remove) {
        foreach ($spec in $specs) {
            if ($IsWindows) {
                Remove-WindowsTask -Spec $spec
            } else {
                # On removal we do not know which mechanism was used, so undo both:
                # disable+delete any systemd-user unit AND strip any cron marker line.
                Remove-SystemdUnit -Spec $spec
                Remove-CronLine -Spec $spec
            }
        }
        Write-Host "install-autostart: removed autostart for slug '$Slug'."
        return 0
    }

    # ---- Install ----
    foreach ($spec in $specs) {
        if ($IsWindows) {
            Install-WindowsTask -Spec $spec -PwshExe $pwshExe
        } elseif (Test-SystemdUserAvailable) {
            Install-SystemdUnit -Spec $spec -PwshExe $pwshExe
        } else {
            Install-CronLine -Spec $spec -PwshExe $pwshExe
        }
    }
    Write-Host "install-autostart: autostart installed for slug '$Slug' (opt-in; manual launch still works)."
    return 0
}

# Dot-source guard: when dot-sourced (the unit test), define the functions above
# and SKIP Main. When run as a script, run Main and propagate its exit code.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-Main)
}
