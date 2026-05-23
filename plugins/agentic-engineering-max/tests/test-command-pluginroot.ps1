# tests/test-command-pluginroot.ps1
#
# Regression test for the v2.0.0 "/aem-init came through empty" defect.
#
# Root cause (confirmed against the Claude Code plugins reference): the
# `${CLAUDE_PLUGIN_ROOT}` substitution variable is resolved inline in SKILL
# content, agent content, hook commands, monitor commands, and MCP/LSP configs
# -- but NOT in slash-COMMAND content. /aem-init, /board, and /unblock shipped
# as commands whose bash blocks referenced CLAUDE_PLUGIN_ROOT, so the variable
# arrived empty, the script path collapsed to "/scripts/...", and pwsh exited 1
# -- which the error table mislabeled "not a git repository".
#
# Secondary defect: /board and /unblock invoked `powershell` (the Windows-only
# exe) instead of `pwsh`, so they would also break on Linux. crosscompat-lint
# scans .ps1 files and missed the `powershell` invocation inside .md bash blocks.
#
# The fix moved all three to skills/ (where the variable substitutes) and
# switched them to pwsh. This test locks BOTH contracts so neither can regress:
#   1. No file under commands/ may reference CLAUDE_PLUGIN_ROOT.
#   2. No bash block in commands/ OR skills/ may invoke the Windows-only
#      `powershell` exe (must use pwsh).
#   3. The three migrated skills exist and reference ${CLAUDE_PLUGIN_ROOT}.
#
# Run:  pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test-command-pluginroot.ps1
# Exit: 0 = all assertions pass, 1 = at least one failed.
#
# Conventions (Dev_006 CLAUDE.md "Testing"): plain .ps1, no Pester, ASCII-only,
# exit 0 on pass / 1 on fail. Resolves paths by RELATIVE position so it passes
# in both the Dev_006 source tree and the flattened public-repo subtree.

$ErrorActionPreference = 'Stop'

# Plugin root is the parent of the tests dir (plugins/agentic-engineering-max).
$pluginRoot   = Split-Path -Parent $PSScriptRoot
$commandsDir  = Join-Path $pluginRoot 'commands'
$skillsDir    = Join-Path $pluginRoot 'skills'

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

# --- Check 1: no commands/*.md references CLAUDE_PLUGIN_ROOT -----------------
# Commands do not get the variable substituted, so any reference is a latent
# empty-expansion bug. (An absent commands/ dir trivially satisfies this.)
$cmdOffenders = @()
if (Test-Path -LiteralPath $commandsDir -PathType Container) {
    foreach ($f in (Get-ChildItem -LiteralPath $commandsDir -Filter '*.md' -File -Recurse)) {
        $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
        if ($text -match 'CLAUDE_PLUGIN_ROOT') {
            $cmdOffenders += $f.FullName
        }
    }
}
Assert -Condition ($cmdOffenders.Count -eq 0) `
    -Name 'no commands/*.md references CLAUDE_PLUGIN_ROOT (commands do not substitute it)' `
    -Detail ("offenders: {0}" -f ($cmdOffenders -join '; '))

# --- Check 2: no .md invokes the Windows-only `powershell` exe ---------------
# Match lowercase `powershell` (or `powershell.exe`) as a whole word, CASE-
# SENSITIVELY (-cmatch). Case sensitivity is the key: prose such as "PowerShell
# 7+" or "the PowerShell expression" must NOT trip the check, while a real
# `powershell -NoProfile ...` command invocation must. `pwsh` never matches
# (it does not contain the substring). The lookbehind/lookahead exclude letters
# so surrounding punctuation (backtick-inline-code, spaces, pipes) is fine.
$psOffenders = @()
foreach ($dir in @($commandsDir, $skillsDir)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -Recurse)) {
        $lineNo = 0
        foreach ($line in (Get-Content -LiteralPath $f.FullName -Encoding UTF8)) {
            $lineNo++
            if ($line -cmatch '(?<![A-Za-z])powershell(\.exe)?(?![A-Za-z])') {
                $psOffenders += ("{0}:{1}" -f $f.FullName, $lineNo)
            }
        }
    }
}
Assert -Condition ($psOffenders.Count -eq 0) `
    -Name 'no .md bash block invokes Windows-only `powershell` (must use pwsh)' `
    -Detail ("offenders: {0}" -f ($psOffenders -join '; '))

# --- Check 3: the three migrated skills exist and reference the variable ------
foreach ($name in @('aem-init', 'board', 'unblock')) {
    $skillFile = Join-Path (Join-Path $skillsDir $name) 'SKILL.md'
    $exists = Test-Path -LiteralPath $skillFile -PathType Leaf
    Assert -Condition $exists `
        -Name ("skill '{0}' exists at skills/{0}/SKILL.md" -f $name) `
        -Detail ("expected {0}" -f $skillFile)
    if ($exists) {
        $text = Get-Content -LiteralPath $skillFile -Raw -Encoding UTF8
        Assert -Condition ($text -match '\$\{CLAUDE_PLUGIN_ROOT\}') `
            -Name ("skill '{0}' references `${{CLAUDE_PLUGIN_ROOT}}` (brace form, substituted in skill content)" -f $name) `
            -Detail 'expected the brace form so Claude Code substitutes it inline'
    }
}

Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:passes, $script:failures)
if ($script:failures -gt 0) { exit 1 } else { exit 0 }
