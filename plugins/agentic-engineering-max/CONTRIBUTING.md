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
4. **Run the test suite.** `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all-tests.ps1` must exit 0. If you add a behavior, add a test that fails before your change and passes after.
5. **Match existing style.** Read a few neighboring files in the area you are changing and match conventions (parameter casing, error-handling, frontmatter shape, etc.).
6. **Open the PR against `main`** with a description that names the issue (if any), summarizes what changed, and lists what was tested.

## Code style notes

- **PowerShell 5.1 is the target.** PowerShell 7 is supported but not required. Avoid features added after 5.1 (pipeline chain `&&`/`||`, ternary, null-coalescing, `?.`) unless gated behind a version check.
- **Python 3.12** where the project uses Python. Add `sys.stdout.reconfigure(encoding="utf-8")` early in any script that may print non-ASCII; Python on Windows defaults to cp1252.
- **ASCII-only inside `.ps1` `"..."` string literals.** Em-dash, smart quotes, right-arrow get mis-decoded by PS5.1's cp1252 read into string terminators. Use `--`, `'`, `"`, `->`. Comments and `@"..."@` here-strings are safe; or save the file UTF-8-with-BOM.
- **Parse-check every PowerShell script after editing.** `[Management.Automation.Language.Parser]::ParseFile($p,[ref]$null,[ref]$e); $e` -- silently-broken hooks look identical to non-firing hooks from the outside. Catching parse errors at edit time saves debugging.
- **Avoid `2>&1` on native exes in PowerShell 5.1.** It corrupts `$?` and exit handling. Use `2>$null` or capture stderr separately via `Start-Process -RedirectStandardError`.
- **JSON files: UTF-8 with no BOM.** Default `Out-File` / `Set-Content` write UTF-16 LE -- use `-Encoding utf8` explicitly when writing JSON or other text other tools will read.

## Cross-platform v2 invitation

This plugin currently targets Windows 10/11 + PowerShell 5.1 + Git for Windows. Cross-platform support is a v2 roadmap item, not a permanent limit. See [STAGED-ROADMAP.md](./STAGED-ROADMAP.md) for the pre-committed adoption threshold and the canonical signal mechanism (a pinned GitHub tracking issue accepting +1 / "me too" comments).

If you want to help bring v2 forward, the most useful contributions are:

- Reports against the pinned `[v2-roadmap] Cross-platform support (Linux + macOS)` issue describing what install step would have worked on your platform.
- A spike PR that converts a single PowerShell tool to a portable form (Python or bash) while preserving the existing automated test suite. Land the spike behind a feature flag so v1 installs are unaffected.
- A test matrix proposal -- what would CI need to look like to validate the cross-platform port without regressing the Windows path.

## Roadmap / dogfooding

The plugin's discipline is intended to be used on real builds, not just demos. **First post-v1 dogfooding target is operator's discretion; suggested candidates include any greenfield project where the build-system discipline is desired.** No task in the spec is gated on this choice -- the plugin ships when its own section 10 success criteria pass.

If you use the plugin on a project, opening an issue describing what worked and what felt friction-y is a high-leverage contribution. Failure-mode reports are how the discipline tightens.

## License

By contributing, you agree that your contributions will be licensed under the MIT License of this project. See [LICENSE](./LICENSE).
