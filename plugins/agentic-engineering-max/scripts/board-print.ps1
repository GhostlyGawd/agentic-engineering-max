# bin/board-print.ps1
#
# Purpose:
#   Stdout-print variant for the /board <slug> slash command. Invokes
#   build-board.ps1 against the same slug (which regenerates task-board.md),
#   then prints the regenerated file to stdout.
#
# Decisions: D-S4 (full-board output schema) + D-S9 (in-repo location).

param(
    [Parameter(Position = 0)]
    [string]$Slug
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Slug)) {
    [Console]::Error.WriteLine('board-print.ps1: missing slug. Usage: board-print.ps1 <project-slug>')
    exit 1
}

$scriptDir = Split-Path -Parent $PSCommandPath
$builder   = Join-Path $scriptDir 'build-board.ps1'

if (-not (Test-Path $builder)) {
    [Console]::Error.WriteLine("board-print.ps1: build-board.ps1 not found at $builder")
    exit 1
}

# Regenerate the board first.
& $builder $Slug
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

# Resolve the same repo root that build-board.ps1 used.
$repoRoot = $null
$cur = (Get-Location).Path
while ($cur -and $cur.Length -gt 3) {
    if ((Test-Path (Join-Path $cur '.git')) -or (Test-Path (Join-Path $cur 'planning'))) {
        $repoRoot = $cur
        break
    }
    $parent = Split-Path $cur -Parent
    if (-not $parent -or $parent -eq $cur) { break }
    $cur = $parent
}
if (-not $repoRoot) {
    $candidate = Split-Path -Parent $scriptDir
    if ($candidate -and (Test-Path (Join-Path $candidate 'planning'))) {
        $repoRoot = $candidate
    }
}
if (-not $repoRoot) {
    [Console]::Error.WriteLine('board-print.ps1: could not locate repo root.')
    exit 1
}

$boardPath = Join-Path $repoRoot ("planning/" + $Slug + "/task-board.md")
if (-not (Test-Path $boardPath)) {
    [Console]::Error.WriteLine("board-print.ps1: task-board.md not found at $boardPath")
    exit 1
}

Get-Content -Raw -Encoding utf8 -Path $boardPath
exit 0
