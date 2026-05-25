# tests/test-aem-init-skill-no-bypass.ps1
#
# Static regression test for the onboarding-ux no-Bypass discipline across the
# four user-facing skills (T011; depends on T001-T005). Asserts:
#   (1) NONE of the four shipped user-facing skills (aem-init, aem-doctor,
#       board, unblock) contains a '-ExecutionPolicy Bypass' token. The
#       classifier-hostile 'pwsh -ExecutionPolicy Bypass <script>.ps1' shape is
#       what gets hard-denied under Remote Control; it must not reappear in any
#       skill that drives a fenced bash ('!') block. The scan is SCOPED to the
#       four named skills on purpose -- agent-instruction skills (pm, reviewer,
#       worker, plan-interviewer) legitimately mention the token in prose, and
#       those skills do not carry an executable '!' block.
#   (2) the /aem-init skill performs its CORE action (wiring core.hooksPath) in
#       plain git -- it contains 'git config core.hooksPath' and does NOT route
#       the core path through a string-invoked .ps1 (every pwsh -File call of the
#       aem-init backing script must carry -ScaffoldOnly, i.e. it is only the
#       optional --slug scaffold, never the core wiring -- the v2.0.0 regression).
#   (3) the /board and /unblock '!' bash blocks stay small (under a fixed line
#       budget) -- a runaway inline script wall is the shape both the classifier
#       and the onboarding-ux design reject.
#
# aem-doctor is created by T006 (not a dependency of this task); it is scanned
# for Bypass WHEN present but is not required to exist for this test to pass.
#
# Run:    pwsh -NoProfile -File tests/test-aem-init-skill-no-bypass.ps1
# Exit:   0 = all pass, 1 = at least one failed.
#
# DUAL-COPY: byte-identical to its plugin-mirror copy. The skills live only in
# the plugin tree, so the plugin dir is located by probing both candidate
# locations from $PSScriptRoot. ASCII-only inside double-quoted literals.

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
    if (Test-Path -LiteralPath (Join-Path $c 'skills/aem-init/SKILL.md')) { $pluginDir = $c; break }
}
if (-not $pluginDir) {
    Write-Host "FAIL: cannot locate skills/aem-init/SKILL.md from $PSScriptRoot"
    exit 1
}
$skillsDir = Join-Path $pluginDir 'skills'

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

# The literal token the no-Bypass discipline forbids. Stored as a string so the
# assertion logic keys on the exact token -- reintroducing it into any scanned
# skill flips the relevant assertion to FAIL (success-criterion: deliberate
# mutation is caught).
$bypassNeedle = '-ExecutionPolicy Bypass'

# --- (1) No -ExecutionPolicy Bypass in any of the four user-facing skills -----
# aem-init/board/unblock are required to exist (created by T001-T005); aem-doctor
# is scanned only when present (it is built by T006, not a dependency here).
$requiredSkills = @('aem-init', 'board', 'unblock')
$optionalSkills = @('aem-doctor')

foreach ($s in $requiredSkills) {
    $p = Join-Path $skillsDir ("{0}/SKILL.md" -f $s)
    if (-not (Test-Path -LiteralPath $p)) {
        Assert-True -Name ("required skill present: {0}" -f $s) -Condition $false -Detail $p
        continue
    }
    Assert-True -Name ("required skill present: {0}" -f $s) -Condition $true
    $txt = [IO.File]::ReadAllText($p)
    $hasBypass = $txt -match [regex]::Escape($bypassNeedle)
    Assert-True -Name ("no -ExecutionPolicy Bypass in {0}" -f $s) -Condition (-not $hasBypass) `
        -Detail 'classifier-hostile shape must not appear in a user-facing skill'
}

foreach ($s in $optionalSkills) {
    $p = Join-Path $skillsDir ("{0}/SKILL.md" -f $s)
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host ("SKIP: optional skill {0} not present yet (built by T006); Bypass scan deferred" -f $s)
        continue
    }
    $txt = [IO.File]::ReadAllText($p)
    $hasBypass = $txt -match [regex]::Escape($bypassNeedle)
    Assert-True -Name ("no -ExecutionPolicy Bypass in {0}" -f $s) -Condition (-not $hasBypass) `
        -Detail 'classifier-hostile shape must not appear in a user-facing skill'
}

# --- (2) /aem-init core action is plain git, not a string-invoked .ps1 --------
$initPath  = Join-Path $skillsDir 'aem-init/SKILL.md'
$initText  = [IO.File]::ReadAllText($initPath)
$initLines = $initText -split "`n"

Assert-True -Name '/aem-init wires core.hooksPath via plain git' `
    -Condition ($initText -match 'git config core\.hooksPath') `
    -Detail "expected the literal 'git config core.hooksPath' (plain-git core action)"

# Collect any shell var assigned a path ending in aem-init.ps1, then assert every
# pwsh -File invocation of that backing script carries -ScaffoldOnly. A core-path
# invocation of the script WITHOUT -ScaffoldOnly is the v2.0.0 shape this guards.
$initVars = @()
foreach ($ln in $initLines) {
    if ($ln -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*.*aem-init\.ps1') { $initVars += $matches[1] }
}
$coreViaScript = $false
foreach ($ln in $initLines) {
    if (-not (($ln -match '(?i)\bpwsh\b') -and ($ln -match '(?i)-File\b'))) { continue }
    $refsInit = ($ln -match 'aem-init\.ps1')
    foreach ($v in $initVars) {
        if ($ln -match ('\$\{?' + [regex]::Escape($v) + '\}?')) { $refsInit = $true }
    }
    if ($refsInit -and ($ln -notmatch '(?i)-ScaffoldOnly\b')) { $coreViaScript = $true }
}
Assert-True -Name '/aem-init does NOT string-invoke the backing .ps1 for the core path' `
    -Condition (-not $coreViaScript) `
    -Detail 'any pwsh -File call of aem-init.ps1 must include -ScaffoldOnly (scaffold-only, never core wiring)'

# --- (3) /board and /unblock '!' blocks stay under the line budget ------------
$blockBudget = 40
function Get-BangBlockLineCount {
    param([string]$Text)
    $ls = $Text -split "`n"
    $inBlock = $false
    $count = 0
    $found = $false
    foreach ($l in $ls) {
        if (-not $inBlock) {
            if ($l -match '^\s*```\s*(!|bash|sh|shell)\s*$') { $inBlock = $true; $found = $true }
        } elseif ($l -match '^\s*```\s*$') {
            break
        } else {
            $count++
        }
    }
    if (-not $found) { return -1 }
    return $count
}

foreach ($s in @('board', 'unblock')) {
    $p = Join-Path $skillsDir ("{0}/SKILL.md" -f $s)
    $cnt = Get-BangBlockLineCount -Text ([IO.File]::ReadAllText($p))
    Assert-True -Name ("/{0} has a fenced '!' block" -f $s) -Condition ($cnt -ge 0)
    Assert-True -Name ("/{0} '!' block within {1}-line budget (actual {2})" -f $s, $blockBudget, $cnt) `
        -Condition ($cnt -ge 0 -and $cnt -le $blockBudget) `
        -Detail 'a large inline script wall is classifier-hostile; keep the block small'
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host ("FAIL: {0} assertion(s) failed, {1} passed." -f $script:failures, $script:passes)
    exit 1
}
Write-Host ("PASS: all {0} assertions passed (no-Bypass skills + plain-git core + small '!' blocks)." -f $script:passes)
exit 0
