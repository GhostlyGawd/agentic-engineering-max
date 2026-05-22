# bin/unblock.ps1
#
# Purpose:
#   Inspect / reset / force-done an escalated task in a build slug. Backing
#   script for the /unblock <slug> T-NNN [--reset|--done] slash command.
#
# Replaces the inline -Command PowerShell that lived in
# ~/.claude/commands/unblock.md (broken arg-parser per Wave 2 handoff).
#
# Decisions:
#   D-S7  -- escalation surfacing (the read side of the unblock workflow).
#   D-S9  -- bin/ as the in-repo location for slash-command backing scripts
#            (matches board-print.ps1 / build-board.ps1).
#
# Safety:
#   --reset and --done only work when frontmatter status is 'escalated'.
#   Any other status errors out.

param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Slug,

    [Parameter(Position = 1, Mandatory = $true)]
    [string]$TaskId,

    [Parameter(Position = 2)]
    [string]$Flag = ''
)

$ErrorActionPreference = 'Stop'

# Normalize: strip a leading T- so 'T-W2-005' resolves to task-W2-005.md.
$taskIdBare = $TaskId -replace '^T-', ''

# Repo root: resolve the operator's repo dynamically from the current working
# directory (the /unblock slash command runs inside the operator's repo). A
# portable plugin cannot hard-code a repo path.
$repoRoot = (git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {
    [Console]::Error.WriteLine("ERROR: /unblock must be run inside a git repository.")
    exit 1
}
$repoRoot = $repoRoot.Trim()
$taskFile = Join-Path $repoRoot (Join-Path 'planning' (Join-Path $Slug (Join-Path 'tasks' ("task-" + $taskIdBare + ".md"))))

if (-not (Test-Path $taskFile)) {
    [Console]::Error.WriteLine("ERROR: task file not found: $taskFile")
    exit 1
}

$content = Get-Content $taskFile -Raw -Encoding UTF8

# --- Extract status from frontmatter ----------------------------------------
$status = ''
if ($content -match '(?m)^status:\s*(.+)$') {
    $status = $Matches[1].Trim()
}

# --- Extract unresolved_findings (list form) --------------------------------
$findings = @()
if ($content -match '(?s)unresolved_findings:\r?\n((?:\s+-\s+.+\r?\n)+)') {
    $block = $Matches[1]
    $findings = @(
        $block -split '\r?\n' |
            Where-Object { $_ -match '^\s+-\s+' } |
            ForEach-Object { ($_.Trim()) -replace '^-\s+', '' }
    )
}

# --- Inspect mode -----------------------------------------------------------
if ([string]::IsNullOrEmpty($Flag)) {
    Write-Host ("Task: $TaskId  status: $status")
    Write-Host ''
    if ($status -ne 'escalated') {
        Write-Host ("This task is not escalated (status=$status). Nothing to unblock.")
        exit 0
    }
    Write-Host '=== Unresolved findings ==='
    if ($findings.Count -eq 0) {
        Write-Host '  (none recorded)'
    } else {
        foreach ($f in $findings) { Write-Host ("  " + $f) }
    }
    Write-Host ''
    Write-Host 'Next steps:'
    Write-Host ("  /unblock $Slug $TaskId --reset   re-enter work queue from scratch")
    Write-Host ("  /unblock $Slug $TaskId --done    accept deliverable as-is")
    exit 0
}

# --- Mutating modes: require escalated status -------------------------------
if ($status -ne 'escalated') {
    [Console]::Error.WriteLine(
        "ERROR: task $TaskId has status=$status; --reset/--done only allowed on escalated tasks."
    )
    exit 1
}

function Write-TaskFileAtomic {
    param([string]$Path, [string]$NewContent)
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, $NewContent, [Text.UTF8Encoding]::new($false))
    Move-Item -Force $tmp $Path
}

if ($Flag -eq '--reset') {
    $new = $content
    $new = $new -replace '(?m)^status:\s*.+$',            'status: open'
    $new = $new -replace '(?m)^review_iterations:\s*.+$', 'review_iterations: 0'
    $new = $new -replace '(?m)^owner:\s*.+$',             'owner:'
    $new = $new -replace '(?m)^claimed_at:\s*.+$',        'claimed_at:'

    # Clear unresolved_findings whether it's currently a list or inline [].
    $replacement = 'unresolved_findings: []'
    $new = $new -replace '(?s)unresolved_findings:\r?\n(?:\s+-\s+.+\r?\n)+', ($replacement + [Environment]::NewLine)
    $new = $new -replace '(?m)^unresolved_findings:\s*\[.*\]\s*$',           $replacement

    Write-TaskFileAtomic -Path $taskFile -NewContent $new
    Write-Host ("Reset $TaskId -> status: open; review_iterations: 0; owner/claimed_at/unresolved_findings cleared.")
    exit 0
}

if ($Flag -eq '--done') {
    $new = $content -replace '(?m)^status:\s*.+$', 'status: done'
    Write-TaskFileAtomic -Path $taskFile -NewContent $new

    Push-Location $repoRoot
    try {
        $relPath = "planning/$Slug/tasks/task-$taskIdBare.md"
        git add $relPath
        git commit -m ("unblock --done: $TaskId force-marked done")
    } finally {
        Pop-Location
    }
    Write-Host ("Forced $TaskId -> status: done and committed. Run git push to sync remote.")
    exit 0
}

[Console]::Error.WriteLine("ERROR: unknown flag: $Flag. Use --reset or --done.")
exit 1
