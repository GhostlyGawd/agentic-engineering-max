# bin/crosscompat-lint.ps1
#
# Cross-platform compatibility lint. Scans PowerShell scripts, bash shims, and
# hook JSON for the mechanical Windows-isms that would break the plugin when it
# runs under PowerShell 7 (pwsh) on Linux. Runs entirely on Windows -- no Linux
# box needed -- because every check is static/byte-level. This is the standing
# guard that keeps the codebase cross-compatible as new code is added; the
# eventual Linux acceptance run only needs to catch the SEMANTIC residue (a
# script shelling out to a Windows-only exe, filesystem case-sensitivity, etc.).
#
# Checks (one finding-type each):
#   literal-backslash : a quoted string using '\' as a path separator. Use
#                       Join-Path or '/'. ('\' does not separate paths on Linux.)
#   powershell-invoke : invoking the Windows-only 'powershell'/'powershell.exe'
#                       executable. Use 'pwsh' (cross-OS PowerShell 7).
#   crlf-shim         : a bash shim ('pre-commit' / *.sh) carrying CR (0x0D)
#                       bytes -- a CRLF shebang silently breaks under Linux bash.
#   non-ascii-literal : a non-ASCII char inside a .ps1 "..." double-quoted
#                       literal (PS5.1 cp1252 hazard; ASCII-only discipline).
#
# Any flagged line can be exempted with a trailing '# crosscompat-ok' comment
# (genuinely Windows-only code, or a false positive -- the comment documents why).
#
# Usage:
#   crosscompat-lint.ps1                 # scan bin, hooks, tests, plugin
#   crosscompat-lint.ps1 <file>...       # scan only the given files (pre-commit)
#
# Exit: 0 = clean, 1 = at least one finding (one line per finding to stderr).
# ASCII-only literals in this file.

param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Paths)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

# Resolve target files. With no args, scan the standard dirs. With args, scan
# exactly those that are lintable types (so pre-commit can hand us the full
# staged list and we self-filter).
$lintExt  = @('.ps1', '.json')
function Test-IsShim([System.IO.FileInfo]$fi) { return ($fi.Name -eq 'pre-commit' -or $fi.Extension -eq '.sh') }

$files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
if (-not $Paths -or $Paths.Count -eq 0) {
    foreach ($d in @('bin', 'hooks', 'tests', 'plugin')) {
        $full = Join-Path $repoRoot $d
        if (Test-Path $full) {
            Get-ChildItem -Path $full -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $lintExt -contains $_.Extension -or (Test-IsShim $_) } |
                ForEach-Object { $files.Add($_) }
        }
    }
} else {
    foreach ($p in $Paths) {
        $full = if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $repoRoot $p }
        if (Test-Path $full -PathType Leaf) {
            $fi = Get-Item $full
            if ($lintExt -contains $fi.Extension -or (Test-IsShim $fi)) { $files.Add($fi) }
        }
    }
}
$files = @($files | Sort-Object FullName -Unique)

$findings = New-Object System.Collections.Generic.List[string]

foreach ($f in $files) {
    $rel = $f.FullName.Substring($repoRoot.Length).TrimStart('\', '/').Replace('\', '/')
    $isPs   = ($f.Extension -eq '.ps1')
    $isJson = ($f.Extension -eq '.json')
    $isShim = (Test-IsShim $f)

    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $text  = [Text.Encoding]::UTF8.GetString($bytes)
    $lines = $text -split "`n"

    if ($isShim -and ($bytes -contains 13)) {
        $findings.Add("crlf-shim         ${rel}: contains CR (0x0D) bytes -- bash shim must be LF-only")
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line   = $lines[$i]
        $lineNo = $i + 1
        if ($line -match '#\s*crosscompat-ok') { continue }
        # Pure-comment lines (usage docs, examples) are not executable -- a
        # backslash path in a comment is harmless. Skip them for the path/token
        # checks. (.json has no comments, so this only affects .ps1/shims.)
        $isCommentLine = ($line -match '^\s*#')

        # literal-backslash: a quoted string with '\' used as a separator (\ then
        # a letter, '$', or a closing quote). Skip regex-bearing lines (PS regex
        # uses \d \s \w \. etc.) and escaped '\\' (UNC / intentional escape).
        if (($isPs -or $isJson) -and -not $isCommentLine) {
            # Distinguishing a path-separator '\' from a regex metachar ('\s',
            # '\d', '\.') in an arbitrary string is undecidable heuristically, so
            # target the concrete path shapes this codebase actually uses:
            #   (a) '\' before a known path segment   -> planning\ , bin\ , \.locks
            #   (b) the string-concat path idiom        -> "...\" + $x
            #   (c) '\' before a variable               -> "planning\$slug"
            # These do not match '\s'/'\d'/'\r' regex metachars. Escaped '\\'
            # (UNC / intentional) is left alone. A genuine miss or FP is handled
            # by the '# crosscompat-ok' suppression.
            # A path separator is a '\' immediately PRECEDED by a word char
            # (foo\bar, bin\spec, planning\$slug, "planning\"+...). Regex
            # metachars (\s \d \r \. \( ) are almost always preceded by
            # punctuation/quote/group ((?im)..\s , :\s , )\r , [^\r ), so the
            # word-char-before requirement excludes them. Skip lines using a
            # regex operator outright, and ignore escaped '\\'.
            $isRegexLine = $line -match '(-match|-cmatch|-imatch|-notmatch|-inotmatch|-replace|-creplace|-ireplace|-split|\[regex\]|\[Regex\])'
            # Also exclude inline regex shapes that survive even without an
            # operator on the line: a regex char-class metachar followed by a
            # quantifier/group/anchor (\s+ \d* \w) ...| ), and adjacent metachars
            # (\r\n, \s\d). These produce false 'word\word' matches. Real path
            # segments (\swarm, bin\spec, .git\index) are NOT this shape.
            $looksRegex = ($line -match '\\[sSdDwWbBAZ]([+*?{}()\[\]|]|$)') -or ($line -match '\\[rntfvsSdDwW]\\')
            if (-not $isRegexLine -and -not $looksRegex -and $line -notmatch '\\\\' -and $line -match '[A-Za-z0-9_][\\][A-Za-z0-9_$"''.]') {
                $findings.Add("literal-backslash ${rel}:${lineNo}: '\' path separator in a string literal -- use Join-Path or '/'")
            }
            # windows-abspath: a drive-letter absolute path in a string literal
            # (e.g. 'D:\...', "C:/..."). No drive letters on Linux -- compute the
            # path (Find-RepoRoot / $PSScriptRoot / env) instead of hard-coding.
            if ($line -match '["''][A-Za-z]:[\\/]') {
                $findings.Add("windows-abspath  ${rel}:${lineNo}: hard-coded drive-letter path -- compute it (Find-RepoRoot/`$PSScriptRoot), do not hard-code")
            }
        }

        # powershell-invoke: 'powershell' as an invoked executable. Match common
        # invocation contexts only, so host-detection vars, doc URLs, and string
        # checks ('powershell.exe' after Join-Path/PSHOME, -cmatch 'powershell',
        # install-powershell.sh) are NOT flagged.
        if ($line -match '(?i)(&\s*|exec\s+|-FilePath\s+[''"]?|FilePath\s+[''"]?|"command"\s*:\s*"[^"]*\s)powershell(\.exe)?\b') {
            $findings.Add("powershell-invoke ${rel}:${lineNo}: invokes Windows-only 'powershell' -- use 'pwsh' (or # crosscompat-ok)")
        }

        # non-ascii-literal: non-ASCII char inside a .ps1 "..." literal.
        if ($isPs) {
            foreach ($m in [regex]::Matches($line, '"([^"]*)"')) {
                $bad = $false
                foreach ($ch in $m.Groups[1].Value.ToCharArray()) { if ([int]$ch -gt 127) { $bad = $true; break } }
                if ($bad) { $findings.Add("non-ascii-literal ${rel}:${lineNo}: non-ASCII char in a double-quoted literal -- use ASCII"); break }
            }
        }
    }
}

if ($findings.Count -eq 0) {
    Write-Host ("crosscompat-lint: clean ({0} files scanned)" -f $files.Count)
    exit 0
}
foreach ($x in $findings) { [Console]::Error.WriteLine($x) }
[Console]::Error.WriteLine(("crosscompat-lint: {0} finding(s) across {1} files" -f $findings.Count, $files.Count))
exit 1
