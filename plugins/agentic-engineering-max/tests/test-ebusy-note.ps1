# tests/test-ebusy-note.ps1
#
# Regression test for hooks/claude-context-inject.ps1 -- the EBUSY first-run
# note that rides alongside the /aem-init nudge (D-S3 / ledger Field 19).
#
# Contract under test: the SessionStart hook appends BOTH the /aem-init nudge
# AND the EBUSY "just retry" note to additionalContext WHEN core.hooksPath is
# NOT wired to the plugin's hooks dir, and appends NEITHER when it IS wired.
# In every case the hook must exit 0 (the top-level try/catch envelope must
# never block session start).
#
# Method: drive the real hook with a STUB docs/CLAUDE-template.md (so the test
# does not depend on the shipped template text). $env:CLAUDE_PLUGIN_ROOT points
# at a temp plugin-root holding the stub; the hook's working directory sits
# inside a temp git repo whose core.hooksPath is either unset (unwired) or set
# to the stub's hooks dir (wired). Empty stdin is piped in (the hook drains
# stdin via [Console]::In.ReadToEnd()).
#
# Run:    pwsh -NoProfile -File tests/test-ebusy-note.ps1
# Exit:   0 = all pass, 1 = at least one failed.
#
# DUAL-COPY: this file is byte-identical to its plugin-mirror copy. The hook is
# plugin-only (not mirrored to repo root), so the plugin dir is located by
# probing both candidate locations from $PSScriptRoot rather than assuming a
# fixed parent. ASCII-only inside double-quoted literals (PS5.1 cp1252 hazard).

$ErrorActionPreference = 'Stop'

# Locate the real hook from either test-copy location:
#   plugin copy: tests/ sits directly under the plugin dir.
#   root copy:   tests/ sits under repo root; the plugin is nested below.
$base = Split-Path -Parent $PSScriptRoot
$candidates = @(
    $base,
    (Join-Path $base 'plugin/plugins/agentic-engineering-max')
)
$pluginDir = $null
foreach ($c in $candidates) {
    if (Test-Path -LiteralPath (Join-Path $c 'hooks/claude-context-inject.ps1')) { $pluginDir = $c; break }
}
if (-not $pluginDir) {
    Write-Host "FAIL: cannot locate hooks/claude-context-inject.ps1 from $PSScriptRoot"
    exit 1
}
$hookPath = Join-Path $pluginDir 'hooks/claude-context-inject.ps1'

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

# Invoke the hook with its CWD inside $RepoDir, capturing stdout + exit code.
# Returns a hashtable: Exit, ParseOk, EventName, Context.
function Invoke-Inject {
    param([Parameter(Mandatory)][string]$RepoDir)

    $rawOut    = $null
    $childExit = $null
    $prevPref  = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $RepoDir
    try {
        # Empty stdin so the hook's [Console]::In.ReadToEnd() returns at once.
        # -ExecutionPolicy Bypass on the child guarantees the hook .ps1 runs
        # regardless of the machine policy (test-harness concern only; the
        # SHIPPED invocation is Bypass-free). Never merge stderr (2>&1 wraps
        # native-exe stderr as RemoteException on PS5.1); the hook emits only
        # the JSON envelope on stdout in every path.
        $rawOut    = '' | & pwsh -NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -File $hookPath
        $childExit = $LASTEXITCODE
    } finally {
        Pop-Location
        $ErrorActionPreference = $prevPref
    }

    if ($null -eq $rawOut)        { $stdout = '' }
    elseif ($rawOut -is [array])  { $stdout = ($rawOut -join "`n") }
    else                          { $stdout = [string]$rawOut }

    $parsed  = $null
    $parseOk = $false
    try {
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $parsed  = $stdout | ConvertFrom-Json
            $parseOk = $true
        }
    } catch {
        $parseOk = $false
    }

    $eventName = $null
    $ctx       = $null
    if ($parseOk) {
        try { $eventName = $parsed.hookSpecificOutput.hookEventName } catch { }
        try { $ctx = [string]$parsed.hookSpecificOutput.additionalContext } catch { $ctx = $null }
    }

    return @{ Exit = $childExit; ParseOk = $parseOk; EventName = $eventName; Context = $ctx; Raw = $stdout }
}

# Markers we assert on. The nudge carries '/aem-init'; the EBUSY note carries
# the distinctive token 'EBUSY'. The stub template carries a unique GUID token
# so we can prove the template is ALWAYS injected (even in the wired case where
# no nudge/EBUSY note is appended).
$nudgeMarker    = '/aem-init'
$ebusyMarker    = 'EBUSY'
$templateMarker = "STUB_TEMPLATE_MARKER_{0}" -f ([guid]::NewGuid().ToString('N'))

$savedPluginRoot = $env:CLAUDE_PLUGIN_ROOT
$workRoot = Join-Path ([IO.Path]::GetTempPath()) ("ebusy-note-test-{0}" -f (Get-Random))
New-Item -ItemType Directory -Path $workRoot | Out-Null

try {
    # --- Stub plugin root with a stub CLAUDE-template.md ----------------------
    $pluginRootStub = Join-Path $workRoot 'plugin-stub'
    $stubDocsDir    = Join-Path $pluginRootStub 'docs'
    New-Item -ItemType Directory -Path $stubDocsDir | Out-Null
    $stubTemplate   = Join-Path $stubDocsDir 'CLAUDE-template.md'
    $stubBody = "# Stub template`n`n$templateMarker`n"
    [IO.File]::WriteAllText($stubTemplate, $stubBody, [Text.UTF8Encoding]::new($false))
    $env:CLAUDE_PLUGIN_ROOT = $pluginRootStub

    # The plugin hooks dir the wired case must point core.hooksPath at. The
    # hook normalizes both sides (forward slashes, no trailing sep, lower-case)
    # so the dir need not exist for the comparison; we forward-slash the value
    # to avoid git-config backslash-escaping.
    $stubHooksDir = (Join-Path $pluginRootStub 'hooks') -replace '\\', '/'

    # --- UNWIRED repo: core.hooksPath NOT set -> nudge + EBUSY note fire ------
    $unwiredRepo = Join-Path $workRoot 'repo-unwired'
    New-Item -ItemType Directory -Path $unwiredRepo | Out-Null
    Push-Location $unwiredRepo
    try {
        git init -q
        git config user.email 'test@example.com'
        git config user.name  'ebusy-note-test'
    } finally {
        Pop-Location
    }

    $u = Invoke-Inject -RepoDir $unwiredRepo

    Assert-True -Name 'UNWIRED: hook exits 0' `
        -Condition ($u.Exit -eq 0) `
        -Detail ("got exit {0}" -f $u.Exit)
    Assert-True -Name 'UNWIRED: stdout is valid JSON' `
        -Condition ([bool]$u.ParseOk) `
        -Detail ("raw: {0}" -f ($u.Raw -replace "`r?`n", ' '))
    Assert-True -Name 'UNWIRED: hookEventName == SessionStart' `
        -Condition ($u.EventName -eq 'SessionStart') `
        -Detail ("got: '{0}'" -f $u.EventName)
    Assert-True -Name 'UNWIRED: additionalContext carries the stub template marker' `
        -Condition (($null -ne $u.Context) -and $u.Context.Contains($templateMarker)) `
        -Detail 'template text not injected'
    Assert-True -Name 'UNWIRED: additionalContext contains the /aem-init nudge' `
        -Condition (($null -ne $u.Context) -and $u.Context.Contains($nudgeMarker)) `
        -Detail 'nudge marker not found'
    Assert-True -Name 'UNWIRED: additionalContext contains the EBUSY note' `
        -Condition (($null -ne $u.Context) -and $u.Context.Contains($ebusyMarker)) `
        -Detail 'EBUSY note not found'

    # --- WIRED repo: core.hooksPath == plugin hooks dir -> NEITHER fires ------
    $wiredRepo = Join-Path $workRoot 'repo-wired'
    New-Item -ItemType Directory -Path $wiredRepo | Out-Null
    Push-Location $wiredRepo
    try {
        git init -q
        git config user.email 'test@example.com'
        git config user.name  'ebusy-note-test'
        git config core.hooksPath $stubHooksDir
    } finally {
        Pop-Location
    }

    $w = Invoke-Inject -RepoDir $wiredRepo

    Assert-True -Name 'WIRED: hook exits 0' `
        -Condition ($w.Exit -eq 0) `
        -Detail ("got exit {0}" -f $w.Exit)
    Assert-True -Name 'WIRED: stdout is valid JSON' `
        -Condition ([bool]$w.ParseOk) `
        -Detail ("raw: {0}" -f ($w.Raw -replace "`r?`n", ' '))
    Assert-True -Name 'WIRED: hookEventName == SessionStart' `
        -Condition ($w.EventName -eq 'SessionStart') `
        -Detail ("got: '{0}'" -f $w.EventName)
    Assert-True -Name 'WIRED: additionalContext still carries the stub template marker' `
        -Condition (($null -ne $w.Context) -and $w.Context.Contains($templateMarker)) `
        -Detail 'template text not injected on the wired path'
    Assert-True -Name 'WIRED: additionalContext does NOT contain the /aem-init nudge' `
        -Condition (($null -ne $w.Context) -and -not $w.Context.Contains($nudgeMarker)) `
        -Detail 'nudge leaked into a wired repo'
    Assert-True -Name 'WIRED: additionalContext does NOT contain the EBUSY note' `
        -Condition (($null -ne $w.Context) -and -not $w.Context.Contains($ebusyMarker)) `
        -Detail 'EBUSY note leaked into a wired repo'
}
finally {
    $env:CLAUDE_PLUGIN_ROOT = $savedPluginRoot
    Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------
Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:passes, $script:failures)
if ($script:failures -gt 0) { exit 1 } else { exit 0 }
