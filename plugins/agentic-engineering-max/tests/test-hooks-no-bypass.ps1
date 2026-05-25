# tests/test-hooks-no-bypass.ps1
#
# Regression test for the onboarding-ux no-Bypass discipline on the hook surface
# (T011; depends on T001-T005). Two parts:
#
#   STATIC: hooks.json and BOTH pre-commit bash shims (repo-root + plugin)
#     contain ZERO '-ExecutionPolicy Bypass' tokens. The hook runner shape must
#     be plain 'pwsh -NoProfile -File <script>' -- the Bypass flag is the
#     classifier-hostile shape and is also unnecessary for hook execution.
#
#   RUNTIME: a trivial clean .ps1 written to a temp dir runs successfully via
#     plain 'pwsh -NoProfile -File' under the machine's DEFAULT execution policy
#     (no Bypass override). This proves the no-Bypass runner shape actually
#     executes a script on a normal machine -- the whole point of dropping the
#     flag.
#
# Run:    pwsh -NoProfile -File tests/test-hooks-no-bypass.ps1
# Exit:   0 = all pass, 1 = at least one failed.
#
# DUAL-COPY: byte-identical to its plugin-mirror copy. hooks.json lives only in
# the plugin tree; the pre-commit shim exists both at repo root and in the plugin
# tree. Both are located by probing candidate paths from $PSScriptRoot, so the
# test works from either copy location and in a shipped (plugin-only) tree.
# ASCII-only inside double-quoted literals.

$ErrorActionPreference = 'Stop'

$base = Split-Path -Parent $PSScriptRoot
$candidates = @(
    $base,
    (Join-Path $base 'plugin/plugins/agentic-engineering-max')
)
$pluginDir = $null
foreach ($c in $candidates) {
    if (Test-Path -LiteralPath (Join-Path $c 'hooks/hooks.json')) { $pluginDir = $c; break }
}
if (-not $pluginDir) {
    Write-Host "FAIL: cannot locate hooks/hooks.json from $PSScriptRoot"
    exit 1
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
        if ($Detail) { Write-Host ("      {0}" -f $Detail) }
        $script:failures++
    }
}

$bypassNeedle = '-ExecutionPolicy Bypass'

# --- STATIC: hooks.json + both pre-commit shims carry no Bypass token ---------
# hooks.json: plugin-only. Shims: repo-root hooks/pre-commit AND the plugin
# hooks/pre-commit. In a shipped (plugin-only) tree the repo-root shim is absent,
# so candidates are de-duplicated and at least one must be found.
$staticTargets = @( (Join-Path $pluginDir 'hooks/hooks.json') )

$shimCandidates = @(
    (Join-Path $base 'hooks/pre-commit'),
    (Join-Path $pluginDir 'hooks/pre-commit')
) | Select-Object -Unique
$shimsFound = @($shimCandidates | Where-Object { Test-Path -LiteralPath $_ })
Assert-True -Name 'at least one pre-commit shim found to scan' -Condition ($shimsFound.Count -gt 0) `
    -Detail ($shimCandidates -join '; ')
foreach ($s in $shimsFound) { $staticTargets += $s }

foreach ($t in $staticTargets) {
    if (-not (Test-Path -LiteralPath $t)) {
        Assert-True -Name ("hook target present: {0}" -f $t) -Condition $false
        continue
    }
    $rel = (Resolve-Path -LiteralPath $t).Path
    $txt = [IO.File]::ReadAllText($t)
    $hasBypass = $txt -match [regex]::Escape($bypassNeedle)
    Assert-True -Name ("no -ExecutionPolicy Bypass in {0}" -f (Split-Path $t -Leaf)) `
        -Condition (-not $hasBypass) -Detail $rel
}

# Positive: hooks.json invokes the runner via the plain 'pwsh -NoProfile -File'
# shape (proves the de-Bypassed runner is the one actually shipped).
$hooksJson = Join-Path $pluginDir 'hooks/hooks.json'
$hooksText = [IO.File]::ReadAllText($hooksJson)
Assert-True -Name "hooks.json uses the plain 'pwsh -NoProfile -File' runner" `
    -Condition ($hooksText -match 'pwsh -NoProfile -File') `
    -Detail 'the hook command shape must be plain pwsh -File, no policy override'

# --- RUNTIME: a clean .ps1 runs via plain pwsh -File under default policy ------
$sentinel = 'AEM_NOBYPASS_OK_42'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aem-nobypass-{0}.ps1" -f (Get-Random))
try {
    # A trivial, side-effect-free script. Single-quoted body so nothing expands.
    Set-Content -LiteralPath $tmp -Value ('Write-Output ''{0}''' -f $sentinel) -Encoding utf8

    # Invoke with the exact no-Bypass runner shape the hooks/shims use. No
    # -ExecutionPolicy override: this must succeed under the machine default.
    $out = (& pwsh -NoProfile -File $tmp 2>$null | Out-String).Trim()
    $ran = ($LASTEXITCODE -eq 0) -and ($out -eq $sentinel)
    Assert-True -Name 'clean .ps1 runs via plain pwsh -NoProfile -File (default policy, no Bypass)' `
        -Condition $ran `
        -Detail ("exit={0} output='{1}'" -f $LASTEXITCODE, $out)
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host ("FAIL: {0} assertion(s) failed, {1} passed." -f $script:failures, $script:passes)
    exit 1
}
Write-Host ("PASS: all {0} assertions passed (hooks/shims carry no Bypass; clean .ps1 runs without it)." -f $script:passes)
exit 0
