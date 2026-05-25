# tests/test-crosscompat-lint.ps1
#
# Regression test for scripts/crosscompat-lint.ps1. Builds temp files with
# known content, runs the lint against each, and asserts whether it flagged
# them. Covers each finding type AND the false-positive guards (regex
# metachars, adjacent metachars, '\' char literals, comments, suppression).
#
# Run:  pwsh -NoProfile -File tests/test-crosscompat-lint.ps1
# Exit: 0 = all pass, 1 = at least one failed.
#
# Convention (CLAUDE.md "Testing"): every guard lands with a regression test.
# Backslash test-DATA is built with [char]92 (not literal '\') so this test
# file is itself cross-compat-lint-clean. ASCII-only literals.
#
# Plugin copy of tests/test-crosscompat-lint.ps1 (dual-copy invariant). The
# ONLY difference from the root copy is the lint path: this subtree carries the
# lint at scripts/crosscompat-lint.ps1 (the root carries it at bin/).

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$lint     = Join-Path $repoRoot (Join-Path 'scripts' 'crosscompat-lint.ps1')
$bs       = [char]92          # backslash, kept out of this file's literals
$nonAscii = [char]0xE9        # 'e-acute' -- a non-ASCII char
$nl       = [char]10          # LF, for building multi-line .md probe content

if (-not (Test-Path $lint)) { Write-Host "FAIL: $lint missing"; exit 1 }

$passes = 0; $failures = 0

function Check {
    param(
        [string]$Name,
        [string]$Content,
        [bool]$ExpectFlagged,
        [string]$ExpectType = '',
        [string]$FileName = 'probe.ps1'
    )
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('cclint-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        $fp = Join-Path $dir $FileName
        # Write LF-only UTF-8 (no BOM) unless the case is specifically testing CR.
        [IO.File]::WriteAllText($fp, $Content, (New-Object Text.UTF8Encoding $false))
        $out  = & pwsh -NoProfile -ExecutionPolicy Bypass -File $lint $fp 2>&1 | Out-String
        $code = $LASTEXITCODE
        $flagged = ($code -ne 0)
        $typeOk = ($ExpectType -eq '') -or ($out -match [regex]::Escape($ExpectType))
        if ($flagged -eq $ExpectFlagged -and $typeOk) {
            Write-Host ("PASS: {0}" -f $Name); $script:passes++
        } else {
            Write-Host ("FAIL: {0} (expected flagged={1} type='{2}', got flagged={3})" -f $Name, $ExpectFlagged, $ExpectType, $flagged)
            ($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 3) | ForEach-Object { Write-Host "   | $_" }
            $script:failures++
        }
    } finally {
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    }
}

# --- Should FLAG (real Windows-isms) ---
Check -Name 'literal-backslash path -> FLAG' -ExpectFlagged $true -ExpectType 'literal-backslash' `
    -Content ("`$p = Join-Path `$r 'bin{0}spec-lint.ps1'" -f $bs)
Check -Name 'backslash path concat -> FLAG' -ExpectFlagged $true -ExpectType 'literal-backslash' `
    -Content ("`$p = ('planning{0}' + `$Slug + '{0}tasks')" -f $bs)
Check -Name 'windows abspath -> FLAG' -ExpectFlagged $true -ExpectType 'windows-abspath' `
    -Content ("`$root = 'D:{0}GitHub Projects{0}Dev_006'" -f $bs)
Check -Name 'powershell invocation -> FLAG' -ExpectFlagged $true -ExpectType 'powershell-invoke' `
    -Content '& powershell -NoProfile -File foo.ps1'  # crosscompat-ok: test data exercising the powershell-invoke detector, not a real invocation
Check -Name 'non-ASCII in .ps1 literal -> FLAG' -ExpectFlagged $true -ExpectType 'non-ascii-literal' `
    -Content ('$msg = "caf{0}"' -f $nonAscii)
Check -Name 'Start-Process WindowStyle param -> FLAG' -ExpectFlagged $true -ExpectType 'windowstyle-startprocess' `
    -Content '$p = Start-Process -FilePath $x -ArgumentList $a -WindowStyle Hidden -PassThru'  # crosscompat-ok: test data exercising the windowstyle detector, not a real invocation
Check -Name 'CRLF shim -> FLAG' -ExpectFlagged $true -ExpectType 'crlf-shim' -FileName 'pre-commit' `
    -Content ("#!/usr/bin/env bash`r`nexec pwsh -File hook.ps1`r`n")

# --- .md fenced-block scans (T009 rule: md-bypass / md-powershell-invoke) ---
# Probe content is a fenced '!' block whose body line carries the offending
# shape. md-bypass needs pwsh + -ExecutionPolicy Bypass + .ps1 co-occurring on
# one line; md-powershell-invoke needs the legacy 'powershell' exe in the block.
# The 'powershell'-exe DATA line carries a trailing '# crosscompat-ok' on its
# SOURCE line here (outside the quoted data) so this test file stays lint-clean,
# exactly as the 'powershell-invoke' .ps1 case above does.
Check -Name '.md bash-block Bypass -> FLAG md-bypass' -ExpectFlagged $true -ExpectType 'md-bypass' -FileName 'probe.md' `
    -Content (@('```!', 'pwsh -NoProfile -ExecutionPolicy Bypass -File foo.ps1', '```') -join $nl)
Check -Name '.md bash-block powershell exe -> FLAG md-powershell-invoke' -ExpectFlagged $true -ExpectType 'md-powershell-invoke' -FileName 'probe.md' `
    -Content (@('```!', 'exec powershell -NoProfile -File foo.ps1', '```') -join $nl)  # crosscompat-ok: md probe DATA exercising the md-powershell-invoke detector, not a real invocation

# --- Should NOT flag (clean / false-positive guards) ---
Check -Name 'clean Join-Path forward-slash -> OK' -ExpectFlagged $false `
    -Content ("`$p = Join-Path `$r 'bin/spec-lint.ps1'")
Check -Name 'regex \s+\d (operator line) -> OK' -ExpectFlagged $false `
    -Content ('if ($x -match "' + $bs + 's+' + $bs + 'd") { }')
Check -Name 'regex \s+ fragment (no operator) -> OK' -ExpectFlagged $false `
    -Content ("`$pat = 'current{0}s+state'" -f $bs)
Check -Name 'adjacent metachars \r\n -> OK' -ExpectFlagged $false `
    -Content ('$pat = "line{0}r{0}n"' -f $bs)
Check -Name "char-literal TrimEnd('\') -> OK" -ExpectFlagged $false `
    -Content ("`$x = `$p.TrimEnd('{0}','/')" -f $bs)
Check -Name 'backslash path in COMMENT -> OK' -ExpectFlagged $false `
    -Content ("# usage: .{0}bin{0}foo.ps1 <slug>" -f $bs)
Check -Name 'suppressed with # crosscompat-ok -> OK' -ExpectFlagged $false `
    -Content ("`$p = 'bin{0}spec.ps1'  # crosscompat-ok" -f $bs)
Check -Name 'conditional WindowStyle splat (sanctioned fix) -> OK' -ExpectFlagged $false `
    -Content "if (`$IsWindows) { `$spArgs['WindowStyle'] = 'Hidden' }"
Check -Name 'WindowStyle in a COMMENT -> OK' -ExpectFlagged $false `
    -Content '# -WindowStyle is Windows-only; add it conditionally'  # crosscompat-ok: test data (a comment-line probe), not a real invocation
Check -Name '.md clean pwsh -File block -> OK' -ExpectFlagged $false -FileName 'probe.md' `
    -Content (@('```bash', 'pwsh -NoProfile -File foo.ps1', '```') -join $nl)
Check -Name '.md Bypass line suppressed (# crosscompat-ok) -> OK' -ExpectFlagged $false -FileName 'probe.md' `
    -Content (@('```!', 'pwsh -NoProfile -ExecutionPolicy Bypass -File foo.ps1  # crosscompat-ok', '```') -join $nl)

Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $passes, $failures)
if ($failures -gt 0) { exit 1 } else { exit 0 }
