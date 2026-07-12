import Foundation
import Security

/// Reads Claude Code's OAuth credentials from the macOS Keychain, refreshes the
/// access token when expired (writing the rotated tokens back so Claude Code
/// keeps working), and queries the official usage endpoint — the same data
/// `/usage` shows inside Claude Code.
struct ClaudeProvider {
    static let keychainService = "Claude Code-credentials"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    /// Claude Code's public OAuth client id.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    func fetch() -> ProviderUsage {
        var usage = ProviderUsage(name: "Claude")
        do {
            var creds = try loadCredentials()
            if creds.isExpired {
                creds = try refresh(creds)
            }
            var (status, json, retryAfter) = try callUsage(token: creds.accessToken)
            if status == 401 {
                // Token was invalidated early (e.g. Claude Code refreshed it
                // after we read it) — re-read, force-refresh, and retry once.
                creds = try loadCredentials()
                creds = try refresh(creds)
                (status, json, retryAfter) = try callUsage(token: creds.accessToken)
            }
            if status == 429 {
                usage.error = "rate limited by usage endpoint"
                usage.retryAfterSeconds = retryAfter ?? 900
                return usage
            }
            guard status == 200 else {
                throw FetchError.message("usage endpoint returned \(status)")
            }
            usage.plan = creds.subscriptionType?.capitalized
            usage.windows = Self.parseWindows(json)
        } catch {
            usage.error = "\(error)"
            usage.errorKind = (error as? FetchError)?.kind ?? .other
        }
        return usage
    }

    /// Whether Claude credentials exist (CLI keychain item or app-connected
    /// account), without triggering the Keychain permission prompt
    /// (attribute-only queries don't require ACL approval).
    static func isConfigured() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess { return true }
        return AppCredentials.load().claude != nil
    }

    static func parseWindows(_ json: [String: Any]) -> [LimitWindow] {
        func window(_ key: String, label: String) -> LimitWindow? {
            guard let obj = json[key] as? [String: Any],
                  let pct = obj["utilization"] as? Double else { return nil }
            let resets = (obj["resets_at"] as? String).flatMap(Fmt.parseISO)
            return LimitWindow(label: label, percent: pct, resetsAt: resets)
        }
        var windows: [LimitWindow] = []
        if let w = window("five_hour", label: "Session (5h)") { windows.append(w) }
        if let w = window("seven_day", label: "Weekly (all)") { windows.append(w) }
        if let w = window("seven_day_opus", label: "Weekly (Opus)") { windows.append(w) }
        if let w = window("seven_day_sonnet", label: "Weekly (Sonnet)") { windows.append(w) }
        return windows
    }

    private func callUsage(token: String) throws -> (Int, [String: Any], Double?) {
        var req = URLRequest(url: Self.usageURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return try HTTP.requestJSON(req)
    }

    // MARK: - Credentials

    struct Credentials {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Double // ms since epoch
        var subscriptionType: String?
        /// Full keychain JSON, preserved so a token refresh doesn't drop fields.
        var raw: [String: Any]
        /// True when these came from the app's own Connect flow rather than
        /// Claude Code's keychain item.
        var fromApp: Bool = false

        var isExpired: Bool {
            Date(timeIntervalSince1970: expiresAt / 1000) < Date().addingTimeInterval(120)
        }
    }

    /// CLI credentials first; falls back to an account connected in-app.
    private func loadCredentials() throws -> Credentials {
        do {
            return try readCLICredentials()
        } catch let error as FetchError where error.kind == .notConfigured {
            guard let token = AppCredentials.load().claude else { throw error }
            return Credentials(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                expiresAt: token.expiresAt,
                subscriptionType: nil,
                raw: [:],
                fromApp: true
            )
        }
    }

    private func readCLICredentials() throws -> Credentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            switch status {
            case errSecItemNotFound:
                throw FetchError.typed(.notConfigured, "Claude Code isn't set up on this Mac")
            case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
                throw FetchError.typed(.permissionDenied, "Keychain access was denied")
            default:
                throw FetchError.message("couldn't read credentials (keychain status \(status))")
            }
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String,
              let refresh = oauth["refreshToken"] as? String else {
            throw FetchError.message("unexpected credential format")
        }
        return Credentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: oauth["expiresAt"] as? Double ?? 0,
            subscriptionType: oauth["subscriptionType"] as? String,
            raw: root
        )
    }

    private func refresh(_ creds: Credentials) throws -> Credentials {
        if creds.fromApp {
            let refreshed = try AppTokenRefresh.claude(AppStoredToken(
                accessToken: creds.accessToken,
                refreshToken: creds.refreshToken,
                expiresAt: creds.expiresAt,
                accountId: nil
            ))
            var updated = creds
            updated.accessToken = refreshed.accessToken
            updated.refreshToken = refreshed.refreshToken
            updated.expiresAt = refreshed.expiresAt
            return updated
        }
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": Self.clientID,
        ])
        let (status, json, _) = try HTTP.requestJSON(req)
        guard status == 200, let access = json["access_token"] as? String else {
            throw FetchError.message("token refresh failed (\(status)) — run `claude` to re-authenticate")
        }
        let newRefresh = json["refresh_token"] as? String ?? creds.refreshToken
        let expiresIn = json["expires_in"] as? Double ?? 3600
        let expiresAt = (Date().timeIntervalSince1970 + expiresIn) * 1000

        var updated = creds
        updated.accessToken = access
        updated.refreshToken = newRefresh
        updated.expiresAt = expiresAt

        // Persist rotated tokens so Claude Code's own login stays valid.
        var root = creds.raw
        var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = access
        oauth["refreshToken"] = newRefresh
        oauth["expiresAt"] = expiresAt
        root["claudeAiOauth"] = oauth
        if let data = try? JSONSerialization.data(withJSONObject: root) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.keychainService,
            ]
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        return updated
    }
}
