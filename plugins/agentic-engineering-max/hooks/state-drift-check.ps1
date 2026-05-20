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
# Checks (post v1.1 / next-wave PR1 cleanup):
#   A. ledger-newer-than-state
#   B. version-pointer drift (PRD + spec)
#   C. missing referenced agents
#   (Former Check D / README schema removed 2026-05-12: live testing showed
#    fresh Claude sessions read plan-state.md directly via Glob and never
#    consult README. README is human-facing convention, not contract.)
#
# Sidecar config (optional): ${CLAUDE_PLUGIN_ROOT}/hooks/state-drift-check.config.json
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
#     allowlist                        array    default []
#       Repo root paths the hook is allowed to act in. When empty/absent, the
#       hook acts in whatever repo it resolves from $PWD (default-allow). The
#       hook only emits read-only drift warnings, so default-allow is safe.
#   Additional keys are silently ignored. Absent file applies all defaults silently.
#
# Allowlist (v1): operator-configurable via the sidecar config 'allowlist' key.
# Empty/absent allowlist => act in the resolved repo. Configure the key to
# restrict the hook to specific repo roots.
# Output channel: hookSpecificOutput.additionalContext (raw stdout is dropped).
# Internal errors: emit [state-drift-check] internal error: <msg>. Never silent-fail.

$ErrorActionPreference = 'Continue'
$null = [Console]::In.ReadToEnd()

try {
    # Plugin root for plugin-internal asset references (sidecar config + the
    # shipped agent files). Prefer the runtime-provided env var; fall back to
    # this script's own location so the hook also works when run directly.
    $pluginRoot = $env:CLAUDE_PLUGIN_ROOT
    if ([string]::IsNullOrWhiteSpace($pluginRoot)) { $pluginRoot = Split-Path -Parent $PSScriptRoot }

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

    # Sidecar config load (resolved under the plugin root). The optional
    # 'allowlist' key restricts which repos the hook acts in; absent/empty
    # means "act in the resolved repo" (default-allow; safe because this hook
    # only emits read-only drift warnings).
    $bufferMinutes = 5
    $waveWindowMinutes = 60
    $ignoredMissingAgents = @()
    $allowlist = @()
    $configPath = Join-Path $pluginRoot 'hooks/state-drift-check.config.json'
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
            if ($null -ne $config.allowlist) {
                $allowlist = @($config.allowlist)
            }
        } catch {
            $msg = $_.Exception.Message -replace "`r?`n", '; '
            if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 297) + '...' }
            $internalErrors += "[state-drift-check] internal error: sidecar config parse: $msg"
        }
    }

    # Allowlist gate: only enforced when an allowlist is configured.
    if ($allowlist.Count -gt 0) {
        $norm = $repoRoot.TrimEnd('\','/')
        $allowed = $false
        foreach ($entry in $allowlist) {
            if ($entry.TrimEnd('\','/').Equals($norm, [StringComparison]::OrdinalIgnoreCase)) {
                $allowed = $true
                break
            }
        }
        if (-not $allowed) { exit 0 }
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
                $agentPath = Join-Path $pluginRoot "agents/$agentName.md"
                if (-not (Test-Path $agentPath)) {
                    $messages += "Drift detected: referenced agent $agentName missing at `${CLAUDE_PLUGIN_ROOT}/agents/$agentName.md. Create or rename before next phase (or add it to the sidecar config 'ignored_missing_agents' if it is an operator-local agent)."
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
