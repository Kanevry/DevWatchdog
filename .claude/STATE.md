---
schema-version: 1
session-type: housekeeping
branch: main
issues: [33, 34, 35, 36, 37]
started_at: 2026-04-21T10:30:00+02:00
status: completed
current-wave: 1
total-waves: 1
completed_at: 2026-04-21T12:15:00+02:00
updated: 2026-04-21T10:15:00Z
release_tag: v3.2.0
---

## Current Wave

Wave 1 — Triage Follow-Up (Wellen A + B) + K2 NSStatusItem Migration + v3.2.0 Release — DONE

## Wave History

### Wave 1 — Resume of interrupted triage session + K2 reopen + release

Picked up an interrupted predecessor that had ~620 lines uncommitted in the working tree (K1/K3, A4, B1 backend, B4 stub). Executed the 3-commit stabilization split, finished Welle B UX/UI, added A3 persistence, migrated K2 to NSStatusItem after a three-parallel-agent research pass, and rolled it all up as a signed v3.2.0 release.

**10 commits pushed** (github + gitlab):

1. `f9596a3` fix(pressure,menubar,about): K1 compressor + K2 TimelineView + K3 dynamic version
2. `fb313b1` feat(process): A4 orphan history + B1 backend ProcessSignalsAnalyzer
3. `0cfb70e` feat(ui): B1 signal badges + confidence row tint; B4 unify UI language to German
4. `64dc6d0` feat(menubar): B2 split suspect kill button (idle/safe vs. active/risky)
5. `e82517e` feat(settings): B3 hardware-aware Default/Recommended hints + per-section reset
6. `affa7ff` feat(sessionlog): A3 persist log entries as JSONL + hydrate on launch
7. `5145b42` revert(menubar): drop K2 TimelineView — breaks xctest IPC (re-opened as #33)
8. `de25d23` chore: session state & metrics (mid-session bookkeeping)
9. `3b27824` feat(menubar): replace MenuBarExtra with NSStatusItem + NSHostingView (closes #33)
10. `9f183d4` chore(release): v3.2.0 — version bump + CHANGELOG entry

**Release:** `v3.2.0` tagged on both remotes · GitHub Release live with signed DMG asset (2.03 MB, SHA-256 `4efbd8f620fb71439d7955449fff38b926824d06ba51d213be7983b7030bc3ea`) · installed to `/Applications/DevWatchdog.app`; previous v3.1.0 kept at `DevWatchdog.app.v3.1.0-backup`.

**Tests: 323 passing** (was 289 pre-session).

## Deviations

- **K2 initially tried then reverted then re-solved:** f9596a3's `TimelineView(.periodic)` fixed the menu-bar-stale-until-hover bug at runtime but broke `xcodebuild test` with a 5.5 min IPC hang (reproducible, git-bisected). Reverted in 5145b42, then — after dispatching 3 parallel research agents — migrated from `MenuBarExtra` to `NSStatusItem` + `NSHostingView` in 3b27824. Research ruled out `.id()` as unverified speculation and confirmed the NSStatusItem approach is what Ice/Stats/Multi.app all use.
- **B4 scope trimmed:** proper i18n (EN source + DE translation via xcstrings) was deferred; unified all mixed strings to pure German now for UX consistency, kept empty xcstrings + `de` knownRegion as scaffolding. Tracked as #37.
- **Welle C deferred as its own session:** G5 / G2 / G1 are 8–12 h of refactor with large regression surface. Tracked as #34, #35, #36.
- **2 commits instead of 3 for the initial stabilization:** A4 and B1-Backend hunks in DevProcess/ProcessMonitor were interleaved; splitting would have required broken intermediate states. Merged into fb313b1.
- **Minor release scoping:** bumped to 3.2.0 (minor, not patch) because the session added multiple user-facing features (why-badges, smart kill split, settings recommendations, session log persistence) beyond pure bug fixes.

## Session Baseline

SESSION_START_REF: 8437fbb (pre-session HEAD)
RELEASE_TAG: v3.2.0 (commit 9f183d4)

## Final Metrics

- Commits: 10 new (plus this STATE.md bookkeeping commit)
- Tag: v3.2.0 on both remotes
- GitHub Release: https://github.com/Kanevry/DevWatchdog/releases/tag/v3.2.0 (live, signed DMG)
- Files added: 5 (ProcessSignals.swift, SettingsRecommendations.swift, SessionLogPersistence.swift, AppDelegate.swift, MenuBarLabel.swift) + 3 test files + 1 xcstrings stub
- LOC delta since v3.1.0: +2 234 / −324
- Tests: 323 passing (was 289 pre-session; +34 new across A4/B1/A3/K1 suites)
- Build: clean, no warnings, Swift 6 strict-concurrency satisfied
- Signature: Developer ID Application (G3QZ66475M), hardened runtime, spctl accepted
- GitLab issues closed: 1 (#33 via "Closes #33" in 3b27824)
- GitLab issues created: 5 (#33 K2-reopen [now closed], #34 G5 libproc, #35 G2 cwd-detection, #36 G1 auto-dev, #37 B4 proper i18n)
- Installed locally: `/Applications/DevWatchdog.app` → v3.2.0; backup at `.v3.1.0-backup`
- App running: PID 27237 (v3.2.0, NSStatusItem path)

## Next Session Recommendations

- **Priority:** Welle C — pick one of G5 (libproc migration, #34), G2 (cwd-based project detection, #35), G1 (signal-based dev detection, #36). G5 is the prerequisite for G2 and G1.
- **Type:** `feature` (substantial refactor, dedicated session)
- **Estimated scope:** 4–6 h for G5 alone, 8–12 h for the full G5+G2+G1 stack
- **Parallel candidate:** #37 (proper i18n) could run in its own 3–5 h session independent of the libproc work
