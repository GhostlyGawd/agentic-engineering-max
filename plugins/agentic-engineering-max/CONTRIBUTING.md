# Contributing to agentic-engineering-max

Thanks for considering a contribution. This plugin packages a battle-tested build discipline; the contribution model favors small, focused changes that keep the discipline strict.

## How to file an issue

Open issues at `https://github.com/GhostlyGawd/agentic-engineering-max/issues`. Include:

- A short title naming the surface affected (e.g., `/worker skill: lock-collision in concurrent claim`).
- Reproduction steps if it is a bug (commands run, expected vs observed, exit codes).
- The Claude Code version (`claude --version`) and PowerShell version (`$PSVersionTable.PSVersion`).
- For cross-platform install reports, see the v2 roadmap section below before filing -- those route into a different tracker.

If you are unsure whether something is a bug or intended behavior, file it as a question -- answering clarifies the spec, which is itself useful.

## How to propose a change (PR flow)

1. **Discuss first for non-trivial changes.** Open an issue describing the proposed change before writing code. The plugin packages an opinionated discipline; PRs that change the discipline without discussion are likely to be rejected even if the code is clean.
2. **Branch from `main`.** Use a topic branch named `feat/<short-slug>`, `fix/<short-slug>`, or `docs/<short-slug>`.
3. **Make focused commits.** One concern per commit. Use a present-tense summary line under 70 characters; body in full sentences explaining the why.
4. **Run the test suite.** `pwsh -NoProfile -File tests/run-all-tests.ps1` must exit 0. If you add a behavior, add a test that fails before your change and passes after.
5. **Match existing style.** Read a few neighboring files in the area you are changing and match conventions (parameter casing, error-handling, frontmatter shape, etc.).
6. **Open the PR against `main`** with a description that names the issue (if any), summarizes what changed, and lists what was tested.

## Code style notes

- **PowerShell 7 (`pwsh`) is the target.** All scripts, hooks, and tests must run under `pwsh` 7 on BOTH Windows and Linux; PowerShell 5.1 is no longer a target. Use `Join-Path` or forward slashes (never literal backslashes), invoke `pwsh` (never `powershell`), keep bash shims LF-only, and keep `.ps1` `"..."` literals ASCII-only. `crosscompat-lint.ps1` (wired into the pre-commit hook) enforces these on every commit; exempt a genuine Windows-only line with a trailing `# crosscompat-ok`.
- **Python 3.12** where the project uses Python. Add `sys.stdout.reconfigure(encoding="utf-8")` early in any script that may print non-ASCII; Python on Windows defaults to cp1252.
- **ASCII-only inside `.ps1` `"..."` string literals.** Em-dash, smart quotes, right-arrow get mis-decoded by PS5.1's cp1252 read into string terminators. Use `--`, `'`, `"`, `->`. Comments and `@"..."@` here-strings are safe; or save the file UTF-8-with-BOM.
- **Parse-check every PowerShell script after editing.** `[Management.Automation.Language.Parser]::ParseFile($p,[ref]$null,[ref]$e); $e` -- silently-broken hooks look identical to non-firing hooks from the outside. Catching parse errors at edit time saves debugging.
- **Avoid `2>&1` on native exes in PowerShell 5.1.** It corrupts `$?` and exit handling. Use `2>$null` or capture stderr separately via `Start-Process -RedirectStandardError`.
- **JSON files: UTF-8 with no BOM.** Default `Out-File` / `Set-Content` write UTF-16 LE -- use `-Encoding utf8` explicitly when writing JSON or other text other tools will read.

## Cross-platform notes

As of v2.0.0 (2026-05-23), the plugin runs on **Windows + Linux under pwsh 7**. PowerShell 5.1 is no longer a target. The cross-platform CI matrix (`tests (ubuntu-latest)` + `tests (windows-latest)` + a Linux `aem-init install + pwsh probe`) runs on every PR. macOS is not in the matrix but should work under pwsh 7; reports against the pinned `[v2-roadmap] Cross-platform support` issue describing macOS-specific install behavior are welcome.

Useful contributions on the cross-platform front:

- Installation-friction reports on Linux or macOS (open an issue with the `claude --version`, `pwsh --version`, and the failing step).
- Test cases for platform-specific edge cases (case-sensitivity, line-endings, sentinel-file semantics under different filesystems).

## Roadmap / dogfooding

The plugin's discipline is intended to be used on real builds, not just demos. **First post-v1 dogfooding target is operator's discretion; suggested candidates include any greenfield project where the build-system discipline is desired.** No task in the spec is gated on this choice -- the plugin ships when its own section 10 success criteria pass.

If you use the plugin on a project, opening an issue describing what worked and what felt friction-y is a high-leverage contribution. Failure-mode reports are how the discipline tightens.

## License

By contributing, you agree that your contributions will be licensed under the MIT License of this project. See [LICENSE](./LICENSE).
