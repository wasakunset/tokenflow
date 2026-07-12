import Foundation

/// One rate-limit window (e.g. "Session (5h)" or "Weekly").
struct LimitWindow {
    let label: String
    let percent: Double
    let resetsAt: Date?
}

/// Usage snapshot for one provider (Claude or Codex).
struct ProviderUsage {
    let name: String
    var plan: String?
    var windows: [LimitWindow] = []
    /// Extra info line, e.g. "from session log (10 Jul 20:40)" when data is stale.
    var note: String?
    /// If set, fetching failed and `windows` is empty.
    var error: String?
    /// What kind of failure `error` is — drives the recovery UI.
    var errorKind: ErrorKind = .other
    /// Set when the provider replied HTTP 429 — seconds to wait before retrying.
    var retryAfterSeconds: Double?

    /// The 5-hour/session window, used for the menu bar title.
    var primaryPercent: Double? { windows.first?.percent }
}

enum ErrorKind {
    /// The provider's CLI was never set up on this machine.
    case notConfigured
    /// The user denied the Keychain prompt.
    case permissionDenied
    case other
}

enum FetchError: Error, CustomStringConvertible {
    case message(String)
    case typed(ErrorKind, String)

    var description: String {
        switch self {
        case .message(let m): return m
        case .typed(_, let m): return m
        }
    }

    var kind: ErrorKind {
        if case .typed(let k, _) = self { return k }
        return .other
    }
}

/// Minimal synchronous HTTP helper (callers run on background queues).
enum HTTP {
    static func requestJSON(_ request: URLRequest) throws -> (status: Int, json: [String: Any], retryAfter: Double?) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?)
        let task = URLSession.shared.dataTask(with: request) { data, resp, err in
            result = (data, resp, err)
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 20)

        if let err = result.2 { throw FetchError.message(err.localizedDescription) }
        guard let http = result.1 as? HTTPURLResponse, let data = result.0 else {
            throw FetchError.message("no response")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
        return (http.statusCode, obj, retryAfter)
    }
}

enum Fmt {
    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    static func parseISO(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? iso.date(from: s)
    }

    /// "18:59" if within 24h, otherwise "Sat 18:59".
    static func reset(_ date: Date?) -> String {
        guard let date else { return "–" }
        let f = DateFormatter()
        f.dateFormat = date.timeIntervalSinceNow < 24 * 3600 ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }

    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: date)
    }

    /// "42m", "3h 12m", "2d 5h" until `date`; nil if past or unknown.
    static func countdown(_ date: Date?) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(1, minutes))m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// "just now", "2 min. ago", …
    static func relative(_ date: Date) -> String {
        if -date.timeIntervalSinceNow < 5 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
