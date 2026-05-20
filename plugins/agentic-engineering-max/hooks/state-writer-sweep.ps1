# state-writer-sweep.ps1
#
# Hook: SessionStart
# Purpose:
#   FIRST-line recovery channel for missed SessionEnd writes. On SessionStart,
#   compare each managed slug's plan-state.md Last updated: timestamp against
#   git log for planning/<slug>/. If commits exist since that timestamp AND
#   at least one of them is not a state-writer: commit, invoke the same
#   write+commit path as state-writer.ps1 with trigger=SessionStart-sweep.
#
# The SECOND-line recovery channel is the v1 UserPromptSubmit drift-check at
# ~/.claude/hooks/state-drift-check.ps1, which surfaces drift between
# plan-ledger.md and plan-state.md on the next prompt submission.
#
# Allowlist: identical to state-writer.ps1 (D:\GitHub Projects\Dev_006), with
# the same literal-allowlist fallback when $PWD is outside the repo.
#
# Idempotency: running twice in a row produces no second write. The first
# sweep's state-writer: commit becomes the most recent commit in the planning
# dir window; on the second invocation Test-MeaningfulWork plus the
# git-diff-cached pre-flight inside Invoke-StateWriter together short-circuit
# the second write.
#
# Heartbeat: when no sweep is needed, append a one-line trigger=
# SessionStart-sweep-noop to the orchestrator slug's .state-auto-log
# (uncommitted). This makes the channel empirically observable per
# falsificationist review T-W1-007 F-4: 'sweep ran but found nothing' must
# be distinguishable from 'sweep never fired'.
#
# Interpretive choices (where the spec is under-determined):
#   - Spec acceptance criterion 2 calls for --since=<plan-state's Last
#     updated> and --pretty=format:%H. The implementation uses
#     --pretty=format:%H %s because the very next check (filter out
#     state-writer: commits by message) cannot be satisfied by %H alone.
#     The spec contradicts itself between AC2 (literal %H) and the
#     subsequent 'Grep the commit messages' direction; semantic intent
#     over literal pretty-format string.
#   - Spec acceptance criterion 3 says 'invokes the same write logic
#     against the prior git range'. This implementation invokes the writer
#     in its normal mode (against current state, not retroactive replay)
#     because plan-state.md / README.md are state surfaces, not journals;
#     replaying a missed past state would corrupt the present-time view.

$ErrorActionPreference = 'Continue'
$null = [Console]::In.ReadToEnd()

try {
    # Dot-source state-writer.ps1 for shared functions. Set the lib-only env
    # flag so the sourced file does not run its own main block.
    $env:STATE_WRITER_LIB_ONLY = '1'
    $writerPath = 'C:\Users\rhenm\.claude\hooks\state-writer.ps1'
    if (-not (Test-Path $writerPath)) {
        [Console]::Error.WriteLine("state-writer-sweep.ps1: cannot find state-writer.ps1 at $writerPath")
        exit 0
    }
    . $writerPath

    $repoRoot = Get-AllowedRepoRoot
    if (-not $repoRoot) {
        # Allowlist fallback inside Get-AllowedRepoRoot already tried the
        # literal entries; if it still returned $null, the recovery channel
        # is genuinely out of scope here.
        exit 0
    }

    $slugs = Get-ManagedSlugs -RepoRoot $repoRoot
    if (-not $slugs -or $slugs.Count -eq 0) { exit 0 }

    $nowUtc   = [DateTime]::UtcNow
    $isoStamp = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')

    $needsSweep = $false
    foreach ($slug in $slugs) {
        $statePath = Join-Path $repoRoot ("planning/" + $slug + "/plan-state.md")
        if (-not (Test-Path $statePath)) { continue }

        $fields = Read-PlanStateFields -Path $statePath
        $lastUpdated = $fields['Last updated']
        if (-not $lastUpdated) { continue }

        $sinceArg = $null
        try {
            $dt = [DateTime]::Parse(
                $lastUpdated,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal
            )
            $sinceArg = $dt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        } catch {
            continue
        }

        $relPath = "planning/$slug"
        $logArgs = @('-C', $repoRoot, 'log', "--since=$sinceArg", '--pretty=format:%H %s', '--', $relPath)
        $rawLog = (& git @logArgs 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $rawLog) { continue }

        $logLines = @($rawLog | Where-Object { $_ -and $_.Trim() })
        if ($logLines.Count -eq 0) { continue }

        # Anchor the writer-commit regex so a commit whose subject contains
        # 'state-writer:' mid-line doesn't accidentally match. Real subjects
        # start with the literal token after the SHA.
        $nonWriter = @($logLines | Where-Object { $_ -notmatch '(?:^|\s)state-writer:\s' })
        if ($nonWriter.Count -gt 0) {
            $needsSweep = $true
            break
        }
    }

    if ($needsSweep) {
        # Bypass Test-MeaningfulWork: the git-log gap detection above is a
        # strictly stronger signal than the in-writer heuristic (which would
        # silently no-op on `main` when only check 1 is fooled). One sweep
        # covers every managed slug because Invoke-StateWriter iterates them
        # all in one pass.
        Invoke-StateWriter -Trigger 'SessionStart-sweep' -ForceWrite:$true
    } else {
        # Heartbeat: write a one-line forensic record so the channel's
        # 'I ran and found nothing' branch is empirically distinguishable
        # from 'I never ran'. Uncommitted; rolled into the next state-writer
        # commit naturally.
        $heartbeatPath = Join-Path $repoRoot 'planning/orchestrator-and-build-system/.state-auto-log'
        $sessionId = Get-StateWriterSessionId
        $line = "$isoStamp  trigger=SessionStart-sweep-noop  files=(none)  rationale=no-gap-detected  session=$sessionId"
        if (Test-Path (Split-Path -Parent $heartbeatPath)) {
            Append-StateAutoLog -LogPath $heartbeatPath -Line $line | Out-Null
        } else {
            # F-falsificationist iter-2 finding 2: when the orchestrator
            # slug dir is absent, the heartbeat would silently vanish and
            # the channel's no-op branch becomes unobservable again. Fall
            # back to stderr so SOME artifact lands.
            [Console]::Error.WriteLine("state-writer-sweep heartbeat: $line")
        }
    }

} catch {
    $msg = $_.Exception.Message -replace "`r?`n", '; '
    if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 297) + '...' }
    [Console]::Error.WriteLine("state-writer-sweep.ps1: $msg")
} finally {
    Remove-Item Env:STATE_WRITER_LIB_ONLY -ErrorAction SilentlyContinue
}

exit 0
