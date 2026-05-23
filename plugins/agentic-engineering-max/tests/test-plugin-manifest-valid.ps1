# tests/test-plugin-manifest-valid.ps1
#
# Regression test for the v1.0.0 install-blocker: plugin.json shipped its
# `repository` field as an npm-style object ({ "type": "git", "url": ... }),
# but the Claude Code plugin schema requires `repository` to be a STRING.
# The result was a hard install failure:
#
#   Failed to install: ... has an invalid manifest file at .claude-plugin/plugin.json.
#   Validation errors: repository: Invalid input: expected string, received object
#
# This test parses the shipped plugin.json (and marketplace.json when present)
# and asserts the field SHAPES that Claude Code's validator enforces, so the
# object-vs-string regression -- and its siblings -- can never ship again.
#
# Layout note: the test resolves manifests by RELATIVE position, so it passes
# both in the Dev_006 `plugin/` source tree and in the flattened public-repo
# subtree (the two share the same relative layout under the plugin root).
#
# Run:  pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test-plugin-manifest-valid.ps1
# Exit: 0 = all assertions pass, 1 = at least one failed.
#
# Conventions (Dev_006 CLAUDE.md "Testing"): plain .ps1, no Pester, ASCII-only,
# exit 0 on pass / 1 on fail.

$ErrorActionPreference = 'Stop'

# Plugin root is the parent of the tests dir (plugins/agentic-engineering-max).
$pluginRoot      = Split-Path -Parent $PSScriptRoot
$pluginJsonPath  = Join-Path $pluginRoot '.claude-plugin/plugin.json'

# marketplace.json lives at the marketplace root, two levels above the plugin
# root: <root>/.claude-plugin/marketplace.json  (same in source + public tree).
$marketplaceRoot = Split-Path -Parent (Split-Path -Parent $pluginRoot)
$marketJsonPath  = Join-Path $marketplaceRoot '.claude-plugin/marketplace.json'

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

# A JSON string field deserializes to [string]; an object deserializes to
# PSCustomObject; an array to [object[]]. Checking the deserialized .NET type
# is exactly what catches the object-vs-string regression.
function Test-IsJsonString {
    param($Value)
    return ($Value -is [string])
}

# --- plugin.json ------------------------------------------------------------
if (-not (Test-Path -LiteralPath $pluginJsonPath -PathType Leaf)) {
    Write-Host ("FAIL: plugin.json not found at {0}" -f $pluginJsonPath)
    exit 1
}

$pluginJson = $null
try {
    $pluginJson = Get-Content -LiteralPath $pluginJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    $pluginJson = $null
}
Assert -Condition ($null -ne $pluginJson) -Name 'plugin.json parses as valid JSON' `
    -Detail ("could not parse {0}" -f $pluginJsonPath)

if ($null -ne $pluginJson) {
    Assert -Condition (Test-IsJsonString $pluginJson.name) `
        -Name 'plugin.json `name` is a string' `
        -Detail ("got type {0}" -f ($pluginJson.name.GetType().Name))

    Assert -Condition ((Test-IsJsonString $pluginJson.version) -and `
            (-not [string]::IsNullOrWhiteSpace($pluginJson.version))) `
        -Name 'plugin.json `version` is a non-empty string'

    # THE core regression: `repository`, when present, MUST be a string.
    $hasRepo = $pluginJson.PSObject.Properties.Name -contains 'repository'
    Assert -Condition ($hasRepo) -Name 'plugin.json declares a `repository` field' `
        -Detail 'field absent'
    if ($hasRepo) {
        Assert -Condition (Test-IsJsonString $pluginJson.repository) `
            -Name 'plugin.json `repository` is a STRING, not an object (v1.0.0 install-blocker)' `
            -Detail ("got type {0}; the Claude Code schema rejects object/array shapes" -f `
                ($pluginJson.repository.GetType().Name))
        Assert -Condition ((Test-IsJsonString $pluginJson.repository) -and `
                ($pluginJson.repository -match '^https?://')) `
            -Name 'plugin.json `repository` is an http(s) URL'
    }

    # `homepage`, when present, is also a string per the schema.
    $hasHome = $pluginJson.PSObject.Properties.Name -contains 'homepage'
    if ($hasHome) {
        Assert -Condition (Test-IsJsonString $pluginJson.homepage) `
            -Name 'plugin.json `homepage` is a string'
    }

    # `keywords`, when present, must be an array (NOT a string).
    $hasKw = $pluginJson.PSObject.Properties.Name -contains 'keywords'
    if ($hasKw) {
        Assert -Condition ($pluginJson.keywords -is [System.Collections.IEnumerable] -and `
                -not (Test-IsJsonString $pluginJson.keywords)) `
            -Name 'plugin.json `keywords` is an array'
    }
}

# --- marketplace.json (validate + version mirror) ---------------------------
if (Test-Path -LiteralPath $marketJsonPath -PathType Leaf) {
    $marketJson = $null
    try {
        $marketJson = Get-Content -LiteralPath $marketJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $marketJson = $null
    }
    Assert -Condition ($null -ne $marketJson) -Name 'marketplace.json parses as valid JSON' `
        -Detail ("could not parse {0}" -f $marketJsonPath)

    if ($null -ne $marketJson -and $null -ne $pluginJson) {
        $entry = $marketJson.plugins | Where-Object { $_.name -eq $pluginJson.name } | Select-Object -First 1
        Assert -Condition ($null -ne $entry) `
            -Name 'marketplace.json lists the plugin by name' `
            -Detail ("no plugins[] entry named {0}" -f $pluginJson.name)
        if ($null -ne $entry) {
            Assert -Condition ($entry.version -eq $pluginJson.version) `
                -Name 'marketplace.json version mirrors plugin.json version' `
                -Detail ("marketplace={0} plugin={1}" -f $entry.version, $pluginJson.version)
        }
    }
} else {
    Write-Host ("INFO: marketplace.json not found at {0} (skipping mirror checks)" -f $marketJsonPath)
}

Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:passes, $script:failures)
if ($script:failures -gt 0) { exit 1 } else { exit 0 }
