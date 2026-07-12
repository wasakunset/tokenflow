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

    /// Regression window for the burn rate: recent enough to react, long
    /// enough that one heavy turn doesn't dominate.
    private let slopeWindow: TimeInterval = 45 * 60
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

    /// Least-squares slope over the recent window → predicted time of hitting
    /// 100%, or nil when there's too little data, usage is flat/idle, or the
    /// window resets before the projected hit.
    func predictedLimitHit(provider: String, window: LimitWindow) -> Date? {
        let recent = samples(Self.key(provider, window), last: slopeWindow)
        guard recent.count >= 3,
              let first = recent.first, let last = recent.last,
              last.t.timeIntervalSince(first.t) >= 10 * 60 else { return nil }

        let t0 = first.t.timeIntervalSince1970
        let xs = recent.map { $0.t.timeIntervalSince1970 - t0 }
        let ys = recent.map(\.pct)
        let n = Double(recent.count)
        let sumX = xs.reduce(0, +), sumY = ys.reduce(0, +)
        let meanX = sumX / n, meanY = sumY / n
        var cov = 0.0, varX = 0.0
        for i in 0..<recent.count {
            cov += (xs[i] - meanX) * (ys[i] - meanY)
            varX += (xs[i] - meanX) * (xs[i] - meanX)
        }
        guard varX > 0 else { return nil }
        let slope = cov / varX // %/second

        // Idle threshold: under ~3%/hour isn't a pace worth warning about.
        guard slope * 3600 >= 3 else { return nil }

        let secondsToFull = (100 - last.pct) / slope
        guard secondsToFull > 0 else { return nil }
        let hit = last.t.addingTimeInterval(secondsToFull)

        // Only meaningful if the wall arrives before the reset does.
        if let resets = window.resetsAt, hit >= resets { return nil }
        return hit
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(series) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
