# DevWatchdog

macOS menu bar app that detects and kills zombie developer processes (node, gradle, webpack, etc.).

## Tech Stack

- **Language:** Swift 6 (strict concurrency)
- **UI:** SwiftUI
- **Target:** macOS 15+
- **Project type:** Xcode project (no Package.swift)

## Build & Test

```bash
# Build
xcodebuild -project DevWatchdog.xcodeproj -scheme DevWatchdog -destination 'platform=macOS' build

# Test
xcodebuild -project DevWatchdog.xcodeproj -scheme DevWatchdog -destination 'platform=macOS' test
```

## Project Structure

- `DevWatchdog/` — App source code
- `DevWatchdogTests/` — Unit tests
- `docs/` — Documentation and screenshots

## CI/CD

- **GitHub Actions:** `.github/workflows/build.yml`
- **GitLab CI:** `.gitlab-ci.yml`

## Remotes

- `origin` — GitHub: Kanevry/DevWatchdog
- `gitlab` — gitlab.buchhaltgenie.at:mobile/DevWatchdog

## Conventions

- Swift 6 strict concurrency — all types must be `Sendable`-safe
- SwiftUI for all UI; no AppKit unless necessary
- Menu bar app architecture (no main window)
