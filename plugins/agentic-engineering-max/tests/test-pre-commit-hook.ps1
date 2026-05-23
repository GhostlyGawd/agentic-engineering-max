# tests/test-pre-commit-hook.ps1
#
# Regression test for hooks/pre-commit.ps1 (state-surface-discipline
# enforcement). Each test runs in its own temp git repo with the hook
# installed via core.hooksPath, then attempts a real `git commit` and
# asserts the expected exit code + stderr substring.
#
# Run:    pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test-pre-commit-hook.ps1
# Exit:   0 = all pass, 1 = at least one failed.
#
# Convention (D:\GitHub Projects\Dev_006\CLAUDE.md "Testing"): every bug
# fix lands with a regression test. The original bug here was the failure
# mode caught while dogfooding on 2026-05-17 -- an operator-direct ledger
# edit (the /unblock fix in PR #24) committed without a matching
# plan-state.md mirror. This test locks in that the hook now blocks it.

$ErrorActionPreference = 'Stop'

$repoRoot     = Split-Path -Parent $PSScriptRoot
$psHookPath   = Join-Path $repoRoot 'hooks/pre-commit.ps1'
$bashHookPath = Join-Path $repoRoot 'hooks/pre-commit'

if (-not (Test-Path $psHookPath))   { Write-Host "FAIL: $psHookPath missing";   exit 1 }
if (-not (Test-Path $bashHookPath)) { Write-Host "FAIL: $bashHookPath missing"; exit 1 }

$script:passes   = 0
$script:failures = 0

function Run-Test {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$SetupStage,
        [Parameter(Mandatory)][int]$ExpectedExit,
        [string]$ExpectedStderrSubstring,
        [string]$ForbiddenStderrSubstring
    )

    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ("pre-commit-test-{0}" -f (Get-Random))
    New-Item -ItemType Directory -Path $testRoot | Out-Null

    try {
        Push-Location $testRoot

        # Fresh repo
        git init -q
        git config user.email 'test@example.com'
        git config user.name  'pre-commit-test'

        # Install the hook under test
        New-Item -ItemType Directory -Path 'hooks' | Out-Null
        Copy-Item $psHookPath   'hooks/pre-commit.ps1'
        Copy-Item $bashHookPath 'hooks/pre-commit'
        # On Linux/macOS git only runs a hook that carries the executable bit,
        # and PowerShell's Copy-Item does NOT preserve it. Restore it so the
        # copied shim actually fires (Windows git ignores the bit).
        if (-not $IsWindows) { & chmod +x 'hooks/pre-commit' }
        git config core.hooksPath hooks

        # Baseline empty commit so subsequent diffs work
        git commit -q --allow-empty -m 'baseline' --no-verify

        # Per-test stage setup
        & $SetupStage

        # Real commit attempt. PS5.1 wraps native-exe stderr as RemoteException
        # when redirected via 2>&1 (see the user's global CLAUDE.md machine
        # notes), so use Start-Process with file redirection instead.
        $stdoutFile = [IO.Path]::GetTempFileName()
        $stderrFile = [IO.Path]::GetTempFileName()
        $proc = Start-Process -FilePath 'git' `
            -ArgumentList @('commit','-m','automated-test') `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError  $stderrFile
        $exit   = $proc.ExitCode
        $output = (Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue) + "`n" + (Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue)
        Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue

        $fail = $false
        $why  = @()

        if ($exit -ne $ExpectedExit) {
            $fail = $true
            $why += ("expected exit {0}, got {1}" -f $ExpectedExit, $exit)
        }
        if ($ExpectedStderrSubstring -and ($output -notmatch [regex]::Escape($ExpectedStderrSubstring))) {
            $fail = $true
            $why += ("expected output to contain: '{0}'" -f $ExpectedStderrSubstring)
        }
        if ($ForbiddenStderrSubstring -and ($output -match [regex]::Escape($ForbiddenStderrSubstring))) {
            $fail = $true
            $why += ("expected output to NOT contain: '{0}'" -f $ForbiddenStderrSubstring)
        }

        if ($fail) {
            Write-Host ("FAIL: {0}" -f $Name)
            foreach ($w in $why) { Write-Host ("  - {0}" -f $w) }
            Write-Host "  --- captured output ---"
            $output -split "`n" | ForEach-Object { Write-Host ("    {0}" -f $_) }
            Write-Host "  -----------------------"
            $script:failures++
        } else {
            Write-Host ("PASS: {0}" -f $Name)
            $script:passes++
        }
    }
    finally {
        Pop-Location
        Remove-Item -Recurse -Force $testRoot -ErrorAction SilentlyContinue
    }
}

# -----------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------

Run-Test -Name 'Ledger staged WITHOUT state -> BLOCKED with violation message' `
    -SetupStage {
        New-Item -ItemType Directory -Path 'planning/test-slug' -Force | Out-Null
        Set-Content 'planning/test-slug/plan-ledger.md' "initial`n" -Encoding UTF8
        Set-Content 'planning/test-slug/plan-state.md'  "initial`n" -Encoding UTF8
        git add planning/test-slug/plan-state.md planning/test-slug/plan-ledger.md
        git commit -q -m 'seed planning files' --no-verify

        Add-Content 'planning/test-slug/plan-ledger.md' "new entry"
        git add planning/test-slug/plan-ledger.md
    } `
    -ExpectedExit 1 `
    -ExpectedStderrSubstring 'STATE-SURFACE DISCIPLINE VIOLATION'

Run-Test -Name 'Ledger + state BOTH staged -> PASSES' `
    -SetupStage {
        New-Item -ItemType Directory -Path 'planning/test-slug' -Force | Out-Null
        Set-Content 'planning/test-slug/plan-ledger.md' "initial`n" -Encoding UTF8
        Set-Content 'planning/test-slug/plan-state.md'  "initial`n" -Encoding UTF8
        git add planning/test-slug/plan-state.md planning/test-slug/plan-ledger.md
        git commit -q -m 'seed planning files' --no-verify

        Add-Content 'planning/test-slug/plan-ledger.md' "new entry"
        Add-Content 'planning/test-slug/plan-state.md'  "mirror update"
        git add planning/test-slug/plan-ledger.md planning/test-slug/plan-state.md
    } `
    -ExpectedExit 0

Run-Test -Name 'State alone staged (no ledger touched) -> PASSES' `
    -SetupStage {
        New-Item -ItemType Directory -Path 'planning/test-slug' -Force | Out-Null
        Set-Content 'planning/test-slug/plan-state.md' "initial`n" -Encoding UTF8
        git add planning/test-slug/plan-state.md
        git commit -q -m 'seed state file' --no-verify

        Add-Content 'planning/test-slug/plan-state.md' "state-only edit"
        git add planning/test-slug/plan-state.md
    } `
    -ExpectedExit 0

Run-Test -Name 'Unrelated file change -> PASSES (no-op)' `
    -SetupStage {
        Set-Content 'random.txt' 'hello' -Encoding UTF8
        git add random.txt
    } `
    -ExpectedExit 0

Run-Test -Name 'Two slugs, only ONE violating -> BLOCKED naming only violator' `
    -SetupStage {
        foreach ($s in @('alpha-slug','beta-slug')) {
            New-Item -ItemType Directory -Path "planning/$s" -Force | Out-Null
            Set-Content "planning/$s/plan-ledger.md" "initial`n" -Encoding UTF8
            Set-Content "planning/$s/plan-state.md"  "initial`n" -Encoding UTF8
        }
        git add planning/alpha-slug/ planning/beta-slug/
        git commit -q -m 'seed two slugs' --no-verify

        # alpha: ledger + state BOTH (compliant). beta: ledger only (violator).
        Add-Content 'planning/alpha-slug/plan-ledger.md' "entry"
        Add-Content 'planning/alpha-slug/plan-state.md'  "mirror"
        Add-Content 'planning/beta-slug/plan-ledger.md'  "entry"
        git add planning/alpha-slug/plan-ledger.md planning/alpha-slug/plan-state.md planning/beta-slug/plan-ledger.md
    } `
    -ExpectedExit 1 `
    -ExpectedStderrSubstring 'beta-slug' `
    -ForbiddenStderrSubstring 'alpha-slug'

# Wildcard-staging guard (2026-05-20): a commit staging 2+ task-*.md files
# is the signature of `git add -A` sweeping in another worker's edits.
Run-Test -Name 'Two task-*.md files staged -> BLOCKED (wildcard-staging guard)' `
    -SetupStage {
        New-Item -ItemType Directory -Path 'planning/swarm-slug/tasks' -Force | Out-Null
        Set-Content 'planning/swarm-slug/tasks/task-006.md' "---`nstatus: open`n---`n" -Encoding UTF8
        Set-Content 'planning/swarm-slug/tasks/task-016.md' "---`nstatus: open`n---`n" -Encoding UTF8
        git add planning/swarm-slug/tasks/task-006.md planning/swarm-slug/tasks/task-016.md
        git commit -q -m 'seed two task files' --no-verify

        # Worker-C scenario: editing its own task-016 but `git add -A` also
        # sweeps in worker-A's mid-edit task-006.
        Add-Content 'planning/swarm-slug/tasks/task-016.md' "work by worker-C"
        Add-Content 'planning/swarm-slug/tasks/task-006.md' "mid-edit by worker-A"
        git add planning/swarm-slug/tasks/task-016.md planning/swarm-slug/tasks/task-006.md
    } `
    -ExpectedExit 1 `
    -ExpectedStderrSubstring 'WILDCARD-STAGING GUARD'

Run-Test -Name 'Single task-*.md file staged -> PASSES (normal worker tick)' `
    -SetupStage {
        New-Item -ItemType Directory -Path 'planning/swarm-slug/tasks' -Force | Out-Null
        Set-Content 'planning/swarm-slug/tasks/task-016.md' "---`nstatus: open`n---`n" -Encoding UTF8
        git add planning/swarm-slug/tasks/task-016.md
        git commit -q -m 'seed one task file' --no-verify

        Add-Content 'planning/swarm-slug/tasks/task-016.md' "work by worker-C"
        Set-Content 'plugin-deliverable.txt' "the actual deliverable" -Encoding UTF8
        git add planning/swarm-slug/tasks/task-016.md plugin-deliverable.txt
    } `
    -ExpectedExit 0

# -----------------------------------------------------------------------
Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:passes, $script:failures)
if ($script:failures -gt 0) { exit 1 } else { exit 0 }
