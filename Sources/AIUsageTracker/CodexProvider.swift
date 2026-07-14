import Foundation

/// Fetches live Codex usage from the ChatGPT backend using the OAuth token
/// Codex CLI stores in ~/.codex/auth.json. If that fails (expired token,
/// offline), falls back to the last rate-limit snapshot Codex wrote into its
/// session logs.
struct CodexProvider {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    /// Codex CLI's public OAuth client id.
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    var codexHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    func fetch() -> ProviderUsage {
        var usage = ProviderUsage(name: "Codex")
        var rateLimitedFor: Double?
        do {
            let (token, accountID) = try readAuth()
            var req = URLRequest(url: Self.usageURL)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if !accountID.isEmpty {
                req.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            }
            let (status, json, retryAfter) = try HTTP.requestJSON(req)
            if status == 429 {
                rateLimitedFor = retryAfter ?? 900
                throw FetchError.message("rate limited by usage endpoint")
            }
            guard status == 200, let rateLimit = json["rate_limit"] as? [String: Any] else {
                throw FetchError.message("usage endpoint returned \(status)")
            }
            usage.plan = (json["plan_type"] as? String)?.capitalized
            usage.windows = Self.parseLive(rateLimit)
            return usage
        } catch {
            // Live fetch failed — try the local session-log snapshot.
            if var fallback = fetchFromSessionLogs() {
                fallback.plan = usage.plan ?? fallback.plan
                fallback.retryAfterSeconds = rateLimitedFor
                return fallback
            }
            usage.error = "\(error)"
            usage.errorKind = (error as? FetchError)?.kind ?? .other
            usage.retryAfterSeconds = rateLimitedFor
            return usage
        }
    }

    /// CLI credentials first; falls back to an account connected in-app.
    private func readAuth() throws -> (token: String, accountID: String) {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            if var token = AppCredentials.load().codex {
                if token.isExpired { token = try AppTokenRefresh.codex(token) }
                return (token.accessToken, token.accountId ?? "")
            }
            throw FetchError.typed(.notConfigured, "Codex isn't set up on this Mac")
        }
        guard let data = try? Data(contentsOf: authURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String else {
            throw FetchError.message("couldn't read ~/.codex/auth.json — log in with `codex` again")
        }
        return (access, tokens["account_id"] as? String ?? "")
    }

    /// Whether Codex credentials exist (CLI file or app-connected account).
    static func isConfigured() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/auth.json").path) {
            return true
        }
        return AppCredentials.load().codex != nil
    }

    /// OpenAI has reshaped this response before (e.g. dropping the 5h window
    /// and putting the weekly limit in `primary_window`), so windows are
    /// labeled by their actual duration, never by their position.
    static func windowLabel(seconds: Double) -> String {
        let hours = seconds / 3600
        if hours <= 12 { return "Session (\(Int(hours))h)" }
        if hours <= 48 { return "Daily" }
        return "Weekly"
    }

    static func parseLive(_ rateLimit: [String: Any]) -> [LimitWindow] {
        func window(_ key: String) -> LimitWindow? {
            guard let obj = rateLimit[key] as? [String: Any],
                  let pct = obj["used_percent"] as? Double else { return nil }
            let resets = (obj["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            let seconds = obj["limit_window_seconds"] as? Double ?? 5 * 3600
            return LimitWindow(label: windowLabel(seconds: seconds), percent: pct, resetsAt: resets)
        }
        var windows: [LimitWindow] = []
        if let w = window("primary_window") { windows.append(w) }
        if let w = window("secondary_window") { windows.append(w) }
        return windows
    }

    // MARK: - Session-log fallback

    /// Newest `token_count` event with `rate_limits` from ~/.codex/sessions/**.jsonl.
    func fetchFromSessionLogs() -> ProviderUsage? {
        guard let file = newestSessionFile(),
              let contents = tail(of: file, bytes: 512 * 1024) else { return nil }

        for line in contents.split(separator: "\n").reversed() {
            guard line.contains("\"rate_limits\""),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }

            func window(_ key: String) -> LimitWindow? {
                guard let w = limits[key] as? [String: Any],
                      let pct = w["used_percent"] as? Double else { return nil }
                let resets = (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                let minutes = w["window_minutes"] as? Double ?? 300
                return LimitWindow(
                    label: Self.windowLabel(seconds: minutes * 60),
                    percent: pct, resetsAt: resets
                )
            }
            var usage = ProviderUsage(name: "Codex")
            if let w = window("primary") { usage.windows.append(w) }
            if let w = window("secondary") { usage.windows.append(w) }
            guard !usage.windows.isEmpty else { continue }
            usage.plan = (limits["plan_type"] as? String)?.capitalized
            if let ts = (obj["timestamp"] as? String).flatMap(Fmt.parseISO) {
                usage.note = "offline — from session log, \(Fmt.timestamp(ts))"
            } else {
                usage.note = "offline — from session log"
            }
            return usage
        }
        return nil
    }

    private func newestSessionFile() -> URL? {
        let sessions = codexHome.appendingPathComponent("sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        var newest: (URL, Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest == nil || mtime > newest!.1 { newest = (url, mtime) }
        }
        return newest?.0
    }

    private func tail(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
