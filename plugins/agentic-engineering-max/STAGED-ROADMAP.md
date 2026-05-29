# STAGED roadmap (retired)

**Status as of v2.3.0 (2026-05-29):** This document is retired. Its premise --
"v1 targets Windows + PowerShell 5.1; Linux/macOS support is STAGED for v2" --
was made obsolete by the v2.0.0 release (2026-05-23), which shipped pure pwsh 7
cross-platform support for Windows + Linux. The file is preserved as a stub so
existing bookmarks and external references resolve, but the canonical roadmap
+ history now lives in:

- **`CHANGELOG.md`** -- per-release scope and dates.
- **Pinned issue `[v2-roadmap] Cross-platform support`** -- still the canonical
  user-facing signal, now scoped to remaining gaps (macOS install reports;
  platform-specific edge cases) rather than the headline port itself.

## Historical note (what this document used to say)

Prior to v2, this document committed the project to a pre-defined adoption
threshold for the cross-platform port: 5 distinct GitHub issues mentioning
macOS or Linux install problems within a 90-day window, OR 3 personal install
attempts by the operator on a non-Windows machine -- whichever fired first.
That threshold fired in early 2026-05; the cross-platform-v2 build (Dev_006
internal slug) ran 2026-05-21 through 2026-05-23 and shipped v2.0.0.
