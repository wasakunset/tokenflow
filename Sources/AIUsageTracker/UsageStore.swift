import Foundation

/// Observable state shared by the menu bar title and the popover UI.
///
/// Handles fetch hygiene so the providers don't get rate-limited:
/// - automatic refreshes are throttled to one attempt per 45s
/// - a provider that answers HTTP 429 is backed off (Retry-After respected)
/// - while backed off or failing, the last good snapshot stays visible with
///   a note instead of being replaced by an error.
final class UsageStore: ObservableObject {
    @Published var claude = ProviderUsage(name: "Claude")
    @Published var codex = ProviderUsage(name: "Codex")
    @Published var lastUpdated: Date?
    @Published var refreshing = false

    /// Called on the main thread after every refresh (updates the status item title).
    var onUpdate: (() -> Void)?

    private var lastGood: [String: (usage: ProviderUsage, at: Date)] = [:]
    private var backoffUntil: [String: Date] = [:]
    private var lastAttempt: Date = .distantPast

    func refresh(force: Bool = false) {
        guard !refreshing else { return }
        // No fetching before the welcome flow — the first Keychain read must
        // happen after the user has seen the "Always Allow" explanation.
        guard AppSettings.shared.hasCompletedWelcome else { return }
        if !force, Date().timeIntervalSince(lastAttempt) < 45 { return }
        lastAttempt = Date()
        refreshing = true

        let showClaude = AppSettings.shared.showClaude
        let showCodex = AppSettings.shared.showCodex
        let skipClaude = !showClaude || isBackedOff("Claude")
        let skipCodex = !showCodex || isBackedOff("Codex")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let claude = skipClaude ? nil : ClaudeProvider().fetch()
            let codex = skipCodex ? nil : CodexProvider().fetch()
            DispatchQueue.main.async {
                guard let self else { return }
                if showClaude { self.claude = self.resolve("Claude", fresh: claude) }
                if showCodex { self.codex = self.resolve("Codex", fresh: codex) }
                NotificationManager.shared.check(self.claude)
                NotificationManager.shared.check(self.codex)
                self.lastUpdated = Date()
                self.refreshing = false
                self.onUpdate?()
            }
        }
    }

    private func isBackedOff(_ name: String) -> Bool {
        (backoffUntil[name] ?? .distantPast) > Date()
    }

    /// Fold a fresh fetch result (or a skipped fetch) into what the UI shows.
    private func resolve(_ name: String, fresh: ProviderUsage?) -> ProviderUsage {
        guard let fresh else {
            // Skipped: still backed off. Keep showing the cached snapshot.
            var usage = lastGood[name]?.usage ?? ProviderUsage(name: name)
            if usage.windows.isEmpty {
                usage.error = "rate limited — retrying \(Fmt.reset(backoffUntil[name]))"
            } else {
                usage.note = staleNote(name, reason: "rate limited")
            }
            return usage
        }

        if fresh.error == nil, !fresh.windows.isEmpty {
            if let retry = fresh.retryAfterSeconds {
                backoffUntil[name] = Date().addingTimeInterval(max(retry, 600))
            } else {
                backoffUntil[name] = nil
            }
            lastGood[name] = (fresh, Date())
            return fresh
        }

        if let retry = fresh.retryAfterSeconds {
            backoffUntil[name] = Date().addingTimeInterval(max(retry, 600))
        }
        if let prev = lastGood[name] {
            var usage = prev.usage
            usage.note = staleNote(
                name,
                reason: fresh.retryAfterSeconds != nil ? "rate limited" : "refresh failed"
            )
            return usage
        }
        return fresh
    }

    private func staleNote(_ name: String, reason: String) -> String {
        let at = lastGood[name].map { Fmt.timestamp($0.at) } ?? "earlier"
        var note = "\(reason) — showing \(at) data"
        if let until = backoffUntil[name], until > Date() {
            note += ", retrying \(Fmt.reset(until))"
        }
        return note
    }
}
