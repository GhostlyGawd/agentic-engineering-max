# tests/test-aem-init-plugin-root.ps1
#
# Regression test for the plugin-root resolution fix in /aem-init.
#
# THE BUG (caught by dogfooding a real fresh install): the /aem-init slash
# command's bash block referenced the plugin install dir as the runtime shell
# var $CLAUDE_PLUGIN_ROOT. That variable is documented only as an env var for
# hook / MCP / monitor subprocesses -- it is NOT reliably exported into a
# slash command's bash block. In a real install it arrived empty, the path
# collapsed to "/scripts/aem-init.ps1", pwsh failed to find it (exit 1), and the
# command's case-block mislabeled exit 1 as "not a git repository". The .ps1
# itself ALSO read $env:CLAUDE_PLUGIN_ROOT internally, so even a corrected path
# would have failed at the second layer.
#
# THE FIX (two layers, both locked here):
#   - command bash block: resolve the root from ${CLAUDE_SKILL_DIR} (the
#     documented render-time template) with a $CLAUDE_PLUGIN_ROOT fallback,
#     verify the script exists, and pass the resolved root to the .ps1 as
#     -PluginRoot. Fail with the CORRECT exit-3 diagnostic if neither resolves.
#   - aem-init.ps1: accept -PluginRoot (preferred), fall back to the env var,
#     Resolve-Path-normalize it, exit 3 if it does not resolve to a real dir.
#
# What this proves:
#   DYNAMIC (.ps1 contract):
#     POS-1  -PluginRoot alone (env var CLEARED) -> exit 0, core.hooksPath set.
#            This is the exact condition the bug failed under.
#     POS-2  -PluginRoot given as "<dir>/commands/.." -> exit 0 and the written
#            core.hooksPath is the NORMALIZED "<dir>/hooks" (no '..'), proving
#            the Resolve-Path normalization of the command-dir-relative form.
#     POS-3  no -PluginRoot but env var SET -> exit 0 (backward-compat: the
#            existing pwsh-probe test and direct invocation keep working).
#     NEG-1  no -PluginRoot, env var CLEARED -> exit 3 (unset case).
#     NEG-2  -PluginRoot pointing at a nonexistent path -> exit 3 (bad-path case).
#   STATIC (command bash-block contract -- prevents silent regression):
#     STAT-1 the command references ${CLAUDE_SKILL_DIR} (render-time fallback).
#     STAT-2 the command passes -PluginRoot to the backing script.
#     STAT-3 the command no longer hard-codes the bare
#            SCRIPT="$CLAUDE_PLUGIN_ROOT/scripts/aem-init.ps1" sole-resolution
#            line that caused the bug.
#
# Run:    pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test-aem-init-plugin-root.ps1
# Exit:   0 = all pass, 1 = at least one failed.
#
# Convention (D:\GitHub Projects\Dev_006\CLAUDE.md "Testing"): targeted,
# high-signal regression test; plain .ps1, no framework dependency. ASCII-only
# inside literals (machine note). git invocations use 2>$null (never 2>&1).

$ErrorActionPreference = 'Stop'

# tests/ sits directly under the plugin dir; the script + command are siblings.
$pluginDir       = Split-Path -Parent $PSScriptRoot
$scriptUnderTest = Join-Path $pluginDir 'scripts/aem-init.ps1'
$commandFile     = Join-Path $pluginDir 'commands/aem-init.md'
$pluginHooksDir  = Join-Path $pluginDir 'hooks'

if (-not (Test-Path -LiteralPath $scriptUnderTest)) { Write-Host "FAIL: script under test missing at $scriptUnderTest"; exit 1 }
if (-not (Test-Path -LiteralPath $commandFile))     { Write-Host "FAIL: command file missing at $commandFile"; exit 1 }
if (-not (Test-Path -LiteralPath $pluginHooksDir -PathType Container)) { Write-Host "FAIL: plugin hooks dir missing at $pluginHooksDir"; exit 1 }

# Resolve the real pwsh ONCE so we can spawn child processes with it explicitly.
$realPwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if ([string]::IsNullOrWhiteSpace($realPwsh)) {
    $realPwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}
if ([string]::IsNullOrWhiteSpace($realPwsh) -or -not (Test-Path -LiteralPath $realPwsh)) {
    Write-Host "FAIL: could not resolve a real pwsh executable to spawn the child"; exit 1
}

$script:passes   = 0
$script:failures = 0

function Assert-True {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Detail
    )
    if ($Condition) {
        Write-Host ("PASS: {0}" -f $Name)
        $script:passes++
    } else {
        Write-Host ("FAIL: {0}" -f $Name)
        if ($Detail) { Write-Host ("  - {0}" -f $Detail) }
        $script:failures++
    }
}

# Tolerant path compare: forward slashes, trimmed trailing sep, lower-cased.
function Normalize-PathForCompare([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return "" }
    $n = $p -replace '\\', '/'
    $n = $n.TrimEnd('/')
    return $n.ToLowerInvariant()
}

# Stand up a fresh temp git repo with core.hooksPath deliberately unset.
function New-ScratchRepo([string]$root, [string]$name) {
    $repo = Join-Path $root $name
    New-Item -ItemType Directory -Path $repo | Out-Null
    Push-Location $repo
    try {
        git init -q
        git config user.email 'test@example.com'
        git config user.name  'aem-pluginroot-test'
    } finally {
        Pop-Location
    }
    return $repo
}

# Spawn aem-init.ps1 as a child pwsh process via -File, forwarding any extra
# args (e.g. -PluginRoot <path>) to the script. 'exit' propagates natively with
# -File. Runs under a temporary 'Continue' preference so a native child's stderr
# does not throw under the ambient 'Stop'. Returns the child's exit code.
function Invoke-AemInit {
    param(
        [Parameter(Mandatory)][string]$WorkingDir,
        [string[]]$ScriptArgs = @()
    )
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $WorkingDir
    try {
        & $realPwsh -NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -File $scriptUnderTest @ScriptArgs 2>$null | Out-Null
        return $LASTEXITCODE
    } finally {
        Pop-Location
        $ErrorActionPreference = $prevPref
    }
}

# The value aem-init.ps1 writes on success: forward-slash form of the resolved
# root + "/hooks". The resolved root is always the real plugin dir.
$expectedHooksValue = ($pluginDir -replace '\\', '/') + '/hooks'

$savedPluginRoot = $env:CLAUDE_PLUGIN_ROOT
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("aem-pluginroot-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    # =====================================================================
    # POS-1: -PluginRoot alone, env var CLEARED -> exit 0, hooksPath set.
    #        (the exact condition the original bug failed under)
    # =====================================================================
    Remove-Item Env:CLAUDE_PLUGIN_ROOT -ErrorAction SilentlyContinue
    $p1Repo = New-ScratchRepo $testRoot 'pos1'
    $exit1  = Invoke-AemInit -WorkingDir $p1Repo -ScriptArgs @('-PluginRoot', $pluginDir)
    Assert-True -Name 'POS-1: -PluginRoot alone (no env var) exits 0' `
        -Condition ($exit1 -eq 0) -Detail ("got exit {0}" -f $exit1)
    $p1Hooks = git -C $p1Repo config --get core.hooksPath 2>$null
    Assert-True -Name 'POS-1: core.hooksPath set to the plugin hooks dir' `
        -Condition ((Normalize-PathForCompare $p1Hooks) -eq (Normalize-PathForCompare $expectedHooksValue)) `
        -Detail ("expected '{0}', got '{1}'" -f $expectedHooksValue, $p1Hooks)

    # =====================================================================
    # POS-2: -PluginRoot "<dir>/commands/.." -> exit 0 and NORMALIZED hooksPath.
    # =====================================================================
    Remove-Item Env:CLAUDE_PLUGIN_ROOT -ErrorAction SilentlyContinue
    $p2Repo  = New-ScratchRepo $testRoot 'pos2'
    $dotdot  = Join-Path (Join-Path $pluginDir 'commands') '..'
    $exit2   = Invoke-AemInit -WorkingDir $p2Repo -ScriptArgs @('-PluginRoot', $dotdot)
    Assert-True -Name 'POS-2: command-dir-relative -PluginRoot exits 0' `
        -Condition ($exit2 -eq 0) -Detail ("got exit {0}" -f $exit2)
    $p2Hooks = git -C $p2Repo config --get core.hooksPath 2>$null
    Assert-True -Name 'POS-2: core.hooksPath is NORMALIZED (no .. segment)' `
        -Condition (((Normalize-PathForCompare $p2Hooks) -eq (Normalize-PathForCompare $expectedHooksValue)) -and ($p2Hooks -notmatch '\.\.')) `
        -Detail ("expected '{0}', got '{1}'" -f $expectedHooksValue, $p2Hooks)

    # =====================================================================
    # POS-3: no -PluginRoot, env var SET -> exit 0 (backward-compat).
    # =====================================================================
    $env:CLAUDE_PLUGIN_ROOT = $pluginDir
    $p3Repo = New-ScratchRepo $testRoot 'pos3'
    $exit3  = Invoke-AemInit -WorkingDir $p3Repo -ScriptArgs @()
    Assert-True -Name 'POS-3: env-var fallback (no -PluginRoot) still exits 0' `
        -Condition ($exit3 -eq 0) -Detail ("got exit {0}" -f $exit3)
    $p3Hooks = git -C $p3Repo config --get core.hooksPath 2>$null
    Assert-True -Name 'POS-3: core.hooksPath set via env-var fallback' `
        -Condition ((Normalize-PathForCompare $p3Hooks) -eq (Normalize-PathForCompare $expectedHooksValue)) `
        -Detail ("expected '{0}', got '{1}'" -f $expectedHooksValue, $p3Hooks)

    # =====================================================================
    # NEG-1: no -PluginRoot, env var CLEARED -> exit 3, hooksPath unset.
    # =====================================================================
    Remove-Item Env:CLAUDE_PLUGIN_ROOT -ErrorAction SilentlyContinue
    $n1Repo = New-ScratchRepo $testRoot 'neg1'
    $exitN1 = Invoke-AemInit -WorkingDir $n1Repo -ScriptArgs @()
    Assert-True -Name 'NEG-1: no root anywhere exits 3 (not the misleading 1)' `
        -Condition ($exitN1 -eq 3) -Detail ("got exit {0}" -f $exitN1)
    $n1Hooks = git -C $n1Repo config --get core.hooksPath 2>$null
    Assert-True -Name 'NEG-1: core.hooksPath left UNWRITTEN' `
        -Condition ([string]::IsNullOrWhiteSpace(($n1Hooks -join ''))) `
        -Detail ("expected unset, got '{0}'" -f $n1Hooks)

    # =====================================================================
    # NEG-2: -PluginRoot pointing at a nonexistent path -> exit 3.
    # =====================================================================
    Remove-Item Env:CLAUDE_PLUGIN_ROOT -ErrorAction SilentlyContinue
    $n2Repo = New-ScratchRepo $testRoot 'neg2'
    $bogus  = Join-Path $testRoot 'does-not-exist-xyz'
    $exitN2 = Invoke-AemInit -WorkingDir $n2Repo -ScriptArgs @('-PluginRoot', $bogus)
    Assert-True -Name 'NEG-2: nonexistent -PluginRoot exits 3' `
        -Condition ($exitN2 -eq 3) -Detail ("got exit {0}" -f $exitN2)
    $n2Hooks = git -C $n2Repo config --get core.hooksPath 2>$null
    Assert-True -Name 'NEG-2: core.hooksPath left UNWRITTEN' `
        -Condition ([string]::IsNullOrWhiteSpace(($n2Hooks -join ''))) `
        -Detail ("expected unset, got '{0}'" -f $n2Hooks)

    # =====================================================================
    # STATIC: lock the command bash-block contract against regression.
    # =====================================================================
    $cmd = Get-Content -Raw -LiteralPath $commandFile

    Assert-True -Name 'STAT-1: command references ${CLAUDE_SKILL_DIR} (render-time fallback)' `
        -Condition ($cmd -match '\$\{CLAUDE_SKILL_DIR\}') `
        -Detail 'command bash block must resolve the root from the documented CLAUDE_SKILL_DIR template'

    Assert-True -Name 'STAT-2: command passes -PluginRoot to the backing script' `
        -Condition ($cmd -match '-PluginRoot') `
        -Detail 'the resolved root must be passed explicitly so the .ps1 does not depend on env export'

    Assert-True -Name 'STAT-3: command no longer hard-codes the bare $CLAUDE_PLUGIN_ROOT sole-resolution line' `
        -Condition ($cmd -notmatch 'SCRIPT="\$CLAUDE_PLUGIN_ROOT/scripts/aem-init\.ps1"') `
        -Detail 'the bare-env-var path was the original bug; it must not return'
}
finally {
    if ($null -eq $savedPluginRoot) {
        Remove-Item Env:CLAUDE_PLUGIN_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:CLAUDE_PLUGIN_ROOT = $savedPluginRoot
    }
    Remove-Item -Recurse -Force $testRoot -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------
Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:passes, $script:failures)
if ($script:failures -gt 0) { exit 1 } else { exit 0 }
