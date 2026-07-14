import Foundation

/// Gemini usage. Unlike Claude/Codex (rolling % windows), Gemini limits are a
/// hard **requests-per-day** count that resets at midnight Pacific:
///   Code Assist free 1,000 · AI Pro 1,500 · AI Ultra 2,000 · API-key free 250.
///
/// The app reads the Gemini CLI's OAuth credentials from ~/.gemini and the
/// tier from Google's Code Assist endpoint, then expresses today's request
/// count as a percentage of the daily limit. If the request count can't be
/// determined it shows a note rather than a fabricated number.
///
/// NOTE: This provider is unverified against a live Gemini account (none was
/// available at build time). On a machine without the Gemini CLI it correctly
/// reports "not set up"; the live path activates once `gemini` is logged in.
struct GeminiProvider {
    static let codeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!

    var geminiHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
    }
    private var credsURL: URL { geminiHome.appendingPathComponent("oauth_creds.json") }

    static func isConfigured() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/oauth_creds.json").path)
    }

    func fetch() -> ProviderUsage {
        var usage = ProviderUsage(name: "Gemini")
        do {
            let token = try readToken()
            let (plan, dailyLimit) = tier(token: token)
            usage.plan = plan

            let used = requestsToday()
            let resets = nextPacificMidnight()
            if let used {
                let pct = min(100, Double(used) / Double(dailyLimit) * 100)
                usage.windows = [LimitWindow(
                    label: "Daily (\(used)/\(dailyLimit))",
                    percent: pct, resetsAt: resets
                )]
            } else {
                // Authenticated, but no local request-count source found.
                usage.windows = [LimitWindow(label: "Daily limit \(dailyLimit)", percent: 0, resetsAt: resets)]
                usage.note = "request tracking unavailable — showing limit only"
            }
        } catch {
            usage.error = "\(error)"
            usage.errorKind = (error as? FetchError)?.kind ?? .other
        }
        return usage
    }

    // MARK: - Credentials

    private func readToken() throws -> String {
        guard FileManager.default.fileExists(atPath: credsURL.path) else {
            throw FetchError.typed(.notConfigured, "Gemini CLI isn't set up on this Mac")
        }
        guard let data = try? Data(contentsOf: credsURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = root["access_token"] as? String else {
            throw FetchError.message("couldn't read ~/.gemini/oauth_creds.json — run `gemini` again")
        }
        // expiry_date is ms since epoch; Google tokens last ~1h.
        if let expiry = root["expiry_date"] as? Double,
           Date(timeIntervalSince1970: expiry / 1000) < Date() {
            throw FetchError.message("Gemini token expired — run `gemini` to refresh")
        }
        return access
    }

    /// Plan name and daily request limit from the Code Assist tier, defaulting
    /// to the free Individual tier when the endpoint is unreachable.
    private func tier(token: String) -> (plan: String?, dailyLimit: Int) {
        var req = URLRequest(url: Self.codeAssistURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["metadata": ["pluginType": "GEMINI"]])

        guard let (status, json, _) = try? HTTP.requestJSON(req), status == 200 else {
            return (nil, 1000)
        }
        let tierId = ((json["currentTier"] as? [String: Any])?["id"] as? String)?.lowercased() ?? ""
        switch tierId {
        case let t where t.contains("ultra"): return ("Ultra", 2000)
        case let t where t.contains("pro"): return ("Pro", 1500)
        case let t where t.contains("standard"): return ("Standard", 1500)
        case let t where t.contains("enterprise"): return ("Enterprise", 2000)
        default: return ("Free", 1000)
        }
    }

    // MARK: - Request count

    /// Best-effort count of today's model requests from the Gemini CLI's local
    /// telemetry log (`~/.gemini/tmp/**/telemetry*.log` or `logs.json`).
    /// Returns nil when no readable source exists, so the UI can be honest.
    private func requestsToday() -> Int? {
        let tmp = geminiHome.appendingPathComponent("tmp")
        guard let enumerator = FileManager.default.enumerator(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        let startOfDay = Calendar.current.startOfDay(for: Date())
        var count = 0
        var found = false
        for case let url as URL in enumerator
        where url.lastPathComponent.contains("telemetry") || url.pathExtension == "log" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            found = true
            for line in text.split(separator: "\n") {
                // Count generate/streamGenerateContent request events dated today.
                guard line.contains("generateContent") || line.contains("api_request") else { continue }
                if let ts = isoTimestamp(in: line), ts < startOfDay { continue }
                count += 1
            }
        }
        return found ? count : nil
    }

    private func isoTimestamp(in line: Substring) -> Date? {
        // Pull the first ISO-8601 looking token, if any.
        guard let range = line.range(of: #"\d{4}-\d{2}-\d{2}T[\d:.]+Z?"#, options: .regularExpression) else {
            return nil
        }
        return Fmt.parseISO(String(line[range]))
    }

    private func nextPacificMidnight() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return cal.startOfDay(for: tomorrow)
    }
}
