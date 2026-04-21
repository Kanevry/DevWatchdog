import Foundation

// MARK: - Recommendation model

struct InsightRecommendation: Identifiable {
    enum Category: String { case thresholdTuning, gapDetection, pressurePattern, missingCoverage }
    let id: String
    let category: Category
    let title: String
    let message: String
    /// Optional one-click apply closure. If nil, only a Dismiss button is shown.
    let apply: (@MainActor () -> Void)?
}

// MARK: - Engine

@MainActor
final class InsightsEngine: ObservableObject {
    @Published private(set) var recommendations: [InsightRecommendation] = []
    @Published private(set) var lastAnalyzedAt: Date?

    private let log: SessionLog
    private let config: WatchdogConfig

    /// Dismissed recommendation IDs persisted in UserDefaults with timestamp.
    /// Format: [recommendationKey: ISO8601 dismissal timestamp]
    private let dismissalKey = "insightsDismissals"
    private var dismissals: [String: Date] = [:]

    init(log: SessionLog, config: WatchdogConfig) {
        self.log = log
        self.config = config
        loadDismissals()
    }

    /// Analyze current SessionLog entries against config.
    func refresh() {
        let entries = log.entries
        var recs: [InsightRecommendation] = []
        recs.append(contentsOf: analyzeThresholdTuning(entries: entries))
        recs.append(contentsOf: analyzeGapDetection(entries: entries))
        recs.append(contentsOf: analyzePressurePattern(entries: entries))
        recs.append(contentsOf: analyzeMissingCoverage(entries: entries))

        // Filter out dismissed (within last 7 days)
        let now = Date()
        recs = recs.filter { rec in
            guard let dismissedAt = dismissals[rec.id] else { return true }
            return now.timeIntervalSince(dismissedAt) > 7 * 86400
        }
        self.recommendations = recs
        self.lastAnalyzedAt = now
    }

    // MARK: - Analysis passes

    /// "Rule X has fired N times in a row with actual close to threshold — suggest raising threshold."
    private func analyzeThresholdTuning(entries: [SessionLogEntry]) -> [InsightRecommendation] {
        let killEntries = entries.filter { $0.kind == .kill && $0.killReason != nil }

        var byRule: [UUID: [SessionLogEntry]] = [:]
        for e in killEntries {
            guard let rid = e.killReason?.ruleID else { continue }
            byRule[rid, default: []].append(e)
        }

        var out: [InsightRecommendation] = []
        for (rid, kills) in byRule {
            guard kills.count >= 4,
                  let rule = config.rules.first(where: { $0.id == rid }) else { continue }

            let recent = kills.suffix(4)
            let actuals = recent.compactMap { $0.killReason?.actualValue }
            let thresholds = recent.compactMap { $0.killReason?.thresholdValue }

            guard let firstTrigger = recent.first?.killReason?.trigger,
                  !actuals.isEmpty,
                  !thresholds.isEmpty else { continue }

            let avgActual = actuals.reduce(0, +) / Double(actuals.count)
            let avgThreshold = thresholds.reduce(0, +) / Double(thresholds.count)

            guard avgActual < avgThreshold * 1.1 else { continue }

            let suggested = (avgThreshold * 1.2).rounded()
            let unit = recent.first?.killReason?.unit ?? ""
            let key = "threshold-tuning:\(rid.uuidString):\(firstTrigger.rawValue)"
            let msg = "Regel \u{201C}\(rule.pattern)\u{201D} hat \(kills.count)\u{D7} gegriffen, Ist-Werte (\(Int(avgActual)) \(unit)) nah am Threshold (\(Int(avgThreshold)) \(unit)). Vorschlag: Threshold auf \(Int(suggested)) \(unit) erh\u{F6}hen."

            out.append(InsightRecommendation(
                id: key,
                category: .thresholdTuning,
                title: "Threshold anheben?",
                message: msg,
                apply: { [weak self] in
                    guard let self else { return }
                    if let idx = self.config.rules.firstIndex(where: { $0.id == rid }) {
                        var r = self.config.rules[idx]
                        switch firstTrigger {
                        case .maxRuntime, .catchAllMaxRuntime: r.maxRuntime = suggested
                        case .maxCPUPercent: r.maxCPUPercent = suggested
                        case .maxRSSMB: r.maxRSSMB = suggested
                        default: return
                        }
                        self.config.rules[idx] = r
                    }
                }
            ))
        }
        return out
    }

    /// "No kills in last 7 days — rules may be too loose, or no zombies."
    private func analyzeGapDetection(entries: [SessionLogEntry]) -> [InsightRecommendation] {
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 86400)
        let recentKills = entries.filter { $0.kind == .kill && $0.timestamp > sevenDaysAgo }
        guard recentKills.isEmpty, !entries.isEmpty else { return [] }
        return [InsightRecommendation(
            id: "gap-detection:7d",
            category: .gapDetection,
            title: "Keine Zombies in 7 Tagen",
            message: "In den letzten 7 Tagen wurde 0\u{D7} ein Zombie gefangen. M\u{F6}gliche Gr\u{FC}nde: Regeln zu locker, oder du hast eh keine Zombies.",
            apply: nil
        )]
    }

    /// "Emergency entered N times in last 24h — suggest soft-kill default."
    private func analyzePressurePattern(entries: [SessionLogEntry]) -> [InsightRecommendation] {
        let dayAgo = Date().addingTimeInterval(-86400)
        let emergencyEntries = entries.filter { $0.kind == .emergencyEntered && $0.timestamp > dayAgo }
        guard emergencyEntries.count >= 3, !config.softKillPreferred else { return [] }
        return [InsightRecommendation(
            id: "pressure-pattern:24h",
            category: .pressurePattern,
            title: "Emergency h\u{E4}ufig aktiv",
            message: "Emergency Mode war heute \(emergencyEntries.count)\u{D7} aktiv. Erw\u{E4}ge Soft-Kill als Default.",
            apply: { [weak self] in self?.config.softKillPreferred = true }
        )]
    }

    /// "Process X detected N times but no rule covers it."
    private func analyzeMissingCoverage(entries: [SessionLogEntry]) -> [InsightRecommendation] {
        var catchAllHits: [String: Int] = [:]
        for e in entries where e.kind == .kill {
            if let reason = e.killReason, reason.trigger == .catchAllMaxRuntime,
               let name = e.processName, !name.isEmpty {
                catchAllHits[name, default: 0] += 1
            }
        }
        return catchAllHits
            .filter { $0.value >= 5 }
            .map { name, count in
                InsightRecommendation(
                    id: "missing-coverage:\(name)",
                    category: .missingCoverage,
                    title: "Regel f\u{FC}r \(name)?",
                    message: "Prozess \u{201C}\(name)\u{201D} wurde \(count)\u{D7} via Catch-All gekillt \u{2014} keine spezifische Regel deckt ihn ab.",
                    apply: nil
                )
            }
    }

    // MARK: - Dismissals

    /// Dismiss a recommendation for 7 days.
    func dismiss(_ rec: InsightRecommendation) {
        dismissals[rec.id] = Date()
        saveDismissals()
        refresh()
    }

    private func loadDismissals() {
        guard let data = UserDefaults.standard.data(forKey: dismissalKey),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else { return }
        dismissals = decoded
    }

    private func saveDismissals() {
        if let data = try? JSONEncoder().encode(dismissals) {
            UserDefaults.standard.set(data, forKey: dismissalKey)
        }
    }
}
