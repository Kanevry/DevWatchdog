import SwiftUI

/// Scrollable view over a ``SessionLog``. Newest entries appear first.
/// Designed to live in a standalone window opened from the menu-bar popover
/// ("Show Log"), sized around 500×600.
struct SessionLogView: View {
    @ObservedObject var log: SessionLog

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if log.entries.isEmpty {
                emptyState
            } else {
                list
            }

            Divider()

            footer
        }
        .frame(minWidth: 500, minHeight: 600)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Text("Session-Protokoll")
                .font(.headline)
            Spacer()
            Text("\(log.entries.count) Einträge")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var list: some View {
        List(log.entries.reversed()) { entry in
            SessionLogRow(entry: entry, timeFormatter: Self.timeFormatter)
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Noch keine Einträge")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Menu {
                Button("Als JSON kopieren") {
                    LogExporter.copyJSONToPasteboard(entries: log.entries)
                }
                Button("Log speichern…") {
                    Task { @MainActor in
                        _ = await LogExporter.promptAndSaveJSON(entries: log.entries)
                    }
                }
            } label: {
                Label("Exportieren", systemImage: "square.and.arrow.up")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(log.entries.isEmpty)

            Spacer()

            Button("Löschen", role: .destructive) {
                log.clear()
            }
            .disabled(log.entries.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Row

private struct SessionLogRow: View {
    let entry: SessionLogEntry
    let timeFormatter: DateFormatter

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.system(size: 12))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(timeFormatter.string(from: entry.timestamp))
                    if let pid = entry.pid {
                        Text("·")
                        Text("PID \(pid)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch entry.kind {
        case .kill:             return "xmark.octagon.fill"
        case .throttle:         return "pause.circle.fill"
        case .resume:           return "play.circle.fill"
        case .emergencyEntered: return "bolt.fill"
        case .emergencyExited:  return "checkmark.circle.fill"
        case .pressureWarning:  return "exclamationmark.triangle.fill"
        case .error:            return "exclamationmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch entry.kind {
        case .kill:             return .red
        case .throttle:         return .orange
        case .resume:           return .green
        case .emergencyEntered: return .yellow
        case .emergencyExited:  return .green
        case .pressureWarning:  return .orange
        case .error:            return .red
        }
    }
}

#Preview {
    let log = SessionLog()
    log.log(.emergencyEntered, "Emergency entered (loadFactor 3.12, level critical)")
    log.log(.kill, "Auto-killed zombie node (512 MB)", pid: 12345, processName: "node")
    log.log(.throttle, "Throttled webpack via SIGSTOP", pid: 23456, processName: "webpack")
    log.log(.resume, "Resumed webpack via SIGCONT", pid: 23456, processName: "webpack")
    log.log(.emergencyExited, "Emergency ended after 47s — 3 killed, 1 throttled, 1024 MB freed")
    log.log(.error, "Kill denied: Xcode", pid: 99999, processName: "Xcode")
    return SessionLogView(log: log)
}
