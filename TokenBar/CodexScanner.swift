import Foundation
import SQLite3

struct CodexThreadUsage {
    var id: String = ""
    var title: String = ""
    var tokens: Double = 0
    var updatedAt: Date? = nil
    var model: String = ""
    var status: String = "idle"
}

struct CodexUsage {
    var available: Bool = false
    var todayTokens: Double = 0
    var weekTokens: Double = 0
    var limitPercent: Double = 0
    var limitResetAt: Date? = nil
    var isLimited: Bool = false
    var activeThread: CodexThreadUsage? = nil
    var latestThreads: [CodexThreadUsage] = []
    var history: [String: Double] = [:]
    var error: String? = nil

    var sessionPercent: Double = 0
    var sessionResetAt: Date? = nil
    var weekPercent: Double = 0
    var weekResetAt: Date? = nil
}

enum CodexScanner {
    private static let dbURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/state_5.sqlite")

    static func scan() async -> CodexUsage {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return CodexUsage(error: "No Chat GPT usage database found")
        }

        let calendar = Calendar.current
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var validKeys: Set<String> = []
        for dayOffset in 0..<7 {
            if let date = calendar.date(byAdding: .day, value: -dayOffset, to: now) {
                validKeys.insert(formatter.string(from: date))
            }
        }

        var history: [String: Double] = Dictionary(uniqueKeysWithValues: validKeys.map { ($0, 0.0) })
        var active: CodexThreadUsage?
        var latestThreads: [CodexThreadUsage] = []
        var sawRows = false

        let query = """
            SELECT
                id,
                title,
                tokens_used,
                COALESCE(updated_at_ms, updated_at * 1000),
                model,
                archived
            FROM threads
            WHERE tokens_used > 0
            ORDER BY COALESCE(updated_at_ms, updated_at * 1000) DESC
            """

        guard let (db, stmt) = openReadable(dbURL, query: query) else {
            return CodexUsage(error: "Could not inspect Chat GPT threads")
        }
        defer {
            sqlite3_finalize(stmt)
            sqlite3_close(db)
        }

        // Rollout files carry the per-thread turn events the status is read from;
        // index them once per scan (only the displayed threads consult it).
        let rollouts = rolloutIndex()

        while sqlite3_step(stmt) == SQLITE_ROW {
            sawRows = true
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? UUID().uuidString
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "Untitled"
            let tokens = Double(sqlite3_column_int64(stmt, 2))
            let updatedMs = sqlite3_column_double(stmt, 3)
            let updatedAt = Date(timeIntervalSince1970: updatedMs / 1000.0)
            let model = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let archived = sqlite3_column_int(stmt, 5) != 0
            // Only the threads that end up on screen (the first 3 rows) need a real
            // status; later rows are only accumulated into the history buckets.
            let status = latestThreads.count < 3
                ? threadStatus(signal: rolloutTurnSignal(threadID: id, rollouts: rollouts),
                               archived: archived, updatedAt: updatedAt, now: now)
                : "idle"
            let thread = CodexThreadUsage(id: id,
                                          title: title.isEmpty ? "Untitled" : title,
                                          tokens: tokens,
                                          updatedAt: updatedAt,
                                          model: model,
                                          status: status)

            if active == nil {
                active = thread
            }

            if latestThreads.count < 3 {
                latestThreads.append(thread)
            }

            let key = formatter.string(from: updatedAt)
            if validKeys.contains(key) {
                history[key, default: 0] += tokens
            }
        }

        guard sawRows else {
            return CodexUsage(error: "No Chat GPT token usage yet")
        }

        let todayKey = formatter.string(from: now)
        let today = history[todayKey] ?? 0
        let week = history.values.reduce(0, +)

        var sessionPercent: Double = 0
        var sessionResetAt: Date? = nil
        var weekPercent: Double = 0
        var weekResetAt: Date? = nil
        var isLimited = false

        if let rateLimits = await fetchCodexRateLimits() ?? readRateLimitsFromRollout() {
            sessionPercent = rateLimits.sessionPercent
            sessionResetAt = rateLimits.sessionResetAt
            weekPercent = rateLimits.weekPercent
            weekResetAt = rateLimits.weekResetAt
            isLimited = rateLimits.isLimited
        } else {
            let limit = readLimitStatus()
            sessionPercent = limit.isLimited ? 100 : 0
            sessionResetAt = limit.resetAt
            weekPercent = min(100.0, (week / 2_000_000.0) * 100.0)
            isLimited = limit.isLimited
        }

        return CodexUsage(
            available: true,
            todayTokens: today,
            weekTokens: week,
            limitPercent: sessionPercent,
            limitResetAt: sessionResetAt,
            isLimited: isLimited,
            activeThread: active,
            latestThreads: latestThreads,
            history: history,
            error: nil,
            sessionPercent: sessionPercent,
            sessionResetAt: sessionResetAt,
            weekPercent: weekPercent,
            weekResetAt: weekResetAt
        )
    }

    /// Opens the Codex state DB read-only and prepares `query`. The DB is in WAL
    /// journal mode: a plain read-only open works while Codex is running (its
    /// writer keeps the `-shm` file around), but fails with `SQLITE_CANTOPEN`
    /// once the WAL is checkpointed and removed — a read-only connection can't
    /// build the shared memory it needs. When that happens, reopen with
    /// `immutable=1`, which reads the file directly without touching WAL/shm.
    /// We only fall back when the normal open fails (i.e. no active writer), so
    /// live data still wins when Codex is running.
    private static func openReadable(_ url: URL, query: String) -> (db: OpaquePointer, stmt: OpaquePointer)? {
        func attempt(_ path: String, flags: Int32) -> (OpaquePointer, OpaquePointer)? {
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                return nil
            }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt {
                return (db, stmt)
            }
            sqlite3_close(db)
            return nil
        }

        if let opened = attempt(url.path, flags: SQLITE_OPEN_READONLY) {
            return opened
        }
        return attempt(url.absoluteString + "?immutable=1",
                       flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
    }

    /// Status comes from the thread's rollout log (see `rolloutTurnSignal`): a turn
    /// in flight is "coding" until the log goes silent long enough to assume the CLI
    /// was killed, a completed turn is "done" until it ages into "idle", and an
    /// archived thread is always "idle" — the user explicitly closed it.
    private static func threadStatus(signal: TurnSignal, archived: Bool,
                                     updatedAt: Date, now: Date) -> String {
        if archived { return "idle" }
        return TurnSignal.status(signal, updatedAt: updatedAt, now: now)
    }

    /// Maps thread id → its rollout file. Rollouts live at
    /// ~/.codex/sessions/YYYY/MM/DD/rollout-<started-at>-<thread-id>.jsonl; a thread
    /// can be updated days after it started, so the whole tree is indexed rather
    /// than guessing a date directory from `updated_at`.
    private static func rolloutIndex() -> [String: URL] {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var index: [String: URL] = [:]
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let base = url.deletingPathExtension().lastPathComponent
            guard base.hasPrefix("rollout-"), base.count > 36 else { continue }
            let id = String(base.suffix(36))
            index[id] = url
        }
        return index
    }

    /// Reads the last event from a thread's rollout to tell whether a turn is in
    /// flight. Codex closes every turn with an `event_msg` of type `task_complete`
    /// (or `turn_aborted` on interrupt); while working, the log tail is
    /// `response_item` records (function calls/outputs, reasoning, messages) and
    /// progress events instead.
    private static func rolloutTurnSignal(threadID: String, rollouts: [String: URL]) -> TurnSignal {
        guard let url = rollouts[threadID],
              let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }

        let window: UInt64 = 64 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return .unknown }

        // Walk backwards so a trailing partial line (mid-write) is skipped naturally
        // by the JSON parse failing.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "event_msg":
                let payload = (obj["payload"] as? [String: Any])?["type"] as? String
                switch payload {
                case "task_complete", "turn_aborted", "error", "shutdown_complete":
                    return .finished
                default:
                    return .working   // task_started, agent_message, token_count, …
                }
            case "response_item", "turn_context":
                return .working
            case "session_meta":
                return .unknown       // brand-new session, no turn yet
            default:
                continue              // unrecognized bookkeeping — keep looking
            }
        }
        return .unknown
    }

    private static func readLimitStatus() -> (isLimited: Bool, resetAt: Date?) {
        let logsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/logs_2.sqlite")
        guard FileManager.default.fileExists(atPath: logsURL.path) else {
            return (false, nil)
        }

        var logsDB: OpaquePointer?
        guard sqlite3_open_v2(logsURL.path, &logsDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = logsDB else {
            return (false, nil)
        }
        defer { sqlite3_close(db) }

        let query = """
            SELECT COALESCE(feedback_log_body, '')
            FROM logs
            WHERE feedback_log_body LIKE '%usage limit%'
              AND feedback_log_body LIKE '%try again at%'
            ORDER BY ts DESC, ts_nanos DESC, id DESC
            LIMIT 1
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return (false, nil)
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let bodyCStr = sqlite3_column_text(stmt, 0) else {
            return (false, nil)
        }

        let body = String(cString: bodyCStr)
        guard let resetAt = parseResetDate(from: body), resetAt > Date() else {
            return (false, nil)
        }
        return (true, resetAt)
    }

    private static func parseResetDate(from text: String) -> Date? {
        guard let range = text.range(of: "try again at ", options: [.caseInsensitive]) else {
            return nil
        }

        var dateText = String(text[range.upperBound...])
        if let end = dateText.firstIndex(where: { $0 == "." || $0 == "\n" }) {
            dateText = String(dateText[..<end])
        }
        dateText = dateText
            .replacingOccurrences(of: #"(\d+)(st|nd|rd|th)"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.date(from: dateText)
    }

    // MARK: - Codex Usage API

    private struct CodexRateLimitResult {
        let sessionPercent: Double
        let sessionResetAt: Date?
        let weekPercent: Double
        let weekResetAt: Date?
        let isLimited: Bool
    }

    private struct CodexAuth: Decodable {
        let tokens: CodexTokens?
    }

    private struct CodexTokens: Decodable {
        let accessToken: String?
        let accountID: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
        }
    }

    private struct CodexUsageResponse: Decodable {
        let rateLimit: CodexRateLimit?
        let rateLimitReachedType: CodexRateLimitReached?

        enum CodingKeys: String, CodingKey {
            case rateLimit = "rate_limit"
            case rateLimitReachedType = "rate_limit_reached_type"
        }
    }

    /// `rate_limit_reached_type` is `null` when no limit is hit, but becomes an
    /// object (`{"type": ..., "details": ...}`) once a limit is reached — older
    /// builds returned a bare string. We only care whether it is present, so
    /// accept any non-null shape without inspecting it. Decoding it as `String?`
    /// (as we used to) threw on the object form, which failed the entire
    /// response decode exactly when a limit was active.
    private struct CodexRateLimitReached: Decodable {
        init(from decoder: Decoder) throws {}
    }

    private struct CodexRateLimit: Decodable {
        let allowed: Bool?
        let limitReached: Bool?
        let primaryWindow: CodexRateLimitWindow?
        let secondaryWindow: CodexRateLimitWindow?

        enum CodingKeys: String, CodingKey {
            case allowed
            case limitReached = "limit_reached"
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    private struct CodexRateLimitWindow: Decodable, WindowDurationProviding {
        let usedPercent: Double?
        let resetAt: Double?
        let resetAfterSeconds: Double?
        let limitWindowSeconds: Double?

        var durationSeconds: Double? { limitWindowSeconds }

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case resetAfterSeconds = "reset_after_seconds"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }

    /// Some plans (observed on `plan_type: "plus"`) only ever populate
    /// `primary_window`, with a `limit_window_seconds` of 604800 (7 days) and
    /// `secondary_window: null` — i.e. the one window OpenAI sends back is the
    /// weekly cap, not a 5h session cap. Trusting the primary/secondary slot
    /// positionally then mislabels the week countdown as "Session" (e.g. "in
    /// 166 hr"). Classify by duration instead: anything under a day is the
    /// session window, anything at/above is the week window.
    private protocol WindowDurationProviding {
        var durationSeconds: Double? { get }
    }

    private static let sessionWindowMaxSeconds: Double = 24 * 60 * 60

    private static func classifyWindows<T: WindowDurationProviding>(
        primary: T?, secondary: T?
    ) -> (session: T?, week: T?) {
        let windows = [primary, secondary].compactMap { $0 }
        guard windows.count > 1 else {
            guard let only = windows.first else { return (nil, nil) }
            return (only.durationSeconds ?? 0) < sessionWindowMaxSeconds ? (only, nil) : (nil, only)
        }
        let sorted = windows.sorted { ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0) }
        return (sorted[0], sorted[1])
    }

    private static func fetchCodexRateLimits() async -> CodexRateLimitResult? {
        guard let auth = readAuth(),
              let accessToken = auth.tokens?.accessToken,
              !accessToken.isEmpty,
              let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            return nil
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenUsage", forHTTPHeaderField: "User-Agent")
        if let accountID = auth.tokens?.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(CodexUsageResponse.self, from: data) else {
            return nil
        }

        return mapRateLimits(decoded)
    }

    private static func readAuth() -> CodexAuth? {
        let candidates = [
            ProcessInfo.processInfo.environment["CODEX_HOME"].map {
                URL(fileURLWithPath: $0).appendingPathComponent("auth.json")
            },
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/auth.json"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/codex/auth.json")
        ].compactMap { $0 }

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let auth = try? JSONDecoder().decode(CodexAuth.self, from: data) {
                return auth
            }

            // Some Codex builds have written auth JSON as a hex-encoded string.
            if let text = String(data: data, encoding: .utf8),
               let decoded = decodeHexJSON(text),
               let auth = try? JSONDecoder().decode(CodexAuth.self, from: decoded) {
                return auth
            }
        }
        return nil
    }

    private static func mapRateLimits(_ response: CodexUsageResponse) -> CodexRateLimitResult {
        let rateLimit = response.rateLimit
        let (session, week) = classifyWindows(primary: rateLimit?.primaryWindow, secondary: rateLimit?.secondaryWindow)

        return CodexRateLimitResult(
            sessionPercent: session?.usedPercent ?? 0,
            sessionResetAt: resetDate(session),
            weekPercent: week?.usedPercent ?? 0,
            weekResetAt: resetDate(week),
            isLimited: rateLimit?.limitReached == true ||
                rateLimit?.allowed == false ||
                response.rateLimitReachedType != nil
        )
    }

    /// While no timer is running the API still reports a rolling
    /// `reset_at` of exactly now + `limit_window_seconds` (the window only
    /// starts counting on the first request), so a full-window
    /// `reset_after_seconds` means there is no real countdown to show.
    private static func resetDate(_ window: CodexRateLimitWindow?) -> Date? {
        if let resetAfterSeconds = window?.resetAfterSeconds,
           let limitWindowSeconds = window?.limitWindowSeconds,
           resetAfterSeconds >= limitWindowSeconds {
            return nil
        }
        if let resetAt = window?.resetAt, resetAt > 0 {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let resetAfterSeconds = window?.resetAfterSeconds {
            return Date().addingTimeInterval(resetAfterSeconds)
        }
        return nil
    }

    // MARK: - Rollout Rate Limits (offline fallback)

    /// The Codex TUI's "5h / Weekly" figures come from `rate_limits` embedded in
    /// `token_count` events written to the session rollout files. When the usage
    /// API is unreachable, read the freshest snapshot from disk instead of the
    /// unreliable token-count heuristic.
    private struct RolloutLine: Decodable {
        let payload: RolloutPayload?
    }

    private struct RolloutPayload: Decodable {
        let rateLimits: RolloutRateLimits?

        enum CodingKeys: String, CodingKey {
            case rateLimits = "rate_limits"
        }
    }

    private struct RolloutRateLimits: Decodable {
        let primary: RolloutWindow?
        let secondary: RolloutWindow?
    }

    private struct RolloutWindow: Decodable, WindowDurationProviding {
        let usedPercent: Double?
        let resetsAt: Double?
        let windowMinutes: Double?

        var durationSeconds: Double? { windowMinutes.map { $0 * 60 } }

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetsAt = "resets_at"
            case windowMinutes = "window_minutes"
        }
    }

    private static func readRateLimitsFromRollout() -> CodexRateLimitResult? {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        guard let latest = mostRecentRollout(in: sessionsDir),
              let rateLimits = latestRolloutRateLimits(in: latest) else {
            return nil
        }

        let (session, week) = classifyWindows(primary: rateLimits.primary, secondary: rateLimits.secondary)
        let sessionUsed = session?.usedPercent ?? 0
        let weekUsed = week?.usedPercent ?? 0
        return CodexRateLimitResult(
            sessionPercent: sessionUsed,
            sessionResetAt: rolloutResetDate(session),
            weekPercent: weekUsed,
            weekResetAt: rolloutResetDate(week),
            isLimited: sessionUsed >= 100 || weekUsed >= 100
        )
    }

    private static func mostRecentRollout(in dir: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest == nil || date > newest!.date {
                newest = (url, date)
            }
        }
        return newest?.url
    }

    private static func latestRolloutRateLimits(in url: URL) -> RolloutRateLimits? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()
        var latest: RolloutRateLimits?
        text.enumerateLines { line, _ in
            guard line.contains("\"rate_limits\""),
                  let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(RolloutLine.self, from: lineData),
                  let rateLimits = entry.payload?.rateLimits else {
                return
            }
            latest = rateLimits
        }
        return latest
    }

    /// Rollout snapshots are written mid-turn, so their `resets_at` reflects a
    /// timer that was genuinely running — but the newest snapshot can predate
    /// the window expiring, in which case no timer is running anymore.
    private static func rolloutResetDate(_ window: RolloutWindow?) -> Date? {
        guard let resetsAt = window?.resetsAt,
              resetsAt > Date().timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: resetsAt)
    }

    private static func decodeHexJSON(_ text: String) -> Data? {
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count.isMultiple(of: 2),
              hex.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)

        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }

        return Data(bytes)
    }
}
