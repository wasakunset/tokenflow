import Foundation
import UserNotifications

/// Fires a macOS notification when a window crosses 70% (warning) or 90%
/// (critical) — once per threshold per window cycle, re-armed when the
/// window resets or usage falls well below the threshold again.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private var notified: [String: (threshold: Int, resetsAt: Date?)] = [:]
    private var authRequested = false

    /// UNUserNotificationCenter crashes outside a real .app bundle
    /// (e.g. `swift run`), so notifications are silently unavailable there.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func check(_ usage: ProviderUsage) {
        guard available, AppSettings.shared.notificationsEnabled,
              usage.error == nil, usage.note == nil else { return }

        for window in usage.windows {
            let key = "\(usage.name)|\(window.label)"
            let crossed: Int? = window.percent >= 90 ? 90 : (window.percent >= 70 ? 70 : nil)

            var state = notified[key]
            if let prev = state, !sameWindowCycle(prev.resetsAt, window.resetsAt) {
                state = nil // the window reset → re-arm
                notified[key] = nil
            }

            if let crossed {
                if state == nil || state!.threshold < crossed {
                    send(provider: usage.name, window: window, threshold: crossed)
                    notified[key] = (crossed, window.resetsAt)
                }
            } else if let prev = state, window.percent < Double(prev.threshold - 5) {
                notified[key] = nil // dropped clearly below → re-arm
            }
        }
    }

    /// Reset timestamps drift by a second or two between fetches on rolling
    /// windows — only treat a clearly different time as a new cycle.
    private func sameWindowCycle(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?): return abs(a.timeIntervalSince(b)) < 120
        default: return false
        }
    }

    private func send(provider: String, window: LimitWindow, threshold: Int) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = "\(provider) at \(Int(window.percent.rounded()))%"
            var body = window.label
            if let countdown = Fmt.countdown(window.resetsAt) {
                body += " — resets in \(countdown) (\(Fmt.reset(window.resetsAt)))"
            }
            content.body = body
            if threshold >= 90 { content.sound = .default }
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            ))
        }

        if authRequested {
            deliver()
        } else {
            authRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { deliver() }
            }
        }
    }

    /// Dev helper (`--test-notification`): exercises the full permission +
    /// delivery path with a fake crossing.
    func sendTest() {
        guard available else { return }
        send(
            provider: "Claude",
            window: LimitWindow(
                label: "Session (5h)", percent: 91,
                resetsAt: Date().addingTimeInterval(42 * 60)
            ),
            threshold: 90
        )
    }

    /// Show banners even though the app is technically always running.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
