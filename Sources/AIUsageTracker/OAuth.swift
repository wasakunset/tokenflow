import AppKit
import CryptoKit
import Foundation
import Network
import Security

// MARK: - App-owned credential storage
// Tokens obtained via our own Connect flow live in our own Keychain item —
// completely separate from the CLIs' credentials, which we never write to
// except when refreshing Claude Code's own token in place.

struct AppStoredToken: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double // ms since epoch
    var accountId: String?

    var isExpired: Bool {
        Date(timeIntervalSince1970: expiresAt / 1000) < Date().addingTimeInterval(120)
    }
}

struct AppCredentials: Codable {
    var claude: AppStoredToken?
    var codex: AppStoredToken?

    static let service = "TokenFlow credentials"

    static func load() -> AppCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let creds = try? JSONDecoder().decode(AppCredentials.self, from: data) else {
            return AppCredentials()
        }
        return creds
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

// MARK: - PKCE helpers

private func randomURLSafe(_ count: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: count)
    _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    return Data(bytes).base64URLEncoded()
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private func codeChallenge(for verifier: String) -> String {
    Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
}

/// Decode a JWT payload without verifying (we only extract our own account id).
private func jwtClaims(_ jwt: String) -> [String: Any] {
    let parts = jwt.split(separator: ".")
    guard parts.count >= 2 else { return [:] }
    var b64 = String(parts[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }
    guard let data = Data(base64Encoded: b64) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

// MARK: - Local callback server

/// Minimal one-shot HTTP server: waits for the browser redirect, replies with
/// a "you can close this tab" page, hands back the query parameters.
final class CallbackServer {
    private var listener: NWListener?
    private var completed = false

    func start(port: UInt16, path: String, completion: @escaping (Result<[String: String], FetchError>) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            listener = try NWListener(using: .tcp, on: nwPort)
        } catch {
            completion(.failure(.message("couldn't listen on port \(port) — is another app using it?")))
            return
        }
        listener?.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                guard let self, let data,
                      let request = String(data: data, encoding: .utf8),
                      let firstLine = request.split(separator: "\r\n").first else {
                    conn.cancel()
                    return
                }
                let parts = firstLine.split(separator: " ")
                let target = parts.count >= 2 ? String(parts[1]) : "/"
                let matches = target.hasPrefix(path)

                let body = matches
                    ? "<html><body style=\"font-family:-apple-system;text-align:center;padding-top:15vh\"><h2>Connected ✓</h2><p>You can close this tab and return to the app.</p></body></html>"
                    : "not found"
                let head = matches ? "HTTP/1.1 200 OK" : "HTTP/1.1 404 Not Found"
                let response = "\(head)\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                })

                if matches, !self.completed {
                    self.completed = true
                    var params: [String: String] = [:]
                    URLComponents(string: "http://localhost\(target)")?.queryItems?
                        .forEach { params[$0.name] = $0.value ?? "" }
                    self.stop()
                    completion(.success(params))
                }
            }
        }
        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

// MARK: - OAuth flows

/// Runs the same browser sign-in the CLIs use: open the provider's authorize
/// page, receive the code on a localhost callback, exchange it for tokens,
/// store them in the app's own Keychain item.
final class OAuthManager: ObservableObject {
    static let shared = OAuthManager()

    @Published var busy: String?
    @Published var errors: [String: String] = [:]

    private var server: CallbackServer?
    private var timeoutTask: DispatchWorkItem?

    /// Only Claude and Codex expose the browser OAuth flow the CLIs use.
    /// Gemini is CLI-detected only, so it must never reach `connect`.
    static func supportsConnect(_ provider: String) -> Bool {
        provider == "Claude" || provider == "Codex"
    }

    func connect(_ provider: String, onSuccess: @escaping () -> Void) {
        guard busy == nil else { return }
        guard Self.supportsConnect(provider) else {
            errors[provider] = "\(provider) has no browser sign-in — use its CLI."
            return
        }
        busy = provider
        errors[provider] = nil

        let finish: (Result<Void, FetchError>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.timeoutTask?.cancel()
                self.server?.stop()
                self.server = nil
                self.busy = nil
                switch result {
                case .success: onSuccess()
                case .failure(let error): self.errors[provider] = "\(error)"
                }
            }
        }

        let verifier = randomURLSafe(64)
        let state = randomURLSafe(32)
        let server = CallbackServer()
        self.server = server

        let config: FlowConfig = provider == "Claude" ? .claude : .codex
        server.start(port: config.port, path: config.callbackPath) { result in
            switch result {
            case .failure(let error):
                finish(.failure(error))
            case .success(let params):
                guard params["state"] == nil || params["state"] == state else {
                    finish(.failure(.message("state mismatch — try again")))
                    return
                }
                guard let code = params["code"] else {
                    finish(.failure(.message(params["error"] ?? "no code returned")))
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try config.exchange(code, verifier, state)
                        finish(.success(()))
                    } catch let error as FetchError {
                        finish(.failure(error))
                    } catch {
                        finish(.failure(.message(error.localizedDescription)))
                    }
                }
            }
        }

        NSWorkspace.shared.open(config.authorizeURL(codeChallenge(for: verifier), state))

        let timeout = DispatchWorkItem { finish(.failure(.message("timed out waiting for browser approval"))) }
        timeoutTask = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 240, execute: timeout)
    }

    // MARK: Flow configurations

    private struct FlowConfig {
        let port: UInt16
        let callbackPath: String
        let authorizeURL: (_ challenge: String, _ state: String) -> URL
        let exchange: (_ code: String, _ verifier: String, _ state: String) throws -> Void

        static let claude = FlowConfig(
            port: 54545,
            callbackPath: "/callback",
            authorizeURL: { challenge, state in
                var c = URLComponents(string: "https://claude.ai/oauth/authorize")!
                c.queryItems = [
                    .init(name: "code", value: "true"),
                    .init(name: "client_id", value: ClaudeProvider.clientID),
                    .init(name: "response_type", value: "code"),
                    .init(name: "redirect_uri", value: "http://localhost:54545/callback"),
                    .init(name: "scope", value: "org:create_api_key user:profile user:inference"),
                    .init(name: "code_challenge", value: challenge),
                    .init(name: "code_challenge_method", value: "S256"),
                    .init(name: "state", value: state),
                ]
                return c.url!
            },
            exchange: { code, verifier, state in
                var req = URLRequest(url: ClaudeProvider.tokenURL)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: [
                    "grant_type": "authorization_code",
                    "code": code,
                    "state": state,
                    "client_id": ClaudeProvider.clientID,
                    "redirect_uri": "http://localhost:54545/callback",
                    "code_verifier": verifier,
                ])
                let (status, json, _) = try HTTP.requestJSON(req)
                guard status == 200, let access = json["access_token"] as? String,
                      let refresh = json["refresh_token"] as? String else {
                    throw FetchError.message("token exchange failed (\(status))")
                }
                let expiresIn = json["expires_in"] as? Double ?? 3600
                var creds = AppCredentials.load()
                creds.claude = AppStoredToken(
                    accessToken: access, refreshToken: refresh,
                    expiresAt: (Date().timeIntervalSince1970 + expiresIn) * 1000,
                    accountId: nil
                )
                creds.save()
            }
        )

        static let codex = FlowConfig(
            port: 1455,
            callbackPath: "/auth/callback",
            authorizeURL: { challenge, state in
                var c = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
                c.queryItems = [
                    .init(name: "response_type", value: "code"),
                    .init(name: "client_id", value: CodexProvider.clientID),
                    .init(name: "redirect_uri", value: "http://localhost:1455/auth/callback"),
                    .init(name: "scope", value: "openid profile email offline_access"),
                    .init(name: "code_challenge", value: challenge),
                    .init(name: "code_challenge_method", value: "S256"),
                    .init(name: "id_token_add_organizations", value: "true"),
                    .init(name: "codex_cli_simplified_flow", value: "true"),
                    .init(name: "state", value: state),
                ]
                return c.url!
            },
            exchange: { code, verifier, _ in
                let (status, json) = try postForm(
                    url: URL(string: "https://auth.openai.com/oauth/token")!,
                    fields: [
                        "grant_type": "authorization_code",
                        "code": code,
                        "redirect_uri": "http://localhost:1455/auth/callback",
                        "client_id": CodexProvider.clientID,
                        "code_verifier": verifier,
                    ]
                )
                guard status == 200, let access = json["access_token"] as? String,
                      let refresh = json["refresh_token"] as? String else {
                    throw FetchError.message("token exchange failed (\(status))")
                }
                let expiresIn = json["expires_in"] as? Double ?? 3600
                let idToken = json["id_token"] as? String ?? ""
                let auth = jwtClaims(idToken)["https://api.openai.com/auth"] as? [String: Any]
                var creds = AppCredentials.load()
                creds.codex = AppStoredToken(
                    accessToken: access, refreshToken: refresh,
                    expiresAt: (Date().timeIntervalSince1970 + expiresIn) * 1000,
                    accountId: auth?["chatgpt_account_id"] as? String
                )
                creds.save()
            }
        )
    }
}

// MARK: - Token refresh for app-stored credentials

enum AppTokenRefresh {
    /// Refresh an app-stored Claude token (same endpoint Claude Code uses).
    static func claude(_ token: AppStoredToken) throws -> AppStoredToken {
        var req = URLRequest(url: ClaudeProvider.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": token.refreshToken,
            "client_id": ClaudeProvider.clientID,
        ])
        let (status, json, _) = try HTTP.requestJSON(req)
        guard status == 200, let access = json["access_token"] as? String else {
            throw FetchError.message("reconnect needed — token refresh failed (\(status))")
        }
        var updated = token
        updated.accessToken = access
        updated.refreshToken = json["refresh_token"] as? String ?? token.refreshToken
        updated.expiresAt = (Date().timeIntervalSince1970 + (json["expires_in"] as? Double ?? 3600)) * 1000
        var creds = AppCredentials.load()
        creds.claude = updated
        creds.save()
        return updated
    }

    static func codex(_ token: AppStoredToken) throws -> AppStoredToken {
        let (status, json) = try postForm(
            url: URL(string: "https://auth.openai.com/oauth/token")!,
            fields: [
                "grant_type": "refresh_token",
                "refresh_token": token.refreshToken,
                "client_id": CodexProvider.clientID,
                "scope": "openid profile email",
            ]
        )
        guard status == 200, let access = json["access_token"] as? String else {
            throw FetchError.message("reconnect needed — token refresh failed (\(status))")
        }
        var updated = token
        updated.accessToken = access
        updated.refreshToken = json["refresh_token"] as? String ?? token.refreshToken
        updated.expiresAt = (Date().timeIntervalSince1970 + (json["expires_in"] as? Double ?? 3600)) * 1000
        var creds = AppCredentials.load()
        creds.codex = updated
        creds.save()
        return updated
    }
}

private func postForm(url: URL, fields: [String: String]) throws -> (Int, [String: Any]) {
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.httpBody = fields
        .map { key, value in
            let escaped = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
            return "\(key)=\(escaped)"
        }
        .joined(separator: "&")
        .data(using: .utf8)
    let (status, json, _) = try HTTP.requestJSON(req)
    return (status, json)
}
