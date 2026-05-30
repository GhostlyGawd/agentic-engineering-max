# tests/test-state-drift-check.ps1
#
# Regression test for the PLUGIN copy of state-drift-check.ps1 (hooks/).
#
# The plugin hook was genericized in 2.4.0: the v1 hook hard-coded a single
# machine allowlist (`D:\GitHub Projects\Dev_006`) and therefore no-opped for
# every consumer. The genericized hook activates on the nearest repo root
# (walk-up from $PWD) with an OPTIONAL STATE_DRIFT_CHECK_ALLOW_ROOT pin. This
# test locks two things the workspace ground-truth test does NOT cover for the
# plugin artifact:
#   1. Generic activation -- the hook fires in an arbitrary repo with NO env
#      pin set (proving it is no longer machine-gated).
#   2. The pin still works -- a mismatched pin makes the hook no-op.
# Plus a Check G (gate-surface drift) NUDGE + its false-positive guard, since
# Check G is one of the three checks newly ported into the plugin in 2.4.0.
#
# Run:   pwsh -NoProfile -File tests/test-state-drift-check.ps1
# Exit:  0 = all pass, 1 = at least one failed.

$ErrorActionPreference = 'Stop'

$pluginRoot = Split-Path -Parent $PSScriptRoot
$hook = Join-Path $pluginRoot (Join-Path 'hooks' 'state-drift-check.ps1')
if (-not (Test-Path $hook)) { Write-Host "FAIL: hook missing at $hook"; exit 1 }

$script:passes = 0
$script:failures = 0

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("drift-plugin-{0}" -f (Get-Random))
$probeDir = Join-Path $testRoot (Join-Path 'planning' 'probe')
$probeTasksDir = Join-Path $probeDir 'tasks'
New-Item -ItemType Directory -Path $probeDir -Force | Out-Null

function Git-Setup {
    param([string[]]$GitArgs)
    $out = & git -C $testRoot @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("git {0} failed: {1}" -f ($GitArgs -join ' '), ($out -join '; ')) }
}

function Run-Hook {
    # Writes $StateContent to the probe plan-state, runs the hook as a subprocess
    # against the temp repo, returns additionalContext text. If $Pin is supplied,
    # STATE_DRIFT_CHECK_ALLOW_ROOT is set to it; otherwise the env var is cleared
    # so the run exercises GENERIC activation.
    param([string]$StateContent, [string]$Pin)
    Set-Content -Path (Join-Path $probeDir 'plan-state.md') -Value $StateContent -Encoding utf8

    $stdoutF = [IO.Path]::GetTempFileName()
    $stderrF = [IO.Path]::GetTempFileName()
    $stdinF  = [IO.Path]::GetTempFileName()
    Set-Content -Path $stdinF -Value '' -NoNewline

    if ($PSBoundParameters.ContainsKey('Pin') -and $Pin) {
        $env:STATE_DRIFT_CHECK_ALLOW_ROOT = $Pin
    } else {
        Remove-Item Env:\STATE_DRIFT_CHECK_ALLOW_ROOT -ErrorAction SilentlyContinue
    }
    try {
        Start-Process -FilePath 'pwsh' `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $hook + '"') `
            -WorkingDirectory $testRoot -NoNewWindow -Wait `
            -RedirectStandardInput $stdinF `
            -RedirectStandardOutput $stdoutF `
            -RedirectStandardError $stderrF | Out-Null
        $out = Get-Content $stdoutF -Raw -ErrorAction SilentlyContinue
    } finally {
        Remove-Item $stdoutF, $stderrF, $stdinF -ErrorAction SilentlyContinue
        Remove-Item Env:\STATE_DRIFT_CHECK_ALLOW_ROOT -ErrorAction SilentlyContinue
    }

    if (-not $out) { return '' }
    try {
        $j = $out | ConvertFrom-Json
        return [string]$j.hookSpecificOutput.additionalContext
    } catch {
        return $out
    }
}

function Set-ProbeGateTasks {
    param([object[]]$Tasks = @())
    if (Test-Path $probeTasksDir) { Remove-Item -Recurse -Force $probeTasksDir }
    if ($Tasks.Count -gt 0) {
        New-Item -ItemType Directory -Path $probeTasksDir -Force | Out-Null
        $n = 0
        foreach ($t in $Tasks) {
            $n++
            $fm = @('---', ("id: T-{0:000}" -f $n), 'title: probe gate', 'status: open')
            if ($t.decider) { $fm += "gate_decider: $($t.decider)" }
            if ($t.state)   { $fm += "gate_state: $($t.state)" }
            $fm += @('---', 'probe body')
            Set-Content -Path (Join-Path $probeTasksDir ("task-{0:000}.md" -f $n)) -Value ($fm -join "`n") -Encoding utf8
        }
    }
}

function Assert {
    param([string]$Name, [bool]$Got, [bool]$Expect)
    if ($Got -eq $Expect) {
        Write-Host ("  PASS  {0}" -f $Name); $script:passes++
    } else {
        Write-Host ("  FAIL  {0} (expected {1}, got {2})" -f $Name, $Expect, $Got); $script:failures++
    }
}

try {
    Write-Host "test-state-drift-check (plugin, genericized):"

    Git-Setup @('init', '-q')
    Git-Setup @('config', 'user.email', 'test@example.com')
    Git-Setup @('config', 'user.name', 'test')
    Set-Content -Path (Join-Path $testRoot 'base.txt') -Value 'base'
    Git-Setup @('add', '-A')
    Git-Setup @('commit', '-q', '-m', 'base')
    Git-Setup @('branch', '-M', 'main')
    Git-Setup @('checkout', '-q', '-b', 'merged-feature')
    Set-Content -Path (Join-Path $testRoot 'feat.txt') -Value 'feat'
    Git-Setup @('add', '-A')
    Git-Setup @('commit', '-q', '-m', 'feat')
    Git-Setup @('checkout', '-q', 'main')
    Git-Setup @('merge', '-q', '--no-ff', '-m', 'merge merged-feature', 'merged-feature')

    # 1. GENERIC ACTIVATION: no env pin, hook must still fire on this arbitrary
    #    repo (the v1 machine allowlist would have no-opped here).
    Set-ProbeGateTasks -Tasks @()
    $ctx = Run-Hook -StateContent 'Next action: open/merge PR for `merged-feature`.'
    Assert 'generic activation: Check E fires with NO allowlist pin' ([bool]($ctx -match 'already merged into main')) $true

    # 2. PIN still works: a mismatched pin makes the hook no-op even with drift.
    $ctx = Run-Hook -StateContent 'Next action: open/merge PR for `merged-feature`.' -Pin '/definitely/not/this/repo'
    Assert 'pin mismatch: hook no-ops (silent)' ([bool]($ctx -match 'already merged into main')) $false

    # 3. Check G NUDGE: drained queue + stale instruction.
    Set-ProbeGateTasks -Tasks @(@{ decider = 'user'; state = 'declined' })
    $ctx = Run-Hook -StateContent 'Next action: Opportunistic - approve or decline the 4 `proposed` intake findings via the HUD Gates tab.'
    Assert 'Check G: drained queue + stale instruction -> NUDGE' ([bool]($ctx -match 'gate queue is empty')) $true

    # 4. Check G false-positive guard: reconciled status text (no imperative).
    $ctx = Run-Hook -StateContent 'Next action: None. All intake findings decided; Gates queue empty (gate_queue=0).'
    Assert 'Check G: reconciled status text -> silent' ([bool]($ctx -match 'gate queue is empty')) $false

    # 5. Clean state -> silent.
    Set-ProbeGateTasks -Tasks @()
    $ctx = Run-Hook -StateContent 'Next action: None -- build complete.'
    Assert 'clean state -> silent' ([bool]($ctx -and $ctx.Trim())) $false
}
finally {
    Remove-Item -Recurse -Force $testRoot -ErrorAction SilentlyContinue
    Remove-Item Env:\STATE_DRIFT_CHECK_ALLOW_ROOT -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:passes, $script:failures)
if ($script:failures -gt 0) { exit 1 } else { exit 0 }
