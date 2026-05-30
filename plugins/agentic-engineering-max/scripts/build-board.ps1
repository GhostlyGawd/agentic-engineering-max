# bin/build-board.ps1
#
# Purpose:
#   Read every planning/<slug>/tasks/task-*.md frontmatter, regenerate
#   planning/<slug>/task-board.md. Invoked by the /pm skill on every tick and
#   indirectly by the /board slash command via bin/board-print.ps1.
#
# Decisions:
#   D-S4 (full-board output schema)
#   D-S9 (in-repo location at bin/build-board.ps1)
#
# Expected per-task frontmatter (YAML between --- fences at top of file):
#   id: T-W1-001 | T-W2-007 | T-NNN
#   title: <one-line title>
#   status: open | proposed | awaiting_user_approval | in_progress | in_review |
#           needs_fixing | escalated | done | closed
#   (proposed / awaiting_user_approval / closed are the control-plane gate
#    statuses, mirrored from master-board.ps1: closed is terminal like done;
#    proposed + awaiting_user_approval are gate-pending and keep the board active.)
#   owner: <worker-id> | <reviewer-id> | (blank)
#   claimed_at: <ISO 8601 UTC> | (blank)
#   review_iterations: <int>            # defaults 0 if missing (per acceptance criteria)
#   depends_on: [T-NNN, T-MMM]          # or YAML list form; defaults []
#   unresolved_findings: ["..."]        # populated by /reviewer on escalation; defaults []
#
# Output: planning/<slug>/task-board.md (Set-Content -Encoding utf8, regenerated each call).
#
# Cross-task invariants honored:
#   - ASCII-only inside "..." literals (em-dash replaced with -- in output template).
#   - No 2>&1 on native exes (no native exes called here; pure PS file reads).
#   - All file writes Set-Content -Encoding utf8.
#   - Frontmatter parser tolerates missing review_iterations (defaults 0).

param(
    [Parameter(Position = 0)]
    [string]$Slug
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Slug)) {
    [Console]::Error.WriteLine('build-board.ps1: missing slug. Usage: build-board.ps1 <project-slug>')
    exit 1
}

function Find-RepoRoot {
    $cur = (Get-Location).Path
    while ($cur -and $cur.Length -gt 3) {
        if ((Test-Path (Join-Path $cur '.git')) -or (Test-Path (Join-Path $cur 'planning'))) {
            return $cur
        }
        $parent = Split-Path $cur -Parent
        if (-not $parent -or $parent -eq $cur) { return $null }
        $cur = $parent
    }
    return $null
}

# Fall back to the script's own location two directories up (bin/.. = repo root)
# so the script works when invoked from outside the repo as well.
$repoRoot = Find-RepoRoot
if (-not $repoRoot) {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $candidate = Split-Path -Parent $scriptDir
    if ($candidate -and (Test-Path (Join-Path $candidate 'planning'))) {
        $repoRoot = $candidate
    }
}
if (-not $repoRoot) {
    [Console]::Error.WriteLine('build-board.ps1: could not locate repo root (no .git or planning/ ancestor).')
    exit 1
}

$planningDir = Join-Path $repoRoot ("planning/" + $Slug)
$tasksDir    = Join-Path $planningDir 'tasks'
$boardPath   = Join-Path $planningDir 'task-board.md'

if (-not (Test-Path $planningDir)) {
    [Console]::Error.WriteLine("build-board.ps1: planning dir not found: $planningDir")
    exit 1
}

$nowUtc   = [DateTime]::UtcNow
$nowStamp = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')

# Parse a YAML-ish frontmatter block. PS 5.1 has no native YAML parser, so we
# do a line-oriented scan supporting:
#   key: value
#   key: [a, b, c]          (inline list)
#   key:                    (followed by `  - item` lines)
function Read-Frontmatter {
    param([string]$Path)

    $raw = Get-Content -Raw -Encoding utf8 -Path $Path -ErrorAction SilentlyContinue
    if (-not $raw) { return $null }

    $lines = $raw -split "`r?`n"
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') { return $null }

    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') { $end = $i; break }
    }
    if ($end -lt 0) { return $null }

    $fm = [ordered]@{
        id                  = ''
        title               = ''
        status              = ''
        owner               = ''
        claimed_at          = ''
        review_iterations   = 0
        depends_on          = @()
        unresolved_findings = @()
    }

    $inList = $null
    for ($i = 1; $i -lt $end; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$') {
            $inList = $null
            $key = $matches[1]
            $val = $matches[2].Trim()
            # Strip surrounding quotes if present
            if ($val -match '^"(.*)"$' -or $val -match "^'(.*)'$") {
                $val = $matches[1]
            }
            switch ($key) {
                'id'                  { $fm.id = $val }
                'title'               { $fm.title = $val }
                'status'              { $fm.status = $val.ToLowerInvariant() }
                'owner'               { $fm.owner = $val }
                'claimed_at'          { $fm.claimed_at = $val }
                'review_iterations'   {
                    if ($val -match '^\d+$') { $fm.review_iterations = [int]$val }
                }
                'depends_on'          {
                    if ($val -match '^\[(.*)\]$') {
                        $items = @($matches[1] -split ',' | ForEach-Object { $_.Trim().Trim('"',"'") } | Where-Object { $_ })
                        $fm.depends_on = $items
                    } elseif (-not $val) {
                        $inList = 'depends_on'
                    }
                }
                'unresolved_findings' {
                    if (-not $val) { $inList = 'unresolved_findings' }
                }
                default { }
            }
        } elseif ($inList -and ($line -match '^\s*-\s*(.*)$')) {
            $item = $matches[1].Trim().Trim('"',"'")
            if ($item) {
                if ($inList -eq 'depends_on') {
                    $fm.depends_on = @($fm.depends_on) + $item
                } elseif ($inList -eq 'unresolved_findings') {
                    $fm.unresolved_findings = @($fm.unresolved_findings) + $item
                }
            }
        }
    }

    return $fm
}

function Format-ClaimedAge {
    param([string]$Iso, [DateTime]$Now)
    if (-not $Iso) { return '' }
    try {
        $dt = [DateTime]::Parse(
            $Iso,
            [Globalization.CultureInfo]::InvariantCulture,
            ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
        )
        $delta = $Now - $dt
        if ($delta.TotalHours -ge 1) {
            return ('claimed {0:N1}h ago' -f $delta.TotalHours)
        } else {
            $mins = [int][Math]::Floor($delta.TotalMinutes)
            return "claimed $mins min ago"
        }
    } catch {
        return ''
    }
}

# Collect tasks.
$buckets = [ordered]@{
    open                   = New-Object System.Collections.ArrayList
    proposed               = New-Object System.Collections.ArrayList
    awaiting_user_approval = New-Object System.Collections.ArrayList
    in_progress            = New-Object System.Collections.ArrayList
    in_review              = New-Object System.Collections.ArrayList
    needs_fixing           = New-Object System.Collections.ArrayList
    escalated              = New-Object System.Collections.ArrayList
    done                   = New-Object System.Collections.ArrayList
    closed                 = New-Object System.Collections.ArrayList
}
$tasksById = @{}

$haveTaskFiles = $false
if (Test-Path $tasksDir) {
    $taskFiles = @(Get-ChildItem -Path $tasksDir -Filter 'task-*.md' -File -ErrorAction SilentlyContinue)
    if ($taskFiles.Count -gt 0) { $haveTaskFiles = $true }
    foreach ($tf in $taskFiles) {
        $fm = Read-Frontmatter -Path $tf.FullName
        if (-not $fm) {
            # Per epistemic-falsificationist review: a silent drop on
            # malformed frontmatter makes the success criterion
            # "all tasks appear on the board" unfalsifiable. Loud-warn so a
            # PM-terminal observer sees the skipped file.
            [Console]::Error.WriteLine("build-board.ps1: WARN dropping $($tf.Name) (frontmatter missing or malformed)")
            continue
        }

        if (-not $fm.id) {
            if ($tf.BaseName -match '^task-(W\d+-\d+|\d+)') {
                $fm.id = 'T-' + $matches[1]
            } else {
                $fm.id = $tf.BaseName
            }
        }
        if (-not $fm.title) { $fm.title = $tf.BaseName }

        $tasksById[$fm.id] = $fm

        if ($buckets.Contains($fm.status)) {
            $bucket = $fm.status
        } else {
            # Unknown status value: bucket into 'open' but loud-warn so a
            # `status: in-progress` (hyphen) typo doesn't silently masquerade
            # as an open task.
            [Console]::Error.WriteLine("build-board.ps1: WARN $($fm.id) has unknown status '$($fm.status)'; bucketing as 'open'")
            $bucket = 'open'
        }
        $null = $buckets[$bucket].Add($fm)
    }
}

# Build the markdown.
$lines = New-Object System.Collections.ArrayList
$null = $lines.Add("=== Board snapshot -- $Slug @ $nowStamp ===")
$null = $lines.Add('')

if (-not $haveTaskFiles) {
    $null = $lines.Add('(no tasks yet)')
    $null = $lines.Add('')
    Set-Content -Path $boardPath -Value ($lines -join "`n") -Encoding utf8
    exit 0
}

# Sort each bucket by id (lexicographic; T-W1-001 sorts before T-W1-002).
foreach ($k in @($buckets.Keys)) {
    $sorted = @($buckets[$k] | Sort-Object { $_.id })
    $buckets[$k] = $sorted
}

function Add-Section {
    param(
        [System.Collections.ArrayList]$Out,
        [string]$Name,
        $Items,
        [scriptblock]$Formatter
    )
    $count = if ($Items) { @($Items).Count } else { 0 }
    $null = $Out.Add("$Name ($count):")
    if ($count -eq 0) {
        $null = $Out.Add('  (none)')
    } else {
        foreach ($t in $Items) {
            $rendered = (& $Formatter $t)
            $null = $Out.Add($rendered)
        }
    }
    $null = $Out.Add('')
}

Add-Section -Out $lines -Name 'open' -Items $buckets.open -Formatter {
    param($t)
    $dep = if ($t.depends_on -and @($t.depends_on).Count -gt 0) {
        '(depends_on: ' + (@($t.depends_on) -join ', ') + ')'
    } else { '' }
    ('  {0,-12} {1,-50} {2}' -f $t.id, $t.title, $dep).TrimEnd()
}

Add-Section -Out $lines -Name 'proposed' -Items $buckets.proposed -Formatter {
    param($t)
    $gate = if ($t.gate_action) { '(gate: ' + $t.gate_action + ')' } else { '' }
    ('  {0,-12} {1,-50} {2}' -f $t.id, $t.title, $gate).TrimEnd()
}

Add-Section -Out $lines -Name 'awaiting_user_approval' -Items $buckets.awaiting_user_approval -Formatter {
    param($t)
    $gate = if ($t.gate_action) { '(gate: ' + $t.gate_action + ')' } else { '' }
    ('  {0,-12} {1,-50} {2}' -f $t.id, $t.title, $gate).TrimEnd()
}

Add-Section -Out $lines -Name 'in_progress' -Items $buckets.in_progress -Formatter {
    param($t)
    $age = Format-ClaimedAge -Iso $t.claimed_at -Now $nowUtc
    ('  {0,-12} {1,-50} {2}  {3}' -f $t.id, $t.title, $t.owner, $age).TrimEnd()
}

Add-Section -Out $lines -Name 'in_review' -Items $buckets.in_review -Formatter {
    param($t)
    ('  {0,-12} {1,-50} {2}  iter {3}/3' -f $t.id, $t.title, $t.owner, $t.review_iterations).TrimEnd()
}

Add-Section -Out $lines -Name 'needs_fixing' -Items $buckets.needs_fixing -Formatter {
    param($t)
    ('  {0,-12} {1,-50} {2}  iter {3}/3' -f $t.id, $t.title, $t.owner, $t.review_iterations).TrimEnd()
}

Add-Section -Out $lines -Name 'escalated' -Items $buckets.escalated -Formatter {
    param($t)
    $lastFinding = ''
    if ($t.unresolved_findings -and @($t.unresolved_findings).Count -gt 0) {
        $lastFinding = 'last: ' + @($t.unresolved_findings)[0]
    }
    ('  {0,-12} {1,-50} iter 3/3  {2}' -f $t.id, $t.title, $lastFinding).TrimEnd()
}

Add-Section -Out $lines -Name 'done' -Items $buckets.done -Formatter {
    param($t)
    ('  {0,-12} {1,-50} {2}' -f $t.id, $t.title, $t.owner).TrimEnd()
}

# Terminal like done, but reached via a gate decline/abandon (control-plane
# D-S6). Rendered as its own section so a closed finding never masquerades as
# an open task, and excluded from activeCount so it does not block ALL TASKS DONE.
Add-Section -Out $lines -Name 'closed' -Items $buckets.closed -Formatter {
    param($t)
    $why = if ($t.gate_state) { '(gate_state: ' + $t.gate_state + ')' } else { '' }
    ('  {0,-12} {1,-50} {2}' -f $t.id, $t.title, $why).TrimEnd()
}

# Blocked = informational subset of open whose depends_on names a task that
# exists in tasksById but is not in 'done'. We render after the done section.
$blockedRows = New-Object System.Collections.ArrayList
foreach ($t in $buckets.open) {
    $waiting = @()
    foreach ($dep in $t.depends_on) {
        $depTask = $tasksById[$dep]
        if ($depTask -and $depTask.status -ne 'done') {
            $waiting += ("$dep ($($depTask.status))")
        }
    }
    if ($waiting.Count -gt 0) {
        $null = $blockedRows.Add([pscustomobject]@{ id = $t.id; title = $t.title; waiting = $waiting })
    }
}
$null = $lines.Add("blocked ($($blockedRows.Count)) -- informational subset of open:")
if ($blockedRows.Count -eq 0) {
    $null = $lines.Add('  (none)')
} else {
    foreach ($r in $blockedRows) {
        $wait = 'waiting on: ' + ($r.waiting -join ', ')
        $null = $lines.Add(('  {0,-12} {1,-50} {2}' -f $r.id, $r.title, $wait).TrimEnd())
    }
}
$null = $lines.Add('')

# All-done sentinel: emit when there is at least one done task and nothing
# actively in the pipeline.
# Active = anything not yet terminal. proposed + awaiting_user_approval are
# gate-pending (awaiting a human decision) so they keep the board active and
# block ALL TASKS DONE; closed is terminal (counts with done, not active).
$activeCount =
    @($buckets.open).Count +
    @($buckets.proposed).Count +
    @($buckets.awaiting_user_approval).Count +
    @($buckets.in_progress).Count +
    @($buckets.in_review).Count +
    @($buckets.needs_fixing).Count +
    @($buckets.escalated).Count
$terminalCount = @($buckets.done).Count + @($buckets.closed).Count
if ($activeCount -eq 0 -and $terminalCount -gt 0) {
    $null = $lines.Add('*** ALL TASKS DONE')
    $null = $lines.Add('')
}

Set-Content -Path $boardPath -Value ($lines -join "`n") -Encoding utf8
exit 0
