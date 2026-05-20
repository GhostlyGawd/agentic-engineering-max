# tests/test-session-start-injection.ps1
#
# Regression test for hooks/claude-context-inject.ps1 (invariant 5 / D-S10).
#
# Proves the SessionStart hook injects build-system principle text through
# hookSpecificOutput.additionalContext WITHOUT replacing or concatenating the
# operator's own CLAUDE.md, and that the operator's CLAUDE.md file is left
# byte-for-byte untouched (read-only invariant, PRD invariants 2 + 5).
#
# Method: stand up a fresh temp git repo containing a sentinel CLAUDE.md whose
# body carries a unique token (OPERATOR_SENTINEL_<guid>). Point
# $env:CLAUDE_PLUGIN_ROOT at the plugin dir, invoke the hook with its working
# directory inside the temp repo, capture stdout, and assert:
#   1. stdout parses as JSON (ConvertFrom-Json).
#   2. .hookSpecificOutput.hookEventName == "SessionStart".
#   3. .hookSpecificOutput.additionalContext contains the template marker
#      "Dogfooding - Principles" (proves the template text was injected).
#   4. .hookSpecificOutput.additionalContext does NOT contain the operator
#      sentinel (proves the operator's CLAUDE.md was not concatenated in).
#   5. the temp repo's CLAUDE.md mtime + SHA256 are unchanged post-invocation
#      (proves the hook never wrote to the operator filesystem).
#
# Run:    powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-session-start-injection.ps1
# Exit:   0 = all pass, 1 = at least one failed.
#
# Convention (D:\GitHub Projects\Dev_006\CLAUDE.md "Testing"): targeted,
# high-signal regression test; plain .ps1, no framework dependency.
# ASCII-only inside this file (machine note: no non-ASCII in PS 5.1 literals).

$ErrorActionPreference = 'Stop'

# tests/ sits directly under the plugin dir; the hook + template are siblings.
$pluginDir    = Split-Path -Parent $PSScriptRoot
$hookPath     = Join-Path $pluginDir 'hooks\claude-context-inject.ps1'
$templatePath = Join-Path $pluginDir 'docs\CLAUDE-template.md'

if (-not (Test-Path -LiteralPath $hookPath))     { Write-Host "FAIL: hook missing at $hookPath";         exit 1 }
if (-not (Test-Path -LiteralPath $templatePath)) { Write-Host "FAIL: template missing at $templatePath"; exit 1 }

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

$savedPluginRoot = $env:CLAUDE_PLUGIN_ROOT
$testRoot = Join-Path $env:TEMP ("session-inject-test-{0}" -f (Get-Random))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    # --- Set up a fresh temp git repo with a sentinel CLAUDE.md ---------------
    Push-Location $testRoot
    try {
        git init -q
        git config user.email 'test@example.com'
        git config user.name  'session-inject-test'
    } finally {
        Pop-Location
    }

    $sentinel  = "OPERATOR_SENTINEL_{0}" -f ([guid]::NewGuid().ToString('N'))
    $claudeMd  = Join-Path $testRoot 'CLAUDE.md'
    $operatorBody = "# Operator CLAUDE.md`n`nThis is the operator's own file.`n$sentinel`n"
    [IO.File]::WriteAllText($claudeMd, $operatorBody, [Text.UTF8Encoding]::new($false))

    # Point the hook at the plugin under test.
    $env:CLAUDE_PLUGIN_ROOT = $pluginDir

    # Record the operator CLAUDE.md fingerprint BEFORE invocation.
    $beforeMtime = (Get-Item -LiteralPath $claudeMd).LastWriteTimeUtc
    $beforeHash  = (Get-FileHash -LiteralPath $claudeMd -Algorithm SHA256).Hash

    # --- Invoke the hook, capturing stdout ------------------------------------
    # SessionStart delivers an event on stdin; the hook drains it via
    # [Console]::In.ReadToEnd(). Pipe an empty string into the child so that
    # read returns immediately instead of blocking on the parent console.
    #
    # The hook is invoked from inside the temp repo (Push-Location) so its
    # "git config --get core.hooksPath" detection runs against the temp repo.
    #
    # Capture mechanism: the call operator collecting the child's success
    # (stdout) stream. We deliberately do NOT use Start-Process file
    # redirection here (a redirected-stdin + -File launch surfaced the
    # interactive banner on PS 5.1) and we do NOT merge stderr into stdout
    # (the 2>&1 merge wraps native-exe stderr as RemoteException on PS 5.1 --
    # see the machine note). The hook emits only the JSON envelope on stdout
    # in every path, so the success stream is exactly the payload under test.
    $childExit = $null
    $rawOut = $null
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $testRoot
    try {
        $rawOut = '' | & powershell -NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -File $hookPath
        $childExit = $LASTEXITCODE
    } finally {
        Pop-Location
        $ErrorActionPreference = $prevPref
    }

    # The envelope is a single compressed JSON line; join defensively in case
    # the capture arrives as a string array.
    if ($null -eq $rawOut) { $stdout = '' }
    elseif ($rawOut -is [array]) { $stdout = ($rawOut -join "`n") }
    else { $stdout = [string]$rawOut }

    # --- Assertion 1: stdout parses as JSON -----------------------------------
    $parsed = $null
    $parseOk = $false
    try {
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $parsed = $stdout | ConvertFrom-Json
            $parseOk = $true
        }
    } catch {
        $parseOk = $false
    }
    Assert-True -Name 'stdout is valid JSON parseable by ConvertFrom-Json' `
        -Condition $parseOk `
        -Detail ("hook exit={0}; raw stdout: {1}" -f $childExit, ($stdout -replace "`r?`n", ' '))

    # The remaining JSON-dependent asserts only make sense if parse succeeded.
    $ctx = $null
    if ($parseOk) {
        $eventName = $null
        try { $eventName = $parsed.hookSpecificOutput.hookEventName } catch { }
        Assert-True -Name '.hookSpecificOutput.hookEventName == "SessionStart"' `
            -Condition ($eventName -eq 'SessionStart') `
            -Detail ("got: '{0}'" -f $eventName)

        try { $ctx = [string]$parsed.hookSpecificOutput.additionalContext } catch { $ctx = $null }
    } else {
        Assert-True -Name '.hookSpecificOutput.hookEventName == "SessionStart"' `
            -Condition $false -Detail 'skipped: JSON did not parse'
    }

    # --- Assertion 3: additionalContext carries the template marker -----------
    $hasTemplate = ($null -ne $ctx) -and ($ctx.Contains('Dogfooding - Principles'))
    Assert-True -Name 'additionalContext contains template text ("Dogfooding - Principles")' `
        -Condition $hasTemplate `
        -Detail 'template marker not found in additionalContext'

    # --- Assertion 4: operator sentinel was NOT concatenated in ---------------
    $hasSentinel = ($null -ne $ctx) -and ($ctx.Contains($sentinel))
    Assert-True -Name 'additionalContext does NOT contain the operator sentinel' `
        -Condition (-not $hasSentinel) `
        -Detail 'operator CLAUDE.md content leaked into additionalContext'

    # --- Assertion 5: operator CLAUDE.md untouched (mtime + hash) -------------
    $afterMtime = (Get-Item -LiteralPath $claudeMd).LastWriteTimeUtc
    $afterHash  = (Get-FileHash -LiteralPath $claudeMd -Algorithm SHA256).Hash
    Assert-True -Name 'operator CLAUDE.md SHA256 unchanged after invocation' `
        -Condition ($beforeHash -eq $afterHash) `
        -Detail ("before={0} after={1}" -f $beforeHash, $afterHash)
    Assert-True -Name 'operator CLAUDE.md mtime unchanged after invocation' `
        -Condition ($beforeMtime -eq $afterMtime) `
        -Detail ("before={0:o} after={1:o}" -f $beforeMtime, $afterMtime)
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
