import Foundation

/// Rolling usage samples per provider window, persisted across launches.
/// Powers the burn-rate prediction and the sparklines. Main-thread only
/// (samples are recorded from the store's main-queue completion).
final class UsageHistory {
    static let shared = UsageHistory()

    struct Sample: Codable {
        let t: Date
        let pct: Double
    }

    private(set) var series: [String: [Sample]] = [:]
    private let fileURL: URL

    private let retention: TimeInterval = 7 * 24 * 3600

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([String: [Sample]].self, from: data) {
            series = loaded
        }
    }

    static func key(_ provider: String, _ window: LimitWindow) -> String {
        "\(provider)|\(window.label)"
    }

    /// Record fresh (non-cached) readings for a provider.
    func record(_ usage: ProviderUsage) {
        guard usage.error == nil, usage.note == nil else { return }
        let now = Date()
        for window in usage.windows {
            let key = Self.key(usage.name, window)
            var samples = series[key] ?? []
            // A drop means the window reset — old samples describe a dead cycle.
            if let last = samples.last, window.percent < last.pct - 1 {
                samples = []
            }
            samples.append(Sample(t: now, pct: window.percent))
            let cutoff = now.addingTimeInterval(-retention)
            samples.removeAll { $0.t < cutoff }
            series[key] = samples
        }
        save()
    }

    func samples(_ key: String, last interval: TimeInterval) -> [Sample] {
        let cutoff = Date().addingTimeInterval(-interval)
        return (series[key] ?? []).filter { $0.t >= cutoff }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(series) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
