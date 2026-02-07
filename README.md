# DevWatchdog

> Your Mac shouldn't be a space heater because of zombie Node.js processes.

**DevWatchdog** is a lightweight macOS menu bar app that monitors and automatically kills zombie development processes (Vitest workers, Jest, tsc, esbuild, webpack) that keep running after their parent crashes or exits.

<p align="center">
  <img src="docs/screenshot-menu.png" alt="DevWatchdog Menu Bar" width="380" />
</p>

## The Problem

If you work with Node.js, you've seen this:

```
PID    %CPU  TIME     COMMAND
48291  100%  2:15:33  node vitest/dist/chunks/forks.abc123.js
48292  100%  2:15:33  node vitest/dist/chunks/forks.abc123.js
48293  100%  2:15:33  node vitest/dist/chunks/forks.abc123.js
48294  100%  2:15:33  node vitest/dist/chunks/forks.abc123.js
```

Seven Vitest fork workers at 100% CPU each. For two hours. The parent process crashed, but the children keep spinning forever, turning your MacBook into a jet engine.

**Why does this happen?**
- **Vitest/Jest fork workers**: Spawned via `child_process.fork()`. If the parent dies via SIGKILL, children never get the signal - they spin in an infinite event loop waiting for IPC messages that never come.
- **esbuild --service**: Stays running as a daemon even after the calling process exits.
- **tsc --watch**: Forgotten watch-mode processes accumulate over time.
- **MCP servers**: Claude Code, Cursor, and other AI tools spawn MCP server processes that outlive their sessions.

## Features

### Smart Zombie Detection
- Monitors `node`, `vitest`, `jest`, `tsc`, `esbuild`, `webpack`, `turbopack`, `eslint`, and more
- **Orphan detection**: Identifies processes whose parent has died (adopted by `launchd`, PPID=1)
- **Project-aware**: Shows which project a zombie belongs to (e.g., "BuchhaltGenieV5: 3 zombies")
- Configurable CPU and runtime thresholds per process pattern

### Three Kill Modes

| Mode | Behavior | Best For |
|------|----------|----------|
| **Smart Auto-Kill** (default) | Kills orphan zombies after a 30s grace period + notification | Daily use |
| **Notification Only** | Warns but never kills automatically | Cautious users |
| **Aggressive** | Kills matching processes immediately | "Just fix it" |

### Menu Bar at a Glance
- **Green shield**: All clear, no zombies
- **Orange eye + count**: Suspect processes being watched
- **Red warning + count**: Zombies detected (will be killed in Smart mode)

### Per-Process Actions
- One-click kill for individual processes
- "Kill All Zombies" button
- Whitelist processes you want to protect (e.g., `next dev`)
- Shows PID, CPU%, memory, runtime, project name, and orphan status

### Fully Configurable
- Custom process rules with glob patterns (e.g., `vitest.*forks`)
- Per-rule CPU threshold, runtime threshold, and action (auto-kill / warn / ignore / whitelist)
- Scan interval (10-120 seconds)
- Grace period before auto-kill (10-120 seconds)
- Sound alert on critical total CPU load
- Launch at login

## Installation

### Download (Recommended)

1. Go to [Releases](https://github.com/Kanevry/DevWatchdog/releases)
2. Download `DevWatchdog.app.zip`
3. Unzip and drag to `/Applications`
4. Open DevWatchdog - it appears in your menu bar

> **Note**: On first launch, macOS may show a security dialog. Go to **System Settings > Privacy & Security** and click "Open Anyway".

### Build from Source

Requires Xcode 16.2+ and macOS 15.0+.

```bash
git clone https://github.com/Kanevry/DevWatchdog.git
cd DevWatchdog
open DevWatchdog.xcodeproj
# Press Cmd+R to build and run
```

Or build from the command line:

```bash
xcodebuild -project DevWatchdog.xcodeproj \
  -scheme DevWatchdog \
  -configuration Release \
  -derivedDataPath build \
  build
```

The built app will be at `build/Build/Products/Release/DevWatchdog.app`.

## Default Rules

These rules come pre-configured and can be customized in Settings > Rules:

| Pattern | CPU Threshold | Runtime Threshold | Action |
|---------|--------------|-------------------|--------|
| `vitest.*forks` | 80% | 15 min | Auto-Kill |
| `vitest.*worker` | 80% | 15 min | Auto-Kill |
| `vitest.*child` | 80% | 15 min | Auto-Kill |
| `jest.*worker` | 80% | 15 min | Auto-Kill |
| `jest` | 80% | 15 min | Auto-Kill |
| `tsc` | 50% | 30 min | Warn |
| `esbuild.*service` | 0% | 60 min | Auto-Kill |
| `next.*dev` | - | - | Whitelist |
| `mcp` | 5% | 120 min | Warn |

## How It Works

1. **Scan**: Every 30 seconds (configurable), DevWatchdog runs `ps aux` and filters for development-related processes owned by the current user.

2. **Classify**: Each process is checked against your rules:
   - Does it match a pattern? (e.g., `vitest.*forks`)
   - Is CPU above threshold? (e.g., >80%)
   - Has it been running longer than threshold? (e.g., >15 min)
   - Is it an orphan? (parent PID = 1, adopted by launchd)

3. **Act**: Based on the kill mode:
   - **Smart**: Orphan zombies get a 30s grace period, then SIGTERM, then SIGKILL after 5s
   - **Notification Only**: Shows macOS notification, user decides
   - **Aggressive**: Immediate SIGTERM + SIGKILL fallback

4. **Notify**: macOS notifications for every detection and kill action. Optional sound alert when total monitored CPU exceeds a threshold (default: 500%).

## System Requirements

- macOS 15.0 (Sequoia) or later
- Apple Silicon or Intel Mac
- No sandbox (needs `ps` and `kill` access)

## Privacy & Security

- **No network access**: DevWatchdog never connects to the internet
- **No telemetry**: Zero data collection
- **Local only**: All configuration stored in UserDefaults on your Mac
- **No sandbox**: Required to run `ps aux` and send `kill` signals. The app cannot function in a sandboxed environment.
- **Open source**: Every line of code is auditable

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Language | Swift 6.0 |
| UI | SwiftUI (MenuBarExtra) |
| Target | macOS 15.0+ |
| Process monitoring | `ps aux` via `Process()` |
| Notifications | `UserNotifications` framework |
| Autostart | `ServiceManagement` (SMAppService) |
| Persistence | `UserDefaults` |

## Contributing

Contributions are welcome! Here are some ideas:

- **New process rules**: Add patterns for Python, Ruby, Go, Rust, or other ecosystems
- **Kill history/log**: Track what was killed and when
- **Menubar CPU chart**: Mini sparkline showing CPU trend
- **Keyboard shortcuts**: Global hotkey for "Kill All Zombies"
- **Homebrew Cask**: Package for `brew install --cask devwatchdog`
- **Localization**: Translate to other languages

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines.

## FAQ

### Will this kill my dev server?
No. `next dev` is whitelisted by default. You can add any process pattern to the whitelist in Settings > Rules.

### Does it need root/admin access?
No. It only monitors and kills processes owned by your user account.

### How is this different from Activity Monitor?
Activity Monitor shows everything but does nothing automatically. DevWatchdog focuses specifically on developer tool zombies and handles them for you.

### Why not just use `pkill`?
You could, but you'd have to remember to run it, know the right patterns, and not accidentally kill processes you need. DevWatchdog does this continuously and intelligently.

### Can I add rules for Python/Ruby/Go processes?
Yes! In Settings > Rules, add a new pattern (e.g., `python.*celery`) with your desired thresholds.

## License

[MIT](LICENSE) - Bernhard Goetzendorfer

---

*Built with frustration and Swift by a developer who was tired of his Mac sounding like a hairdryer.*
