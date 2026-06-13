import Foundation
import Security

// Fetches Claude's OFFICIAL usage from Anthropic's OAuth endpoint — the same
// data shown in Claude → Settings → Usage. Reads the Claude Code OAuth token
// from the macOS Keychain ("Claude Code-credentials") and calls
// GET https://api.anthropic.com/api/oauth/usage.
//
// The access token expires roughly every 8 hours. After the Mac sleeps past that
// (e.g. overnight) the stored token is already expired on wake, so a plain request
// would 401 ("Login expired") until Claude Code itself happens to run and refresh
// it. To recover on its own, the scanner refreshes the token here — using the
// stored refresh token — and writes the new credentials back to the Keychain so
// Claude Code stays in sync.
struct ClaudeUsage {
    var available: Bool = false
    var sessionPercent: Double = 0      // five_hour utilization (0–100)
    var sessionResetAt: Date? = nil
    var weekPercent: Double = 0         // seven_day utilization (0–100)
    var weekResetAt: Date? = nil
    var transient: Bool = false         // temporary failure (429/5xx/network) — keep last data
    var retryAfter: TimeInterval? = nil // server-advised wait from Retry-After (429)
    var error: String? = nil
}

enum ClaudeScanner {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let userAgent = "claude-cli/1.0.0 (external)"
    // Claude Code's public OAuth client id (used to refresh the access token).
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    // Where Claude Code keeps its credentials, plus a private backup item TokenBar
    // owns so a rotated refresh token is never lost even if writing Claude Code's
    // item fails.
    private static let claudeService = "Claude Code-credentials"
    private static let backupService = "com.tokenbar.app-claude-oauth"

    static func scan() async -> ClaudeUsage {
        guard var creds = readCredentials() else {
            return ClaudeUsage(available: false,
                               error: "Not signed in — open Claude Code to log in")
        }

        // Proactively refresh an expired (or about-to-expire) token before calling
        // the usage endpoint, so a token that went stale during sleep recovers itself.
        var didRefresh = false
        if creds.needsRefresh {
            switch await refreshCredentials(creds) {
            case .refreshed(let updated):
                creds = updated
                writeCredentials(updated)
                didRefresh = true
            case .revoked:
                return ClaudeUsage(available: false,
                                   error: "Login expired — open Claude Code to refresh")
            case .temporary(let retry):
                // Couldn't refresh right now (endpoint rate-limited / offline) — keep
                // the last good usage on screen and try again shortly.
                return ClaudeUsage(available: false, transient: true,
                                   retryAfter: retry, error: "Rate limited by Anthropic")
            }
        }

        var (usage, unauthorized) = await fetchUsage(token: creds.accessToken)

        // A 401 on a token we believed valid (clock skew, or Claude Code rotated it
        // out from under us). Try a single refresh + retry before declaring logout.
        if unauthorized, !didRefresh, creds.refreshToken != nil {
            switch await refreshCredentials(creds) {
            case .refreshed(let updated):
                creds = updated
                writeCredentials(updated)
                (usage, unauthorized) = await fetchUsage(token: updated.accessToken)
            case .revoked:
                return ClaudeUsage(available: false,
                                   error: "Login expired — open Claude Code to refresh")
            case .temporary(let retry):
                return ClaudeUsage(available: false, transient: true,
                                   retryAfter: retry, error: "Rate limited by Anthropic")
            }
        }

        return usage
    }

    // MARK: - Usage request

    // Returns the parsed usage plus whether the call was rejected with 401 (so the
    // caller can attempt a token refresh).
    private static func fetchUsage(token: String) async -> (usage: ClaudeUsage, unauthorized: Bool) {
        var request = URLRequest(url: usageURL, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            switch code {
            case 200:
                return (parse(data), false)
            case 401:
                return (ClaudeUsage(available: false,
                                    error: "Login expired — open Claude Code to refresh"), true)
            case 429:
                // Rate limited. Transient → keep showing the last good usage; pass
                // Retry-After up so the caller can back off instead of hammering.
                return (ClaudeUsage(available: false, transient: true,
                                    retryAfter: retryAfterSeconds(http),
                                    error: "Rate limited by Anthropic"), false)
            case 500...599:
                return (ClaudeUsage(available: false, transient: true,
                                    error: "Anthropic service error (HTTP \(code))"), false)
            default:
                return (ClaudeUsage(available: false,
                                    error: "Usage API error (HTTP \(code))"), false)
            }
        } catch {
            return (ClaudeUsage(available: false, transient: true, error: "Network error"), false)
        }
    }

    // Parses the Retry-After header (delta-seconds, or an HTTP-date) into seconds.
    private static func retryAfterSeconds(_ http: HTTPURLResponse?) -> TimeInterval? {
        guard let value = http?.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let secs = TimeInterval(value) { return max(0, secs) }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        if let date = fmt.date(from: value) { return max(0, date.timeIntervalSinceNow) }
        return nil
    }

    // MARK: - Token refresh

    private enum RefreshResult {
        case refreshed(ClaudeCredentials)
        case revoked              // refresh token no longer valid → genuine logout
        case temporary(TimeInterval?)  // 429/5xx/network/malformed → try again later
    }

    private static func refreshCredentials(_ creds: ClaudeCredentials) async -> RefreshResult {
        guard let refresh = creds.refreshToken else { return .revoked }

        var request = URLRequest(url: tokenURL, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientID,
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                if let updated = applyRefresh(to: creds, response: data) { return .refreshed(updated) }
                return .temporary(nil)
            case 400, 401, 403:
                // Only treat an explicit invalid_grant as a real logout — other 4xx
                // (e.g. a malformed request) must NOT wipe a still-valid session.
                if isInvalidGrant(data) { return .revoked }
                return .temporary(nil)
            case 429, 500...599:
                return .temporary(retryAfterSeconds(response as? HTTPURLResponse))
            default:
                return .temporary(nil)
            }
        } catch {
            return .temporary(nil)
        }
    }

    private struct RefreshResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    // Folds a successful refresh response into the credentials, preserving every
    // other field (subscriptionType, scopes, …) so the written-back blob matches
    // what Claude Code expects.
    private static func applyRefresh(to creds: ClaudeCredentials, response data: Data) -> ClaudeCredentials? {
        guard let r = try? JSONDecoder().decode(RefreshResponse.self, from: data),
              !r.accessToken.isEmpty else { return nil }
        var updated = creds
        updated.accessToken = r.accessToken
        if let newRefresh = r.refreshToken, !newRefresh.isEmpty { updated.refreshToken = newRefresh }
        let ttl = r.expiresIn ?? 28_800   // default to ~8h if the server omits it
        updated.expiresAt = Date().addingTimeInterval(ttl)

        updated.oauth["accessToken"] = updated.accessToken
        if let rt = updated.refreshToken { updated.oauth["refreshToken"] = rt }
        updated.oauth["expiresAt"] = Int64(updated.expiresAt!.timeIntervalSince1970 * 1000)
        return updated
    }

    private static func isInvalidGrant(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("invalid_grant")
    }

    // MARK: - Response parsing

    private struct UsageResponse: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?
            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }
    }

    private static func parse(_ data: Data) -> ClaudeUsage {
        guard let r = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            return ClaudeUsage(available: false, error: "Could not read usage response")
        }
        var usage = ClaudeUsage(available: true)
        if let f = r.fiveHour {
            usage.sessionPercent = f.utilization ?? 0
            usage.sessionResetAt = f.resetsAt.flatMap(parseDate)
        }
        if let w = r.sevenDay {
            usage.weekPercent = w.utilization ?? 0
            usage.weekResetAt = w.resetsAt.flatMap(parseDate)
        }
        return usage
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func parseDate(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }

    // MARK: - Credentials

    private struct ClaudeCredentials {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var oauth: [String: Any]   // the OAuth object, kept whole so writeback preserves all fields
        var wrapped: Bool          // whether the JSON nested everything under "claudeAiOauth"

        // Refresh slightly before the listed expiry to absorb clock skew. Only when a
        // refresh token and a known expiry are present — an unknown expiry is left alone.
        var needsRefresh: Bool {
            guard refreshToken != nil, let expiresAt else { return false }
            return Date() >= expiresAt.addingTimeInterval(-60)
        }
    }

    // Reads the freshest available credentials. Compares Claude Code's Keychain item
    // against TokenBar's own backup item and picks whichever expires later — so a
    // self-refresh whose write to Claude Code's item failed, and an independent
    // refresh by Claude Code itself, both resolve correctly.
    private static func readCredentials() -> ClaudeCredentials? {
        var candidates: [ClaudeCredentials] = []
        if let d = keychainData(service: claudeService), let c = parseCredentials(d) {
            candidates.append(c)
        }
        if let d = keychainData(service: backupService), let c = parseCredentials(d) {
            candidates.append(c)
        }
        if candidates.isEmpty {
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
            if let d = try? Data(contentsOf: file), let c = parseCredentials(d) {
                candidates.append(c)
            }
        }
        return candidates.max { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }
    }

    private static func parseCredentials(_ data: Data) -> ClaudeCredentials? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let wrapped = obj["claudeAiOauth"] is [String: Any]
        let oauth = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let refresh = oauth["refreshToken"] as? String
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1000)
        }
        return ClaudeCredentials(accessToken: token, refreshToken: refresh,
                                 expiresAt: expiresAt, oauth: oauth, wrapped: wrapped)
    }

    // Persists refreshed credentials: always to TokenBar's own backup (never prompts,
    // can't fail), then best-effort to Claude Code's shared item so Claude Code keeps
    // working without a re-login.
    private static func writeCredentials(_ creds: ClaudeCredentials) {
        let json: [String: Any] = creds.wrapped ? ["claudeAiOauth": creds.oauth] : creds.oauth
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }

        writeKeychain(service: backupService, data: data)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: claudeService,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            // No Keychain item (file-based install) → update the file instead.
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
            try? data.write(to: file, options: [.atomic])
        }
    }

    private static func keychainData(service: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func writeKeychain(service: String, data: Data) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecAttrAccount] = "claude-oauth"
            add[kSecValueData] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
