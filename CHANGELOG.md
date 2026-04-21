# Changelog

All notable changes to DevWatchdog are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.1.0] — 2026-04-21

First signed release. Builds on v3.0 (Emergency Mode) with a full observability
layer: structured logging, kill-reason audit, a weekly Insights summary, dev
filter by path, log export, and richer rule match modes.

### Added

- **Structured logger (`DWLogger`)** — all `SessionLog` calls now flow through a
  level-filtered, category-tagged logger with `kind → category` mapping.
- **Insights tab** — weekly summary of kills, top projects / process types,
  reclaimed CPU-hours and RSS-MB; 7-day dismissal per card.
- **Dev Filter (`inclusionPatterns`)** — narrow the watch surface to specific
  path patterns for single-project focus, configured in Settings.
- **Log export** — JSON export with 6 secret-flag redactions, via pasteboard
  or `NSSavePanel`; entry points from the Session Log view menu.
- **Match modes for rules** — rule patterns now support `glob`, `regex`,
  `substring`, and `exact`. Migration-safe decoder keeps existing rules working.
- **Kill-reason audit** — every kill carries a structured `KillTrigger` and
  `KillReason` (orphan, maxRuntime, emergency-cpu, emergency-rss, manual,
  rule-override), persisted in the session log for post-hoc review.
- **Process-info hardening (`ProcPIDInfo`)** — Mach-backed PID info fallback
  with a `ps` timeout watchdog, minimum-age gate, and PID-reuse guard.

### Changed

- `SessionLog.log` is now a thin adapter over `DWLogger` — behaviour preserved,
  every entry additionally gets a structured category.
- Rule decoder is migration-safe: legacy rules without `matchMode` decode as
  `glob` (previous behaviour).

### Fixed

- Swift 6 strict-concurrency issue in the kill pipeline (`withUnsafeBytes(of:)`
  instead of `withUnsafeMutablePointer`).
- PID-reuse window closed: the PID is re-validated against start-time before
  every kill signal.

### Tests

- **+136 new tests** across 10 new test files (`DWLogger`, `InclusionPatterns`,
  `KillReason`, `MatchModeMigration`, `ProcPIDInfo`, `EmergencyMinAge`,
  `PIDReuse`, `PSFailureCounter`, `Insights`, `LogExporter`).
- Total: **288 tests passing**, zero Swift 6 warnings, strict-concurrency clean.

### Build & Distribution

- First **Developer ID signed** release (`G3QZ66475M`) with the hardened
  runtime. Notarization is planned for a subsequent release — use
  right-click → Open or `xattr -d com.apple.quarantine` on first launch.
- DMG artifact (`DevWatchdog-3.1.0.dmg`) shipped as a GitHub Release asset.

Closes GitLab epic [#21](https://gitlab.gotzendorfer.at/mobile/DevWatchdog/-/issues/21)
and sub-issues #22–#32 (minus #25, deferred).

---

## [3.0.0] — 2026-04-20 *(never tagged — superseded by 3.1.0)*

### Added

- **Emergency Mode** — when 5-minute load average exceeds
  `emergencyLoadFactor × CPU-count`, grace periods shrink and `maxRuntime`
  thresholds compress until load returns to normal.
- New per-rule `maxCPUPercent` and `maxRSSMB` fields for resource-aware
  killing. Decoder is migration-safe (old rules decode with `0` defaults).
- `emergencyMinAgeSeconds` setting to protect freshly-spawned processes from
  Emergency-triggered kills.

Closes GitLab epic #2 and sub-issues #3–#14.

---

## [2.1.0] — 2026-04-06

### Added

- CI pipeline on GitLab (macos-15 runner).
- Process detection for Bun, Deno, and SWC toolchains.
- Expanded test coverage.

### Fixed

- CI: removed `sudo xcode-select` (runner uses system Xcode).

---

## [2.0.0] — earlier

- Orphan-first zombie detection.
- Process-type-specific kill limits.
- Smart action bar (Kill Zombies / Kill Suspects with traffic-light colouring).

---

## [1.0.0] — initial release

- Menu bar app, 30-second scan, basic auto-kill with grace period.
