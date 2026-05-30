# state-drift-check.ps1
# Hook: UserPromptSubmit
#   Originally specified as Stop, but the Claude Code runtime's Stop output
#   schema does not accept hookSpecificOutput.additionalContext; that channel
#   is valid only for UserPromptSubmit / PreToolUse / PostToolUse / PostToolBatch.
#   Migrated to UserPromptSubmit so drift warnings are properly injected into
#   the next-turn model context. Semantically near-identical (every Stop is
#   followed by a UserPromptSubmit); arguably better since the check runs
#   against the state the model is about to act on.
# Purpose: Detect drift between plan-state.md and plan-ledger.md, version-pointer
#   drift, and missing referenced agents; nudge for wave-closer when an
#   implementation wave appears closed.
#
# Checks:
#   A. ledger-newer-than-state
#   B. version-pointer drift (PRD + spec)
#   C. missing referenced agents (consumer ~/.claude/agents OR plugin agents/)
#   E. stale Next-action/Open-PR-stack branch already merged into main
#   F. post-merge Lifecycle stage staleness (build|release|publish/<slug> merged)
#   G. gate-surface drift (gate queue drained but Next-action says "go decide")
#   (Former Check D / README schema removed 2026-05-12: fresh Claude sessions
#    read plan-state.md directly via Glob and never consult README.)
#
# Sidecar config (optional): <user-home>/.claude/hooks/state-drift-check.config.json
#   Recognized keys (v1.1):
#     ledger_state_buffer_minutes      integer  default 5
#       Tolerance window for the "ledger newer than state" drift check.
#     wave_detection_window_minutes    integer  default 60
#       Time window for the wave-N git-log scan. Wider than ledger buffer because a
#       review cycle (multi-stance review then close) typically runs longer than
#       five minutes; reusing the ledger buffer as the wave window made the
#       wave-closure nudge fire only when review was extremely fast.
#     ignored_missing_agents           array    default []
#       List of agent basenames (no .md) that the agent-existence check should
#       suppress. Use when planning docs cite historically-deleted agents whose
#       references survive in the prose for documentation reasons.
#   Additional keys are silently ignored. Absent file applies all defaults silently.
#
# Activation: ships with the plugin; activates on the nearest repo root (walk-up
#   from $PWD), no-ops silently outside any repo. STATE_DRIFT_CHECK_ALLOW_ROOT
#   pins activation to one root if set. (v1 shipped a hard-coded machine
#   allowlist that no-opped for every consumer; genericized in 2.4.0.)
# Output channel: hookSpecificOutput.additionalContext (raw stdout is dropped).
# Internal errors: emit [state-drift-check] internal error: <msg>. Never silent-fail.

$ErrorActionPreference = 'Continue'
$null = [Console]::In.ReadToEnd()

try {
    # Activation: this hook ships with the plugin, so it activates on whatever
    # repo the session is in -- the nearest .git/planning root found by walking
    # up from $PWD (same convention as state-writer.ps1). It no-ops silently
    # when $PWD is outside any repo. The optional STATE_DRIFT_CHECK_ALLOW_ROOT
    # env var PINS activation to a single root (used by the regression tests;
    # also lets a consumer scope the hook to one checkout if they want).

    # Resolve repo root: walk up from $PWD looking for .git or planning dir.
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

    if (-not $repoRoot) { exit 0 }

    # Optional pin: if STATE_DRIFT_CHECK_ALLOW_ROOT is set, only activate when
    # the resolved repo root matches it (case-insensitive, trailing-separator
    # tolerant). Unset => activate on any resolved repo root.
    if ($env:STATE_DRIFT_CHECK_ALLOW_ROOT) {
        $norm = $repoRoot.TrimEnd('\','/')
        $pin  = $env:STATE_DRIFT_CHECK_ALLOW_ROOT.TrimEnd('\','/')
        if (-not $pin.Equals($norm, [StringComparison]::OrdinalIgnoreCase)) { exit 0 }
    }

    # Sidecar config load.
    $bufferMinutes = 5
    $waveWindowMinutes = 60
    $ignoredMissingAgents = @()
    $configPath = Join-Path $HOME (Join-Path '.claude' (Join-Path 'hooks' 'state-drift-check.config.json'))
    $internalErrors = @()
    if (Test-Path $configPath) {
        try {
            $configRaw = Get-Content -Raw -Path $configPath -ErrorAction Stop
            $config = $configRaw | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $config.ledger_state_buffer_minutes) {
                $bufferMinutes = [int]$config.ledger_state_buffer_minutes
            }
            if ($null -ne $config.wave_detection_window_minutes) {
                $waveWindowMinutes = [int]$config.wave_detection_window_minutes
            }
            if ($null -ne $config.ignored_missing_agents) {
                $ignoredMissingAgents = @($config.ignored_missing_agents)
            }
        } catch {
            $msg = $_.Exception.Message -replace "`r?`n", '; '
            if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 297) + '...' }
            $internalErrors += "[state-drift-check] internal error: sidecar config parse: $msg"
        }
    }

    $messages = @()

    # Locate planning dirs.
    $planningRoot = Join-Path $repoRoot 'planning'
    if (Test-Path $planningRoot) {
        $planningDirs = Get-ChildItem -Path $planningRoot -Directory -ErrorAction SilentlyContinue
        foreach ($pd in $planningDirs) {
            $slug = $pd.Name
            $statePath  = Join-Path $pd.FullName 'plan-state.md'
            $ledgerPath = Join-Path $pd.FullName 'plan-ledger.md'
            $prdPath    = Join-Path $pd.FullName 'prd.md'
            $specPath   = Join-Path $pd.FullName 'spec.md'
            $planPath   = Join-Path $pd.FullName 'plan.md'

            # Check A: ledger newer than state.
            if (Test-Path $ledgerPath) {
                if (-not (Test-Path $statePath)) {
                    $messages += "Drift detected: plan-ledger.md exists in $slug but plan-state.md is missing. Create plan-state.md before next phase."
                } else {
                    $ledgerMtime = (Get-Item $ledgerPath).LastWriteTime
                    $stateMtime  = (Get-Item $statePath).LastWriteTime
                    if (($ledgerMtime - $stateMtime).TotalMinutes -gt $bufferMinutes) {
                        $messages += "Drift detected: plan-ledger.md newer than plan-state.md in $slug. Update plan-state.md before next phase."
                    }
                }
            }

            # Check B: version-pointer drift.
            if (Test-Path $statePath) {
                $stateContent = Get-Content -Raw -Path $statePath -ErrorAction SilentlyContinue
                if ($stateContent) {
                    if ($stateContent -match '(?im)Latest PRD version:\s*([vV][\d\.]+)') {
                        $stateVer = $matches[1]
                        if (Test-Path $prdPath) {
                            $prdHead = Get-Content -Path $prdPath -TotalCount 20 -ErrorAction SilentlyContinue
                            $prdHeadStr = ($prdHead -join "`n")
                            if ($prdHeadStr -match '(?im)^\*\*Version:\*\*\s*([vV][\d\.]+)') {
                                $prdVer = $matches[1]
                                if ($stateVer -ne $prdVer) {
                                    $messages += "Drift detected: plan-state.md says PRD $stateVer but prd.md frontmatter says $prdVer in $slug. Update plan-state.md before next phase."
                                }
                            }
                        }
                    }
                    if ($stateContent -match '(?im)Latest spec version:\s*([vV][\d\.]+)') {
                        $stateSpecVer = $matches[1]
                        if (Test-Path $specPath) {
                            $specHead = Get-Content -Path $specPath -TotalCount 20 -ErrorAction SilentlyContinue
                            $specHeadStr = ($specHead -join "`n")
                            if ($specHeadStr -match '(?im)^\*\*Version:\*\*\s*([vV][\d\.]+)') {
                                $specVer = $matches[1]
                                if ($stateSpecVer -ne $specVer) {
                                    $messages += "Drift detected: plan-state.md says spec $stateSpecVer but spec.md frontmatter says $specVer in $slug. Update plan-state.md before next phase."
                                }
                            }
                        }
                    }
                }
            }

            # Check C: missing referenced agent.
            $scanFiles = @($planPath, $statePath, $ledgerPath, $prdPath, $specPath) | Where-Object { Test-Path $_ }
            $foundAgents = @{}
            foreach ($sf in $scanFiles) {
                $content = Get-Content -Raw -Path $sf -ErrorAction SilentlyContinue
                if (-not $content) { continue }
                $regex = [regex]'agents[\\/]([a-zA-Z0-9_\-]+)\.md'
                $allMatches = $regex.Matches($content)
                foreach ($m in $allMatches) {
                    $name = $m.Groups[1].Value
                    if (-not $foundAgents.ContainsKey($name)) { $foundAgents[$name] = $true }
                }
            }
            foreach ($agentName in $foundAgents.Keys) {
                if ($ignoredMissingAgents -contains $agentName) { continue }
                # A referenced agent may live in the consumer's ~/.claude/agents/
                # OR be one this plugin ships under ${CLAUDE_PLUGIN_ROOT}/agents/.
                # Present in EITHER location => no drift.
                $agentFound = Test-Path (Join-Path $HOME (Join-Path '.claude' (Join-Path 'agents' "$agentName.md")))
                if (-not $agentFound -and $env:CLAUDE_PLUGIN_ROOT) {
                    $agentFound = Test-Path (Join-Path $env:CLAUDE_PLUGIN_ROOT (Join-Path 'agents' "$agentName.md"))
                }
                if (-not $agentFound) {
                    $messages += "Drift detected: referenced agent $agentName missing (not in ~/.claude/agents/ or the plugin's agents/). Create or rename before next phase."
                }
            }

            # Check E: stale Next-action / Open-PR-stack branch references (ground truth).
            #   Checks A/B/C verify INTERNAL consistency between planning docs; none
            #   reads the free-prose Next-action/Open-PR-stack fields against the world.
            #   The wave-closure nudge below only fires on implementation/wave-N/ path
            #   commits, so work that lands outside that path (e.g. a bin/-level fix
            #   round) never trips it. This check closes that gap: if a token in
            #   Next-action/Open-PR-stack resolves to a git branch that STILL EXISTS
            #   and is already merged into main, the field describes work that has
            #   already landed -- stale. Purely local (no network/gh); a merged-then
            #   -deleted branch leaves no ref, so past-tense mentions do not false-fire.
            #   2026-05-28: extended to also catch PLAIN-TEXT slashy branch tokens
            #   (e.g. 'build/control-plane' mentioned without backticks). The v2.2.0
            #   control-plane drift sat undetected because Check E v1 only matched
            #   `backtick-quoted` tokens. The git-ref existence check is still the
            #   strongest filter -- a slashy token that does not resolve as a real
            #   branch is silently dropped.
            #   (See state-surface-discipline plan-ledger 2026-05-26 + 2026-05-28.)
            if (Test-Path $statePath) {
                & git -C $repoRoot show-ref --verify --quiet 'refs/heads/main' 2>$null
                $mainExists = ($LASTEXITCODE -eq 0)
                if ($mainExists) {
                    $stateLines  = Get-Content -Path $statePath -ErrorAction SilentlyContinue
                    $actionLines = @($stateLines) | Where-Object { $_ -match '(?im)^(Next action|Open-PR stack):' }
                    $nudgedBranches = @{}
                    foreach ($line in $actionLines) {
                        # Collect candidate tokens from BOTH match modes. Each entry
                        # carries the token + the full-match string (used to remove
                        # the token from the line before applying the past-tense gate
                        # so a branch literally named "merged-feature" does not
                        # self-gate).
                        $candidates = New-Object System.Collections.Generic.List[object]
                        foreach ($tm in [regex]::Matches($line, '`([^`]+)`')) {
                            $candidates.Add([pscustomobject]@{ Token = $tm.Groups[1].Value.Trim(); FullMatch = $tm.Value })
                        }
                        # Plain-text slashy tokens: lowercase-letter start, then
                        # [a-z0-9_-]+, '/', then [a-z][a-z0-9._/-]*. Lookbehind
                        # rejects tokens that are inside backticks (handled above),
                        # part of a longer word/identifier, or a continuation of a
                        # longer slashy path. Lookahead rejects backtick/word-char
                        # continuation.
                        foreach ($tm in [regex]::Matches($line, '(?<![`\w/])[a-z][a-z0-9_-]*\/[a-z][a-z0-9._\/-]*(?![`\w])')) {
                            $candidates.Add([pscustomobject]@{ Token = $tm.Value.Trim(); FullMatch = $tm.Value })
                        }
                        foreach ($cand in $candidates) {
                            $token = $cand.Token
                            if (-not $token) { continue }
                            if ($token -match '\s') { continue }                                 # branch names have no spaces
                            if ($token -match '\.\.') { continue }                                # commit range, not a branch
                            if ($token -match '\.(md|ps1|psd1|json|jsonl|yml|yaml|txt|sh)$') { continue }  # filename
                            if ($token -match '(?i)^(task-|T-W?\d)') { continue }                 # task id
                            if ($token -in @('main','master','HEAD','origin/main','origin/HEAD')) { continue }
                            if ($nudgedBranches.ContainsKey($token)) { continue }
                            # Past-tense gate: if the line -- minus the branch token
                            # itself -- frames the branch as already landed, it is a
                            # historical mention (e.g. "landed via PR #71 (`x`, merged
                            # 2026-..)"), not pending work.
                            $lineSansToken = $line -replace [regex]::Escape($cand.FullMatch), ' '
                            if ($lineSansToken -match '(?i)\b(merged|landed|shipped|released|done|complete|completed|closed)\b') { continue }
                            # Resolve as a real branch: local first, then origin/<token>.
                            $ref = $null
                            & git -C $repoRoot show-ref --verify --quiet "refs/heads/$token" 2>$null
                            if ($LASTEXITCODE -eq 0) {
                                $ref = $token
                            } else {
                                & git -C $repoRoot show-ref --verify --quiet "refs/remotes/origin/$token" 2>$null
                                if ($LASTEXITCODE -eq 0) { $ref = "origin/$token" }
                            }
                            if (-not $ref) { continue }
                            # Already fully merged into main?
                            & git -C $repoRoot merge-base --is-ancestor $ref main 2>$null
                            if ($LASTEXITCODE -eq 0) {
                                $messages += "Drift detected: plan-state.md in $slug names branch '$token' as pending work, but it is already merged into main. Update Next action / Open-PR stack (and delete the merged branch)."
                                $nudgedBranches[$token] = $true
                            }
                        }
                    }
                }
            }

            # Check F: post-merge Lifecycle stage staleness (2026-05-28).
            #   When a build/<slug>, release/<slug>, or publish/<slug> branch is
            #   merged into main but plan-state.md's Lifecycle stage is still
            #   non-terminal, the project shipped but plan-state was never updated.
            #   Complementary to Check E: Check E nudges when a Next-action mentions
            #   a merged branch; Check F nudges when the lifecycle stage itself is
            #   stale. Either signal catches the drift; together they double-cover
            #   the post-ship state-refresh obligation. Terminal-vocabulary check
            #   mirrors bin/gen-planning-index.ps1's Get-StageClass (the canonical
            #   single source of truth for the Lifecycle stage vocabulary lives in
            #   CLAUDE.md "Planning - Lifecycle stage vocabulary"; both files apply
            #   the same rule).
            if (Test-Path $statePath) {
                & git -C $repoRoot show-ref --verify --quiet 'refs/heads/main' 2>$null
                $mainExistsF = ($LASTEXITCODE -eq 0)
                if ($mainExistsF) {
                    $stage = $null
                    foreach ($l in (Get-Content -Path $statePath -ErrorAction SilentlyContinue)) {
                        if ($l -match '^\s*Lifecycle stage:\s*(.+?)\s*$') {
                            $stage = ($Matches[1] -replace '\*', '').Trim()
                            break
                        }
                    }
                    if ($stage) {
                        $shortStage = $stage
                        $emdash = [char]0x2014
                        foreach ($d in @((' ' + $emdash), ' - ', '. ')) {
                            $idx = $shortStage.IndexOf($d)
                            if ($idx -ge 0) { $shortStage = $shortStage.Substring(0, $idx) }
                        }
                        $shortStage = $shortStage.Trim().TrimEnd('.')
                        # Terminal: Built/Shipped/Archived (canonical) + Done/Released/Complete (legacy aliases).
                        $isTerminal = $shortStage -match '(?i)^(built|shipped|archived|done|released|complete)\b'
                        if (-not $isTerminal) {
                            foreach ($prefix in @('build', 'release', 'publish')) {
                                $cand = "$prefix/$slug"
                                $ref = $null
                                & git -C $repoRoot show-ref --verify --quiet "refs/heads/$cand" 2>$null
                                if ($LASTEXITCODE -eq 0) { $ref = $cand }
                                else {
                                    & git -C $repoRoot show-ref --verify --quiet "refs/remotes/origin/$cand" 2>$null
                                    if ($LASTEXITCODE -eq 0) { $ref = "origin/$cand" }
                                }
                                if (-not $ref) { continue }
                                & git -C $repoRoot merge-base --is-ancestor $ref main 2>$null
                                if ($LASTEXITCODE -eq 0) {
                                    $messages += "Drift detected: branch '$cand' for $slug is merged into main, but plan-state.md Lifecycle stage is still '$shortStage' (non-terminal). Update to a terminal stage (Built/Shipped/Archived)."
                                    break  # one nudge per slug, even if multiple candidate branches match
                                }
                            }
                        }
                    }
                }
            }

            # Check G: gate-surface drift.
            #   The gate-decision path (scripts/gate-apply.ps1, or a direct
            #   task-frontmatter edit) marks a finding decided -- gate_state
            #   approved|declined, status terminal -- but does NOT touch
            #   plan-state.md. So a Next-action that tells the operator to
            #   "approve or decline the proposed findings" can outlive the queue
            #   it points at. Detection mirrors Check E/F: a cheap text
            #   pre-filter (an imperative approve/decline aimed at a
            #   proposed/pending gate finding) gates a ground-truth scan. The
            #   pending-gate predicate (gate_decider == 'user' AND effective
            #   gate_state == 'pending', absent state => pending) mirrors
            #   scripts/gate-schema.ps1 Get-GateQueue, the canonical reader --
            #   inlined to keep the hook self-contained (same precedent as
            #   Check F mirroring Get-StageClass). Fires only when the slug HAS
            #   gate tasks but NONE are still pending: a drained queue with a
            #   stale "go decide them" instruction. A non-empty queue
            #   (instruction accurate) or a slug with no gates at all stays
            #   silent.
            if (Test-Path $statePath) {
                $nextActionLinesG = @(Get-Content -Path $statePath -ErrorAction SilentlyContinue) |
                    Where-Object { $_ -match '(?im)^Next action:' }
                $staleGateInstruction = $false
                foreach ($naLine in $nextActionLinesG) {
                    # Anchored on an approve/decline verb within one sentence of a
                    # gate/finding noun, so a STATUS report ("all findings
                    # decided; queue empty") -- no imperative -- does not match.
                    if ($naLine -match '(?i)\b(approve|decline)\b[^.]{0,100}\b(gates?|findings?|intake|proposed|pending)\b' -or
                        $naLine -match '(?i)\b(proposed|pending)\b[^.]{0,60}\b(gates?|findings?|intake)\b[^.]{0,60}\b(approve|decline)\b') {
                        $staleGateInstruction = $true
                        break
                    }
                }
                if ($staleGateInstruction) {
                    $tasksDirG = Join-Path $pd.FullName 'tasks'
                    $gateTasksTotal = 0
                    $pendingGates = 0
                    if (Test-Path $tasksDirG) {
                        foreach ($tf in @(Get-ChildItem -Path $tasksDirG -Filter 'task-*.md' -File -ErrorAction SilentlyContinue)) {
                            $rawG = Get-Content -Raw -Path $tf.FullName -ErrorAction SilentlyContinue
                            if (-not $rawG) { continue }
                            $flines = $rawG -split "`r?`n"
                            if ($flines.Count -lt 3 -or $flines[0].Trim() -ne '---') { continue }
                            $decider = ''
                            $gstate = ''
                            for ($gi = 1; $gi -lt $flines.Count; $gi++) {
                                if ($flines[$gi].Trim() -eq '---') { break }
                                if ($flines[$gi] -match '^\s*gate_decider:\s*(.*)$') {
                                    $decider = $matches[1].Trim().Trim('"', "'").ToLowerInvariant()
                                } elseif ($flines[$gi] -match '^\s*gate_state:\s*(.*)$') {
                                    $gstate = $matches[1].Trim().Trim('"', "'").ToLowerInvariant()
                                }
                            }
                            if (-not $decider) { continue }
                            $gateTasksTotal++
                            # D-S1 default: absent gate_state => pending when a decider is set.
                            if (-not $gstate) { $gstate = 'pending' }
                            if ($decider -eq 'user' -and $gstate -eq 'pending') { $pendingGates++ }
                        }
                    }
                    if ($gateTasksTotal -gt 0 -and $pendingGates -eq 0) {
                        $messages += "Drift detected: plan-state.md Next action in $slug still instructs approving/declining proposed gate findings, but the gate queue is empty (all decided). Update Next action so the surface reflects the drained queue."
                    }
                }
            }
        }

    }

    # Wave-closure nudge: git log in time window, scan for wave paths.
    # Scoped per-project: a wave-N commit in slug X requires the same window's
    # commit set to touch planning/X/plan-state.md. An unrelated plan-state.md
    # update in slug Y does not satisfy slug X's closure check.
    try {
        $gitDir = Join-Path $repoRoot '.git'
        if (Test-Path $gitDir) {
            $gitArgs = @('-C', $repoRoot, 'log', "--since=$waveWindowMinutes minutes ago", '--name-only', '--pretty=format:%H')
            $rawOutput = & git $gitArgs 2>$null
            $gitExit = $LASTEXITCODE
            if ($gitExit -eq 0 -and $rawOutput) {
                $touched = @($rawOutput) | Where-Object { $_ -and -not ($_ -match '^[a-f0-9]{7,40}$') }
                $waveSlugs = @{}
                foreach ($t in $touched) {
                    if ($t -match '^planning/([^/]+)/implementation/wave-[^/]+/') {
                        $waveSlugs[$matches[1]] = $true
                    }
                }
                foreach ($slug in $waveSlugs.Keys) {
                    $slugStatePattern = "^planning/$([regex]::Escape($slug))/plan-state\.md$"
                    $stateTouched = $touched | Where-Object { $_ -match $slugStatePattern }
                    if (-not $stateTouched) {
                        $messages += "Wave appears closed in $slug - invoke wave-closer to update plan-state.md."
                    }
                }
            } elseif ($gitExit -ne 0) {
                $internalErrors += "[state-drift-check] internal error: git log returned exit $gitExit"
            }
        }
    } catch {
        $msg = $_.Exception.Message -replace "`r?`n", '; '
        if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 297) + '...' }
        $internalErrors += "[state-drift-check] internal error: wave-closure check: $msg"
    }

    # Output assembly.
    $all = @($messages) + @($internalErrors)
    if ($all.Count -gt 0) {
        $joined = ($all -join "`n")
        $payload = [pscustomobject]@{
            hookSpecificOutput = [pscustomobject]@{
                hookEventName = 'UserPromptSubmit'
                additionalContext = $joined
            }
        }
        $payload | ConvertTo-Json -Compress -Depth 5
    }

    exit 0
} catch {
    $msg = $_.Exception.Message -replace "`r?`n", '; '
    if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 297) + '...' }
    $errPayload = [pscustomobject]@{
        hookSpecificOutput = [pscustomobject]@{
            hookEventName = 'UserPromptSubmit'
            additionalContext = "[state-drift-check] internal error: $msg"
        }
    }
    $errPayload | ConvertTo-Json -Compress -Depth 5
    exit 0
}
