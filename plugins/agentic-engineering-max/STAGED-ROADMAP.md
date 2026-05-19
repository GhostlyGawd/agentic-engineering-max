# STAGED roadmap

`agentic-engineering-max` v1 targets Windows 10/11 + PowerShell 5.1 (or later) +
Git for Windows. Linux and macOS are **STAGED for v2** -- declared as a roadmap
item, not deferred indefinitely.

## v2 cross-platform: pre-committed adoption threshold

Cross-platform v2 is prioritized when EITHER (a) at least 5 distinct GitHub
issues are opened against `github.com/GhostlyGawd/agentic-engineering-max`
mentioning macOS or Linux installation problems within any 90-day window since
v1.0.0, OR (b) the operator reports 3 personal install attempts on a non-Windows
machine. Whichever fires first.

## Adoption signal

The canonical adoption signal is the pinned tracking issue
`[v2-roadmap] Cross-platform support (Linux + macOS)` on the public repo. It
accepts "+1" / "me too" comments and links to install-problem issues mentioning
macOS or Linux. When the threshold above fires, v2 work begins.

## Why STAGED, not SHIPPED-v1

v1 preserves the dogfooding loop on the operator's Windows + PS 5.1 + Python 3.12
machine. Cross-platform ports (PowerShell Core 7+, Python rewrite) would either
break the dogfooding loop or require the operator to acquire a dev environment
they do not own. v1 ships now; v2 ships when adoption demands it.
