# bin/gate-schema.ps1
#
# Purpose:
#   The single shared reader for the control-plane frontmatter schema (spec
#   D-S1). Every control-plane component (the web server, triage, the gate
#   mutator) parses task frontmatter through THIS helper, so the schema is
#   defined and validated in one place. It returns the full additive key set
#   (kind, parent, gate_decider, gate_action, gate_state, dedup_key, source,
#   recurrence_of) alongside the existing keys, applying the D-S1 defaults:
#     - kind absent        => 'task'  (every pre-schema task-*.md is a task)
#     - gate_state absent  => 'pending' WHEN a gate_decider is present
#
#   Plus two predicate helpers:
#     - Test-IsContainer -Kind <k> : true for goal/epic (never claimable, D-S3)
#     - Get-GateQueue -Slug <s>    : every gate_decider == user task in a slug
#
# Decisions:
#   D-S1 (flat additive schema keys; line-oriented parser, no nested maps)
#   D-S3 (containers are goal/epic; this is the shared schema reader)
#
# The parser is line-oriented, mirroring claimable-width.ps1's
# Read-ClaimableFrontmatter and build-board.ps1's Read-Frontmatter: FLAT keys
# only (key: value, key: [a,b], or key: followed by `  - item` lines). PS has
# no native YAML parser and the shipped parsers are all line-scanners; flat
# gate_decider/gate_action keys (NOT a nested gate: map) keep every consumer on
# the existing `^key:\s*(.*)$` pattern with zero parser rewrite.
#
# Dot-sourceable (defines the functions) AND directly invokable:
#   gate-schema.ps1 -Path <task.md>   -> one-line parsed summary
#   gate-schema.ps1 -Slug <slug>      -> gate_queue=<n>
#
# Cross-task invariants honored:
#   - ASCII-only inside "..." literals.
#   - No 2>&1 on native exes (pure PS file reads; no native exes invoked).
#   - Paths built with Join-Path / forward slashes (no literal backslash).

param(
    [Parameter()]
    [string]$Path,

    [Parameter()]
    [string]$Slug
)

$ErrorActionPreference = 'Stop'

function Find-GateSchemaRepoRoot {
    # Walk up from the current location looking for a repo marker. CWD-first
    # (not $PSScriptRoot-first) so a dot-sourcing test operating in a temp repo
    # resolves to THAT repo, not the real bin/.. the script lives in.
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

# Line-oriented frontmatter scan over the full control-plane schema. Returns a
# pscustomobject with every key (existing + new) or $null if the file has no
# parseable `---` ... `---` frontmatter block.
function Read-ControlPlaneFrontmatter {
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
        type                = ''
        wave                = ''
        kind                = ''
        parent              = ''
        gate_decider        = ''
        gate_action         = ''
        gate_state          = ''
        dedup_key           = ''
        source              = ''
        recurrence_of       = ''
    }

    $inList = $null
    for ($i = 1; $i -lt $end; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$') {
            $inList = $null
            $key = $matches[1]
            $val = $matches[2].Trim()
            if ($val -match '^"(.*)"$' -or $val -match "^'(.*)'$") { $val = $matches[1] }
            switch ($key) {
                'id'                { $fm.id = $val }
                'title'             { $fm.title = $val }
                'status'            { $fm.status = $val.ToLowerInvariant() }
                'owner'             { $fm.owner = $val }
                'claimed_at'        { $fm.claimed_at = $val }
                'review_iterations' { if ($val -match '^\d+$') { $fm.review_iterations = [int]$val } }
                'type'              { $fm.type = $val }
                'wave'              { $fm.wave = $val }
                'kind'              { $fm.kind = $val.ToLowerInvariant() }
                'parent'            { $fm.parent = $val }
                'gate_decider'      { $fm.gate_decider = $val.ToLowerInvariant() }
                'gate_action'       { $fm.gate_action = $val.ToLowerInvariant() }
                'gate_state'        { $fm.gate_state = $val.ToLowerInvariant() }
                'dedup_key'         { $fm.dedup_key = $val }
                'source'            { $fm.source = $val }
                'recurrence_of'     { $fm.recurrence_of = $val }
                'depends_on' {
                    if ($val -match '^\[(.*)\]$') {
                        $fm.depends_on = @($matches[1] -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
                    } elseif (-not $val) {
                        $inList = 'depends_on'
                    }
                }
                'unresolved_findings' {
                    if ($val -match '^\[(.*)\]$') {
                        $fm.unresolved_findings = @($matches[1] -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
                    } elseif (-not $val) {
                        $inList = 'unresolved_findings'
                    }
                }
                default { }
            }
        } elseif ($inList -and ($line -match '^\s*-\s*(.*)$')) {
            $item = $matches[1].Trim().Trim('"', "'")
            if ($item) { $fm[$inList] = @($fm[$inList]) + $item }
        }
    }

    # D-S1 defaults.
    if ([string]::IsNullOrWhiteSpace($fm.kind)) { $fm.kind = 'task' }
    if ([string]::IsNullOrWhiteSpace($fm.gate_state) -and -not [string]::IsNullOrWhiteSpace($fm.gate_decider)) {
        $fm.gate_state = 'pending'
    }

    return [pscustomobject]$fm
}

# True when a kind denotes a container (goal/epic). A blank/absent kind is a
# task (D-S1 default), so it is NOT a container.
function Test-IsContainer {
    param([string]$Kind)
    $k = if ([string]::IsNullOrWhiteSpace($Kind)) { 'task' } else { $Kind.ToLowerInvariant() }
    return ($k -eq 'goal' -or $k -eq 'epic')
}

# Every task in a slug whose gate_decider is 'user' -- the queue the web HUD's
# Gates tab and the gate mutator reason about. Each returned object is the
# parsed frontmatter augmented with a TaskFile path note-property.
function Get-GateQueue {
    param([Parameter(Mandatory)][string]$Slug)

    $repoRoot = Find-GateSchemaRepoRoot
    if (-not $repoRoot) { return @() }
    $tasksDir = Join-Path $repoRoot (Join-Path 'planning' (Join-Path $Slug 'tasks'))
    if (-not (Test-Path $tasksDir)) { return @() }

    $queue = New-Object System.Collections.ArrayList
    foreach ($tf in @(Get-ChildItem -Path $tasksDir -Filter 'task-*.md' -File -ErrorAction SilentlyContinue)) {
        $fm = Read-ControlPlaneFrontmatter -Path $tf.FullName
        if (-not $fm) { continue }
        if ($fm.gate_decider -eq 'user') {
            $fm | Add-Member -NotePropertyName TaskFile -NotePropertyValue $tf.FullName -Force
            $null = $queue.Add($fm)
        }
    }
    return @($queue)
}

# Direct invocation: -Path prints a one-line parsed summary; -Slug prints the
# gate-queue count. Dot-sourcing (InvocationName '.') defines the functions
# only and skips this block.
if ($MyInvocation.InvocationName -ne '.') {
    if ($Path) {
        $fm = Read-ControlPlaneFrontmatter -Path $Path
        if (-not $fm) {
            [Console]::Error.WriteLine("gate-schema.ps1: could not parse frontmatter at $Path")
            exit 1
        }
        Write-Output ("id={0} kind={1} status={2} gate_decider={3} gate_action={4} gate_state={5}" -f `
            $fm.id, $fm.kind, $fm.status, $fm.gate_decider, $fm.gate_action, $fm.gate_state)
        exit 0
    }
    elseif ($Slug) {
        $q = Get-GateQueue -Slug $Slug
        Write-Output ("gate_queue={0}" -f @($q).Count)
        exit 0
    }
    else {
        [Console]::Error.WriteLine('gate-schema.ps1: provide -Path <task.md> or -Slug <project-slug>')
        exit 1
    }
}
