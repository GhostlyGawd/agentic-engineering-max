# bin/triage-intake.ps1
#
# Purpose:
#   The deterministic, ZERO-LLM triage step (spec D-S5). On each controller wake
#   it folds the unprocessed tail of planning/<slug>/backlog/intake.jsonl into
#   the board: dedup live matches into a `## Triage notes` body line, materialize
#   done-matches as gated recurrences, materialize no-match findings per the
#   D-S12 promotion policy, advance the backlog/intake.processed high-water mark,
#   and drop a wake-sentinel (T-102) for any materialized proposed/open task.
#
#   The algorithm is a PURE FORWARD SCAN keyed on the high-water mark, so the
#   intake log stays strictly append-only (cross-task invariant 13) and a re-run
#   with the mark advanced materializes nothing new (idempotency).
#
# Decisions:
#   D-S5  (intake record schema + SHA256-16hex dedup_key + idempotent triage)
#   D-S12 (per-kind promotion policy + two NON-OVERRIDABLE code guards:
#          cross-slug findings and recurrences are ALWAYS user-gated -- the
#          HARD INVARIANT, PRD 8.1 / cross-task invariant 9)
#
# dedup_key (D-S5):
#   SHA256( target_slug + " " + target + " " + symbol + " " + kind ), rendered
#   lowercase hex, truncated to the first 16 hex chars. Three single-space
#   delimiters between the four fields (spec v1.0.1 correction).
#
# Triage branches per finding:
#   live match  (dedup_key hits a task in proposed|open|in_progress|in_review|
#                needs_fixing|escalated|awaiting_user_approval)
#                -> append a `## Triage notes` cross-reference line; NO new task.
#   done match  (dedup_key hits a done|closed task)
#                -> materialize a `proposed` task with recurrence_of: T-NNN,
#                   gate_decider: user, gate_action: promote (FORCED user-gate,
#                   overrides policy -- the recurrence guard).
#   no match    -> materialize a task per the promotion policy:
#                   auto => gate_decider auto-policy + status open (+gate approved)
#                   user => gate_decider user      + status proposed (+pending)
#                  then the cross-slug guard overrides to user/proposed last.
#
# Both the helper functions are dot-sourceable AND the script is directly
# invokable: `triage-intake.ps1 <slug> [controller-id]` runs one triage pass and
# prints `triage: processed=<n> materialized=<m> deduped=<d> recurrence=<r>`.
#
# Cross-task invariants honored:
#   - ASCII-only inside "..." literals (em-dash/arrows only in comments).
#   - No 2>&1 on native exes (pure PS file ops; no native exes invoked).
#   - Paths built with Join-Path / forward slashes (no literal backslash).
#   - UTF-8 (no BOM) for every write; intake.jsonl is never rewritten.
#   - Reuses the wake-sentinel CreateNew primitive (T-102); no new lock type.

param(
    [Parameter(Position = 0)]
    [string]$Slug,

    [Parameter(Position = 1)]
    [string]$ControllerId = 'controller'
)

$ErrorActionPreference = 'Stop'

# Capture the CLI args BEFORE dot-sourcing the dependency scripts: gate-schema.ps1
# and wake-sentinel.ps1 both declare `param($Slug ...)` / `param(... $ControllerId)`,
# and dot-sourcing them runs those param blocks in THIS scope -- which would reset
# our $Slug/$ControllerId to their (empty/default) values. We use the captured
# copies in the direct-invoke block and pass slugs explicitly into every function.
$script:CliSlug         = $Slug
$script:CliControllerId = $ControllerId

. (Join-Path $PSScriptRoot 'gate-schema.ps1')
. (Join-Path $PSScriptRoot 'wake-sentinel.ps1')

# Live (dedup-eligible) and terminal (recurrence-eligible) status sets, D-S5.
$script:TriageLiveStatuses = @(
    'proposed', 'open', 'in_progress', 'in_review',
    'needs_fixing', 'escalated', 'awaiting_user_approval'
)
$script:TriageDoneStatuses = @('done', 'closed')

function Find-TriageRepoRoot {
    # Walk up from the current location looking for a repo marker. CWD-first
    # (not $PSScriptRoot-first) so a dot-sourcing test operating in a temp repo
    # resolves to THAT repo, not the real bin/.. the script lives in. Same
    # pattern as claimable-width.ps1 / wake-sentinel.ps1.
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

# The D-S5 dedup_key. Deterministic SHA256 over the four fields joined by single
# spaces, lowercase hex, first 16 chars. Identical inputs always yield the same
# key, so reviewer-emitted keys (T-204) and triage-computed keys agree.
function Get-DedupKey {
    param(
        [string]$TargetSlug,
        [string]$Target,
        [string]$Symbol,
        [string]$Kind
    )
    $material = $TargetSlug + ' ' + $Target + ' ' + $Symbol + ' ' + $Kind
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($material)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
    return $hex.Substring(0, 16)
}

# Read the per-kind promotion policy from .build-config.json (D-S12). Defaults to
# the conservative shipped policy on any miss: bug auto, feature/process user.
function Get-TriagePromotionPolicy {
    param([string]$PlanningDir)
    $policy = @{ bug = 'auto'; feature = 'user'; process = 'user' }
    $cfg = Join-Path $PlanningDir '.build-config.json'
    if (Test-Path $cfg) {
        try {
            $obj = Get-Content -Raw -Encoding utf8 $cfg | ConvertFrom-Json
            if ($obj.PSObject.Properties.Name -contains 'promotion_policy' -and $obj.promotion_policy) {
                foreach ($k in @('bug', 'feature', 'process')) {
                    $prop = $obj.promotion_policy.PSObject.Properties[$k]
                    if ($prop -and $prop.Value) { $policy[$k] = ([string]$prop.Value).ToLowerInvariant() }
                }
            }
        } catch { }
    }
    return $policy
}

# Resolve the gate fields for a no-match / done-match finding. The two code
# guards (recurrence and cross-slug) WIN over the configured policy -- this is
# where the HARD INVARIANT is enforced un-misconfigurably (D-S12).
function Resolve-TriageGate {
    param(
        [string]$Kind,
        [bool]$IsCrossSlug,
        [bool]$IsRecurrence,
        [hashtable]$Policy
    )
    if ($IsRecurrence -or $IsCrossSlug) {
        return @{ decider = 'user'; status = 'proposed'; gate_state = 'pending' }
    }
    $p = 'user'
    if ($Policy.ContainsKey($Kind)) { $p = $Policy[$Kind] }
    if ($p -eq 'auto') {
        return @{ decider = 'auto-policy'; status = 'open'; gate_state = 'approved' }
    }
    return @{ decider = 'user'; status = 'proposed'; gate_state = 'pending' }
}

# Derive a task id (T-NNN) from a parsed frontmatter record, falling back to the
# filename stem when the id field is blank (matching build-board's derivation).
function Get-TriageTaskId {
    param([pscustomobject]$Fm, [string]$TaskFile)
    if ($Fm -and -not [string]::IsNullOrWhiteSpace($Fm.id)) { return $Fm.id }
    $stem = [IO.Path]::GetFileNameWithoutExtension($TaskFile)
    if ($stem -match '^task-(W\d+-\d+|\d+)$') { return 'T-' + $matches[1] }
    return $stem
}

# Scan a slug's board for the first task whose dedup_key matches. Live matches
# take precedence over done matches (D-S5 step order). Returns a hashtable
# { Type = 'live'|'done'|'none'; Id; File } -- ids/files blank when 'none'.
function Find-DedupMatch {
    param(
        [string]$RepoRoot,
        [string]$Slug,
        [string]$Key
    )
    $result = @{ Type = 'none'; Id = ''; File = '' }
    $tasksDir = Join-Path $RepoRoot (Join-Path 'planning' (Join-Path $Slug 'tasks'))
    if (-not (Test-Path $tasksDir)) { return $result }

    $doneHit = $null
    foreach ($tf in @(Get-ChildItem -Path $tasksDir -Filter 'task-*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $fm = Read-ControlPlaneFrontmatter -Path $tf.FullName
        if (-not $fm) { continue }
        if ([string]::IsNullOrWhiteSpace($fm.dedup_key)) { continue }
        if ($fm.dedup_key -ne $Key) { continue }
        if ($script:TriageLiveStatuses -contains $fm.status) {
            return @{ Type = 'live'; Id = (Get-TriageTaskId -Fm $fm -TaskFile $tf.FullName); File = $tf.FullName }
        }
        if (($script:TriageDoneStatuses -contains $fm.status) -and (-not $doneHit)) {
            $doneHit = @{ Type = 'done'; Id = (Get-TriageTaskId -Fm $fm -TaskFile $tf.FullName); File = $tf.FullName }
        }
    }
    if ($doneHit) { return $doneHit }
    return $result
}

# Allocate the next numeric task stem (NNN) for a slug, scanning task-NNN.md
# files once. The caller increments the returned value for each subsequent
# materialization within a run so freshly-written files do not collide.
function Get-NextTaskStem {
    param([string]$TasksDir)
    $max = 0
    foreach ($f in @(Get-ChildItem -Path $TasksDir -Filter 'task-*.md' -File -ErrorAction SilentlyContinue)) {
        if ($f.BaseName -match '^task-(\d+)$') {
            $n = [int]$matches[1]
            if ($n -gt $max) { $max = $n }
        }
    }
    return ($max + 1)
}

# Single-line title from a finding's text: collapse whitespace, truncate to 72.
function Get-TriageTitle {
    param([string]$Text)
    $t = ($Text -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return 'untitled finding' }
    if ($t.Length -gt 72) { $t = $t.Substring(0, 72).TrimEnd() }
    return $t
}

# Append a `## Triage notes` cross-reference bullet to an existing task body
# (the live-match fold). Atomic in-memory build then temp-file Move-Item.
function Add-TriageNote {
    param(
        [string]$TaskFile,
        [string]$Note
    )
    $raw = Get-Content -Raw -Encoding utf8 -Path $TaskFile
    $lines = $raw -split "`r?`n"
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $lines) { $list.Add($l) }

    $idx = -1
    for ($i = 0; $i -lt $list.Count; $i++) {
        if ($list[$i].Trim() -eq '## Triage notes') { $idx = $i; break }
    }

    if ($idx -ge 0) {
        # Insert after the last non-blank line of the existing section (before the
        # next `## ` heading or EOF).
        $end = $list.Count
        for ($j = $idx + 1; $j -lt $list.Count; $j++) {
            if ($list[$j] -match '^##\s') { $end = $j; break }
        }
        $ins = $end
        while ($ins -gt ($idx + 1) -and [string]::IsNullOrWhiteSpace($list[$ins - 1])) { $ins-- }
        $list.Insert($ins, $Note)
    } else {
        if ($list.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($list[$list.Count - 1])) { $list.Add('') }
        $list.Add('## Triage notes')
        $list.Add($Note)
    }

    $newText = ($list -join "`n")
    if (-not $newText.EndsWith("`n")) { $newText += "`n" }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($newText)
    $tmp = "$TaskFile.tmp"
    [IO.File]::WriteAllBytes($tmp, $bytes)
    Move-Item -Force -LiteralPath $tmp -Destination $TaskFile
}

# Materialize a new task file from a finding. Returns the task id (T-NNN).
function New-MaterializedTask {
    param(
        [string]$TasksDir,
        [int]$Stem,
        [string]$Status,
        [string]$Decider,
        [string]$GateState,
        [string]$Key,
        [string]$Source,
        [string]$RecurrenceOf,
        [string]$FindingKind,
        [string]$TargetSlug,
        [string]$Text,
        [string]$Ts
    )
    if (-not (Test-Path $TasksDir)) { New-Item -ItemType Directory -Path $TasksDir -Force | Out-Null }
    $stemStr = '{0:D3}' -f $Stem
    $taskId = 'T-' + $stemStr
    $title = Get-TriageTitle -Text $Text
    $taskFile = Join-Path $TasksDir ("task-" + $stemStr + ".md")

    # Body description: the finding text verbatim (single paragraph) + provenance.
    $bodyText = ($Text -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($bodyText)) { $bodyText = '(no finding text)' }

    $content = @"
---
id: $taskId
title: $title
status: $Status
owner:
claimed_at:
review_iterations: 0
depends_on: []
unresolved_findings: []
type: code
wave:
kind: task
parent:
gate_decider: $Decider
gate_action: promote
gate_state: $GateState
dedup_key: $Key
source: $Source
recurrence_of: $RecurrenceOf
---

# $taskId -- $title

$bodyText

## Triage notes
- materialized from $Source (kind: $FindingKind, target_slug: $TargetSlug) at $Ts
"@
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($content)
    [IO.File]::WriteAllBytes($taskFile, $bytes)
    return $taskId
}

# Coalesce a possibly-absent JSON property to a trimmed string.
function Get-IntakeField {
    param($Record, [string]$Name)
    $prop = $Record.PSObject.Properties[$Name]
    if ($prop -and $null -ne $prop.Value) { return ([string]$prop.Value).Trim() }
    return ''
}

# One full triage pass over planning/<Slug>/backlog/intake.jsonl. Returns a
# summary object with the per-branch counts and the list of created task ids.
function Invoke-TriageIntake {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [string]$ControllerId = 'controller'
    )

    $summary = [pscustomobject]@{
        Slug         = $Slug
        Processed    = 0
        Materialized = 0
        Deduped      = 0
        Recurrence   = 0
        CreatedIds   = @()
    }

    $repoRoot = Find-TriageRepoRoot
    if (-not $repoRoot) { return $summary }

    $planningDir = Join-Path $repoRoot (Join-Path 'planning' $Slug)
    $backlogDir = Join-Path $planningDir 'backlog'
    $intakePath = Join-Path $backlogDir 'intake.jsonl'
    $processedPath = Join-Path $backlogDir 'intake.processed'

    if (-not (Test-Path $intakePath)) { return $summary }

    $allLines = @(Get-Content -Path $intakePath -Encoding utf8)
    $total = $allLines.Count

    # High-water mark = count of already-consumed lines (default 0). Clamp to the
    # current total so a truncated/rolled file never throws (append-only, but be
    # defensive against a manual edit).
    $hwm = 0
    if (Test-Path $processedPath) {
        $rawHwm = (Get-Content -Raw -Encoding utf8 $processedPath).Trim()
        if ($rawHwm -match '^\d+$') { $hwm = [int]$rawHwm }
    }
    if ($hwm -gt $total) { $hwm = $total }

    # Per-target-slug next-stem counters, lazily initialized by scanning each
    # target slug's tasks dir once.
    $nextStem = @{}
    $policy = Get-TriagePromotionPolicy -PlanningDir $planningDir
    $createdIds = New-Object System.Collections.ArrayList
    $wakeSlugs = New-Object System.Collections.Generic.HashSet[string]

    for ($i = $hwm; $i -lt $total; $i++) {
        $line = $allLines[$i]
        $summary.Processed++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $rec = $null
        try { $rec = $line | ConvertFrom-Json } catch { $rec = $null }
        if (-not $rec) { continue }

        $kind = (Get-IntakeField -Record $rec -Name 'kind').ToLowerInvariant()
        $sourceTask = Get-IntakeField -Record $rec -Name 'source_task'
        $targetSlug = Get-IntakeField -Record $rec -Name 'target_slug'
        $target = Get-IntakeField -Record $rec -Name 'target'
        $symbol = Get-IntakeField -Record $rec -Name 'symbol'
        $text = Get-IntakeField -Record $rec -Name 'text'
        $ts = Get-IntakeField -Record $rec -Name 'ts'
        if ([string]::IsNullOrWhiteSpace($targetSlug)) { $targetSlug = $Slug }

        # dedup_key: always COMPUTE from the fields so triage is authoritative and
        # reviewer-emitted keys (which use the same hash) agree.
        $key = Get-DedupKey -TargetSlug $targetSlug -Target $target -Symbol $symbol -Kind $kind

        $lineNo = $i + 1
        $source = "intake:planning/$Slug/backlog/intake.jsonl#L$lineNo"

        $match = Find-DedupMatch -RepoRoot $repoRoot -Slug $targetSlug -Key $key

        if ($match.Type -eq 'live') {
            # Fold into the live task; create NO rival (the dedup guardrail).
            $note = "- deduped finding from ${sourceTask}: $text"
            Add-TriageNote -TaskFile $match.File -Note $note
            $summary.Deduped++
            continue
        }

        $isRecurrence = ($match.Type -eq 'done')
        $isCrossSlug = ($targetSlug -ne $Slug)
        $recurrenceOf = if ($isRecurrence) { $match.Id } else { '' }

        $gate = Resolve-TriageGate -Kind $kind -IsCrossSlug $isCrossSlug -IsRecurrence $isRecurrence -Policy $policy

        $targetTasksDir = Join-Path $repoRoot (Join-Path 'planning' (Join-Path $targetSlug 'tasks'))
        if (-not $nextStem.ContainsKey($targetSlug)) {
            $nextStem[$targetSlug] = Get-NextTaskStem -TasksDir $targetTasksDir
        }
        $stem = $nextStem[$targetSlug]
        $nextStem[$targetSlug] = $stem + 1

        $taskId = New-MaterializedTask -TasksDir $targetTasksDir -Stem $stem `
            -Status $gate.status -Decider $gate.decider -GateState $gate.gate_state `
            -Key $key -Source $source -RecurrenceOf $recurrenceOf `
            -FindingKind $kind -TargetSlug $targetSlug -Text $text -Ts $ts

        $null = $createdIds.Add($taskId)
        $summary.Materialized++
        if ($isRecurrence) { $summary.Recurrence++ }
        # Any materialized proposed/open task is new work -> wake its controller.
        if ($gate.status -eq 'proposed' -or $gate.status -eq 'open') {
            $null = $wakeSlugs.Add($targetSlug)
        }
    }

    # Advance the high-water mark to the full line count (idempotency).
    if (-not (Test-Path $backlogDir)) { New-Item -ItemType Directory -Path $backlogDir -Force | Out-Null }
    $hwmBytes = [Text.UTF8Encoding]::new($false).GetBytes(($total.ToString() + [Environment]::NewLine))
    [IO.File]::WriteAllBytes($processedPath, $hwmBytes)

    # Drop a wake-sentinel per target slug that gained new work.
    foreach ($ws in $wakeSlugs) {
        $null = New-WakeSentinel -Slug $ws -ControllerId $ControllerId
    }

    $summary.CreatedIds = @($createdIds)
    return $summary
}

# Direct invocation: run one triage pass and print a one-line summary. Dot-source
# (InvocationName '.') defines the functions only and skips this block.
if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($script:CliSlug)) {
        [Console]::Error.WriteLine('triage-intake.ps1: missing slug. Usage: triage-intake.ps1 <project-slug> [controller-id]')
        exit 1
    }
    $result = Invoke-TriageIntake -Slug $script:CliSlug -ControllerId $script:CliControllerId
    Write-Output ("triage: processed={0} materialized={1} deduped={2} recurrence={3}" -f `
        $result.Processed, $result.Materialized, $result.Deduped, $result.Recurrence)
    exit 0
}
