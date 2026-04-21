# Changelog

All notable changes to DevWatchdog are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.2.0] — 2026-04-21

Triage follow-up release. User-facing UX clarity (why-badges, smart kill split,
hardware-aware recommendations), new infrastructure (disk-persisted session log
+ newly-orphaned detection), the Apple-Silicon-correct memory-pressure signal,
and a migration off `MenuBarExtra` to `NSStatusItem` that finally makes the
menu-bar icon refresh without hovering.

### Added

- **"Why?" signal badges** per suspect row — `NEW ORPHAN`, `ORPHAN`, `IDLE Nm`,
  `ACTIVE N%`, `LEAK N MB`, `RULE …`, `KILL …`, `EXPIRED`, `PAUSED`. Each badge
  is a short capsule with a German tooltip explaining the heuristic. Overall
  `KillConfidence` (high/medium/low) colors the status dot and row background
  so a crowded list draws the eye to real zombies first.
- **Smart-split kill buttons** — when both idle (≈0 % CPU) and active (≥ 1 %
  CPU) suspects exist, the popover renders two distinct buttons: "N inaktive
  beenden" (green, safe) and "N aktive beenden" (red/orange, risky). Kills a
  running test/build only when you explicitly say so.
- **Hardware-aware settings recommendations** — each timing slider carries a
  live "Standard: X · Empfohlen: Y (für Z GB RAM)" hint scaled from the host's
  RAM / core count. Per-section reset button for Timing.
- **Disk-persisted session log** — every log entry is now streamed to
  `~/Library/Application Support/DevWatchdog/sessions/YYYY-MM-DD.jsonl`. The
  log hydrates the last 24 h on launch; 14-day rotation keeps disk usage
  bounded. Insights finally accrues value across restarts.
- **Newly-orphaned detection** — `PPID` history is tracked across scans; a
  `X → 1` transition is classified as `newlyOrphaned` (high confidence),
  steady-state `PPID == 1` as `adoptedByLaunchd` (conservative, medium).
- **Memory compressor signal** — `host_statistics64(HOST_VM_INFO64)` fills the
  gap where `vm.swapusage` is always zero on Apple Silicon. `PressureDeriver`
  now takes `max(swapFraction, compressorFraction)` so Emergency mode
  triggers on the real memory signal.

### Changed

- **Menu-bar architecture**: replaced `MenuBarExtra` with an `NSStatusItem` +
  `NSHostingView` setup owned by `AppDelegate`. Fixes FB11857447 — the system
  menu-bar server now sees `@Published` updates immediately without requiring
  a hover or click on the icon. Emergency-state pulse (`phaseAnimator`),
  accessibility labels, and the panic hotkey (`⌘⇧⌥P`) are preserved.
- **UI language unified to German** across every surface — previously a mix
  of German (MenuBar / Emergency) and English (Settings / Rules / About).
- **About window version** reads `CFBundleShortVersionString` at runtime
  instead of a hardcoded string, so release builds always display correctly.

### Fixed

- Menu-bar icon no longer requires a hover to reflect fresh scan results
  (FB11857447 / FB12094112). A prior attempt using `TimelineView(.periodic)`
  broke `xcodebuild test` with a 5.5 min IPC hang and was reverted in favor
  of the NSStatusItem migration above.
- `Swap` readout on Apple Silicon showing permanent `0.0 / 0.0 GB` — replaced
  with a Compressor-dominated `Speicher` row; `Swap` still surfaces only when
  the host actually has non-zero swap usage.
- About tab showing hard-coded `v2.0.0` regardless of the shipped build.
- Various mixed DE/EN UI labels ("General" / "Rules" / "Warn:" / "Kill:")
  that made the app look half-finished.

### Open follow-ups

See GitLab issues #34 (libproc migration), #35 (project detection via
`PROC_PIDVNODEPATHINFO`), #36 (signal-based dev detection), #37 (proper
i18n via `Localizable.xcstrings`). These are the next session's scope.

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
