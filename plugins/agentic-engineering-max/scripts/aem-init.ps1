# aem-init.ps1 -- backing script for the /aem-init slash command (D-S9).
#
# Configures the current git repository to use the agentic-engineering-max
# plugin's hooks directory (sets core.hooksPath) and, optionally, scaffolds a
# new planning slug with stub plan-state.md + plan-ledger.md state surfaces.
#
# Invoked by commands/aem-init.md. The slash-command surface translates
# --slug -> -Slug and --force -> -Force.
#
# Exit codes:
#   0  success
#   1  not inside a git repository
#   2  core.hooksPath conflict (existing non-default, non-plugin value) and
#      -Force was not passed
#   3  plugin hooks directory unavailable -- the plugin root could not be
#      resolved (neither -PluginRoot nor $env:CLAUDE_PLUGIN_ROOT yielded an
#      existing directory), or <root>/hooks does not exist on disk. Both mean
#      "the plugin hooks dir cannot be resolved."
#   4  unexpected internal error (top-level catch)
#   5  PowerShell 7+ (pwsh) not resolvable on PATH, or reported version < 7.
#      Emitted by the pre-config probe BEFORE any git config mutation, so a
#      failed probe leaves core.hooksPath untouched.
#
# Conventions: ASCII-only inside double-quoted literals; git invocations send
# stderr to $null (never the merge-into-stdout redirection form, which corrupts
# $LASTEXITCODE handling on PS 5.1).

[CmdletBinding()]
param(
    [string]$Slug,
    [switch]$Force,
    # Plugin install root, passed in by the /aem-init slash command (which
    # resolves it from the documented ${CLAUDE_SKILL_DIR} template, falling back
    # to $CLAUDE_PLUGIN_ROOT). Explicit passing avoids relying on the env var
    # being exported into a child pwsh process. When omitted (e.g. direct
    # invocation or the probe test) the script falls back to the env var.
    [string]$PluginRoot
)

try {
    # --- 1. Confirm we are inside a git repository ----------------------------
    $gitDir = git rev-parse --git-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitDir)) {
        [Console]::Error.WriteLine("[aem-init] error: not inside a git repository")
        exit 1
    }

    # --- 1.5 Probe: PowerShell 7+ (pwsh) must be resolvable on PATH -----------
    # The plugin hooks run under pwsh (hooks.json targets the 'pwsh' command),
    # so 'pwsh' must resolve on the PATH the hook shell will use. The current
    # process being pwsh is NOT sufficient evidence -- a bare existence check
    # (which pwsh / Get-Command) is a false-pass vector (guardrail 3). We invoke
    # 'pwsh' as an EXTERNAL command and parse its reported major version,
    # asserting >= 7. This runs strictly BEFORE any 'git config' mutation
    # (D-S7), so a failed probe leaves core.hooksPath untouched.
    $pwshMajor = $null
    try {
        $pwshVerRaw = & pwsh -NoProfile -NoLogo -Command '$PSVersionTable.PSVersion.Major' 2>$null
        if ($LASTEXITCODE -eq 0) {
            $verText = (($pwshVerRaw -join '') -replace '[^0-9]', '')
            $parsed = 0
            if (-not [string]::IsNullOrWhiteSpace($verText) -and [int]::TryParse($verText, [ref]$parsed)) {
                $pwshMajor = $parsed
            }
        }
    } catch {
        # pwsh not found on PATH: the external-command invocation throws a
        # CommandNotFoundException, which lands here. Leave $pwshMajor null.
        $pwshMajor = $null
    }

    if ($null -eq $pwshMajor -or $pwshMajor -lt 7) {
        [Console]::Error.WriteLine("[aem-init] error: PowerShell 7+ (pwsh) is required but was not found on PATH, or it reported a version below 7.")
        [Console]::Error.WriteLine("[aem-init] The plugin hooks run under 'pwsh'; install PowerShell 7+ and ensure it is on PATH, then re-run.")
        [Console]::Error.WriteLine("[aem-init]   Linux:   wget -qO- https://aka.ms/install-powershell.sh | sudo bash")
        [Console]::Error.WriteLine("[aem-init]   macOS:   brew install --cask powershell")
        [Console]::Error.WriteLine("[aem-init]   Windows: winget install --id Microsoft.PowerShell --source winget")
        exit 5
    }

    # --- 2. Resolve the plugin hooks directory --------------------------------
    # Prefer an explicitly-passed -PluginRoot (the /aem-init slash command
    # resolves the root and passes it in, because $env:CLAUDE_PLUGIN_ROOT is not
    # reliably exported into the command's bash block). Fall back to the env var
    # so direct invocation (e.g. the pwsh-probe test) keeps working.
    $pluginRoot = if (-not [string]::IsNullOrWhiteSpace($PluginRoot)) { $PluginRoot } else { $env:CLAUDE_PLUGIN_ROOT }
    if ([string]::IsNullOrWhiteSpace($pluginRoot)) {
        [Console]::Error.WriteLine("[aem-init] error: plugin root not provided via -PluginRoot and CLAUDE_PLUGIN_ROOT is unset; run from inside the plugin runtime")
        exit 3
    }

    # Normalize: collapse any '..' segment from the command-dir-relative form
    # (${CLAUDE_SKILL_DIR}/..) into a clean absolute path. A root that does not
    # exist on disk is treated as unresolved (exit 3) -- same class as unset.
    try {
        $pluginRoot = (Resolve-Path -LiteralPath $pluginRoot -ErrorAction Stop).Path
    } catch {
        [Console]::Error.WriteLine("[aem-init] error: plugin root path does not exist: $pluginRoot")
        exit 3
    }

    $pluginHooksDir = Join-Path $pluginRoot "hooks"
    if (-not (Test-Path -LiteralPath $pluginHooksDir -PathType Container)) {
        [Console]::Error.WriteLine("[aem-init] error: plugin hooks directory not found at $pluginHooksDir")
        exit 3
    }

    # Forward-slash form for cross-OS git compatibility.
    $hooksPathValue = ($pluginRoot -replace '\\', '/') + '/hooks'

    # --- 3. Inspect any existing core.hooksPath -------------------------------
    $existing = git config --get core.hooksPath 2>$null
    # git config --get exits 1 when the key is simply unset -- that is the
    # legitimate "no value" case (no output). A nonzero exit accompanied by
    # actual output (e.g. exit 2 for a multi-valued key) must NOT be collapsed
    # to empty: doing so would normalize to "no conflict" and silently bypass
    # the exit-2 conflict guard, overwriting a real existing value. Only treat
    # as unset when git both failed AND produced no output.
    if ($LASTEXITCODE -ne 0 -and [string]::IsNullOrWhiteSpace(($existing -join ' '))) { $existing = "" }

    # Normalize for comparison: forward slashes, trimmed trailing separator,
    # lower-cased. Tolerates trailing-separator and case differences.
    function Normalize-PathForCompare([string]$p) {
        if ([string]::IsNullOrWhiteSpace($p)) { return "" }
        $n = $p -replace '\\', '/'
        $n = $n.TrimEnd('/')
        return $n.ToLowerInvariant()
    }

    $existingNorm = Normalize-PathForCompare $existing
    $pluginNorm   = Normalize-PathForCompare $hooksPathValue
    $defaultNorm  = Normalize-PathForCompare ".git/hooks"

    $isConflict = ($existingNorm -ne "") -and `
                  ($existingNorm -ne $pluginNorm) -and `
                  ($existingNorm -ne $defaultNorm)

    if ($isConflict -and -not $Force) {
        [Console]::Error.WriteLine("[aem-init] error: core.hooksPath is already set to '$existing'. Re-run with --force to overwrite it with the plugin hooks path.")
        exit 2
    }

    # --- 4. Set core.hooksPath ------------------------------------------------
    git config core.hooksPath $hooksPathValue 2>$null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("[aem-init] error: failed to set core.hooksPath")
        exit 4
    }

    # --- 5. Optional slug scaffolding -----------------------------------------
    $scaffolded = $false
    $slugDir = $null
    if (-not [string]::IsNullOrWhiteSpace($Slug)) {
        $today = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
        $slugDir = Join-Path (Join-Path (Get-Location) "planning") $Slug
        if (-not (Test-Path -LiteralPath $slugDir -PathType Container)) {
            New-Item -ItemType Directory -Path $slugDir -Force | Out-Null
        }

        $planState = @"
## plan-state -- $Slug

Status: **Not started**
Lifecycle stage: Planning - interview not yet begun
Last updated: $today
Latest PRD version: none
Latest spec version: none
Open-PR stack: none
Next action: Run the plan-interviewer to reach 100% understanding before any PRD or spec is written.
Scorecard summary: 0/0 interview fields at 100%

Per-field versioned history lives in plan-ledger.md. This file is overwritten in place; the ledger is append-only.
"@

        $planLedger = @"
## plan-ledger -- $Slug

Append-only. Strike through superseded entries; never delete. Each entry carries an ISO-dated v1.x (YYYY-MM-DD) header.

### Scorecard (v1.0 -- $today)

| Field | Understanding | Notes |
|---|---|---|
| (define interview criteria here) | 0% | placeholder -- replace during the plan interview |
"@

        $utf8 = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $slugDir "plan-state.md"), $planState, $utf8)
        [IO.File]::WriteAllText((Join-Path $slugDir "plan-ledger.md"), $planLedger, $utf8)
        $scaffolded = $true
    }

    # --- 6. Success summary ---------------------------------------------------
    Write-Host "[aem-init] done."
    Write-Host ("  core.hooksPath set to: {0}" -f $hooksPathValue)
    if ($scaffolded) {
        Write-Host ("  scaffolded planning slug: {0}" -f $Slug)
        Write-Host ("    - {0}" -f (Join-Path $slugDir "plan-state.md"))
        Write-Host ("    - {0}" -f (Join-Path $slugDir "plan-ledger.md"))
        Write-Host "  next action: run the plan-interviewer on this slug to reach 100% understanding."
    } else {
        Write-Host "  next action: pass --slug <name> to scaffold a planning slug, or run the plan-interviewer."
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine("[aem-init] internal error: " + $_.Exception.Message)
    exit 4
}
