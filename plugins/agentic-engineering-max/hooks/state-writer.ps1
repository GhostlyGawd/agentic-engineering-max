# state-writer.ps1
#
# Hook: SessionEnd
# Purpose:
#   Autonomous one-commit-per-session state writer. On every session end, if
#   meaningful work happened in the session, bump Last updated: in every
#   managed slug's plan-state.md, rewrite README.md's Current state + Next
#   action sections from those plan-state.md files, append a forensic line
#   to each touched slug's .state-auto-log, then run ONE git add + git
#   commit covering exactly those files. (Spec D-S10 / PRD Sec 7.3.)
#
# This is SessionEnd. Do NOT add a Stop hook fallback. The Falsificationist's
# refusal (PRD Sec 12 D5) is encoded as cross-task invariant 5: any belt-and-
# suspenders Stop fallback would mask SessionEnd channel failures forever.
# The v1 UserPromptSubmit drift-check at ~/.claude/hooks/state-drift-check.ps1
# is the documented recovery channel. Nothing else.
#
# Allowlist (v1): D:\GitHub Projects\Dev_006 only. Out-of-allowlist invocation
# exits 0 silently with no writes. If $PWD is outside the repo (SessionStart
# may fire from anywhere), a literal allowlist fallback re-resolves the root.
#
# Meaningful-work heuristic (any one TRUE -> we write):
#   1. git rev-list --count <merge-base..HEAD> on current branch > 0
#      (skipped on `main` / `HEAD` detached; checks 2-3 cover those cases)
#   2. git status --porcelain emits any line (unstaged or untracked changes)
#   3. Any planning/<slug>/tasks/*.md mtime within the last 4 hours
#   When invoked with -ForceWrite (SessionStart-sweep uses this), the
#   heuristic is bypassed: the sweep's git-log gap detection IS the work
#   signal; re-checking via heuristic would deadlock the recovery channel on
#   `main` where heuristic check 1 always falls through silently.
#
# .state-auto-log line format (one line per write, per slug):
#   <ISO>  trigger=<SessionEnd|SessionStart-sweep>  files=<comma-list>  rationale=<one-line>  session=<session_id>
#
# Interpretive choices (places where the spec is under-determined):
#   A. session=<session_id> instead of D-S10's literal commit=<sha>. The log
#      line is part of the same commit it describes; embedding the resulting
#      SHA inside the file the SHA hashes is mathematically impossible (the
#      SHA depends on file content; file content depends on the SHA). The
#      D-S10 commit-message format ("state-writer: auto-update for session
#      <id> at <ISO>") makes the mapping from session_id to SHA unambiguous
#      via `git log --grep="session <id>"`. T-W2-006 audit tooling consumes
#      this format. SPEC AMENDMENT NEEDED: D-S10 line 284.
#   B. Minimal plan-state.md mutation: bumps only Last updated. Spec line 433
#      says "overwrite, the 8-field schema"; spec line 443 (Notes) says
#      "leave others unchanged unless commit history clearly indicates
#      otherwise." This implementation harmonizes to the Notes reading.
#      Phase-owning agents (plan-interviewer, PRD writer, spec writer,
#      wave-closer) are the authoritative writers of the other seven fields.
#   C. README body schema invented (multi-slug bullet summary per slug's
#      Status / Next action). Spec D-S10 leaves the body format under-
#      determined; this implementation chose per-slug mirror so the README
#      stays useful as a fresh-session orientation surface. T-W1-009 / Wave 2
#      dogfood will surface revisions.
#   D. Heading rewrites symmetric: both ## Current state and ## Next action
#      headings preserved verbatim (no date suffix on either).
#
# Functions defined here are dot-sourceable by state-writer-sweep.ps1; set
# $env:STATE_WRITER_LIB_ONLY=1 before dot-sourcing to suppress the main block.

$ErrorActionPreference = 'Continue'

# ---------- Library functions ----------

function Get-AllowedRepoRoot {
    # Resolve repo root by walking up from $PWD; allowlist-gate against the
    # known managed repo. If the walk-up fails (e.g., SessionStart fires from
    # outside the repo), fall back to the literal allowlist entries so the
    # recovery channel remains observable.
    $allowlist = @('D:\GitHub Projects\Dev_006')

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

    if ($repoRoot) {
        $norm = $repoRoot.TrimEnd('\','/')
        foreach ($entry in $allowlist) {
            if ($entry.TrimEnd('\','/').Equals($norm, [StringComparison]::OrdinalIgnoreCase)) {
                return $repoRoot
            }
        }
    }

    # Walk-up failed or hit an unallowed root. Try the allowlist literally.
    foreach ($entry in $allowlist) {
        if (Test-Path (Join-Path $entry '.git')) {
            return $entry
        }
    }
    return $null
}

function Get-StateWriterSessionId {
    # D-S2 priority: env CLAUDE_SESSION_ID -> env CLAUDECODE_SESSION_ID -> pid-<PID>.
    if ($env:CLAUDE_SESSION_ID) { return $env:CLAUDE_SESSION_ID }
    if ($env:CLAUDECODE_SESSION_ID) { return $env:CLAUDECODE_SESSION_ID }
    return "pid-$PID"
}

function Get-ManagedSlugs {
    # A managed slug is any planning/<slug>/ directory containing at least one
    # of plan-state.md, plan-ledger.md, or prd.md. Sorted alphabetically so
    # forensic diffs across sessions stay stable.
    param([string]$RepoRoot)
    $planningRoot = Join-Path $RepoRoot 'planning'
    if (-not (Test-Path $planningRoot)) { return @() }

    $slugs = @()
    foreach ($dir in (Get-ChildItem -Path $planningRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        foreach ($candidate in @('plan-state.md','plan-ledger.md','prd.md')) {
            if (Test-Path (Join-Path $dir.FullName $candidate)) {
                $slugs += $dir.Name
                break
            }
        }
    }
    return $slugs
}

function Test-MeaningfulWork {
    # Returns $true if any of the 3 D-S10 heuristic checks passes. Skipped
    # entirely when -ForceWrite is set (caller has already established work
    # via a stronger signal, typically the sweep's git-log gap detection).
    param([string]$RepoRoot, [string[]]$Slugs)

    # 1. git rev-list count > 0 vs. main (only meaningful on feature branches).
    #    On `main` or detached HEAD this check is silently skipped; checks 2-3
    #    catch the same-branch and uncommitted cases. Documented narrowing.
    $branchArgs = @('-C', $RepoRoot, 'rev-parse', '--abbrev-ref', 'HEAD')
    $branch = (& git @branchArgs 2>$null)
    if ($LASTEXITCODE -eq 0 -and $branch) {
        $branch = $branch.Trim()
        if ($branch -and $branch -ne 'main' -and $branch -ne 'HEAD') {
            $mbArgs = @('-C', $RepoRoot, 'merge-base', 'main', $branch)
            $mb = (& git @mbArgs 2>$null)
            if ($LASTEXITCODE -eq 0 -and $mb) {
                $mb = $mb.Trim()
                $rvArgs = @('-C', $RepoRoot, 'rev-list', '--count', "$mb..HEAD")
                $cnt = (& git @rvArgs 2>$null)
                if ($LASTEXITCODE -eq 0 -and $cnt -and ([int]$cnt.Trim()) -gt 0) {
                    return $true
                }
            }
        }
    }

    # 2. git status --porcelain non-empty
    $stArgs = @('-C', $RepoRoot, 'status', '--porcelain')
    $st = (& git @stArgs 2>$null)
    if ($LASTEXITCODE -eq 0 -and $st) {
        $stClean = ($st | Where-Object { $_ -and $_.Trim() })
        if ($stClean) { return $true }
    }

    # 3. tasks/*.md mtime within last 4 hours
    $cutoff = (Get-Date).AddHours(-4)
    foreach ($slug in $Slugs) {
        $tasksDir = Join-Path $RepoRoot ("planning/" + $slug + "/tasks")
        if (-not (Test-Path $tasksDir)) { continue }
        $recent = Get-ChildItem -Path $tasksDir -Filter 'task-*.md' -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.LastWriteTime -gt $cutoff }
        if ($recent) { return $true }
    }

    return $false
}

function Read-PlanStateFields {
    # Read the 8-field schema from plan-state.md. Returns an ordered hashtable
    # with the canonical key names. Missing fields default to ''.
    param([string]$Path)

    $fm = [ordered]@{
        'Status'               = ''
        'Lifecycle stage'      = ''
        'Last updated'         = ''
        'Latest PRD version'   = ''
        'Latest spec version'  = ''
        'Open-PR stack'        = ''
        'Next action'          = ''
        'Scorecard summary'    = ''
    }
    if (-not (Test-Path $Path)) { return $fm }

    $raw = Get-Content -Raw -Encoding utf8 -Path $Path -ErrorAction SilentlyContinue
    if (-not $raw) { return $fm }

    foreach ($key in @($fm.Keys)) {
        $escaped = [regex]::Escape($key)
        $pattern = "(?im)^$escaped`:\s*(.*)$"
        $m = [regex]::Match($raw, $pattern)
        if ($m.Success) {
            $fm[$key] = $m.Groups[1].Value.Trim()
        }
    }
    return $fm
}

function Compute-PlanStateRewrite {
    # Pure: read current plan-state.md, return the rewritten content with
    # Last updated bumped to $IsoDate. Returns $null if the file is missing
    # or no change is needed (caller treats absence/no-change as a no-op).
    param([string]$Path, [string]$IsoDate)

    if (-not (Test-Path $Path)) { return $null }
    $raw = Get-Content -Raw -Encoding utf8 -Path $Path -ErrorAction SilentlyContinue
    if (-not $raw) { return $null }

    $newRaw = [regex]::Replace(
        $raw,
        '(?im)^(Last updated:\s*).*$',
        "Last updated: $IsoDate",
        1
    )
    return $newRaw
}

function Build-ReadmeStateBody {
    # Construct the body that replaces ## Current state's content. Multi-slug
    # bullet summary derived from each plan-state.md's Status field, plus an
    # auto-write marker for forensic traceability.
    param([string]$RepoRoot, [string[]]$Slugs, [string]$IsoStamp)

    $lines = @()
    $lines += ''
    $lines += "(auto-written by state-writer at $IsoStamp)"
    $lines += ''
    foreach ($slug in $Slugs) {
        $statePath = Join-Path $RepoRoot ("planning/" + $slug + "/plan-state.md")
        $fields = Read-PlanStateFields -Path $statePath
        $status = if ($fields['Status']) { $fields['Status'] } else { '(no Status field)' }
        $lines += "- ``planning/$slug/``: $status"
    }
    $lines += ''
    return ($lines -join "`n")
}

function Build-ReadmeNextActionBody {
    param([string]$RepoRoot, [string[]]$Slugs, [string]$IsoStamp)

    $lines = @()
    $lines += ''
    $lines += "(auto-written by state-writer at $IsoStamp; one bullet per managed slug from its plan-state.md Next action field.)"
    $lines += ''
    foreach ($slug in $Slugs) {
        $statePath = Join-Path $RepoRoot ("planning/" + $slug + "/plan-state.md")
        $fields = Read-PlanStateFields -Path $statePath
        $nxt = if ($fields['Next action']) { $fields['Next action'] } else { '(no Next action field)' }
        $lines += "- ``planning/$slug/``: $nxt"
    }
    $lines += ''
    return ($lines -join "`n")
}

function Compute-ReadmeRewrite {
    # Pure: read current README.md, return rewritten content with Current
    # state + Next action bodies replaced. Returns $null if README is missing.
    param(
        [string]$ReadmePath,
        [string]$CurrentStateBody,
        [string]$NextActionBody
    )

    if (-not (Test-Path $ReadmePath)) { return $null }
    $raw = Get-Content -Raw -Encoding utf8 -Path $ReadmePath -ErrorAction SilentlyContinue
    if (-not $raw) { return $null }

    function Replace-Section {
        param([string]$Text, [string]$HeadingPattern, [string]$NewHeading, [string]$NewBody)
        $pattern = "(?ims)^(##\s+$HeadingPattern[^\r\n]*)\r?\n(.*?)(?=^##\s|\z)"
        $m = [regex]::Match($Text, $pattern)
        if (-not $m.Success) { return $Text }
        $replacement = $NewHeading + "`n" + $NewBody + "`n"
        return $Text.Substring(0, $m.Index) + $replacement + $Text.Substring($m.Index + $m.Length)
    }

    # Symmetric heading treatment: both headings preserved verbatim (no date
    # suffix). Phase-owning agents may rename the heading if they want; the
    # writer doesn't impose a date stamp.
    $newRaw = Replace-Section -Text $raw `
        -HeadingPattern 'current\s+state' `
        -NewHeading '## Current state' `
        -NewBody $CurrentStateBody

    $newRaw = Replace-Section -Text $newRaw `
        -HeadingPattern 'next\s+action' `
        -NewHeading '## Next action' `
        -NewBody $NextActionBody

    return $newRaw
}

# BOM-less UTF-8 encoder. PS5.1's `Set-Content -Encoding utf8` writes a BOM,
# while `Get-Content -Raw -Encoding utf8` strips one if present. That
# asymmetry means a Get/Set round-trip on a BOM-less file inserts a BOM,
# making rollback non-byte-faithful and re-firing the sweep on the next
# session. Using `[IO.File]` APIs with an explicit BOM-less encoder keeps
# the cache, the write, and the rollback all on the same byte rails.
$script:Utf8NoBom = New-Object Text.UTF8Encoding $false

function Append-StateAutoLog {
    # Append a single line (plus terminating newline) to the slug's
    # .state-auto-log. Returns $false if the parent dir doesn't exist
    # (caller treats as a forensic gap and logs to stderr).
    param([string]$LogPath, [string]$Line)
    $dir = Split-Path -Parent $LogPath
    if (-not (Test-Path $dir)) { return $false }
    if (-not (Test-Path $LogPath)) {
        [IO.File]::WriteAllText($LogPath, $Line + "`n", $script:Utf8NoBom)
    } else {
        [IO.File]::AppendAllText($LogPath, $Line + "`n", $script:Utf8NoBom)
    }
    return $true
}

function Read-CacheBytes {
    # Snapshot a file's raw bytes for transactional rollback. Returns $null
    # when the file does not exist (caller distinguishes "file did not exist"
    # from "file existed but was empty"; only the former triggers a Remove
    # on rollback).
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return [IO.File]::ReadAllBytes($Path)
}

function Restore-FromCache {
    # Transactional rollback: restore working tree to pre-write state from
    # the in-memory byte cache. For files that existed: write the cached
    # bytes back verbatim. For files that didn't exist (cache value $null):
    # delete. Byte-faithful regardless of source BOM / trailing-newline shape.
    param([hashtable]$Cache)
    foreach ($path in @($Cache.Keys)) {
        $original = $Cache[$path]
        if ($null -eq $original) {
            if (Test-Path $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        } else {
            [IO.File]::WriteAllBytes($path, $original)
        }
    }
}

function Test-StaleGitIndexLock {
    # Stale `.git/index.lock` orphan detection. Two failure modes documented
    # in wave-1-channel-test.md Notes section surface as the same symptom:
    #   (A) writer exited via rollback path with the lock still held;
    #   (B) writer killed by Claude Code shutdown or OS timeout between
    #       successful `git add` (which acquired the lock) and `git commit`.
    # Returns the FileInfo when stale; $null otherwise. Two independent gates
    # protect legitimate concurrent git operations from accidental removal:
    #   1. Age threshold: legit git ops typically release the lock in well
    #      under N seconds (default 30). A long-running legit op (clone, gc)
    #      can exceed this; gate 2 covers that case.
    #   2. Live `git` process check: if ANY git.exe is running, leave the
    #      lock alone regardless of age. Conservative no-op.
    param(
        [string]$RepoRoot,
        [int]$AgeThresholdSeconds = 30
    )
    $lockPath = Join-Path $RepoRoot '.git\index.lock'
    if (-not (Test-Path $lockPath)) { return $null }
    $lockFile = Get-Item -LiteralPath $lockPath -ErrorAction SilentlyContinue
    if (-not $lockFile) { return $null }
    $ageSec = ((Get-Date) - $lockFile.LastWriteTime).TotalSeconds
    if ($ageSec -lt $AgeThresholdSeconds) { return $null }
    $liveGit = Get-Process -Name 'git' -ErrorAction SilentlyContinue
    if ($liveGit) { return $null }
    return $lockFile
}

function Remove-StaleGitIndexLock {
    # Remove a stale `.git/index.lock` and append a forensic line to the
    # supplied .state-auto-log path documenting the action. Returns $true on
    # success, $false on remove failure (caller continues to `git add`; git
    # will surface its own loud error there, which the existing transactional
    # rollback path handles).
    param(
        [string]$LogPath,
        [string]$IsoStamp,
        [string]$Trigger,
        [string]$SessionId,
        [System.IO.FileInfo]$LockFile
    )
    $ageSec = [int]((Get-Date) - $LockFile.LastWriteTime).TotalSeconds
    try {
        Remove-Item -LiteralPath $LockFile.FullName -Force -ErrorAction Stop
    } catch {
        $errLine = "$IsoStamp  ERROR  trigger=$Trigger  rationale=stale-index-lock-remove-failed; age=${ageSec}s  session=$SessionId"
        Append-StateAutoLog -LogPath $LogPath -Line $errLine | Out-Null
        return $false
    }
    $line = "$IsoStamp  trigger=$Trigger  action=removed-stale-index-lock  rationale=lock-age=${ageSec}s; no-live-git  session=$SessionId"
    Append-StateAutoLog -LogPath $LogPath -Line $line | Out-Null
    return $true
}

function Invoke-StateWriterCore {
    # Shared write+commit path used by both SessionEnd and SessionStart-sweep.
    # Transactional: any git failure rolls back working-tree changes from
    # the in-memory cache. $Trigger goes into .state-auto-log lines verbatim.
    # -ForceWrite bypasses Test-MeaningfulWork; the sweep uses this because
    # its git-log gap detection is a strictly stronger signal than the
    # heuristic, which would otherwise silently no-op on `main`.
    param(
        [string]$Trigger = 'SessionEnd',
        [bool]$ForceWrite = $false
    )

    $repoRoot = Get-AllowedRepoRoot
    if (-not $repoRoot) { return }

    $slugs = Get-ManagedSlugs -RepoRoot $repoRoot
    if (-not $slugs -or $slugs.Count -eq 0) { return }

    if (-not $ForceWrite) {
        if (-not (Test-MeaningfulWork -RepoRoot $repoRoot -Slugs $slugs)) { return }
    }

    $nowUtc       = [DateTime]::UtcNow
    $isoStamp     = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $todayIsoDate = $nowUtc.ToString('yyyy-MM-dd')
    $sessionId    = Get-StateWriterSessionId
    $rationale    = "trigger=$Trigger; slugs=" + ($slugs -join ',')

    # Phase 1: cache pre-write content (raw bytes, BOM-preserving) for every
    # file we might modify. Raw-byte caching is required for byte-faithful
    # rollback under PS5.1's BOM-emitting default encoder.
    $cache       = @{}  # path -> pre-write raw bytes ($null if file didn't exist)
    $statePaths  = New-Object System.Collections.ArrayList
    $logPaths    = New-Object System.Collections.ArrayList
    $readmePath  = Join-Path $repoRoot 'README.md'

    foreach ($slug in $slugs) {
        $sp = Join-Path $repoRoot ("planning/" + $slug + "/plan-state.md")
        $lp = Join-Path $repoRoot ("planning/" + $slug + "/.state-auto-log")
        $cache[$sp] = Read-CacheBytes -Path $sp
        $cache[$lp] = Read-CacheBytes -Path $lp
        $null = $statePaths.Add($sp)
        $null = $logPaths.Add($lp)
    }
    $cache[$readmePath] = Read-CacheBytes -Path $readmePath

    # Phase 2: compute new content for every file (still in memory).
    $newContent = @{}
    foreach ($sp in $statePaths) {
        $rewritten = Compute-PlanStateRewrite -Path $sp -IsoDate $todayIsoDate
        if ($null -ne $rewritten) { $newContent[$sp] = $rewritten }
    }

    $currentStateBody = Build-ReadmeStateBody -RepoRoot $repoRoot -Slugs $slugs -IsoStamp $isoStamp
    $nextActionBody   = Build-ReadmeNextActionBody -RepoRoot $repoRoot -Slugs $slugs -IsoStamp $isoStamp
    $readmeRewrite = Compute-ReadmeRewrite -ReadmePath $readmePath `
                                            -CurrentStateBody $currentStateBody `
                                            -NextActionBody $nextActionBody
    if ($null -ne $readmeRewrite) { $newContent[$readmePath] = $readmeRewrite }

    # Phase 3: write new content to disk via [IO.File]::WriteAllText with the
    # script-scoped BOM-less UTF-8 encoder. Compute-*-Rewrite functions
    # preserve source files' trailing-newline state, so byte content is
    # exactly what we want on disk; the encoder avoids BOM-injection. No-op
    # writes are skipped via byte-compare against the cached pre-write bytes.
    $modifiedFiles = New-Object System.Collections.ArrayList
    foreach ($path in @($newContent.Keys)) {
        $new       = $newContent[$path]
        $newBytes  = $script:Utf8NoBom.GetBytes($new)
        $oldBytes  = $cache[$path]
        if ($null -ne $oldBytes -and $oldBytes.Length -eq $newBytes.Length) {
            $same = $true
            for ($i = 0; $i -lt $oldBytes.Length; $i++) {
                if ($oldBytes[$i] -ne $newBytes[$i]) { $same = $false; break }
            }
            if ($same) { continue }
        }
        [IO.File]::WriteAllBytes($path, $newBytes)
        $null = $modifiedFiles.Add($path)
    }

    # Phase 4: append the .state-auto-log line for every managed slug.
    $relStateFiles = @($modifiedFiles | ForEach-Object {
        $p = $_
        if ($p.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $p.Substring($repoRoot.Length).TrimStart('\','/').Replace('\','/')
        } else { $p }
    })
    $fileList = if ($relStateFiles.Count -gt 0) { $relStateFiles -join ',' } else { '(none)' }

    $loggedSlugs = New-Object System.Collections.ArrayList
    foreach ($i in 0..($slugs.Count - 1)) {
        $slug    = $slugs[$i]
        $logPath = $logPaths[$i]
        $line    = "$isoStamp  trigger=$Trigger  files=$fileList  rationale=$rationale  session=$sessionId"
        if (Append-StateAutoLog -LogPath $logPath -Line $line) {
            $null = $loggedSlugs.Add($logPath)
        } else {
            [Console]::Error.WriteLine("state-writer: WARN parent dir missing for $logPath; skipping log append for slug=$slug")
        }
    }

    # Phase 5: stage + commit (one shot). On any failure, revert from cache.
    $allPaths = @()
    foreach ($p in $modifiedFiles) { $allPaths += $p }
    foreach ($p in $loggedSlugs)   { $allPaths += $p }
    if ($allPaths.Count -eq 0) {
        # No state changes AND no log lines (the latter only happens when
        # every slug had a missing parent dir, which is exotic). Nothing to
        # commit; nothing to revert.
        return
    }

    $allRel = @($allPaths | ForEach-Object {
        $p = $_
        if ($p.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $p.Substring($repoRoot.Length).TrimStart('\','/').Replace('\','/')
        } else { $p }
    })

    # Pre-flight: clear stale `.git/index.lock` orphans before `git add`.
    # Covers both failure modes documented in wave-1-channel-test.md Notes:
    # (A) prior writer rolled back with the lock still held, and (B) prior
    # writer killed between `git add` and `git commit`. Both surface here as
    # the same symptom; Test-StaleGitIndexLock's age + live-git gates protect
    # legitimate concurrent git ops from accidental removal. The forensic
    # line lands in the orchestrator slug's .state-auto-log, which is already
    # in $allPaths from Phase 4, so the removal record rides this commit.
    $stale = Test-StaleGitIndexLock -RepoRoot $repoRoot
    if ($stale) {
        $orchestratorLog = Join-Path $repoRoot 'planning/orchestrator-and-build-system/.state-auto-log'
        if (Test-Path (Split-Path -Parent $orchestratorLog)) {
            Remove-StaleGitIndexLock -LogPath $orchestratorLog -IsoStamp $isoStamp -Trigger $Trigger -SessionId $sessionId -LockFile $stale | Out-Null
        }
    }

    $addArgs = @('-C', $repoRoot, 'add', '--') + $allRel
    & git @addArgs 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $errLine = "$isoStamp  ERROR  trigger=$Trigger  rationale=git-add-failed  session=$sessionId"
        Restore-FromCache -Cache $cache
        Append-StateAutoLog -LogPath (Join-Path $repoRoot 'planning/orchestrator-and-build-system/.state-auto-log') -Line $errLine | Out-Null
        return
    }

    # Verify there is something staged before committing (git add can succeed
    # while staging zero new bytes if the working tree is byte-identical to
    # HEAD for these paths).
    $diffArgs = @('-C', $repoRoot, 'diff', '--cached', '--quiet', '--') + $allRel
    & git @diffArgs 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        # Nothing actually staged. Revert any working-tree-only edits to keep
        # disk byte-identical to HEAD (so the next sweep doesn't mistake us
        # for an aborted SessionEnd).
        Restore-FromCache -Cache $cache
        return
    }

    $msg = "state-writer: auto-update for session $sessionId at $isoStamp"
    $commitArgs = @('-C', $repoRoot, 'commit', '-m', $msg, '--') + $allRel
    & git @commitArgs 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # Commit refused (pre-commit hook, gpg failure, identity unset, ...).
        # Unstage and revert working tree so the next sweep correctly sees the
        # session as never having written.
        $resetArgs = @('-C', $repoRoot, 'reset', 'HEAD', '--') + $allRel
        & git @resetArgs 2>$null | Out-Null
        Restore-FromCache -Cache $cache
        $errLine = "$isoStamp  ERROR  trigger=$Trigger  rationale=git-commit-refused  session=$sessionId"
        # Best-effort error record: only safe if the orchestrator slug's dir
        # still exists (it does in v1; the allowlist guarantees one repo).
        $errLogPath = Join-Path $repoRoot 'planning/orchestrator-and-build-system/.state-auto-log'
        Append-StateAutoLog -LogPath $errLogPath -Line $errLine | Out-Null
        return
    }
}

function Invoke-StateWriter {
    param(
        [string]$Trigger = 'SessionEnd',
        [bool]$ForceWrite = $false
    )
    try {
        Invoke-StateWriterCore -Trigger $Trigger -ForceWrite:$ForceWrite
    } catch {
        $msg = $_.Exception.Message -replace "`r?`n", '; '
        if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 297) + '...' }
        $errLine = "$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))  ERROR  trigger=$Trigger  $msg"
        try {
            $repoRoot = Get-AllowedRepoRoot
            if ($repoRoot) {
                $fallback = Join-Path $repoRoot 'planning/orchestrator-and-build-system/.state-auto-log'
                if (Test-Path (Split-Path -Parent $fallback)) {
                    Append-StateAutoLog -LogPath $fallback -Line $errLine | Out-Null
                } else {
                    [Console]::Error.WriteLine($errLine)
                }
            } else {
                [Console]::Error.WriteLine($errLine)
            }
        } catch {
            [Console]::Error.WriteLine($errLine)
        }
    }
}

# ---------- Main block (suppressed when dot-sourced as library) ----------

if (-not $env:STATE_WRITER_LIB_ONLY) {
    $null = [Console]::In.ReadToEnd()
    Invoke-StateWriter -Trigger 'SessionEnd'
    exit 0
}
