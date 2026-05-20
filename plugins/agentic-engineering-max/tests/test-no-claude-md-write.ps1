# tests/test-no-claude-md-write.ps1
#
# Regression test for invariant 2 (PRD section 8): the plugin must NEVER write
# to the operator's CLAUDE.md. All principle injection flows through the
# claude-context-inject.ps1 SessionStart hook as hookSpecificOutput.
# additionalContext -- no file-write code path may touch <repo-root>\CLAUDE.md.
#
# Strategy:
#   1. Stand up a throwaway git repo in a temp dir.
#   2. Drop a sentinel CLAUDE.md carrying a known marker string, then pin its
#      LastWriteTimeUtc to a fixed past timestamp and record its SHA256 hash.
#   3. Run the two code paths that touch the operator's repo on bootstrap:
#        (a) scripts\aem-init.ps1  -- exercised WITH --slug so the file-writing
#            scaffold path runs (the path most likely to clobber by accident).
#        (b) hooks\claude-context-inject.ps1 -- the SessionStart injector, fed a
#            JSON event on stdin (it drains stdin) with CLAUDE_PLUGIN_ROOT set.
#   4. Assert CLAUDE.md mtime + hash are unchanged after both invocations, and
#      that the hook emitted valid JSON with a populated additionalContext.
#   5. Clean up the temp repo and restore the parent's CLAUDE_PLUGIN_ROOT.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-no-claude-md-write.ps1
# Exit: 0 = all assertions pass, 1 = at least one failed.
#
# Conventions (D:\GitHub Projects\Dev_006\CLAUDE.md "Testing"): plain .ps1, no
# Pester, ASCII-only, no 2>&1 on native exes (git stderr goes to $null).

$ErrorActionPreference = 'Stop'

# Plugin root is the parent of the tests dir (plugins\agentic-engineering-max).
$pluginRoot = Split-Path -Parent $PSScriptRoot
$aemInit    = Join-Path $pluginRoot 'scripts\aem-init.ps1'
$injectHook = Join-Path $pluginRoot 'hooks\claude-context-inject.ps1'
$template   = Join-Path $pluginRoot 'docs\CLAUDE-template.md'

$script:passes   = 0
$script:failures = 0

function Assert {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Name,
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

# Preflight: every dependency must be present, or the test cannot run.
foreach ($p in @($aemInit, $injectHook, $template)) {
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host ("FAIL: required dependency missing: {0}" -f $p)
        exit 1
    }
}

$testRoot        = Join-Path $env:TEMP ("no-claude-md-write-{0}" -f (Get-Random))
$savedPluginRoot = $env:CLAUDE_PLUGIN_ROOT
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    Push-Location $testRoot

    # Fresh throwaway repo. core.hooksPath starts unset, so aem-init will set it
    # to the plugin hooks dir without a conflict.
    git init -q
    git config user.email 'test@example.com'
    git config user.name  'no-claude-md-write-test'

    # Sentinel operator CLAUDE.md with a known marker + pinned mtime + hash.
    $marker   = "OPERATOR-SENTINEL-" + ([Guid]::NewGuid().ToString('N'))
    $claudeMd = Join-Path $testRoot 'CLAUDE.md'
    Set-Content -LiteralPath $claudeMd -Value ("# Operator CLAUDE.md`n`n" + $marker + "`n") -Encoding UTF8

    $fixedTime = (Get-Date '2020-01-01T00:00:00Z').ToUniversalTime()
    (Get-Item -LiteralPath $claudeMd).LastWriteTimeUtc = $fixedTime

    $beforeMtime = (Get-Item -LiteralPath $claudeMd).LastWriteTimeUtc
    $beforeHash  = (Get-FileHash -LiteralPath $claudeMd -Algorithm SHA256).Hash

    # Both invoked code paths resolve the plugin via CLAUDE_PLUGIN_ROOT.
    $env:CLAUDE_PLUGIN_ROOT = $pluginRoot

    # --- (a) aem-init in the temp repo (child process; cwd pinned to temp repo).
    # --slug runs the scaffold write path; the slash command maps --slug -> -Slug.
    $aemCmd  = "Set-Location -LiteralPath '$testRoot'; & '$aemInit' -Slug 'sentinel-slug'"
    $aemOut  = & powershell -NoProfile -ExecutionPolicy Bypass -Command $aemCmd
    $aemExit = $LASTEXITCODE

    # --- (b) SessionStart hook. Feed a JSON event on stdin (it calls ReadToEnd)
    # so the child does not block waiting for input; capture its stdout envelope.
    $hookCmd    = "Set-Location -LiteralPath '$testRoot'; & '$injectHook'"
    $hookOut    = '{}' | & powershell -NoProfile -ExecutionPolicy Bypass -Command $hookCmd
    $hookExit   = $LASTEXITCODE
    $hookOutStr = ($hookOut | Out-String).Trim()

    # --- Assertions ----------------------------------------------------------
    Assert -Condition ($aemExit -eq 0) -Name 'aem-init exits 0 in a clean repo' `
        -Detail ("expected exit 0, got {0}" -f $aemExit)

    $afterMtime = (Get-Item -LiteralPath $claudeMd).LastWriteTimeUtc
    $afterHash  = (Get-FileHash -LiteralPath $claudeMd -Algorithm SHA256).Hash
    $afterText  = Get-Content -LiteralPath $claudeMd -Raw -Encoding UTF8

    Assert -Condition ($afterMtime -eq $beforeMtime) -Name 'CLAUDE.md mtime unchanged' `
        -Detail ("before={0:o} after={1:o}" -f $beforeMtime, $afterMtime)

    Assert -Condition ($afterHash -eq $beforeHash) -Name 'CLAUDE.md content hash unchanged' `
        -Detail ("before={0} after={1}" -f $beforeHash, $afterHash)

    Assert -Condition ($afterText -match [regex]::Escape($marker)) -Name 'CLAUDE.md marker still present' `
        -Detail 'sentinel marker string was lost'

    $parsed = $null
    try { $parsed = $hookOutStr | ConvertFrom-Json } catch { $parsed = $null }
    Assert -Condition ($null -ne $parsed) -Name 'hook stdout parses as JSON' `
        -Detail ("hook exit {0}; raw: {1}" -f $hookExit, $hookOutStr)

    $ctx = $null
    if ($null -ne $parsed) { $ctx = $parsed.hookSpecificOutput.additionalContext }
    Assert -Condition (-not [string]::IsNullOrWhiteSpace($ctx)) -Name 'additionalContext populated' `
        -Detail 'hookSpecificOutput.additionalContext was empty'
}
finally {
    Pop-Location
    if ($null -eq $savedPluginRoot) {
        Remove-Item Env:\CLAUDE_PLUGIN_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:CLAUDE_PLUGIN_ROOT = $savedPluginRoot
    }
    Remove-Item -Recurse -Force $testRoot -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:passes, $script:failures)
if ($script:failures -gt 0) { exit 1 } else { exit 0 }
