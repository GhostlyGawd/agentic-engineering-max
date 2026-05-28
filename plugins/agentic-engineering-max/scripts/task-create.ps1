# bin/task-create.ps1
#
# Purpose:
#   The pure-pwsh writer behind the `/task-create` skill (spec D-S8). Turns a
#   one-line chat insight into a GATED design task: it writes a `kind: task`
#   task file into planning/<slug>/tasks/ carrying the locked design-task
#   frontmatter and drops a wake-sentinel (T-102) so the dormant controller
#   (T-203) picks it up promptly.
#
#   The created task's deliverable is "a design plan document at
#   planning/<slug>/designs/<task-id>-design.md". A NORMAL worker claims it,
#   writes the design plan, and sets `status: awaiting_user_approval`. On the
#   user's APPROVE (D-S2 spawn-next-stage, handled by bin/gate-apply.ps1 in
#   T-103), the gate mutator creates a downstream spec-writer task. This writer
#   owns ONLY the first hop: chat insight -> gated design task.
#
# Decisions:
#   D-S8 (task-create target slug, deliverable, locked gate frontmatter)
#   D-S4 (drop a wake-sentinel via the shared bin/wake-sentinel.ps1 helper)
#
# Usage:
#   bin/task-create.ps1 -Text "<one-line insight>" [-Slug inbox] [-ControllerId controller]
#     -Slug defaults to `inbox` (the dedicated unsorted-capture slug, D-S8).
#     -Slug foo targets planning/foo/tasks/ (created on demand).
#
# Output (stdout, one line each, parse-friendly for the web POST /api/create):
#   created <T-NNN> at planning/<slug>/tasks/task-NNN.md
#   wake <created|present>: <wake-sentinel path>
#   task_id=<T-NNN>
#
# Cross-task invariants honored:
#   - ASCII-only inside "..." literals.
#   - No 2>&1 on native exes (pure PS file ops; no native exes invoked).
#   - Paths built with Join-Path / forward slashes (no literal backslash).
#   - UTF-8 (no BOM) for every file written.

param(
    [Parameter(Mandatory)]
    [string]$Text,

    [Parameter()]
    [string]$Slug = 'inbox',

    [Parameter()]
    [string]$ControllerId = 'controller'
)

$ErrorActionPreference = 'Stop'

function Find-TaskCreateRepoRoot {
    # Walk up from the current location looking for a repo marker. CWD-first
    # (not $PSScriptRoot-first) so a test operating in a temp repo resolves to
    # THAT repo, not the real bin/.. the script lives in. Same pattern as
    # wake-sentinel.ps1's Find-WakeRepoRoot, so this writer and the wake helper
    # it dot-sources agree on the repo root.
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

# Derive a single-line title from the captured text: first non-empty line,
# whitespace-collapsed, truncated to 70 chars. Never empty (falls back to a
# generic label) so the board always has a title.
function Get-TaskTitle {
    param([string]$Text)
    $firstLine = (($Text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $firstLine) { return 'Untitled task-create capture' }
    $collapsed = ($firstLine.Trim() -replace '\s+', ' ')
    if ($collapsed.Length -gt 70) { $collapsed = $collapsed.Substring(0, 70).TrimEnd() }
    return $collapsed
}

$repoRoot = Find-TaskCreateRepoRoot
if (-not $repoRoot) {
    [Console]::Error.WriteLine('task-create.ps1: could not locate repo root (no .git/planning in cwd ancestors or script-dir ancestor).')
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = 'inbox' }

$tasksDir = Join-Path $repoRoot (Join-Path 'planning' (Join-Path $Slug 'tasks'))
if (-not (Test-Path $tasksDir)) {
    # -Force is idempotent and creates the planning/<slug> parent too. A brand
    # new -Slug foo is materialized on demand here.
    New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
}

# Highest existing plain-numeric task stem (task-NNN). Mixed-form stems like
# task-W1-001 are ignored for numbering -- the capture slugs use plain NNN.
$maxNum = 0
foreach ($tf in @(Get-ChildItem -Path $tasksDir -Filter 'task-*.md' -File -ErrorAction SilentlyContinue)) {
    if ($tf.BaseName -match '^task-0*(\d+)$') {
        $n = [int]$matches[1]
        if ($n -gt $maxNum) { $maxNum = $n }
    }
}

$title = Get-TaskTitle -Text $Text
$nowIso = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

# Atomic NNN allocation: try CreateNew on task-NNN.md starting at max+1; on a
# collision (a concurrent task-create grabbed it) bump NNN and retry. This
# closes the TOCTOU window between "scan for max" and "write the file".
$num = $maxNum + 1
$taskId = $null
$taskFile = $null
$attempts = 0
while ($attempts -lt 1000) {
    $attempts++
    $stemNum = '{0:D3}' -f $num
    $candidateId = 'T-' + $stemNum
    $candidatePath = Join-Path $tasksDir ("task-{0}.md" -f $stemNum)
    $designRel = "planning/$Slug/designs/$candidateId-design.md"

    $body = @"
---
id: $candidateId
title: $title
status: open
owner:
claimed_at:
review_iterations: 0
depends_on: []
unresolved_findings: []
kind: task
type: design
gate_decider: user
gate_action: spawn-next-stage
gate_state: pending
source: task-create
---

# $candidateId -- $title

## Goal
Produce a design plan that turns the captured insight below into an
actionable proposal. This is a gated design task (D-S8): a worker writes the
design plan, then sets ``status: awaiting_user_approval``. On the user's
APPROVE the gate (D-S2 spawn-next-stage) creates a downstream spec-writer task
for ``$Slug``; on DECLINE the task closes.

## Captured insight
$Text

## Deliverables
- ``$designRel`` -- a design plan document: problem statement, proposed
  approach, alternatives considered, scope/non-goals, and a recommended next
  step (typically: hand off to the spec-writer for ``$Slug``).

## Acceptance criteria
- ``$designRel`` exists and covers problem, approach, alternatives, scope.
- The worker sets ``status: awaiting_user_approval`` after writing the plan
  (this surfaces the task in the control-plane Gates queue).

## Source
Captured via ``/task-create`` on $nowIso into slug ``$Slug``.
"@

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($body -replace "`r?`n", [Environment]::NewLine))
    try {
        $fs = [IO.File]::Open($candidatePath, 'CreateNew', 'ReadWrite', 'None')
        try {
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush()
        } finally {
            $fs.Dispose()
        }
        $taskId = $candidateId
        $taskFile = $candidatePath
        break
    } catch [System.IO.IOException] {
        # Collision: a concurrent writer took this NNN (or a stale partial
        # exists). Bump and retry. Re-throw only if it is NOT a "file exists"
        # race (e.g. a real permissions error surfaces here too, but the
        # CreateNew-collision is the expected case).
        if (-not (Test-Path $candidatePath)) { throw }
        $num++
        continue
    }
}

if (-not $taskId) {
    [Console]::Error.WriteLine('task-create.ps1: could not allocate a task number after 1000 attempts.')
    exit 1
}

# Precompute everything that reads $Slug BEFORE dot-sourcing wake-sentinel.ps1:
# its own param() block runs in THIS scope on dot-source and would clobber
# same-named vars ($Slug/$ControllerId) to empty strings. We snapshot the two
# values into wake-only locals and build the display path up front so the
# post-dot-source code never reads the clobbered $Slug.
$relTaskPath = "planning/$Slug/tasks/" + (Split-Path -Leaf $taskFile)
$wakeSlug = $Slug
$wakeCtrl = $ControllerId

# Drop the wake-sentinel via the shared helper (D-S4) so the four drop points
# (task-create, approve, retry, triage) cannot drift in idiom.
$existedBefore = $false
. (Join-Path $PSScriptRoot 'wake-sentinel.ps1')
$probe = Get-WakeSentinelPath -Slug $wakeSlug -ControllerId $wakeCtrl
if ($probe) { $existedBefore = Test-Path $probe }
$wakePath = New-WakeSentinel -Slug $wakeSlug -ControllerId $wakeCtrl
$wakeState = if ($existedBefore) { 'present' } else { 'created' }
Write-Output ("created {0} at {1}" -f $taskId, $relTaskPath)
if ($wakePath) {
    Write-Output ("wake {0}: {1}" -f $wakeState, $wakePath)
} else {
    Write-Output 'wake skipped: repo root unresolved for wake-sentinel'
}
Write-Output ("task_id={0}" -f $taskId)
exit 0
