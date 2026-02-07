import SwiftUI

struct ProcessRowView: View {
    let process: DevProcess
    let isZombie: Bool
    var onKill: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(isZombie ? .red : .orange)
                .frame(width: 6, height: 6)

            // Process info
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(process.processName)
                        .font(.system(.caption, weight: .medium))
                    if process.isOrphan {
                        Text("orphan")
                            .font(.system(size: 9))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.red.opacity(0.7)))
                    }
                }

                HStack(spacing: 8) {
                    if let project = process.projectName {
                        Text(project)
                            .foregroundStyle(.secondary)
                    }
                    Text("PID \(process.pid)")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2)
            }

            Spacer()

            // Stats
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 4) {
                    Text(process.cpuFormatted)
                        .foregroundStyle(cpuColor)
                        .fontWeight(.medium)
                    Text("CPU")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(process.runtimeFormatted)
                        .foregroundStyle(.secondary)
                    Text(process.memoryFormatted)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)

            // Kill button
            Button {
                onKill()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(isHovered ? .red : .secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help("Kill process \(process.pid)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var cpuColor: Color {
        if process.cpuPercent >= 100 { return .red }
        if process.cpuPercent >= 50 { return .orange }
        return .primary
    }
}
