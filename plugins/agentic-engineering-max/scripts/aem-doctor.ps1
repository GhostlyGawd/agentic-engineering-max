# aem-doctor.ps1 -- backing script for the /aem-doctor skill, and the tail-call
# health check run by /aem-init after it wires the hooks.
#
# A READ-ONLY routine: it inspects, it never mutates. It runs four checks, each
# printing one plain-English status line and, on failure, one concrete fix line:
#
#   (a) git repo?            -- 'git rev-parse --git-dir' (stderr discarded).
#   (b) PowerShell 7 present -- external 'pwsh --version', parsed for major >= 7.
#   (c) hooks wired?         -- 'git config --get core.hooksPath' compared
#                               (slash/case/trailing-separator-tolerant) to
#                               <plugin-root>/hooks.
#   (d) can scripts run?     -- effective execution policy read via a benign
#                               INLINE child 'pwsh -Command "(Get-ExecutionPolicy)"'.
#                               This probe loads NO script file, so the policy
#                               can be reported even where script files are
#                               blocked. It uses no dynamic-eval cmdlet, no
#                               policy-override flag, and loads no .ps1.
#
# The routine always runs all four checks to completion and prints a final
# one-line summary ("all good" or an N-things-to-fix line).
#
# Exit codes:
#   0  all four checks passed (healthy setup).
#   1  at least one check reported a fixable problem. This is advisory: callers
#      that only care that the check RAN (e.g. /aem-init's tail) ignore it.
#
# Conventions (shared with aem-init.ps1): ASCII-only inside double-quoted
# literals; git invocations send stderr to $null (never the 2>&1 merge form,
# which corrupts $LASTEXITCODE on PS 5.1).

[CmdletBinding()]
param(
    # Plugin install root, passed in by the /aem-doctor skill (which resolves it
    # from ${CLAUDE_PLUGIN_ROOT}). Explicit passing avoids relying on the env
    # var being exported into a child pwsh process. When omitted, falls back to
    # $env:CLAUDE_PLUGIN_ROOT; when neither resolves, check (c) still runs but
    # reports that it could not verify the exact path.
    [string]$PluginRoot
)

# Normalize a path for tolerant comparison: forward slashes, trimmed trailing
# separator, lower-cased. Tolerates slash-direction, case, and trailing-sep
# differences (same shape as aem-init.ps1's comparison).
function Get-NormPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return "" }
    $n = $p -replace '\\', '/'
    $n = $n.TrimEnd('/')
    return $n.ToLowerInvariant()
}

# Collected short issue descriptions (drive the summary line + exit code).
$issues = New-Object System.Collections.Generic.List[string]

Write-Host "[aem-doctor] checking this repo's build-system setup..."

# --- (a) git repository? ------------------------------------------------------
git rev-parse --git-dir 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "[aem-doctor] (a) git repo: OK"
} else {
    Write-Host "[aem-doctor] (a) git repo: NOT a git repository"
    Write-Host "[aem-doctor]     fix: run from your repo root, or 'git init' to start one here."
    $issues.Add("not a git repository")
}

# --- (b) PowerShell 7 present on PATH? ----------------------------------------
# The plugin hooks and scripts run under 'pwsh', so we probe the EXTERNAL pwsh
# on PATH (not just the current process) and assert major version >= 7.
$pwshVer = $null
$pwshMajor = 0
try {
    $verRaw = & pwsh --version 2>$null
    if ($LASTEXITCODE -eq 0 -and $verRaw) {
        $m = [regex]::Match((($verRaw -join ' ')), '(\d+)\.(\d+)\.(\d+)')
        if ($m.Success) {
            $pwshVer = $m.Value
            $pwshMajor = [int]$m.Groups[1].Value
        }
    }
} catch {
    # pwsh not found on PATH: the external invocation throws
    # CommandNotFoundException, landing here. Leave $pwshVer null.
    $pwshVer = $null
}

if ($null -ne $pwshVer -and $pwshMajor -ge 7) {
    Write-Host ("[aem-doctor] (b) PowerShell 7: OK (version {0})" -f $pwshVer)
} else {
    Write-Host "[aem-doctor] (b) PowerShell 7: NOT found on PATH (or below version 7)"
    Write-Host "[aem-doctor]     fix: install PowerShell 7+ and ensure 'pwsh' is on PATH (install hints are in scripts/aem-init.ps1)."
    $issues.Add("PowerShell 7 not found")
}

# --- (c) hooks wired? ---------------------------------------------------------
# Resolve the plugin root (param first, then env). It may be empty in standalone
# use -- that is not fatal; we degrade to a non-strict check.
$root = if (-not [string]::IsNullOrWhiteSpace($PluginRoot)) { $PluginRoot } else { $env:CLAUDE_PLUGIN_ROOT }
$expectedHooksNorm = ""
if (-not [string]::IsNullOrWhiteSpace($root)) {
    $rp = $root
    try { $rp = (Resolve-Path -LiteralPath $root -ErrorAction Stop).Path } catch { $rp = $root }
    $expectedHooksNorm = Get-NormPath (($rp -replace '\\', '/') + '/hooks')
}

$hooksPath = git config --get core.hooksPath 2>$null
$hooksNorm = Get-NormPath $hooksPath
$hooksSet = -not [string]::IsNullOrWhiteSpace($hooksPath)
$defaultNorm = Get-NormPath ".git/hooks"

if ($hooksSet -and $expectedHooksNorm -ne "" -and $hooksNorm -eq $expectedHooksNorm) {
    Write-Host "[aem-doctor] (c) hooks wired: OK"
} elseif ($hooksSet -and $expectedHooksNorm -eq "" -and $hooksNorm -ne $defaultNorm) {
    # Plugin root unknown (standalone run): core.hooksPath is set to a
    # non-default value but we cannot confirm it points at THIS plugin.
    Write-Host ("[aem-doctor] (c) hooks wired: set to '{0}' (plugin root unknown -- not verified)" -f $hooksPath)
} else {
    Write-Host "[aem-doctor] (c) hooks wired: NO (core.hooksPath does not point at the plugin hooks)"
    Write-Host "[aem-doctor]     fix: run /aem-init in this repo to wire core.hooksPath."
    $issues.Add("hooks not wired (run /aem-init)")
}

# --- (d) can scripts run here? ------------------------------------------------
# Read the effective execution policy via a benign INLINE child pwsh. Using
# -Command (an inline expression) rather than -File means this probe loads no
# script file, so it returns a value even on a box where running .ps1 files is
# blocked. Never use a dynamic-eval cmdlet or a policy-override flag here.
$policy = $null
try {
    $polRaw = & pwsh -NoProfile -Command "(Get-ExecutionPolicy)" 2>$null
    if ($LASTEXITCODE -eq 0 -and $polRaw) { $policy = ($polRaw -join '').Trim() }
} catch {
    $policy = $null
}

# Policies that block running local scripts. RemoteSigned / Unrestricted /
# Bypass do not block local scripts; Undefined resolves to a default elsewhere.
$blockingPolicies = @('Restricted', 'AllSigned')

if ($null -eq $policy -or $policy -eq "") {
    # Could not read the policy (typically because pwsh is missing -- already
    # surfaced by check (b)). Report it but do not double-count as an issue and
    # do not emit a second fix command.
    Write-Host "[aem-doctor] (d) script execution: could not read the execution policy (is pwsh installed? see check b)"
} elseif ($blockingPolicies -contains $policy) {
    Write-Host ("[aem-doctor] (d) script execution: BLOCKED -- the current execution policy ({0}) prevents scripts from running." -f $policy)
    Write-Host "[aem-doctor]     fix: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned   (or ask your IT admin if policy is locked down)."
    $issues.Add("scripts blocked by execution policy")
} else {
    Write-Host ("[aem-doctor] (d) script execution: OK (policy: {0})" -f $policy)
}

# --- summary ------------------------------------------------------------------
if ($issues.Count -eq 0) {
    Write-Host "[aem-doctor] all good -- this repo is set up correctly."
    exit 0
} elseif ($issues.Count -eq 1) {
    Write-Host ("[aem-doctor] one thing to fix: {0}." -f $issues[0])
    exit 1
} else {
    Write-Host ("[aem-doctor] {0} things to fix: {1}." -f $issues.Count, ($issues -join "; "))
    exit 1
}
