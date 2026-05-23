# tests/test-aem-init-git-config-safety.ps1
#
# Regression test for scripts/aem-init.ps1 (invariant 1 / D-S9).
#
# Proves aem-init.ps1 refuses to clobber a pre-existing, non-default
# core.hooksPath unless the operator explicitly passes -Force:
#   - Without -Force, the script exits 2 (the documented hooksPath-conflict
#     code) and leaves the existing core.hooksPath byte-for-byte untouched.
#   - With -Force, the script exits 0 and rewrites core.hooksPath to the
#     plugin hooks directory.
#
# Method: stand up a fresh temp git repo under $env:TEMP\aem-test-<guid>, set
# its local core.hooksPath to a non-default sentinel ("tests/fake-hooks"),
# point $env:CLAUDE_PLUGIN_ROOT at the real plugin dir (so the script can
# resolve a hooks/ directory and not bail with exit 3), invoke the script with
# its working directory inside the temp repo, and assert the exit code and the
# resulting core.hooksPath value after each invocation.
#
# Run:    pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test-aem-init-git-config-safety.ps1
# Exit:   0 = all pass, 1 = at least one failed.
#
# Convention (D:\GitHub Projects\Dev_006\CLAUDE.md "Testing"): targeted,
# high-signal regression test; plain .ps1, no framework dependency.
# ASCII-only inside this file (machine note: no non-ASCII in PS 5.1 literals).
# git invocations use 2>$null (never the 2>&1 merge form, which wraps native
# stderr as RemoteException on PS 5.1 and corrupts $LASTEXITCODE handling).

$ErrorActionPreference = 'Stop'

# tests/ sits directly under the plugin dir; the script under test is a sibling.
$pluginDir       = Split-Path -Parent $PSScriptRoot
$scriptUnderTest = Join-Path $pluginDir 'scripts/aem-init.ps1'
$pluginHooksDir  = Join-Path $pluginDir 'hooks'

if (-not (Test-Path -LiteralPath $scriptUnderTest)) { Write-Host "FAIL: script under test missing at $scriptUnderTest"; exit 1 }
if (-not (Test-Path -LiteralPath $pluginHooksDir -PathType Container)) { Write-Host "FAIL: plugin hooks dir missing at $pluginHooksDir"; exit 1 }

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

# The value aem-init.ps1 will write into core.hooksPath, computed identically
# to the script (forward-slash form of $CLAUDE_PLUGIN_ROOT + "/hooks").
$expectedHooksValue = ($pluginDir -replace '\\', '/') + '/hooks'
$sentinel           = 'tests/fake-hooks'

$savedPluginRoot = $env:CLAUDE_PLUGIN_ROOT
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("aem-test-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    # --- Set up a fresh temp git repo with a non-default core.hooksPath -------
    Push-Location $testRoot
    try {
        git init -q
        git config user.email 'test@example.com'
        git config user.name  'aem-init-test'
        git config core.hooksPath $sentinel
    } finally {
        Pop-Location
    }

    # Sanity: the sentinel is actually in place before we invoke the script.
    $preValue = git -C $testRoot config --get core.hooksPath 2>$null
    Assert-True -Name 'sentinel core.hooksPath is set before invocation' `
        -Condition ((Normalize-PathForCompare $preValue) -eq (Normalize-PathForCompare $sentinel)) `
        -Detail ("got: '{0}'" -f $preValue)

    # Point the script at the real plugin dir so its hooks/ resolves (else the
    # script exits 3 -- "plugin hooks dir unavailable" -- before reaching the
    # conflict guard we are testing).
    $env:CLAUDE_PLUGIN_ROOT = $pluginDir

    # --- Invocation 1: WITHOUT -Force (expect refusal, exit 2) ----------------
    # Run from inside the temp repo so the script's git operations target it.
    # 2>$null discards the script's stderr (its conflict message); Out-Null
    # swallows the child's stdout. Neither uses the 2>&1 merge form.
    #
    # The child pwsh process writes its conflict message to stderr. On PS 5.1
    # a native exe's stderr is wrapped as a NativeCommandError record; under the
    # ambient $ErrorActionPreference='Stop' that record would TERMINATE the test
    # mid-run. Drop to 'Continue' around the child call (the sibling
    # test-session-start-injection.ps1 uses the same guard) so the exit code is
    # captured instead of throwing.
    $exitNoForce = $null
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $testRoot
    try {
        & pwsh -NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -File $scriptUnderTest 2>$null | Out-Null
        $exitNoForce = $LASTEXITCODE
    } finally {
        Pop-Location
        $ErrorActionPreference = $prevPref
    }

    Assert-True -Name 'aem-init without -Force exits 2 (hooksPath conflict)' `
        -Condition ($exitNoForce -eq 2) `
        -Detail ("got exit code: {0}" -f $exitNoForce)

    $afterNoForce = git -C $testRoot config --get core.hooksPath 2>$null
    Assert-True -Name 'core.hooksPath unchanged after refused invocation' `
        -Condition ((Normalize-PathForCompare $afterNoForce) -eq (Normalize-PathForCompare $sentinel)) `
        -Detail ("expected sentinel '{0}', got '{1}'" -f $sentinel, $afterNoForce)

    # --- Invocation 2: WITH -Force (expect overwrite, exit 0) -----------------
    # Same 'Continue' guard as invocation 1 (defensive: even the success path
    # could emit a benign stderr line under some git configurations).
    $exitForce = $null
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $testRoot
    try {
        & pwsh -NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -File $scriptUnderTest -Force 2>$null | Out-Null
        $exitForce = $LASTEXITCODE
    } finally {
        Pop-Location
        $ErrorActionPreference = $prevPref
    }

    Assert-True -Name 'aem-init with -Force exits 0' `
        -Condition ($exitForce -eq 0) `
        -Detail ("got exit code: {0}" -f $exitForce)

    $afterForce = git -C $testRoot config --get core.hooksPath 2>$null
    Assert-True -Name 'core.hooksPath now points at the plugin hooks dir' `
        -Condition ((Normalize-PathForCompare $afterForce) -eq (Normalize-PathForCompare $expectedHooksValue)) `
        -Detail ("expected '{0}', got '{1}'" -f $expectedHooksValue, $afterForce)
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
