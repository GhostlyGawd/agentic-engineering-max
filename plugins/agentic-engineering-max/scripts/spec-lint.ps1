# bin/spec-lint.ps1
#
# Purpose:
#   Catch two classes of "assertion drifts from the thing it asserts about"
#   in planning documents:
#     1. Char-count drift: "<content>" (N chars) where content.Length != N.
#     2. Task-count drift: "N tasks total" where the file contains a
#        different count of ### T-\d+ task headings.
#
#   Both bug patterns surfaced during the build-system-plugin build (2026-05-18
#   worker-A run, T-003 + T-004 commits). Root cause: the plan-interviewer
#   asserted "(76 chars)" once in plan-ledger.md and 3 downstream documents
#   inherited the assertion verbatim without re-validating; spec writer wrote
#   "35 tasks total" in an intro paragraph that drifted from the actual count
#   of 38 task headings authored later in the same file.
#
# Usage:
#   spec-lint.ps1 [path...]
#   With no args, scans every .md under planning/.
#
# Exit codes:
#   0 = no findings
#   1 = at least one finding (lines printed to stderr)

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Paths
)

$ErrorActionPreference = 'Stop'

function Find-RepoRoot {
    $cur = (Get-Location).Path
    while ($cur -and $cur.Length -gt 3) {
        if (Test-Path (Join-Path $cur '.git')) { return $cur }
        $parent = Split-Path $cur -Parent
        if (-not $parent -or $parent -eq $cur) { return $null }
        $cur = $parent
    }
    return $null
}

if (-not $Paths -or $Paths.Count -eq 0) {
    $repoRoot = Find-RepoRoot
    if (-not $repoRoot) {
        [Console]::Error.WriteLine('spec-lint.ps1: no paths given and could not locate repo root.')
        exit 1
    }
    $Paths = @(Get-ChildItem -Path (Join-Path $repoRoot 'planning') -Filter '*.md' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}

$findings = @()

# Pattern 1: quoted string followed by "(N chars)" or "(N char)".
# Optional close-backtick (for markdown code-span wrapping) between the
# closing quote and the paren.
$charPattern = [regex]'"([^"\n]*)"\s*`?\s*\((\d+)\s*chars?\)'

# Pattern 2: "N tasks total" or "N task total" inline phrase.
$taskCountPattern = [regex]'(\d+)\s+tasks?\s+total'

# Pattern 3: per-file count of "### T-\d+" headings (the spec task-heading convention).
$taskHeadingPattern = [regex]'(?m)^###\s+T-\d+'

foreach ($file in $Paths) {
    if (-not (Test-Path $file)) { continue }
    # Force array form: Get-Content returns a bare String for single-line
    # files (or files with no trailing newline), and indexing into a String
    # in PS returns chars not lines -- which silently breaks the per-line
    # sweep below. @(...) coerces to a 1-element array of the full content.
    $lines = @(Get-Content $file)
    $fileText = $lines -join "`n"

    # Char-count sweep
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        foreach ($m in $charPattern.Matches($line)) {
            $content = $m.Groups[1].Value
            $claimed = [int]$m.Groups[2].Value
            $actual = $content.Length
            if ($actual -ne $claimed) {
                $snippet = if ($content.Length -gt 50) { $content.Substring(0, 47) + '...' } else { $content }
                $findings += [pscustomobject]@{
                    File = $file
                    Line = $i + 1
                    Type = 'char-count'
                    Claimed = $claimed
                    Actual = $actual
                    Snippet = $snippet
                }
            }
        }
    }

    # Task-count sweep
    $taskCount = ($taskHeadingPattern.Matches($fileText) | Measure-Object).Count
    if ($taskCount -gt 0) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            foreach ($m in $taskCountPattern.Matches($line)) {
                $claimed = [int]$m.Groups[1].Value
                if ($claimed -ne $taskCount) {
                    $trimmed = $line.Trim()
                    $snippet = if ($trimmed.Length -gt 60) { $trimmed.Substring(0, 57) + '...' } else { $trimmed }
                    $findings += [pscustomobject]@{
                        File = $file
                        Line = $i + 1
                        Type = 'task-count'
                        Claimed = $claimed
                        Actual = $taskCount
                        Snippet = $snippet
                    }
                }
            }
        }
    }
}

if ($findings.Count -eq 0) {
    exit 0
}

foreach ($f in $findings) {
    [Console]::Error.WriteLine(("{0}:{1}  {2}  claimed={3} actual={4}  '{5}'" -f $f.File, $f.Line, $f.Type, $f.Claimed, $f.Actual, $f.Snippet))
}
[Console]::Error.WriteLine('')
[Console]::Error.WriteLine(("spec-lint: {0} finding(s)" -f $findings.Count))
exit 1
