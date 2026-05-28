# bin/master-board.ps1
#
# Purpose:
#   The cross-slug master board (spec D-S6). A PURE READ helper that walks
#   planning/lineage.psd1 parent-edges as the tree root (portfolio > slug), then
#   under each slug builds the goal > epic > task > subtask tree from `parent:`
#   edges (via the T-101 reader in bin/gate-schema.ps1), and computes each
#   container's rolled-up status + a <done>/<total> progress fraction.
#
#   Rollup (COMPUTED, never written to a container's frontmatter, D-S6 / cross-
#   task invariant 11). A container's leaves are its transitive task/subtask
#   descendants. Precedence:
#     - done        if all leaves are done|closed
#     - escalated   else if any leaf is escalated
#     - in_progress else if any leaf is in_progress|in_review|needs_fixing
#     - open        else if any leaf is open|proposed|awaiting_user_approval
#   Progress fraction = <leaves done|closed> / <total leaves>.
#
#   Emits a structured object the web server (T-301 / D-S10) renders as the
#   GET /api/board JSON:
#     { generated_at, portfolio: [ { slug, parent, summary, containers, tasks } ] }
#
# Usage:
#   master-board.ps1                      # prints a text tree of the portfolio
#   master-board.ps1 -RepoRoot <dir>      # operate on an alternate tree (tests)
#   . master-board.ps1 ; Get-MasterBoard  # dot-source; returns the object
#
# Decisions:
#   D-S6 (container rollup is computed; one cross-slug walk the web server renders)
#
# Cross-task invariants honored:
#   - ASCII-only inside "..." literals.
#   - No 2>&1 on native exes (pure PS file reads; no native exes invoked).
#   - Paths built with Join-Path (no literal backslash, no drive-letter absolute).
#   - A container's frontmatter is NEVER mutated (pure read).

param(
    [Parameter()]
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

# Bring in the shared T-101 frontmatter reader (Read-ControlPlaneFrontmatter,
# Test-IsContainer). Dot-sourcing trips gate-schema's InvocationName '.' guard,
# so only its functions load; its direct-invocation block is skipped.
. (Join-Path $PSScriptRoot 'gate-schema.ps1')

# The set of leaf statuses that count as "done" for the progress fraction and
# the all-done rollup. `closed` (declined/abandoned) counts as done per D-S6.
$script:MasterBoardDoneStatuses = @('done', 'closed')

# Compute a container's rolled-up status + progress from its leaf descendants.
# $leaves is an array of leaf frontmatter objects (kind task/subtask only).
function Get-RollupStatus {
    param([object[]]$Leaves)

    $total = @($Leaves).Count
    $done  = @($Leaves | Where-Object { $script:MasterBoardDoneStatuses -contains $_.status }).Count

    $status =
        if ($total -eq 0) {
            'open'
        } elseif ($done -eq $total) {
            'done'
        } elseif (@($Leaves | Where-Object { $_.status -eq 'escalated' }).Count -gt 0) {
            'escalated'
        } elseif (@($Leaves | Where-Object { @('in_progress', 'in_review', 'needs_fixing') -contains $_.status }).Count -gt 0) {
            'in_progress'
        } else {
            'open'
        }

    return [pscustomobject]@{
        status   = $status
        done     = $done
        total    = $total
        progress = ("{0}/{1}" -f $done, $total)
    }
}

# Walk a node's parent chain upward, returning the ordered list of ancestor ids.
# $byId maps id -> frontmatter. Guards against a parent cycle via a visited set.
function Get-AncestorIds {
    param(
        [object]$Node,
        [hashtable]$ById
    )
    $ancestors = New-Object System.Collections.ArrayList
    $visited = @{}
    $cur = $Node
    while ($cur -and -not [string]::IsNullOrWhiteSpace($cur.parent)) {
        $parentId = $cur.parent
        if ($visited.ContainsKey($parentId)) { break }  # cycle guard
        $visited[$parentId] = $true
        $null = $ancestors.Add($parentId)
        $cur = if ($ById.ContainsKey($parentId)) { $ById[$parentId] } else { $null }
    }
    return @($ancestors)
}

# Build the per-slug board: read every task-*.md, split into containers
# (goal/epic) and leaves (task/subtask), and attach each container's rollup.
function Get-SlugBoard {
    param(
        [string]$Slug,
        [string]$PlanningDir
    )

    $tasksDir = Join-Path (Join-Path $PlanningDir $Slug) 'tasks'
    $containers = New-Object System.Collections.ArrayList
    $leaves     = New-Object System.Collections.ArrayList

    if (-not (Test-Path $tasksDir)) {
        return [pscustomobject]@{ containers = @(); tasks = @() }
    }

    # Read all frontmatter once, index by id.
    $all = New-Object System.Collections.ArrayList
    $byId = @{}
    foreach ($tf in @(Get-ChildItem -Path $tasksDir -Filter 'task-*.md' -File -ErrorAction SilentlyContinue)) {
        $fm = Read-ControlPlaneFrontmatter -Path $tf.FullName
        if (-not $fm) { continue }
        $null = $all.Add($fm)
        if (-not [string]::IsNullOrWhiteSpace($fm.id)) { $byId[$fm.id] = $fm }
    }

    foreach ($fm in $all) {
        if (Test-IsContainer -Kind $fm.kind) {
            $null = $containers.Add($fm)
        } else {
            $null = $leaves.Add($fm)
        }
    }

    # Build the container rows with computed rollup over their descendant leaves.
    $containerRows = New-Object System.Collections.ArrayList
    foreach ($c in $containers) {
        $myLeaves = @($leaves | Where-Object {
            (Get-AncestorIds -Node $_ -ById $byId) -contains $c.id
        })
        $roll = Get-RollupStatus -Leaves $myLeaves
        $null = $containerRows.Add([pscustomobject]@{
            id       = $c.id
            title    = $c.title
            kind     = $c.kind
            parent   = $c.parent
            status   = $roll.status
            done     = $roll.done
            total    = $roll.total
            progress = $roll.progress
        })
    }

    $taskRows = New-Object System.Collections.ArrayList
    foreach ($l in $leaves) {
        $null = $taskRows.Add([pscustomobject]@{
            id     = $l.id
            title  = $l.title
            kind   = $l.kind
            parent = $l.parent
            status = $l.status
        })
    }

    return [pscustomobject]@{ containers = @($containerRows); tasks = @($taskRows) }
}

# The public entry point: the full cross-slug master-board object.
function Get-MasterBoard {
    param([string]$RepoRoot)

    if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
    $planningDir = Join-Path $RepoRoot 'planning'
    $lineagePath = Join-Path $planningDir 'lineage.psd1'

    $portfolio = New-Object System.Collections.ArrayList
    if (Test-Path $lineagePath) {
        $lineage = Import-PowerShellDataFile -LiteralPath $lineagePath
        foreach ($entry in @($lineage.projects)) {
            $slug = $entry.slug
            if ([string]::IsNullOrWhiteSpace($slug)) { continue }
            $board = Get-SlugBoard -Slug $slug -PlanningDir $planningDir
            $null = $portfolio.Add([pscustomobject]@{
                slug       = $slug
                parent     = $entry.parent
                summary    = $entry.summary
                containers = $board.containers
                tasks      = $board.tasks
            })
        }
    }

    return [pscustomobject]@{
        generated_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        portfolio    = @($portfolio)
    }
}

# Render the board object as an ASCII text tree for manual/terminal use.
function Write-MasterBoardText {
    param([object]$Board)

    Write-Output ("Master board -- generated {0}" -f $Board.generated_at)
    foreach ($p in @($Board.portfolio)) {
        $parentTag = if ([string]::IsNullOrWhiteSpace($p.parent)) { '(root)' } else { ("parent: {0}" -f $p.parent) }
        Write-Output ("- {0}  [{1}]" -f $p.slug, $parentTag)
        foreach ($c in @($p.containers)) {
            Write-Output ("    [{0}] {1} -- {2}  ({3} {4})" -f $c.kind, $c.id, $c.title, $c.status, $c.progress)
        }
        foreach ($t in @($p.tasks)) {
            Write-Output ("      - {0} {1} -- {2}  ({3})" -f $t.kind, $t.id, $t.title, $t.status)
        }
    }
}

# Direct invocation prints the text tree; dot-sourcing (InvocationName '.') only
# defines the functions and skips this block.
if ($MyInvocation.InvocationName -ne '.') {
    $board = Get-MasterBoard -RepoRoot $RepoRoot
    Write-MasterBoardText -Board $board
    exit 0
}
