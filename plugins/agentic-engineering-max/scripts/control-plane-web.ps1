# bin/control-plane-web.ps1
#
# Purpose:
#   The local control-plane web HUD server (spec T-301 / D-S10). A pwsh
#   System.Net.HttpListener bound to http://127.0.0.1:<web_port> (default 8787
#   from .build-config.json) that serves the static webui/ front-end (T-302) and
#   the D-S10 JSON API. It is NEVER load-bearing: every mutation delegates to a
#   shared helper (the gate mutator T-103, task-create T-104, the controller
#   spawn, the stop sentinel), so the same effect is reachable from the CLI with
#   the server dead.
#
#   GET routes (pure reads):
#     /api/board            -> Get-MasterBoard (T-202) JSON
#     /api/gates            -> Get-GateQueue (T-101) across all slugs (user-decider queue)
#     /api/loops            -> .beat heartbeat freshness + controller log tail
#     /api/logs?file=&tail= -> allowlisted tail of a logs/ file (no traversal)
#     /<anything else>      -> static file from webui/ (index.html at /)
#
#   POST routes (mutations; all reject non-loopback remote addresses):
#     /api/approve  {slug, task_id}        -> Invoke-GateDecision approve
#     /api/decline  {slug, task_id}        -> Invoke-GateDecision decline
#     /api/retry    {slug, task_id, notes} -> Invoke-GateDecision retry
#     /api/create   {text, slug?}          -> bin/task-create.ps1
#     /api/launch   {slug}                 -> spawn orchestrator-loop.ps1 detached
#     /api/stop     {slug}                 -> drop controller.headless-stop sentinel
#
#   The request router is factored into Invoke-ControlPlaneRoute, a dot-sourceable
#   function the regression test drives directly (no live socket needed).
#
# Decisions: D-S10 (route names + shapes, loopback bind, logs allowlist),
#   D-S9 (delegate every mutation to the one gate mutator), D-S6 (board read),
#   D-S4 (the helpers drop the wake-sentinel themselves on approve/retry/create).
#
# Usage:
#   pwsh bin/control-plane-web.ps1 [-Slug control-plane] [-Port <n>] [-RepoRoot <dir>]
#     -Slug    : which planning/<slug>/.build-config.json supplies web_port (default control-plane)
#     -Port    : override the configured/default port
#     -RepoRoot: operate on an alternate tree (tests); defaults to the cwd repo root
#   . bin/control-plane-web.ps1 ; Invoke-ControlPlaneRoute -Method GET -Path /api/board -RepoRoot <dir>
#
# Cross-task invariants honored:
#   - ASCII-only inside "..." literals.
#   - No 2>&1 on native exes (only 2>$null on the task-create child).
#   - Paths built with Join-Path / forward slashes (no literal backslash).
#   - UTF-8 (no BOM) for every byte written to the wire and to disk.

param(
    [Parameter()]
    [string]$Slug = 'control-plane',

    [Parameter()]
    [int]$Port = 0,

    [Parameter()]
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

# Snapshot our bound params BEFORE dot-sourcing the helpers below. Several of
# them (gate-schema, wake-sentinel, gate-apply, master-board) declare -Slug /
# -RepoRoot / -Path params; dot-sourcing runs their param() blocks in THIS scope
# with no arguments, which would clobber our values. The direct-invocation block
# at the bottom reads these snapshots, not the (now-reset) params. Same guard
# pattern as gate-apply.ps1.
$cliSlug     = $Slug
$cliPort     = $Port
$cliRepoRoot = $RepoRoot

# Dot-source the shared helpers. $PSScriptRoot is bin/ whether we are run via
# -File or dot-sourced, so the siblings resolve either way. Their direct-
# invocation blocks are gated on InvocationName -ne '.', so dot-sourcing here
# only defines their functions. master-board pulls in gate-schema's reader;
# gate-apply pulls in gate-schema + wake-sentinel; we add gate-schema explicitly
# for Get-GateQueue. (task-create / orchestrator-loop are NOT dot-sourced -- they
# carry mandatory params and are invoked as child processes / spawned.)
. (Join-Path $PSScriptRoot 'master-board.ps1')
. (Join-Path $PSScriptRoot 'gate-apply.ps1')
. (Join-Path $PSScriptRoot 'gate-schema.ps1')

# --- repo-root + config helpers -------------------------------------------

function Find-WebRepoRoot {
    # CWD-first repo-root walk, same idiom as the sibling helpers.
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

# Resolve the listen port: an explicit override wins, else the slug's
# .build-config.json web_port, else 8787.
function Resolve-WebPort {
    param([Parameter(Mandatory)][string]$RepoRoot, [string]$Slug = 'control-plane', [int]$Override = 0)
    if ($Override -gt 0) { return $Override }
    $cfg = Join-Path (Join-Path (Join-Path $RepoRoot 'planning') $Slug) '.build-config.json'
    if (Test-Path $cfg) {
        try {
            $o = Get-Content -Raw -Encoding utf8 $cfg | ConvertFrom-Json
            if (($o.PSObject.Properties.Name -contains 'web_port') -and $o.web_port) { return [int]$o.web_port }
        } catch { }
    }
    return 8787
}

# Read heartbeat_ttl_seconds from a slug's config (default 180) -- the FRESH/STALE
# threshold for the loops view.
function Get-WebStaleSeconds {
    param([Parameter(Mandatory)][string]$RepoRoot, [string]$Slug = 'control-plane')
    $cfg = Join-Path (Join-Path (Join-Path $RepoRoot 'planning') $Slug) '.build-config.json'
    if (Test-Path $cfg) {
        try {
            $o = Get-Content -Raw -Encoding utf8 $cfg | ConvertFrom-Json
            if (($o.PSObject.Properties.Name -contains 'heartbeat_ttl_seconds') -and $o.heartbeat_ttl_seconds) {
                return [int]$o.heartbeat_ttl_seconds
            }
        } catch { }
    }
    return 180
}

# The list of slugs to aggregate over: lineage.psd1 projects, falling back to any
# planning/<slug>/tasks directory.
function Get-WebSlugs {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $planning = Join-Path $RepoRoot 'planning'
    $lineage  = Join-Path $planning 'lineage.psd1'
    if (Test-Path $lineage) {
        try {
            $data = Import-PowerShellDataFile -LiteralPath $lineage
            $s = @($data.projects | ForEach-Object { $_.slug } | Where-Object { $_ })
            if ($s.Count -gt 0) { return $s }
        } catch { }
    }
    if (Test-Path $planning) {
        return @(Get-ChildItem -Path $planning -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'tasks') } |
            ForEach-Object { $_.Name })
    }
    return @()
}

# --- response builders ----------------------------------------------------

# A response is a flat object the router returns and the wire-writer renders.
function New-WebResponse {
    param([int]$StatusCode, [string]$ContentType, [AllowEmptyString()][string]$Body)
    return [pscustomobject]@{ StatusCode = $StatusCode; ContentType = $ContentType; Body = $Body }
}

function New-JsonResponse {
    param([Parameter(Mandatory)][object]$Object, [int]$StatusCode = 200)
    $json = $Object | ConvertTo-Json -Depth 12
    if ($null -eq $json) { $json = 'null' }
    return New-WebResponse -StatusCode $StatusCode -ContentType 'application/json; charset=utf-8' -Body $json
}

function New-ErrorResponse {
    param([int]$StatusCode, [string]$Message)
    return New-JsonResponse -Object ([pscustomobject]@{ ok = $false; error = $Message }) -StatusCode $StatusCode
}

# Infer a content-type from a static file's extension.
function Get-WebMimeType {
    param([string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.htm'  { return 'text/html; charset=utf-8' }
        '.js'   { return 'text/javascript; charset=utf-8' }
        '.mjs'  { return 'text/javascript; charset=utf-8' }
        '.css'  { return 'text/css; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.svg'  { return 'image/svg+xml' }
        '.ico'  { return 'image/x-icon' }
        default { return 'application/octet-stream' }
    }
}

# --- GET handlers ---------------------------------------------------------

# GET /api/gates: every gate_decider == user task across all slugs, mapped to the
# D-S10 shape. design_path is the gate's source doc (its task file, repo-relative).
function Get-WebGates {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $gates = New-Object System.Collections.ArrayList
    $rootFull = [IO.Path]::GetFullPath($RepoRoot)
    Push-Location $RepoRoot
    try {
        foreach ($slug in (Get-WebSlugs -RepoRoot $RepoRoot)) {
            foreach ($g in @(Get-GateQueue -Slug $slug)) {
                $design = $g.TaskFile
                if ($design) {
                    $ff = [IO.Path]::GetFullPath($design)
                    if ($ff.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
                        $design = $ff.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
                    }
                }
                $null = $gates.Add([pscustomobject]@{
                    slug          = $slug
                    task_id       = $g.id
                    kind          = $g.kind
                    gate_decider  = $g.gate_decider
                    gate_action   = $g.gate_action
                    gate_state    = $g.gate_state
                    recurrence_of = $g.recurrence_of
                    title         = $g.title
                    design_path   = $design
                })
            }
        }
    } finally {
        Pop-Location
    }
    return [pscustomobject]@{ gates = @($gates) }
}

# GET /api/loops: live agents from .beat heartbeat freshness (grouped by id
# prefix, the same way the controller counts) plus the controller log tail.
function Get-WebLoops {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [datetime]$NowUtc = [DateTime]::UtcNow,
        [int]$StaleSeconds = 180
    )
    $controllers = New-Object System.Collections.ArrayList
    $workers     = New-Object System.Collections.ArrayList
    $reviewers   = New-Object System.Collections.ArrayList

    foreach ($slug in (Get-WebSlugs -RepoRoot $RepoRoot)) {
        $hbDir = Join-Path (Join-Path (Join-Path (Join-Path $RepoRoot 'planning') $slug) '.locks') 'heartbeats'
        if (-not (Test-Path $hbDir)) { continue }
        foreach ($b in @(Get-ChildItem -Path $hbDir -Filter '*.beat' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $ageSec = [int](($NowUtc - $b.LastWriteTimeUtc).TotalSeconds)
            $entry = [pscustomobject]@{
                id      = $b.BaseName
                slug    = $slug
                age_sec = $ageSec
                state   = $(if ($ageSec -gt $StaleSeconds) { 'STALE' } else { 'FRESH' })
            }
            if ($b.BaseName.StartsWith('worker')) {
                $null = $workers.Add($entry)
            } elseif ($b.BaseName.StartsWith('reviewer')) {
                $null = $reviewers.Add($entry)
            } else {
                $null = $controllers.Add($entry)
            }
        }
    }

    return [pscustomobject]@{
        controllers         = @($controllers)
        workers             = @($workers)
        reviewers           = @($reviewers)
        controller_log_tail = @(Get-WebControllerLogTail -RepoRoot $RepoRoot -Tail 20)
    }
}

# Tail of the most-recent orchestrator log (the controller's running narrative).
function Get-WebControllerLogTail {
    param([Parameter(Mandatory)][string]$RepoRoot, [int]$Tail = 20)
    $logsDir = Join-Path $RepoRoot 'logs'
    if (-not (Test-Path $logsDir)) { return @() }
    $log = Get-ChildItem -Path $logsDir -Filter 'orchestrator-*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $log) { return @() }
    return @(Get-Content -Path $log.FullName -Tail $Tail -ErrorAction SilentlyContinue)
}

# GET /api/logs: allowlisted tail of a logs/ file. The filename must be a bare
# build-log name (no separators, no '..'); the resolved path must stay inside
# logs/. Rejects traversal with 400; missing file with 404.
function Get-WebLogsResponse {
    param([Parameter(Mandatory)][string]$RepoRoot, [string]$File, [string]$Tail)
    $n = 200
    if ($Tail -and ($Tail -match '^\d+$')) { $n = [int]$Tail }
    if ([string]::IsNullOrWhiteSpace($File)) { return (New-ErrorResponse -StatusCode 400 -Message 'missing file parameter') }
    # Reject any path separator or parent-dir token outright (defense before the
    # canonical-containment check below).
    if (($File -match '[\\/]') -or ($File -match '\.\.')) {
        return (New-ErrorResponse -StatusCode 400 -Message 'invalid filename: path traversal rejected')
    }
    if ($File -notmatch '^[A-Za-z0-9._-]+$') {
        return (New-ErrorResponse -StatusCode 400 -Message 'invalid filename')
    }
    # Allowlist to the build-log name prefixes the system produces.
    if ($File -notmatch '^(headless|orchestrator|spawn|pm|weblaunch)') {
        return (New-ErrorResponse -StatusCode 403 -Message 'filename not in the logs allowlist')
    }
    $logsDir  = Join-Path $RepoRoot 'logs'
    $logsFull = [IO.Path]::GetFullPath($logsDir)
    $full     = [IO.Path]::GetFullPath((Join-Path $logsDir $File))
    if (-not $full.StartsWith($logsFull, [StringComparison]::OrdinalIgnoreCase)) {
        return (New-ErrorResponse -StatusCode 400 -Message 'invalid filename: outside logs dir')
    }
    if (-not (Test-Path $full -PathType Leaf)) {
        return (New-ErrorResponse -StatusCode 404 -Message 'log file not found')
    }
    $lines = @(Get-Content -Path $full -Tail $n -ErrorAction SilentlyContinue)
    return (New-JsonResponse -Object ([pscustomobject]@{ file = $File; lines = @($lines) }))
}

# GET /<path>: static file from webui/. '/' maps to index.html. Rejects traversal;
# 404 when the file (or the whole webui/ dir, before T-302) is absent.
function Get-WebStaticResponse {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Path)
    $rel = if ($Path -eq '/' -or [string]::IsNullOrWhiteSpace($Path)) { 'index.html' } else { $Path.TrimStart('/') }
    if ($rel -match '\.\.') { return (New-ErrorResponse -StatusCode 400 -Message 'path traversal rejected') }
    $webuiDir  = Join-Path $RepoRoot 'webui'
    $webuiFull = [IO.Path]::GetFullPath($webuiDir)
    $full      = [IO.Path]::GetFullPath((Join-Path $webuiDir $rel))
    if (-not $full.StartsWith($webuiFull, [StringComparison]::OrdinalIgnoreCase)) {
        return (New-ErrorResponse -StatusCode 403 -Message 'forbidden')
    }
    if (-not (Test-Path $full -PathType Leaf)) {
        return (New-WebResponse -StatusCode 404 -ContentType 'text/plain; charset=utf-8' -Body 'not found')
    }
    return (New-WebResponse -StatusCode 200 -ContentType (Get-WebMimeType -Path $full) -Body ([IO.File]::ReadAllText($full)))
}

# --- POST handlers --------------------------------------------------------

# Resolve the pwsh executable running this process (cross-platform full path).
function Get-WebPwshExe {
    $p = (Get-Process -Id $PID).Path
    if ($p) { return $p }
    return 'pwsh'
}

# POST /api/approve|decline|retry: delegate to the one gate mutator (D-S9).
# Push-Location to RepoRoot so Invoke-GateDecision's CWD-first repo resolution
# lands on the intended tree (makes the handler RepoRoot-driven for the test).
function Invoke-WebGate {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidateSet('approve', 'decline', 'retry')][string]$Decision,
        [object]$Body
    )
    $slug   = if ($Body) { $Body.slug } else { $null }
    $taskId = if ($Body) { $Body.task_id } else { $null }
    $notes  = if ($Body -and $Body.notes) { [string]$Body.notes } else { '' }
    if ([string]::IsNullOrWhiteSpace($slug) -or [string]::IsNullOrWhiteSpace($taskId)) {
        return (New-ErrorResponse -StatusCode 400 -Message 'slug and task_id are required')
    }
    Push-Location $RepoRoot
    try {
        $r = Invoke-GateDecision -Slug $slug -TaskId $taskId -Decision $Decision -Notes $notes
        return (New-JsonResponse -Object ([pscustomobject]@{ ok = $true; status = $r.Status; gate_state = $r.GateState }))
    } catch {
        return (New-ErrorResponse -StatusCode 500 -Message $_.Exception.Message)
    } finally {
        Pop-Location
    }
}

# POST /api/create: run bin/task-create.ps1 (D-S8) as a child and parse its
# `task_id=<T-NNN>` line. The child resolves its repo root from the inherited cwd
# (we Push-Location to RepoRoot first).
function Invoke-WebCreate {
    param([Parameter(Mandatory)][string]$RepoRoot, [object]$Body)
    $text = if ($Body) { [string]$Body.text } else { '' }
    if ([string]::IsNullOrWhiteSpace($text)) {
        return (New-ErrorResponse -StatusCode 400 -Message 'text is required')
    }
    $slug   = if ($Body -and $Body.slug) { [string]$Body.slug } else { 'inbox' }
    $script = Join-Path (Join-Path $RepoRoot 'bin') 'task-create.ps1'
    if (-not (Test-Path $script)) {
        return (New-ErrorResponse -StatusCode 500 -Message 'task-create.ps1 not found')
    }
    $pwsh = Get-WebPwshExe
    Push-Location $RepoRoot
    try {
        $out = & $pwsh -NoProfile -File $script -Text $text -Slug $slug 2>$null
    } finally {
        Pop-Location
    }
    $taskId = $null
    foreach ($line in @($out)) {
        if ($line -match '^task_id=(.+)$') { $taskId = $matches[1].Trim() }
    }
    if ($taskId) {
        return (New-JsonResponse -Object ([pscustomobject]@{ ok = $true; task_id = $taskId }))
    }
    return (New-ErrorResponse -StatusCode 500 -Message 'task-create produced no task_id')
}

# POST /api/launch: spawn orchestrator-loop.ps1 for the slug, detached and
# env-stripped (mirrors launch-build.ps1 so each nested claude gets a fresh
# session id). Returns the spawned pid.
function Invoke-WebLaunch {
    param([Parameter(Mandatory)][string]$RepoRoot, [object]$Body)
    $slug = if ($Body) { [string]$Body.slug } else { '' }
    if ([string]::IsNullOrWhiteSpace($slug)) {
        return (New-ErrorResponse -StatusCode 400 -Message 'slug is required')
    }
    $script = Join-Path (Join-Path $RepoRoot 'bin') 'orchestrator-loop.ps1'
    if (-not (Test-Path $script)) {
        return (New-ErrorResponse -StatusCode 500 -Message 'orchestrator-loop.ps1 not found')
    }
    # Strip the parent Claude session env so the spawned controller's nested
    # agents get their own session ids (see launch-build.ps1 rationale).
    foreach ($v in @('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SSE_PORT', 'CLAUDE_CODE_SESSION_ID')) {
        if (Test-Path "env:$v") { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
    }
    $pwsh   = Get-WebPwshExe
    $logDir = Join-Path $RepoRoot 'logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $stamp   = Get-Date -Format 'yyyyMMddHHmmss'
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $script + '" ' + $slug
    $spArgs  = @{
        FilePath               = $pwsh
        ArgumentList           = $argLine
        PassThru               = $true
        WorkingDirectory       = $RepoRoot
        RedirectStandardOutput = (Join-Path $logDir ("weblaunch-" + $slug + "-" + $stamp + ".out.log"))
        RedirectStandardError  = (Join-Path $logDir ("weblaunch-" + $slug + "-" + $stamp + ".err.log"))
    }
    # -WindowStyle is Windows-only; Linux pwsh throws. Add it conditionally via
    # the splat (bareword key, not the -WindowStyle parameter token).
    if ($IsWindows) { $spArgs['WindowStyle'] = 'Hidden' }
    $proc = Start-Process @spArgs
    return (New-JsonResponse -Object ([pscustomobject]@{ ok = $true; slug = $slug; pid = $proc.Id }))
}

# POST /api/stop: drop the controller stop sentinel for the slug. The running
# controller exits on its next tick when it sees controller.headless-stop.
function Invoke-WebStop {
    param([Parameter(Mandatory)][string]$RepoRoot, [object]$Body)
    $slug = if ($Body) { [string]$Body.slug } else { '' }
    if ([string]::IsNullOrWhiteSpace($slug)) {
        return (New-ErrorResponse -StatusCode 400 -Message 'slug is required')
    }
    $locksDir = Join-Path (Join-Path (Join-Path $RepoRoot 'planning') $slug) '.locks'
    New-Item -ItemType Directory -Path $locksDir -Force | Out-Null
    $stopFile = Join-Path $locksDir 'controller.headless-stop'
    $body = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') + [Environment]::NewLine
    [IO.File]::WriteAllBytes($stopFile, [Text.UTF8Encoding]::new($false).GetBytes($body))
    return (New-JsonResponse -Object ([pscustomobject]@{ ok = $true; slug = $slug }))
}

# --- the router -----------------------------------------------------------

# Map a single request to a response. Dot-source the script and call this
# directly in tests -- no socket required. POST mutations reject non-loopback
# remote addresses (defense in depth even though the server binds loopback).
function Invoke-ControlPlaneRoute {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query = @{},
        [object]$Body = $null,
        [bool]$IsLoopback = $true,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $m = $Method.ToUpperInvariant()

    if ($m -eq 'GET') {
        switch -Regex ($Path) {
            '^/api/board$' { return (New-JsonResponse -Object (Get-MasterBoard -RepoRoot $RepoRoot)) }
            '^/api/gates$' { return (New-JsonResponse -Object (Get-WebGates -RepoRoot $RepoRoot)) }
            '^/api/loops$' {
                $stale = Get-WebStaleSeconds -RepoRoot $RepoRoot -Slug 'control-plane'
                return (New-JsonResponse -Object (Get-WebLoops -RepoRoot $RepoRoot -StaleSeconds $stale))
            }
            '^/api/logs$' { return (Get-WebLogsResponse -RepoRoot $RepoRoot -File $Query['file'] -Tail $Query['tail']) }
            '^/api/' { return (New-ErrorResponse -StatusCode 404 -Message 'unknown API route') }
            default { return (Get-WebStaticResponse -RepoRoot $RepoRoot -Path $Path) }
        }
    }

    if ($m -eq 'POST') {
        if (-not $IsLoopback) {
            return (New-ErrorResponse -StatusCode 403 -Message 'forbidden: non-loopback remote address')
        }
        switch -Regex ($Path) {
            '^/api/approve$' { return (Invoke-WebGate -RepoRoot $RepoRoot -Decision 'approve' -Body $Body) }
            '^/api/decline$' { return (Invoke-WebGate -RepoRoot $RepoRoot -Decision 'decline' -Body $Body) }
            '^/api/retry$'   { return (Invoke-WebGate -RepoRoot $RepoRoot -Decision 'retry'   -Body $Body) }
            '^/api/create$'  { return (Invoke-WebCreate -RepoRoot $RepoRoot -Body $Body) }
            '^/api/launch$'  { return (Invoke-WebLaunch -RepoRoot $RepoRoot -Body $Body) }
            '^/api/stop$'    { return (Invoke-WebStop -RepoRoot $RepoRoot -Body $Body) }
            default          { return (New-ErrorResponse -StatusCode 404 -Message 'unknown API route') }
        }
    }

    return (New-ErrorResponse -StatusCode 405 -Message 'method not allowed')
}

# --- wire glue (live server only) -----------------------------------------

# Write a router result to an HttpListenerResponse.
function Write-WebResponse {
    param([Parameter(Mandatory)][object]$Response, [Parameter(Mandatory)][object]$Result)
    $Response.StatusCode  = [int]$Result.StatusCode
    $Response.ContentType = $Result.ContentType
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$Result.Body)
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

# --- direct invocation: start the listener --------------------------------

# Dot-sourcing (InvocationName '.') defines the functions only and skips this.
if ($MyInvocation.InvocationName -ne '.') {
    $repoRoot = if ($cliRepoRoot) { $cliRepoRoot } else { Find-WebRepoRoot }
    if (-not $repoRoot) {
        [Console]::Error.WriteLine('control-plane-web: could not locate repo root (no .git/planning in cwd ancestors).')
        exit 1
    }
    Set-Location $repoRoot

    $port   = Resolve-WebPort -RepoRoot $repoRoot -Slug $cliSlug -Override $cliPort
    $prefix = 'http://127.0.0.1:' + $port + '/'

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($prefix)
    try {
        $listener.Start()
    } catch {
        [Console]::Error.WriteLine("control-plane-web: failed to bind $prefix : $($_.Exception.Message)")
        exit 1
    }
    Write-Host ("control-plane-web: listening on {0} (repo: {1}); Ctrl-C to stop." -f $prefix, $repoRoot)

    try {
        while ($listener.IsListening) {
            $ctx = $listener.GetContext()
            try {
                $req = $ctx.Request

                $query = @{}
                foreach ($k in $req.QueryString.AllKeys) {
                    if ($k) { $query[$k] = $req.QueryString[$k] }
                }

                $bodyObj = $null
                if ($req.HttpMethod.ToUpperInvariant() -eq 'POST') {
                    $reader = [IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
                    try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    if (-not [string]::IsNullOrWhiteSpace($raw)) {
                        try { $bodyObj = $raw | ConvertFrom-Json } catch { $bodyObj = $null }
                    }
                }

                $result = Invoke-ControlPlaneRoute `
                    -Method $req.HttpMethod `
                    -Path $req.Url.AbsolutePath `
                    -Query $query `
                    -Body $bodyObj `
                    -IsLoopback ([bool]$req.IsLocal) `
                    -RepoRoot $repoRoot

                Write-WebResponse -Response $ctx.Response -Result $result
            } catch {
                try {
                    Write-WebResponse -Response $ctx.Response -Result (New-ErrorResponse -StatusCode 500 -Message $_.Exception.Message)
                } catch { }
            } finally {
                try { $ctx.Response.OutputStream.Close() } catch { }
            }
        }
    } finally {
        if ($listener.IsListening) { $listener.Stop() }
        $listener.Close()
    }
    exit 0
}
