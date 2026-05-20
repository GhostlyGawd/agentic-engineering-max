# claude-context-inject.ps1
# Hook: SessionStart
#
# (a) SessionStart contract (D-S10 / PRD 7.3):
#     On every session start this hook injects the build-system principle text
#     into the model's context via hookSpecificOutput.additionalContext. It:
#       1. Wraps the whole body in a top-level try/catch. On ANY exception it
#          emits a single diagnostic line "[claude-context-inject] internal
#          error: <msg>" through additionalContext and exits 0 -- it must never
#          block session start.
#       2. Reads ${env:CLAUDE_PLUGIN_ROOT}/docs/CLAUDE-template.md from disk.
#          If the file is missing it emits the internal-error line and exits 0.
#       3. Detects core.hooksPath via "git config --get core.hooksPath" with
#          stderr suppressed to $null (the safe redirection -- the stderr-merge
#          form corrupts native-exe exit handling on Windows PowerShell 5.1, so
#          it is deliberately avoided here).
#       4. Composes additionalContext = verbatim template content, then a blank
#          line, then the nudge string if applicable.
#       5. Emits the JSON envelope to stdout via ConvertTo-Json -Depth 10
#          -Compress, then exits 0.
#
# (b) No-operator-write invariant (PRD invariants 2 + 5):
#     This hook is strictly read-only on the operator's filesystem. It uses no
#     content-writing cmdlets (none of the file-creation / file-overwrite
#     family) against operator paths, never modifies the operator's own
#     principle file, and never creates files. Its only output channel is
#     stdout (the additionalContext JSON envelope).
#
# (c) Nudge condition (D-S10 step 3 / ledger Field 19 LOCKED v1):
#     The /aem-init nudge is appended whenever core.hooksPath is NOT configured
#     to the plugin's hooks dir. Two branches trigger it: (1) core.hooksPath
#     resolves empty -- git not on PATH, not inside a git repo, or the config
#     key is unset; (2) core.hooksPath is any non-empty value that does not
#     match the plugin hooks dir (a foreign hooks setup where build-system
#     enforcement is not wired to the plugin). Only an exact match to the plugin
#     hooks dir (trailing-separator and slash-direction tolerant, case-
#     insensitive) suppresses the nudge.
#
# Output channel: hookSpecificOutput.additionalContext (raw stdout is ignored).
# ASCII discipline: every double-quoted literal in this file is ASCII only.
#   The non-ASCII principle text lives in CLAUDE-template.md and is read as file
#   content, never embedded in a script string literal.

$ErrorActionPreference = 'Continue'

# Drain stdin: SessionStart delivers a JSON event on stdin; leaving it unread
# can wedge the calling process. We do not parse it.
try { $null = [Console]::In.ReadToEnd() } catch { }

$errPrefix = "[claude-context-inject] internal error: "
$nudge = "Run /aem-init to enable build-system enforcement (pre-commit hook for state-mirror discipline)."

function Write-Envelope {
    param([string]$Context)
    $payload = [pscustomobject]@{
        hookSpecificOutput = [pscustomobject]@{
            hookEventName     = 'SessionStart'
            additionalContext = $Context
        }
    }
    $payload | ConvertTo-Json -Depth 10 -Compress
}

try {
    $pluginRoot = $env:CLAUDE_PLUGIN_ROOT
    if ([string]::IsNullOrWhiteSpace($pluginRoot)) {
        Write-Envelope ($errPrefix + "CLAUDE_PLUGIN_ROOT is not set")
        exit 0
    }

    $templatePath = Join-Path $pluginRoot 'docs/CLAUDE-template.md'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        Write-Envelope ($errPrefix + "template not found at " + $templatePath)
        exit 0
    }

    $templateText = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8

    # Detect core.hooksPath. Suppress stderr to $null (never the stderr-merge
    # redirection, which corrupts native-exe exit handling on PS 5.1). If git
    # is not on PATH the call throws; treat any failure as "empty" so the nudge
    # fires.
    $hooksPath = $null
    try {
        $hooksPath = (& git config --get core.hooksPath 2>$null)
        if ($hooksPath -is [array]) { $hooksPath = ($hooksPath -join '').Trim() }
        elseif ($null -ne $hooksPath) { $hooksPath = ([string]$hooksPath).Trim() }
    } catch {
        $hooksPath = $null
    }

    # Normalize a path for tolerant comparison: forward slashes, no trailing
    # separator, lower-cased.
    function Format-PathKey {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
        $p = $Path -replace '\\', '/'
        $p = $p.TrimEnd('/')
        return $p.ToLowerInvariant()
    }

    $pluginHooksKey = Format-PathKey (Join-Path $pluginRoot 'hooks')
    $hooksPathKey   = Format-PathKey $hooksPath

    # Nudge whenever core.hooksPath is NOT configured to the plugin's hooks dir
    # (Field 19 LOCKED v1). This covers two cases the operator-conversion nudge
    # exists for: (1) empty -- git absent / not a repo / key unset; (2) any other
    # non-empty value -- a foreign hooks dir where build-system enforcement is
    # not wired to the plugin. Only an exact (tolerant) match to the plugin hooks
    # dir suppresses the nudge.
    $appendNudge = ($hooksPathKey -ne $pluginHooksKey)

    $composed = $templateText
    if ($appendNudge) {
        $composed = $templateText + "`n`n" + $nudge
    }

    Write-Envelope $composed
    exit 0
} catch {
    $msg = $_.Exception.Message -replace "`r?`n", '; '
    if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 297) + '...' }
    Write-Envelope ($errPrefix + $msg)
    exit 0
}
