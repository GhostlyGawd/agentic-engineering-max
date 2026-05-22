# tests/test-aem-init-pwsh-probe.ps1
#
# Regression test for the pwsh-availability probe in scripts/aem-init.ps1
# (cross-platform-v2 task T-PROBE-TEST; success criterion (c); guardrail 3).
#
# What it proves:
#   POSITIVE: with a real pwsh 7+ resolvable (the host this test runs under),
#     aem-init.ps1 proceeds PAST the probe and sets core.hooksPath, exiting 0
#     in a scratch git repo with CLAUDE_PLUGIN_ROOT pointed at the real plugin
#     dir.
#   NEGATIVE 1 (version too low): when the 'pwsh' the probe invokes reports a
#     major version BELOW 7, the script exits 5, writes a copy-pasteable
#     install hint to stderr, and leaves core.hooksPath UNWRITTEN.
#   NEGATIVE 2 (absent / not runnable): when invoking 'pwsh' throws (as a
#     CommandNotFoundException would when pwsh is absent), the script likewise
#     exits 5 with the install hint and core.hooksPath unwritten.
#
# guardrail 3 (the false-pass vector): NEGATIVE 1's shim genuinely EXISTS and
# RESPONDS, so a naive existence check (which pwsh / Get-Command pwsh) would
# wrongly PASS. Only the probe's actual version parse (>= 7) catches that the
# reported version is too old -- which is exactly what this case asserts.
#
# --- Why the shim is a FUNCTION, not a PATH-shadowed executable ----------
# The obvious approach -- drop a fake 'pwsh' on a dir prepended to PATH -- does
# NOT work: pwsh unconditionally prepends its own $PSHOME to the child process
# PATH at startup, so the real pwsh.exe always resolves first and the fake is
# never seen. PowerShell command precedence, however, resolves a FUNCTION named
# 'pwsh' before any external 'pwsh' on PATH. So we spawn the child with
# -Command, define a 'pwsh' function shim, then run the real script file via the
# call operator. The script still executes as its own .ps1 in a real pwsh
# process (mirrors the real /aem-init invocation; not dot-sourced) -- only its
# internal '& pwsh' probe call is intercepted by the shim.
#
# --- Why the negative cases re-exit with $LASTEXITCODE -------------------
# pwsh quirk: 'exit N' inside a script file invoked via the call operator
# ('& script.ps1') RETURNS to the caller (and sets $LASTEXITCODE) rather than
# terminating the process; a bare 'pwsh -Command "& ''script''"' whose script
# exits 5 reports process exit 1, NOT 5. The trailing '; exit $LASTEXITCODE'
# re-propagates the script's real exit code. The POSITIVE case uses -File,
# which propagates 'exit' to the process natively, so it needs no such wrapper.
#
# Run:    pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test-aem-init-pwsh-probe.ps1
# Exit:   0 = all pass, 1 = at least one failed.
#
# Convention (D:\GitHub Projects\Dev_006\CLAUDE.md "Testing"): targeted,
# high-signal regression test; plain .ps1, no framework dependency. ASCII-only
# inside this file (machine note: no non-ASCII in PS literals). git invocations
# use 2>$null (never the 2>&1 merge form, which wraps native stderr as a
# RemoteException and corrupts $LASTEXITCODE handling).

$ErrorActionPreference = 'Stop'

# tests/ sits directly under the plugin dir; the script under test is a sibling.
$pluginDir       = Split-Path -Parent $PSScriptRoot
$scriptUnderTest = Join-Path $pluginDir 'scripts/aem-init.ps1'
$pluginHooksDir  = Join-Path $pluginDir 'hooks'

if (-not (Test-Path -LiteralPath $scriptUnderTest)) { Write-Host "FAIL: script under test missing at $scriptUnderTest"; exit 1 }
if (-not (Test-Path -LiteralPath $pluginHooksDir -PathType Container)) { Write-Host "FAIL: plugin hooks dir missing at $pluginHooksDir"; exit 1 }

# Resolve the real pwsh ONCE, by full path, so we can spawn child processes with
# it explicitly. The probe inside the child still resolves 'pwsh' on its own.
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

# Normalize a path for tolerant comparison: forward slashes, trimmed trailing
# separator, lower-cased. Mirrors aem-init.ps1's own comparison normalization.
function Normalize-PathForCompare([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return "" }
    $n = $p -replace '\\', '/'
    $n = $n.TrimEnd('/')
    return $n.ToLowerInvariant()
}

# Read a captured stderr file back as a single string ('' if missing/empty).
function Get-StderrText([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    $t = [string](Get-Content -Raw -LiteralPath $path -ErrorAction SilentlyContinue)
    if ($null -eq $t) { return '' }
    return $t
}

# Stand up a fresh temp git repo (no core.hooksPath set) and return its path.
function New-ScratchRepo([string]$root, [string]$name) {
    $repo = Join-Path $root $name
    New-Item -ItemType Directory -Path $repo | Out-Null
    Push-Location $repo
    try {
        git init -q
        git config user.email 'test@example.com'
        git config user.name  'aem-probe-test'
        # Deliberately leave core.hooksPath unset.
    } finally {
        Pop-Location
    }
    return $repo
}

# The value aem-init.ps1 writes into core.hooksPath on success: forward-slash
# form of CLAUDE_PLUGIN_ROOT + "/hooks". Computed identically to the script.
$expectedHooksValue = ($pluginDir -replace '\\', '/') + '/hooks'

$savedPluginRoot = $env:CLAUDE_PLUGIN_ROOT
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("aem-probe-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $testRoot | Out-Null

# Spawn aem-init.ps1 as a child pwsh process via -File. 'exit' propagates to the
# process natively in this form. stderr -> file (never the 2>&1 merge form);
# stdout discarded. Runs under a temporary 'Continue' preference so a native
# child's stderr does not throw under the ambient 'Stop'.
function Invoke-AemInitFile {
    param([Parameter(Mandatory)][string]$WorkingDir, [Parameter(Mandatory)][string]$StderrFile)
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $WorkingDir
    try {
        & $realPwsh -NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -File $scriptUnderTest 2>$StderrFile | Out-Null
        return $LASTEXITCODE
    } finally {
        Pop-Location
        $ErrorActionPreference = $prevPref
    }
}

# Spawn aem-init.ps1 with a 'pwsh' function shim injected ahead of it, so the
# script's internal '& pwsh' probe call resolves to the shim. The trailing
# 'exit $LASTEXITCODE' re-propagates the script's exit code (see header note).
function Invoke-AemInitShim {
    param(
        [Parameter(Mandatory)][string]$WorkingDir,
        [Parameter(Mandatory)][string]$Shim,
        [Parameter(Mandatory)][string]$StderrFile
    )
    # Single-quote the script path inside the command; keep $LASTEXITCODE literal.
    $cmd = "$Shim; & '$scriptUnderTest'; exit " + '$LASTEXITCODE'
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $WorkingDir
    try {
        & $realPwsh -NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -Command $cmd 2>$StderrFile | Out-Null
        return $LASTEXITCODE
    } finally {
        Pop-Location
        $ErrorActionPreference = $prevPref
    }
}

# Shim emulating a real pwsh 6: prints "6" on stdout and reports success, just
# as 'pwsh -Command $PSVersionTable.PSVersion.Major' would on a v6 install.
$shimVersion6 = 'function pwsh { Write-Output ''6''; $global:LASTEXITCODE = 0 }'
# Shim emulating an absent / non-runnable pwsh: invoking it throws, mirroring
# the CommandNotFoundException the probe catches when pwsh is not on PATH.
$shimAbsent   = 'function pwsh { throw ''pwsh not found'' }'

try {
    $env:CLAUDE_PLUGIN_ROOT = $pluginDir

    # =========================================================================
    # POSITIVE: real pwsh 7+ -> probe passes -> exit 0, core.hooksPath set.
    # =========================================================================
    $posRepo   = New-ScratchRepo $testRoot 'pos'
    $posStderr = Join-Path $testRoot 'pos.stderr.txt'
    $exitPos   = Invoke-AemInitFile -WorkingDir $posRepo -StderrFile $posStderr

    Assert-True -Name 'positive: aem-init exits 0 when real pwsh 7+ is on PATH' `
        -Condition ($exitPos -eq 0) `
        -Detail ("got exit code: {0}; stderr: {1}" -f $exitPos, (Get-StderrText $posStderr))

    $posHooks = git -C $posRepo config --get core.hooksPath 2>$null
    Assert-True -Name 'positive: core.hooksPath set to the plugin hooks dir' `
        -Condition ((Normalize-PathForCompare $posHooks) -eq (Normalize-PathForCompare $expectedHooksValue)) `
        -Detail ("expected '{0}', got '{1}'" -f $expectedHooksValue, $posHooks)

    # =========================================================================
    # NEGATIVE 1: shim reports version 6 -> exit 5, hint on stderr, hooks unset.
    # (directly exercises guardrail 3 -- the existence-check false-pass vector)
    # =========================================================================
    $negV6Repo   = New-ScratchRepo $testRoot 'neg-v6'
    $negV6Stderr = Join-Path $testRoot 'neg-v6.stderr.txt'
    $exitV6      = Invoke-AemInitShim -WorkingDir $negV6Repo -Shim $shimVersion6 -StderrFile $negV6Stderr

    Assert-True -Name 'negative(v6): aem-init exits 5 when resolvable pwsh reports version 6' `
        -Condition ($exitV6 -eq 5) `
        -Detail ("got exit code: {0}" -f $exitV6)

    $errV6 = Get-StderrText $negV6Stderr
    Assert-True -Name 'negative(v6): stderr states PowerShell 7+ (pwsh) is required' `
        -Condition ($errV6 -match 'PowerShell 7\+ \(pwsh\) is required') `
        -Detail ("stderr was: {0}" -f $errV6)

    # The Linux install hint is emitted unconditionally on every platform, so it
    # is a stable cross-OS substring proving the copy-pasteable hint is present.
    Assert-True -Name 'negative(v6): stderr carries a copy-pasteable install hint' `
        -Condition ($errV6 -match 'install-powershell\.sh') `
        -Detail ("stderr was: {0}" -f $errV6)

    $hooksV6 = git -C $negV6Repo config --get core.hooksPath 2>$null
    Assert-True -Name 'negative(v6): core.hooksPath left UNWRITTEN after failed probe' `
        -Condition ([string]::IsNullOrWhiteSpace(($hooksV6 -join ''))) `
        -Detail ("expected unset, got '{0}'" -f $hooksV6)

    # =========================================================================
    # NEGATIVE 2: shim throws (pwsh absent / not runnable) -> exit 5, hooks unset.
    # =========================================================================
    $negAbsRepo   = New-ScratchRepo $testRoot 'neg-absent'
    $negAbsStderr = Join-Path $testRoot 'neg-absent.stderr.txt'
    $exitAbs      = Invoke-AemInitShim -WorkingDir $negAbsRepo -Shim $shimAbsent -StderrFile $negAbsStderr

    Assert-True -Name 'negative(absent): aem-init exits 5 when invoking pwsh throws' `
        -Condition ($exitAbs -eq 5) `
        -Detail ("got exit code: {0}" -f $exitAbs)

    $errAbs = Get-StderrText $negAbsStderr
    Assert-True -Name 'negative(absent): stderr carries a copy-pasteable install hint' `
        -Condition ($errAbs -match 'install-powershell\.sh') `
        -Detail ("stderr was: {0}" -f $errAbs)

    $hooksAbs = git -C $negAbsRepo config --get core.hooksPath 2>$null
    Assert-True -Name 'negative(absent): core.hooksPath left UNWRITTEN after failed probe' `
        -Condition ([string]::IsNullOrWhiteSpace(($hooksAbs -join ''))) `
        -Detail ("expected unset, got '{0}'" -f $hooksAbs)
}
finally {
    # Restore the operator's env var to whatever it was before the test.
    $env:CLAUDE_PLUGIN_ROOT = $savedPluginRoot
    Remove-Item -Recurse -Force $testRoot -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------
Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:passes, $script:failures)
if ($script:failures -gt 0) { exit 1 } else { exit 0 }
