# bin/gate-apply.ps1
#
# Purpose:
#   The ONE atomic gate-state mutator (spec D-S9). Exposes
#   Invoke-GateDecision -Slug -TaskId -Decision <approve|decline|retry>
#   [-Notes] [-DeciderId], the single code path that mutates gate state, used
#   by BOTH the web server (D-S10) and any CLI/test caller. The same helper
#   works from a CLI with the server dead -- so the web app is never load-
#   bearing.
#
# Transition table (D-S2), locked:
#   approve + gate_action == promote          -> status: open,  gate_state: approved
#   approve + gate_action == spawn-next-stage -> status: done,  gate_state: approved
#                                                + create the downstream spec-writer
#                                                  task (D-S8) depends_on the held task
#   decline                                   -> status: closed, gate_state: declined
#   retry                                     -> status: needs_fixing (gate_state left
#                                                  at pending) + a `## Gate thread` ->
#                                                  `### Gate retry <N>` body append (D-S7)
#   A wake-sentinel (D-S4) is dropped on approve and retry (not required on decline).
#
# Atomic-write discipline (mirrors the reviewer SKILL Step 9):
#   build the full new file IN MEMORY -> in-memory parse-check via the T-101
#   reader (Read-ControlPlaneFrontmatter) over a system-temp probe file ->
#   [IO.File]::WriteAllBytes to an adjacent .tmp -> Move-Item-with-retry over
#   the target. On a parse-fail the function aborts with the target file
#   byte-unchanged and NO adjacent .tmp litter (the adjacent .tmp is created
#   only AFTER the parse-check passes; the probe lives in the system temp dir).
#
# It NEVER edits task-board.md (the controller regenerates that, D-S6).
#
# Decisions: D-S2 (state machine), D-S4 (wake-sentinel drop), D-S7 (gate
# thread), D-S8 (downstream spawn), D-S9 (single atomic mutator).
#
# Dot-sourceable (defines Invoke-GateDecision + helpers) AND directly invokable:
#   gate-apply.ps1 -Slug <s> -TaskId <T-NNN> -Decision <approve|decline|retry>
#                  [-Notes "..."] [-DeciderId <id>]
#
# Cross-task invariants honored:
#   - ASCII-only inside "..." literals.
#   - No 2>&1 on native exes (pure PS file ops; no native exes invoked).
#   - Paths built with Join-Path / forward slashes (no literal backslash).
#   - UTF-8 (no BOM) for every file write.

param(
    [Parameter()]
    [string]$Slug,

    [Parameter()]
    [string]$TaskId,

    [Parameter()]
    [ValidateSet('approve', 'decline', 'retry')]
    [string]$Decision,

    [Parameter()]
    [string]$Notes = '',

    [Parameter()]
    [string]$DeciderId = 'user'
)

$ErrorActionPreference = 'Stop'

# Snapshot our bound CLI parameters BEFORE dot-sourcing the helpers below. Both
# gate-schema.ps1 and wake-sentinel.ps1 declare a `-Slug` param; dot-sourcing
# them runs their param() blocks in THIS scope with no arguments, which would
# reset $Slug to '' and clobber the value bound to us. The direct-invocation
# block at the bottom reads these snapshots, not the (now-clobbered) params.
$cliSlug      = $Slug
$cliTaskId    = $TaskId
$cliDecision  = $Decision
$cliNotes     = $Notes
$cliDeciderId = $DeciderId

# Dot-source the shared schema reader (T-101) and the wake-sentinel primitive
# (T-102) so this mutator reuses the SAME parser + sentinel idiom every other
# control-plane actor uses. $PSScriptRoot is bin/ whether we are invoked via
# -File or dot-sourced, so the siblings resolve either way. Their direct-
# invocation blocks are gated on InvocationName -ne '.', so dot-sourcing here
# only defines their functions.
. (Join-Path $PSScriptRoot 'gate-schema.ps1')
. (Join-Path $PSScriptRoot 'wake-sentinel.ps1')

function Find-GateApplyRepoRoot {
    # Walk up from the current location looking for a repo marker. CWD-first
    # (not $PSScriptRoot-first) so a dot-sourcing test operating in a temp repo
    # resolves to THAT repo, not the real bin/.. the script lives in. Same
    # pattern as gate-schema.ps1 / wake-sentinel.ps1.
    $cur = (Get-Location).Path
    while ($cur -and $cur.Length -gt 3) {
        if ((Test-Path (Join-Path $cur '.git')) -or (Test-Path (Join-Path $cur 'planning'))) {
            return $cur
        }
        $parent = Split-Path $cur -Parent
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    $scriptDir = Split-Path -Parent $PSCommandPath
    $candidate = Split-Path -Parent $scriptDir
    if ($candidate -and (Test-Path (Join-Path $candidate 'planning'))) { return $candidate }
    return $null
}

# Resolve a slug's tasks directory under a repo root. Returns $null when absent.
function Get-GateTasksDir {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Slug)
    $d = Join-Path $RepoRoot (Join-Path 'planning' (Join-Path $Slug 'tasks'))
    if (Test-Path $d) { return $d }
    return $null
}

# Locate the on-disk task file whose frontmatter `id` equals $TaskId. Returns
# the full path or $null. Matches on the parsed `id` (T-NNN), NOT the filename
# stem, because the two intentionally differ across the build.
function Find-GateTaskFile {
    param(
        [Parameter(Mandatory)][string]$TasksDir,
        [Parameter(Mandatory)][string]$TaskId
    )
    foreach ($tf in @(Get-ChildItem -Path $TasksDir -Filter 'task-*.md' -File -ErrorAction SilentlyContinue)) {
        $fm = Read-ControlPlaneFrontmatter -Path $tf.FullName
        if ($fm -and $fm.id -eq $TaskId) { return $tf.FullName }
    }
    return $null
}

# Detect the newline convention of a raw file body so a rewrite preserves it
# (minimal diff). CRLF if any CRLF present, else LF.
function Get-NewlineStyle {
    param([string]$Raw)
    if ($Raw -match "`r`n") { return "`r`n" }
    return "`n"
}

# Split a raw task file into its frontmatter line array and body line array.
# Returns $null when there is no parseable `---` ... `---` fence pair.
function Split-TaskFile {
    param([Parameter(Mandatory)][string]$Raw)
    $lines = $Raw -split "`r?`n"
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') { return $null }
    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') { $end = $i; break }
    }
    if ($end -lt 0) { return $null }
    $fm = @($lines[1..($end - 1)])
    $body = @()
    if ($end -lt ($lines.Count - 1)) { $body = @($lines[($end + 1)..($lines.Count - 1)]) }
    return [pscustomobject]@{ Frontmatter = $fm; Body = $body }
}

# Set (or append) a flat `key: value` line in a frontmatter line array. Matches
# the exact key followed by a colon so `status` never collides with a longer
# key. Returns the mutated array.
function Set-FrontmatterValue {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Frontmatter,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    $pattern = '^' + [regex]::Escape($Key) + '\s*:'
    $found = $false
    $out = foreach ($line in $Frontmatter) {
        if ($line -match $pattern) {
            $found = $true
            ('{0}: {1}' -f $Key, $Value)
        } else {
            $line
        }
    }
    $out = @($out)
    if (-not $found) { $out += ('{0}: {1}' -f $Key, $Value) }
    return $out
}

# In-memory parse-check of composed content via the T-101 reader, BEFORE any
# adjacent .tmp is written. Writes to a system-temp probe (never the task dir),
# parses it, deletes it. Returns the parsed frontmatter object, or $null when
# the content does not parse. Because the probe is in the system temp dir, a
# parse-fail leaves the task directory free of any .tmp litter.
function Test-ComposedContent {
    param([Parameter(Mandatory)][string]$Content)
    $probe = Join-Path ([IO.Path]::GetTempPath()) ('gate-apply-probe-{0}.md' -f ([guid]::NewGuid().ToString('N')))
    try {
        [IO.File]::WriteAllBytes($probe, [Text.UTF8Encoding]::new($false).GetBytes($Content))
        return Read-ControlPlaneFrontmatter -Path $probe
    } finally {
        Remove-Item -Path $probe -Force -ErrorAction SilentlyContinue
    }
}

# Atomic save: parse-check (in memory) -> WriteAllBytes to adjacent .tmp ->
# Move-Item-with-retry over the target. Aborts (throws) with the target byte-
# unchanged and no adjacent .tmp litter on a parse-fail. The optional
# -ExpectStatus asserts the composed frontmatter carries the intended status
# (guards against a botched compose). -ForceParseFailForTest is a test seam
# (also honored via $env:GATE_APPLY_FORCE_PARSEFAIL) that corrupts the content
# so the in-memory parse-check fails -- exercising the byte-unchanged guarantee.
function Save-GateFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [string]$ExpectStatus,
        [switch]$ForceParseFailForTest
    )

    $check = $Content
    if ($ForceParseFailForTest -or ($env:GATE_APPLY_FORCE_PARSEFAIL -eq '1')) {
        # Prepend junk so the reader's `$lines[0] -ne '---'` guard rejects it.
        $check = 'PARSEFAIL' + [Environment]::NewLine + $Content
    }

    $parsed = Test-ComposedContent -Content $check
    if (-not $parsed) {
        throw "gate-apply: in-memory parse-check failed for $Path; aborting (file byte-unchanged)."
    }
    if ($ExpectStatus -and ($parsed.status -ne $ExpectStatus)) {
        throw ("gate-apply: composed status '{0}' != expected '{1}' for {2}; aborting." -f $parsed.status, $ExpectStatus, $Path)
    }

    $tmp = "$Path.tmp"
    [IO.File]::WriteAllBytes($tmp, [Text.UTF8Encoding]::new($false).GetBytes($Content))

    $moved = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Move-Item -Path $tmp -Destination $Path -Force
            $moved = $true
            break
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 200
        }
    }
    if (-not $moved) {
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
        throw "gate-apply: Move-Item failed after 3 attempts for $Path; aborting (no .tmp litter)."
    }
}

# Append a `### Gate retry <N>` entry to the task body under a `## Gate thread`
# section (created on first append), mirroring the reviewer's append-only
# `## Review iteration <N>` style (D-S7). <N> = prior retry count + 1.
function Add-GateRetryEntry {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Body,
        [Parameter(Mandatory)][string]$Newline,
        [Parameter(Mandatory)][string]$DeciderId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Notes
    )
    $bodyText = ($Body -join $Newline)
    $priorRetries = ([regex]::Matches($bodyText, '(?m)^###\s+Gate retry\s+\d+')).Count
    $n = $priorRetries + 1
    $iso = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

    $entry = ('### Gate retry {0} -- {1}' -f $n, $iso) + $Newline +
             ('**Decider:** {0}' -f $DeciderId) + $Newline +
             '**Decision:** retry' + $Newline +
             $Notes

    $trimmed = $bodyText.TrimEnd()
    if ($bodyText -match '(?m)^##\s+Gate thread\s*$') {
        $newBody = $trimmed + $Newline + $Newline + $entry + $Newline
    } else {
        $newBody = $trimmed + $Newline + $Newline + '## Gate thread' + $Newline + $Newline + $entry + $Newline
    }
    return $newBody
}

# Create the downstream spec-writer task (D-S8 spawn-next-stage). Its deliverable
# is "run the spec-writer for <slug>" (produce planning/<slug>/spec.md) and it
# depends_on the approved held task. Returns the created file path.
function New-DownstreamSpecTask {
    param(
        [Parameter(Mandatory)][string]$TasksDir,
        [Parameter(Mandatory)][string]$HeldFilePath,
        [Parameter(Mandatory)][string]$HeldId,
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$Newline
    )
    $heldStem = [IO.Path]::GetFileNameWithoutExtension($HeldFilePath)  # e.g. task-foo
    $baseStem = "$heldStem-spec"
    $targetPath = Join-Path $TasksDir ("{0}.md" -f $baseStem)
    $suffix = 1
    while (Test-Path $targetPath) {
        $suffix++
        $targetPath = Join-Path $TasksDir ("{0}-{1}.md" -f $baseStem, $suffix)
    }
    $downstreamId = "$HeldId-SPEC"

    $fm = @(
        '---'
        "id: $downstreamId"
        "title: Run the spec-writer for $Slug"
        'status: open'
        'owner:'
        'claimed_at:'
        'review_iterations: 0'
        "depends_on: [$HeldId]"
        'unresolved_findings: []'
        'kind: task'
        'type: code'
        'wave:'
        'source: gate-spawn'
        '---'
    )
    $body = @(
        ''
        "# $downstreamId -- Run the spec-writer for $Slug"
        ''
        '## Goal'
        "Run the spec-writer for ``$Slug`` to produce its implementation spec, building on the approved design task $HeldId."
        ''
        '## Deliverables'
        "- ``planning/$Slug/spec.md``"
        ''
        '## Dependencies'
        "- depends_on: $HeldId (the approved design task)"
        ''
        '## Notes'
        "Spawned by the gate mutator (D-S8 spawn-next-stage) on approval of $HeldId."
        ''
    )
    $content = ($fm + $body) -join $Newline
    Save-GateFile -Path $targetPath -Content $content -ExpectStatus 'open'
    return $targetPath
}

# THE single gate mutator. Applies the D-S2 transition for $Decision over the
# task identified by $TaskId in $Slug, atomically. Returns a pscustomobject
# summary: { TaskId, Status, GateState, Decision, DownstreamTask, WakeSentinel }.
function Invoke-GateDecision {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][ValidateSet('approve', 'decline', 'retry')][string]$Decision,
        [string]$Notes = '',
        [string]$DeciderId = 'user',
        [switch]$ForceParseFailForTest
    )

    $repoRoot = Find-GateApplyRepoRoot
    if (-not $repoRoot) { throw "gate-apply: could not locate repo root (no .git/planning in cwd ancestors)." }

    $tasksDir = Get-GateTasksDir -RepoRoot $repoRoot -Slug $Slug
    if (-not $tasksDir) { throw "gate-apply: no tasks dir for slug '$Slug' under $repoRoot." }

    $taskPath = Find-GateTaskFile -TasksDir $tasksDir -TaskId $TaskId
    if (-not $taskPath) { throw "gate-apply: no task with id '$TaskId' in $tasksDir." }

    $fmObj = Read-ControlPlaneFrontmatter -Path $taskPath
    if (-not $fmObj) { throw "gate-apply: task $TaskId did not parse; aborting." }

    $raw = [IO.File]::ReadAllText($taskPath)
    $nl = Get-NewlineStyle -Raw $raw
    $split = Split-TaskFile -Raw $raw
    if (-not $split) { throw "gate-apply: task $TaskId has no frontmatter fence; aborting." }
    $fmLines = $split.Frontmatter
    $bodyLines = $split.Body

    $downstreamTask = $null
    $expectStatus = $null

    switch ($Decision) {
        'approve' {
            $action = $fmObj.gate_action
            if ($action -ne 'promote' -and $action -ne 'spawn-next-stage') {
                throw "gate-apply: approve requires gate_action 'promote' or 'spawn-next-stage' on $TaskId; got '$action'."
            }
            $fmLines = Set-FrontmatterValue -Frontmatter $fmLines -Key 'gate_state' -Value 'approved'
            if ($action -eq 'promote') {
                $fmLines = Set-FrontmatterValue -Frontmatter $fmLines -Key 'status' -Value 'open'
                $expectStatus = 'open'
            } else {
                # spawn-next-stage: held task done + downstream spec task created.
                $fmLines = Set-FrontmatterValue -Frontmatter $fmLines -Key 'status' -Value 'done'
                $expectStatus = 'done'
            }
        }
        'decline' {
            $fmLines = Set-FrontmatterValue -Frontmatter $fmLines -Key 'gate_state' -Value 'declined'
            $fmLines = Set-FrontmatterValue -Frontmatter $fmLines -Key 'status' -Value 'closed'
            $expectStatus = 'closed'
        }
        'retry' {
            # status -> needs_fixing; gate_state left at pending (untouched).
            $fmLines = Set-FrontmatterValue -Frontmatter $fmLines -Key 'status' -Value 'needs_fixing'
            $expectStatus = 'needs_fixing'
            $newBodyText = Add-GateRetryEntry -Body $bodyLines -Newline $nl -DeciderId $DeciderId -Notes $Notes
            $bodyLines = $newBodyText -split "`r?`n"
        }
    }

    $content = (@('---') + $fmLines + @('---') + $bodyLines) -join $nl

    # Atomic write of the held task. On approve+spawn-next-stage, create the
    # downstream task FIRST so a failure there leaves the held task unchanged
    # (no half-applied transition with a missing downstream).
    if ($Decision -eq 'approve' -and $fmObj.gate_action -eq 'spawn-next-stage') {
        $downstreamTask = New-DownstreamSpecTask -TasksDir $tasksDir -HeldFilePath $taskPath -HeldId $TaskId -Slug $Slug -Newline $nl
    }

    Save-GateFile -Path $taskPath -Content $content -ExpectStatus $expectStatus -ForceParseFailForTest:$ForceParseFailForTest

    # Drop a wake-sentinel on approve / retry (D-S4). Not required on decline.
    $wake = $null
    if ($Decision -eq 'approve' -or $Decision -eq 'retry') {
        $wake = New-WakeSentinel -Slug $Slug
    }

    # Re-read to report the on-disk truth.
    $final = Read-ControlPlaneFrontmatter -Path $taskPath

    return [pscustomobject]@{
        TaskId         = $TaskId
        Status         = $final.status
        GateState      = $final.gate_state
        Decision       = $Decision
        DownstreamTask = $downstreamTask
        WakeSentinel   = $wake
    }
}

# Direct invocation: drive Invoke-GateDecision from CLI args and print a one-line
# summary. Dot-sourcing (InvocationName '.') defines the functions only.
if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($cliSlug) -or [string]::IsNullOrWhiteSpace($cliTaskId) -or [string]::IsNullOrWhiteSpace($cliDecision)) {
        [Console]::Error.WriteLine('gate-apply.ps1: usage: gate-apply.ps1 -Slug <s> -TaskId <T-NNN> -Decision <approve|decline|retry> [-Notes "..."] [-DeciderId <id>]')
        exit 1
    }
    try {
        $r = Invoke-GateDecision -Slug $cliSlug -TaskId $cliTaskId -Decision $cliDecision -Notes $cliNotes -DeciderId $cliDeciderId
        $down = if ($r.DownstreamTask) { $r.DownstreamTask } else { '(none)' }
        Write-Output ("gate {0}: {1} -> status={2} gate_state={3} downstream={4}" -f $r.Decision, $r.TaskId, $r.Status, $r.GateState, $down)
        exit 0
    } catch {
        [Console]::Error.WriteLine("gate-apply.ps1: $($_.Exception.Message)")
        exit 1
    }
}
