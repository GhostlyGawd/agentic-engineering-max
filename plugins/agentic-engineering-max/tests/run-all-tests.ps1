# tests/run-all-tests.ps1
#
# Test runner for the agentic-engineering-max plugin (spec ss7.3 / PRD D18).
# Discovers every sibling `test-*.ps1`, runs each as its own process, and
# reports a per-test PASS/FAIL line plus a final tally.
#
# Run:    pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run-all-tests.ps1
# Exit:   0 = all discovered tests passed, 1 = at least one failed (or none found).
#
# Conventions: ASCII-only literals; child tests are invoked as separate
# processes so a crash or `exit` in one cannot abort the runner; stderr is
# NOT merged into stdout (no `2>&1`, which corrupts $LASTEXITCODE on PS 5.1).

$ErrorActionPreference = 'Stop'

# Discover sibling test scripts. run-all-tests.ps1 does not match test-*.ps1,
# so the runner never recurses into itself.
$tests = Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'test-*.ps1' -File |
    Sort-Object Name

$pass  = 0
$fail  = 0
$total = 0

foreach ($t in $tests) {
    $total++
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $t.FullName
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        $pass++
        Write-Host ("[{0}] PASS" -f $t.Name)
    } else {
        $fail++
        Write-Host ("[{0}] FAIL (exit {1})" -f $t.Name, $code)
    }
}

Write-Host ("{0} pass, {1} fail, {2} total" -f $pass, $fail, $total)

if ($fail -eq 0 -and $total -gt 0) {
    exit 0
} else {
    exit 1
}
