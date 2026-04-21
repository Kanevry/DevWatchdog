import SwiftUI

struct InsightsView: View {
    @ObservedObject var engine: InsightsEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if engine.recommendations.isEmpty {
                emptyState
            } else {
                recommendationsList
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .task { engine.refresh() }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.yellow)
            Text("Insights")
                .font(.headline)
            Spacer()
            if let ts = engine.lastAnalyzedAt {
                Text("Analysiert: \(ts.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                engine.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Insights aktualisieren")
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Keine Empfehlungen")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Sobald DevWatchdog genug Session-Daten hat, zeigen wir hier Tuning-Vorschl\u{E4}ge.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recommendationsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(engine.recommendations) { rec in
                    InsightCard(recommendation: rec, engine: engine)
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Insight Card

private struct InsightCard: View {
    let recommendation: InsightRecommendation
    let engine: InsightsEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                Text(recommendation.title)
                    .font(.headline)
                Spacer()
            }
            Text(recommendation.message)
                .font(.body)
                .foregroundStyle(.primary)
            HStack {
                Spacer()
                if let apply = recommendation.apply {
                    Button("Anwenden") {
                        apply()
                        engine.refresh()
                    }
                    .controlSize(.small)
                }
                Button("Ausblenden") {
                    engine.dismiss(recommendation)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    private var iconName: String {
        switch recommendation.category {
        case .thresholdTuning: return "slider.horizontal.3"
        case .gapDetection: return "magnifyingglass"
        case .pressurePattern: return "thermometer.high"
        case .missingCoverage: return "questionmark.circle"
        }
    }

    private var iconColor: Color {
        switch recommendation.category {
        case .thresholdTuning: return .blue
        case .gapDetection: return .gray
        case .pressurePattern: return .orange
        case .missingCoverage: return .purple
        }
    }
}
