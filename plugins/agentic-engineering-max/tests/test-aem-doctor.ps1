# tests/test-aem-doctor.ps1
#
# Regression test for scripts/aem-doctor.ps1 -- the shared 4-check health routine
# run standalone by /aem-doctor and at the tail of /aem-init (T006). It also makes
# the D-S4 Restricted-detection contract falsifiable.
#
# Contract under test (spec.md Task T015):
#   (1) healthy git repo with core.hooksPath wired to the (passed) plugin hooks
#       dir -> exit 0, all four checks reported, summary "all good".
#   (2) a dir that is NOT a git repo -> check (a) reports the failure + a fix
#       line, and the routine still runs the remaining checks to completion.
#   (3) a git repo with core.hooksPath NOT wired -> check (c) reports NO and
#       points the user at /aem-init.
#   (4) process-scope Restricted simulation (D-S4). This tests the locked-down
#       PROBE MECHANISM and the SKILL bash PRE-FLIGHT path -- NOT a -File load of
#       the doctor under Restricted (which would correctly be refused by the host
#       and is therefore out of scope). Two GPO-free assertions:
#         (4a) DYNAMIC -- a child 'pwsh -Command' that sets Process-scope
#              Restricted and then reads (Get-ExecutionPolicy) still returns
#              'Restricted'. This proves the inline -Command probe answers under
#              a blocking policy while loading no script file.
#         (4b) STATIC -- the /aem-doctor SKILL.md '!' block contains the inline
#              Get-ExecutionPolicy pre-flight, branches on Restricted/AllSigned,
#              prints exactly ONE fix command, and 'exit's on that branch BEFORE
#              the 'pwsh -File ...aem-doctor.ps1' load line (ordering + count).
#
# The healthy/not-a-repo/unwired cases launch the backing .ps1 via a child
# 'pwsh -ExecutionPolicy Bypass -File' so the script loads regardless of the
# build machine's policy (a TEST-HARNESS concern only; the SHIPPED invocation is
# Bypass-free). Under that Bypass host, check (d)'s inline probe reads 'Bypass'
# -- a non-blocking value -- so check (d) reports OK deterministically and the
# healthy case is machine-independent. The Restricted path is exercised by (4a)
# (the probe mechanism) and (4b) (the pre-flight that fires before any .ps1 load).
#
# Run:    pwsh -NoProfile -File tests/test-aem-doctor.ps1
# Exit:   0 = all pass, 1 = at least one failed.
#
# DUAL-COPY: byte-identical to its plugin-mirror copy. The doctor script + skill
# live only in the plugin tree, so the plugin dir is located by probing both
# candidate locations from $PSScriptRoot. ASCII-only inside double-quoted
# literals (PS5.1 cp1252 hazard); paths built via Join-Path (no backslash
# literals, no drive letters).

$ErrorActionPreference = 'Stop'

# Locate the plugin dir from either test-copy location:
#   plugin copy: tests/ sits directly under the plugin dir.
#   root copy:   tests/ sits under repo root; the plugin is nested below.
$base = Split-Path -Parent $PSScriptRoot
$candidates = @(
    $base,
    (Join-Path $base 'plugin/plugins/agentic-engineering-max')
)
$pluginDir = $null
foreach ($c in $candidates) {
    if (Test-Path -LiteralPath (Join-Path $c 'scripts/aem-doctor.ps1')) { $pluginDir = $c; break }
}
if (-not $pluginDir) {
    Write-Host "FAIL: cannot locate scripts/aem-doctor.ps1 from $PSScriptRoot"
    exit 1
}
$doctorScript = Join-Path $pluginDir 'scripts/aem-doctor.ps1'
$doctorSkill  = Join-Path $pluginDir 'skills/aem-doctor/SKILL.md'

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
        if ($Detail) { Write-Host ("      {0}" -f $Detail) }
        $script:failures++
    }
}

# Run the backing doctor .ps1 with CWD inside $RepoDir, passing -PluginRoot, and
# capture its stdout (Write-Host output is captured across the process boundary)
# plus its exit code. -ExecutionPolicy Bypass on the child is the harness concern
# noted in the header. Never use the 2>&1 merge form (it wraps native-exe stderr
# as RemoteException on PS5.1 and corrupts $LASTEXITCODE).
function Invoke-Doctor {
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$PluginRoot
    )
    $rawOut   = $null
    $childExit = $null
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $RepoDir
    try {
        $rawOut = & pwsh -NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass `
            -File $doctorScript -PluginRoot $PluginRoot
        $childExit = $LASTEXITCODE
    } finally {
        Pop-Location
        $ErrorActionPreference = $prevPref
    }
    if ($null -eq $rawOut)       { $lines = @() }
    elseif ($rawOut -is [array]) { $lines = $rawOut }
    else                         { $lines = @([string]$rawOut) }
    return @{ Exit = $childExit; Lines = $lines; Text = ($lines -join "`n") }
}

$workRoot = Join-Path ([IO.Path]::GetTempPath()) ("aem-doctor-test-{0}" -f (Get-Random))
New-Item -ItemType Directory -Path $workRoot | Out-Null

try {
    # Stub plugin root with a real hooks dir. The healthy case wires
    # core.hooksPath at this dir; the doctor normalizes both sides
    # (forward slashes, no trailing sep, lower-case) before comparing.
    $pluginRootStub = Join-Path $workRoot 'plugin-stub'
    $stubHooksDir   = Join-Path $pluginRootStub 'hooks'
    New-Item -ItemType Directory -Path $stubHooksDir | Out-Null
    $stubHooksValue = $stubHooksDir -replace '\\', '/'

    # --- (1) HEALTHY: git repo + hooks wired -> exit 0, all four checks, all good
    $healthyRepo = Join-Path $workRoot 'repo-healthy'
    New-Item -ItemType Directory -Path $healthyRepo | Out-Null
    Push-Location $healthyRepo
    try {
        git init -q
        git config user.email 'test@example.com'
        git config user.name  'aem-doctor-test'
        git config core.hooksPath $stubHooksValue
    } finally { Pop-Location }

    $h = Invoke-Doctor -RepoDir $healthyRepo -PluginRoot $pluginRootStub

    Assert-True -Name 'HEALTHY: doctor exits 0' `
        -Condition ($h.Exit -eq 0) `
        -Detail ("got exit {0}; output: {1}" -f $h.Exit, ($h.Text -replace "`r?`n", ' '))
    Assert-True -Name 'HEALTHY: summary says all good' `
        -Condition ($h.Text -match 'all good') `
        -Detail ($h.Text -replace "`r?`n", ' ')
    Assert-True -Name 'HEALTHY: all four checks reported (a,b,c,d)' `
        -Condition (($h.Text -match '\(a\) git repo') -and ($h.Text -match '\(b\) PowerShell 7') `
            -and ($h.Text -match '\(c\) hooks wired') -and ($h.Text -match '\(d\) script execution')) `
        -Detail ($h.Text -replace "`r?`n", ' ')
    Assert-True -Name 'HEALTHY: check (c) hooks wired reports OK' `
        -Condition ($h.Text -match '\(c\) hooks wired: OK') `
        -Detail 'wired core.hooksPath should match the passed -PluginRoot hooks dir'

    # --- (2) NOT A GIT REPO: check (a) fails, routine still completes -----------
    $nonRepo = Join-Path $workRoot 'not-a-repo'
    New-Item -ItemType Directory -Path $nonRepo | Out-Null

    $n = Invoke-Doctor -RepoDir $nonRepo -PluginRoot $pluginRootStub

    Assert-True -Name 'NOT-A-REPO: doctor exits 1 (fixable problem)' `
        -Condition ($n.Exit -eq 1) `
        -Detail ("got exit {0}" -f $n.Exit)
    Assert-True -Name 'NOT-A-REPO: check (a) reports not a git repository' `
        -Condition ($n.Text -match '\(a\) git repo: NOT a git repository') `
        -Detail ($n.Text -replace "`r?`n", ' ')
    Assert-True -Name 'NOT-A-REPO: check (a) prints a git-init fix line' `
        -Condition ($n.Text -match 'git init') `
        -Detail 'check (a) must offer a concrete fix'
    Assert-True -Name 'NOT-A-REPO: routine runs to completion (check (d) + summary present)' `
        -Condition (($n.Text -match '\(d\) script execution') -and ($n.Text -match 'to fix')) `
        -Detail 'a failed early check must not short-circuit the remaining checks'

    # --- (3) HOOKS UNWIRED: git repo, no core.hooksPath -> check (c) -> /aem-init
    $unwiredRepo = Join-Path $workRoot 'repo-unwired'
    New-Item -ItemType Directory -Path $unwiredRepo | Out-Null
    Push-Location $unwiredRepo
    try {
        git init -q
        git config user.email 'test@example.com'
        git config user.name  'aem-doctor-test'
    } finally { Pop-Location }

    $u = Invoke-Doctor -RepoDir $unwiredRepo -PluginRoot $pluginRootStub

    Assert-True -Name 'UNWIRED: doctor exits 1' `
        -Condition ($u.Exit -eq 1) `
        -Detail ("got exit {0}" -f $u.Exit)
    Assert-True -Name 'UNWIRED: check (c) reports NO' `
        -Condition ($u.Text -match '\(c\) hooks wired: NO') `
        -Detail ($u.Text -replace "`r?`n", ' ')
    Assert-True -Name 'UNWIRED: check (c) fix points at /aem-init' `
        -Condition ($u.Text -match '/aem-init') `
        -Detail 'the unwired fix is to run /aem-init'

    # --- (4a) DYNAMIC Restricted probe: inline -Command answers, loads no .ps1 --
    $probeRaw = & pwsh -NoProfile -NoLogo -Command "Set-ExecutionPolicy -Scope Process Restricted -Force; (Get-ExecutionPolicy).ToString()"
    $probe = (($probeRaw -join '') -replace '\s', '')
    Assert-True -Name '(4a) inline probe returns Restricted under process-scope Restricted' `
        -Condition ($probe -eq 'Restricted') `
        -Detail ("probe returned '{0}' (expected Restricted); proves the -Command probe reads a blocking policy without loading a script" -f $probe)
}
finally {
    Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
}

# --- (4b) STATIC: the SKILL '!' pre-flight blocks BEFORE the .ps1 load ---------
# Extract the fenced '!' block from the /aem-doctor SKILL, then assert the
# locked-down branch: an inline Get-ExecutionPolicy probe, a Restricted/AllSigned
# branch carrying exactly ONE fix command, and an 'exit' on that branch that
# precedes the 'pwsh -File ...aem-doctor.ps1' load (a blocked box never loads it).
if (-not (Test-Path -LiteralPath $doctorSkill)) {
    Assert-True -Name '(4b) /aem-doctor SKILL.md present' -Condition $false -Detail $doctorSkill
} else {
    $skillText  = [IO.File]::ReadAllText($doctorSkill)
    $skillLines = $skillText -split "`r?`n"

    # Collect the lines inside the first fenced '!' (or bash/sh) block.
    $blockLines = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    $foundBlock = $false
    foreach ($l in $skillLines) {
        if (-not $inBlock) {
            if ($l -match '^\s*```\s*(!|bash|sh|shell)\s*$') { $inBlock = $true; $foundBlock = $true }
        } elseif ($l -match '^\s*```\s*$') {
            break
        } else {
            $blockLines.Add($l)
        }
    }

    Assert-True -Name "(4b) /aem-doctor SKILL has a fenced '!' block" `
        -Condition $foundBlock `
        -Detail 'the doctor skill must drive an executable bash block'

    # Inline policy probe: a -Command (NOT -File) read of Get-ExecutionPolicy.
    $probeIdx = -1
    for ($i = 0; $i -lt $blockLines.Count; $i++) {
        $bl = $blockLines[$i]
        if (($bl -match 'Get-ExecutionPolicy') -and ($bl -match '-Command') -and ($bl -notmatch '-File')) { $probeIdx = $i; break }
    }
    Assert-True -Name '(4b) pre-flight reads policy via an inline -Command Get-ExecutionPolicy probe' `
        -Condition ($probeIdx -ge 0) `
        -Detail 'the locked-down probe must load no script file'

    # Blocked-policy branch: an if that tests Restricted AND AllSigned.
    $ifIdx = -1
    for ($i = 0; $i -lt $blockLines.Count; $i++) {
        $bl = $blockLines[$i]
        if (($bl -match '^\s*if\b') -and ($bl -match 'Restricted') -and ($bl -match 'AllSigned')) { $ifIdx = $i; break }
    }
    Assert-True -Name '(4b) branches on both Restricted and AllSigned' `
        -Condition ($ifIdx -ge 0) `
        -Detail 'the blocked-policy branch must cover both blocking policies'

    # First 'exit' after the if = the blocked-branch exit.
    $blockedExitIdx = -1
    if ($ifIdx -ge 0) {
        for ($i = $ifIdx + 1; $i -lt $blockLines.Count; $i++) {
            if ($blockLines[$i] -match '^\s*exit\b') { $blockedExitIdx = $i; break }
        }
    }
    Assert-True -Name '(4b) blocked branch exits' `
        -Condition ($blockedExitIdx -ge 0) `
        -Detail 'the blocked-policy branch must exit (never fall through to the .ps1 load)'

    # Exactly ONE fix command in the blocked branch (the Set-ExecutionPolicy line).
    $fixCount = 0
    if ($ifIdx -ge 0 -and $blockedExitIdx -ge $ifIdx) {
        for ($i = $ifIdx; $i -le $blockedExitIdx; $i++) {
            $matches2 = [regex]::Matches($blockLines[$i], 'Set-ExecutionPolicy')
            $fixCount += $matches2.Count
        }
    }
    Assert-True -Name '(4b) blocked branch prints exactly ONE fix command' `
        -Condition ($fixCount -eq 1) `
        -Detail ("found {0} Set-ExecutionPolicy fix command(s) in the blocked branch (expected 1)" -f $fixCount)

    # The doctor .ps1 load line: pwsh ... -File ... .ps1 (the probe used -Command).
    $loadIdx = -1
    for ($i = 0; $i -lt $blockLines.Count; $i++) {
        $bl = $blockLines[$i]
        if (($bl -match '(?i)\bpwsh\b') -and ($bl -match '(?i)-File\b') -and ($bl -match '\.ps1|\$SCRIPT')) { $loadIdx = $i; break }
    }
    Assert-True -Name '(4b) the doctor .ps1 is loaded via pwsh -File' `
        -Condition ($loadIdx -ge 0) `
        -Detail 'the full report runs only where scripts can load'

    # Ordering: the blocked-branch exit must come BEFORE the .ps1 load.
    Assert-True -Name '(4b) blocked-branch exit precedes the .ps1 load (no wall on a blocked box)' `
        -Condition ($blockedExitIdx -ge 0 -and $loadIdx -ge 0 -and $blockedExitIdx -lt $loadIdx) `
        -Detail ("blocked exit at block-line {0}, .ps1 load at block-line {1}" -f $blockedExitIdx, $loadIdx)
}

Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:passes, $script:failures)
if ($script:failures -gt 0) { exit 1 } else { exit 0 }
