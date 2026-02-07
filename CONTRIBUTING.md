# Contributing to DevWatchdog

Thanks for your interest in contributing! DevWatchdog is a simple but useful tool, and contributions are welcome.

## Getting Started

### Prerequisites
- macOS 15.0+
- Xcode 16.2+
- Swift 6.0

### Setup

```bash
git clone https://github.com/Kanevry/DevWatchdog.git
cd DevWatchdog
open DevWatchdog.xcodeproj
```

Press `Cmd+R` to build and run. The app will appear in your menu bar.

## What to Contribute

### Easy Wins
- **New process rules**: Know a common zombie pattern? Add it to `ProcessRule.defaultRules`
- **Bug fixes**: Found a parsing edge case in `ProcessMonitor`? Fix it!
- **Documentation**: Improve README, add screenshots, write guides

### Medium Effort
- **Kill history log**: Add a persistent log of killed processes
- **Menubar sparkline**: Mini CPU chart in the menu bar
- **Localization**: Add translations (German, Japanese, etc.)

### Larger Features
- **Homebrew Cask**: Create a Homebrew formula for easy installation
- **Auto-update**: Integrate Sparkle framework for automatic updates
- **Process rules as YAML**: Allow community-contributed rule files

## Code Style

- Swift 6.0 with strict concurrency checking
- SwiftUI for all UI
- `@MainActor` for all observable classes
- Keep files focused - one type per file
- Use meaningful names (no abbreviations except well-known ones like PID, CPU)

## Architecture

```
DevWatchdog/
├── DevWatchdogApp.swift      # Entry point, MenuBarExtra setup
├── Models/                   # Data models (immutable where possible)
│   ├── DevProcess.swift      # Process info (PID, CPU, memory, etc.)
│   ├── ProcessRule.swift     # Kill/warn rules with pattern matching
│   └── WatchdogConfig.swift  # User settings (UserDefaults-backed)
├── Services/                 # Business logic
│   ├── ProcessMonitor.swift  # ps aux parsing, zombie classification
│   ├── ProcessKiller.swift   # SIGTERM/SIGKILL with grace period
│   └── NotificationService.swift  # macOS notifications
└── Views/                    # SwiftUI views
    ├── MenuBarView.swift     # Main dropdown menu
    ├── ProcessRowView.swift  # Single process row
    └── SettingsView.swift    # Settings window (tabbed)
```

### Key Design Decisions

1. **`ps aux` over libproc**: Simpler, no C interop, CPU% pre-calculated, no special entitlements needed.

2. **No sandbox**: The app needs `ps` and `kill` access. This is a fundamental requirement that cannot work in a sandboxed environment.

3. **UserDefaults for config**: Simple, native, no external dependencies. Rules are JSON-encoded.

4. **MenuBarExtra (not NSStatusItem)**: Modern SwiftUI API available since macOS 13. Cleaner code, better integration with SwiftUI state management.

5. **SIGTERM then SIGKILL**: Graceful first (5s timeout), then force. Gives processes a chance to clean up.

## Submitting Changes

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/my-feature`
3. Make your changes
4. Test manually (build + run, verify in menu bar)
5. Commit with a descriptive message
6. Push and open a Pull Request

### Commit Messages

Use conventional commits:
- `feat: Add Python process rules`
- `fix: Handle ps aux parsing for processes with spaces in path`
- `docs: Add screenshot to README`
- `refactor: Extract process classification logic`

## Testing

Currently, DevWatchdog doesn't have automated tests (it's a small utility app). Manual testing checklist:

- [ ] App launches and shows in menu bar
- [ ] Green checkmark when no zombies
- [ ] Run `node -e "while(true){}"` and verify detection after scan interval
- [ ] Kill button works for individual processes
- [ ] "Kill All" works
- [ ] Settings persist after restart
- [ ] Notifications appear
- [ ] Login item toggle works

If you add automated tests (great!), use XCTest and place them in a `DevWatchdogTests/` directory.

## Questions?

Open an issue on GitHub. For bugs, include:
- macOS version
- Xcode version
- Steps to reproduce
- Expected vs actual behavior

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
