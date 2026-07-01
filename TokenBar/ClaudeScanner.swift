import Foundation
import Security
import CryptoKit
import Observation
import AppKit

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
struct ClaudeThreadUsage {
    var id: String = ""
    var title: String = ""
    var updatedAt: Date? = nil
    var status: String = "idle"
}

struct ClaudeUsage {
    var available: Bool = false
    var sessionPercent: Double = 0      // five_hour utilization (0–100)
    var sessionResetAt: Date? = nil
    var weekPercent: Double = 0         // seven_day utilization (0–100)
    var weekResetAt: Date? = nil
    var transient: Bool = false         // temporary failure (429/5xx/network) — keep last data
    var retryAfter: TimeInterval? = nil // server-advised wait from Retry-After (429)
    var latestThreads: [ClaudeThreadUsage] = []  // recent local sessions (independent of the API)
    var error: String? = nil
}

enum ClaudeScanner {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
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
        // The "Latest Threads" list comes from local session files and is independent
        // of the usage API, so attach it to whatever the API flow returns (available,
        // rate-limited, or signed-out).
        var usage = await scanUsage()
        usage.latestThreads = latestThreads()
        return usage
    }

    private static func scanUsage() async -> ClaudeUsage {
        guard var creds = readCredentials() else {
            return ClaudeUsage(available: false,
                               error: "Not signed in — sign in from Settings")
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
                                   error: "Login expired — sign in from Settings")
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
                                   error: "Login expired — sign in from Settings")
            case .temporary(let retry):
                return ClaudeUsage(available: false, transient: true,
                                   retryAfter: retry, error: "Rate limited by Anthropic")
            }
        }

        return usage
    }

    // MARK: - Latest Threads (local session files)

    // Claude Code keeps each conversation as a JSONL rollout at
    // ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl. There's no usage API for
    // these, so the "Latest Threads" list is built from the newest session files:
    // title from the generated `ai-title` line, last activity from the file's
    // modification time, and a coding/done/idle status derived from that (mirroring
    // Codex).
    private static let projectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    private static let codingWindow: TimeInterval = 60    // active right now
    private static let idleWindow: TimeInterval = 300     // no activity for 5 min

    static func latestThreads(limit: Int = 3, now: Date = Date()) -> [ClaudeThreadUsage] {
        var threads: [ClaudeThreadUsage] = []
        // Pull extra candidates since some session files (sub-agents / brand-new
        // sessions) have no usable title and get skipped.
        for file in recentSessionFiles(candidates: limit * 4) {
            guard let title = sessionTitle(file.url) else { continue }
            threads.append(ClaudeThreadUsage(
                id: file.url.deletingPathExtension().lastPathComponent,
                title: title,
                updatedAt: file.modified,
                status: threadStatus(updatedAt: file.modified, now: now)
            ))
            if threads.count >= limit { break }
        }
        return threads
    }

    private static func recentSessionFiles(candidates: Int) -> [(url: URL, modified: Date)] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, modified))
        }
        return Array(files.sorted { $0.modified > $1.modified }.prefix(candidates))
    }

    // Reads a bounded window from the END of a session file to find the latest
    // `ai-title` (regenerated near the tail as the conversation grows), falling back
    // to the first real user message when the whole file fits in the window. Bounded
    // so multi-MB session files aren't loaded in full every scan.
    private static func sessionTitle(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let window: UInt64 = 256 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return nil }

        // When we started mid-file, drop the partial first line so decoding begins on
        // a clean line / UTF-8 boundary.
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data = Data(data[(newline + 1)...])
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var aiTitle: String?
        var firstUserText: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.contains("ai-title") {
                if let obj = jsonObject(line),
                   (obj["type"] as? String) == "ai-title",
                   let value = (obj["aiTitle"] as? String)?
                       .trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    aiTitle = value
                }
            } else if start == 0, firstUserText == nil, line.contains("\"type\":\"user\"") {
                // Only meaningful when the whole file is in the window (small/new
                // sessions); large files always have an ai-title.
                if let obj = jsonObject(line), let value = userText(obj) {
                    firstUserText = value
                }
            }
        }

        let title = aiTitle ?? firstUserText
        return title.map { String($0.prefix(80)) }
    }

    private static func jsonObject(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func userText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        var text: String?
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            text = blocks
                .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ")
        }
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.hasPrefix("<") else { return nil }   // skip <command-…> / tool wrappers
        return value
    }

    private static func threadStatus(updatedAt: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(updatedAt)
        if elapsed <= codingWindow { return "coding" }
        if elapsed <= idleWindow { return "done" }
        return "idle"
    }

    // MARK: - Independent OAuth login

    // Lets TokenBar sign in to Claude on its own — the same OAuth 2.0 + PKCE flow
    // Claude Code uses — so an expired/revoked session can be re-authenticated here
    // without having to launch Claude Code. The user authorizes in a browser and
    // pastes back the "code#state" string the callback page shows.
    private static let authorizeURL = "https://claude.ai/oauth/authorize"
    private static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    private static let loginScope = "org:create_api_key user:profile user:inference"

    struct LoginChallenge {
        let url: URL
        let verifier: String
        let state: String
    }

    // Builds the authorize URL plus the PKCE verifier/state to retain until the user
    // pastes their code back.
    static func beginLogin() -> LoginChallenge {
        let (verifier, challenge) = pkcePair()
        let state = randomHex(32)
        var comps = URLComponents(string: authorizeURL)!
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: loginScope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return LoginChallenge(url: comps.url!, verifier: verifier, state: state)
    }

    // Exchanges the pasted authorization code for tokens and writes them to the
    // Keychain in Claude Code's format. Returns nil on success, or a user-facing
    // error message on failure.
    static func completeLogin(rawCode: String, verifier: String, state: String) async -> String? {
        // The callback page hands back "code#state" (and may append "&…"). Keep the
        // code, and prefer the state it echoes back over our own.
        let pieces = rawCode.split(whereSeparator: { $0 == "#" || $0 == "&" }).map(String.init)
        guard let code = pieces.first, !code.isEmpty else {
            return "That doesn't look like a valid authorization code."
        }
        let returnedState = pieces.count > 1 ? pieces[1] : state

        var request = URLRequest(url: tokenURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "state": returnedState,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                return "Sign-in failed (HTTP \(status)). Please try again."
            }
            guard let r = try? JSONDecoder().decode(RefreshResponse.self, from: data),
                  !r.accessToken.isEmpty else {
                return "Couldn't read the sign-in response."
            }
            let ttl = r.expiresIn ?? 28_800
            let expiresAt = Date().addingTimeInterval(ttl)
            var oauth: [String: Any] = [
                "accessToken": r.accessToken,
                "scopes": ["user:inference", "user:profile"],
                "expiresAt": Int64(expiresAt.timeIntervalSince1970 * 1000),
            ]
            if let rt = r.refreshToken, !rt.isEmpty { oauth["refreshToken"] = rt }
            let creds = ClaudeCredentials(accessToken: r.accessToken,
                                          refreshToken: r.refreshToken,
                                          expiresAt: expiresAt, oauth: oauth, wrapped: true)
            writeCredentials(creds)
            return nil
        } catch {
            return "Network error during sign-in. Please try again."
        }
    }

    // MARK: - PKCE helpers

    // (verifier, challenge) where challenge = base64url(SHA256(verifier)).
    private static func pkcePair() -> (verifier: String, challenge: String) {
        let verifier = base64URL(randomBytes(32))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        return (verifier, challenge)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func randomHex(_ count: Int) -> String {
        randomBytes(count).map { String(format: "%02x", $0) }.joined()
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
                                    error: "Login expired — sign in from Settings"), true)
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

// Drives the in-app Claude sign-in UI: open the browser, collect the pasted code,
// exchange it, and report the outcome. Lives here alongside the OAuth flow it uses.
@MainActor
@Observable
final class ClaudeLoginModel {
    enum Phase: Equatable {
        case idle
        case awaitingCode
        case exchanging
        case success
        case failed(String)
    }

    var phase: Phase = .idle
    var pastedCode: String = ""
    private var challenge: ClaudeScanner.LoginChallenge?

    var isBusy: Bool { phase == .exchanging }

    // Opens the authorize URL in the default browser and waits for the pasted code.
    func startLogin() {
        let c = ClaudeScanner.beginLogin()
        challenge = c
        pastedCode = ""
        phase = .awaitingCode
        NSWorkspace.shared.open(c.url)
    }

    // Exchanges the pasted code. Returns true on success so the caller can refresh.
    @discardableResult
    func submitCode() async -> Bool {
        guard let c = challenge else { return false }
        let code = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return false }
        phase = .exchanging
        if let error = await ClaudeScanner.completeLogin(rawCode: code,
                                                         verifier: c.verifier, state: c.state) {
            phase = .failed(error)
            return false
        }
        phase = .success
        pastedCode = ""
        challenge = nil
        return true
    }

    func reset() {
        phase = .idle
        pastedCode = ""
        challenge = nil
    }
}
