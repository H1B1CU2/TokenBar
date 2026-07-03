import Foundation
import SQLite3

struct AntigravityThreadUsage {
    var id: String = ""
    var title: String = ""
    var updatedAt: Date? = nil
    var status: String = "idle"
}

struct AntigravityModelUsage {
    var remainingPercent: Double = 100
    var resetAt: Date? = nil
    var description: String = ""
}

struct AntigravityGroupUsage {
    var displayName: String = ""
    var description: String = ""
    var weekly: AntigravityModelUsage = AntigravityModelUsage()
    var fiveHour: AntigravityModelUsage = AntigravityModelUsage()
}

struct AntigravityUsage {
    var available: Bool = false
    var gemini: AntigravityGroupUsage = AntigravityGroupUsage()
    var claudeGpt: AntigravityGroupUsage = AntigravityGroupUsage()
    var latestThreads: [AntigravityThreadUsage] = []  // recent local conversations (independent of the server)
    var error: String? = nil
}

enum AntigravityScanner {

    static func scan() async -> AntigravityUsage {
        // The "Latest Threads" list comes from local conversation databases and is
        // independent of the language server, so attach it to whatever the quota flow
        // returns (available or not).
        var usage = await scanQuota()
        usage.latestThreads = latestThreads()
        return usage
    }

    private static func scanQuota() async -> AntigravityUsage {
        // 1. Find the PID and CSRF token of the language_server process
        guard let psOutput = runShellCommand("ps -xo pid,command | grep -v grep | grep language_server"),
              let (pid, csrfToken) = extractPidAndCsrf(psOutput) else {
            return AntigravityUsage(available: false, error: "Antigravity language server not running")
        }
        
        // 2. Find the listening ports for this PID
        guard let lsofOutput = runShellCommand("lsof -i -P -n -p \(pid) | grep LISTEN") else {
            return AntigravityUsage(available: false, error: "Could not find language server port")
        }
        
        let ports = parsePorts(lsofOutput)
        if ports.isEmpty {
            return AntigravityUsage(available: false, error: "No listening ports found for language server")
        }
        
        // 3. Try querying each port until one succeeds
        for port in ports {
            if let usage = await fetchQuota(port: port, csrfToken: csrfToken) {
                return usage
            }
        }
        
        return AntigravityUsage(available: false, error: "Failed to fetch quota from local server")
    }
    
    // MARK: - Process and Port Parsing
    
    private static func extractPidAndCsrf(_ psLine: String) -> (String, String)? {
        let parts = psLine.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        
        guard let pid = parts.first else { return nil }
        
        // Search for --csrf_token argument
        for (index, part) in parts.enumerated() {
            if part == "--csrf_token" && index + 1 < parts.count {
                return (pid, parts[index + 1])
            }
        }
        
        return nil
    }
    
    private static func parsePorts(_ lsofOutput: String) -> [Int] {
        var ports: [Int] = []
        let lines = lsofOutput.components(separatedBy: .newlines)
        for line in lines {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 9 else { continue }
            // Expected name format is e.g. 127.0.0.1:57770
            let nameField = parts[8]
            if let portPart = nameField.components(separatedBy: ":").last,
               let port = Int(portPart.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)) {
                if !ports.contains(port) {
                    ports.append(port)
                }
            }
        }
        // Try higher ports first as they are typically the HTTP server (the lower one is often the LSP socket)
        return ports.sorted(by: >)
    }
    
    // MARK: - HTTP Query
    
    private struct RetrieveUserQuotaSummaryResponse: Codable {
        let response: QuotaSummary?
    }
    
    private struct QuotaSummary: Codable {
        let groups: [QuotaGroup]?
        let description: String?
    }
    
    private struct QuotaGroup: Codable {
        let displayName: String?
        let description: String?
        let buckets: [QuotaBucket]?
    }
    
    private struct QuotaBucket: Codable {
        let bucketId: String?
        let displayName: String?
        let description: String?
        let window: String?
        let remainingFraction: Double?
        let resetTime: String?
    }
    
    private static func fetchQuota(port: Int, csrfToken: String) async -> AntigravityUsage? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else {
            return nil
        }
        
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        request.httpBody = "{}".data(using: .utf8)
        
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(RetrieveUserQuotaSummaryResponse.self, from: data),
              let groups = decoded.response?.groups else {
            return nil
        }
        
        var geminiGroup = AntigravityGroupUsage()
        var claudeGptGroup = AntigravityGroupUsage()
        
        for group in groups {
            let name = group.displayName ?? ""
            var groupUsage = AntigravityGroupUsage()
            groupUsage.displayName = name
            groupUsage.description = group.description ?? ""
            
            if let buckets = group.buckets {
                for bucket in buckets {
                    let usage = AntigravityModelUsage(
                        remainingPercent: (bucket.remainingFraction ?? 1.0) * 100,
                        resetAt: bucket.resetTime.flatMap(parseDate),
                        description: bucket.description ?? ""
                    )
                    if bucket.window == "weekly" {
                        groupUsage.weekly = usage
                    } else if bucket.window == "5h" {
                        groupUsage.fiveHour = usage
                    }
                }
            }
            
            if name.contains("Gemini") {
                geminiGroup = groupUsage
            } else if name.contains("Claude") || name.contains("GPT") {
                claudeGptGroup = groupUsage
            }
        }
        
        return AntigravityUsage(
            available: true,
            gemini: geminiGroup,
            claudeGpt: claudeGptGroup,
            error: nil
        )
    }
    
    // MARK: - Shell Helper
    
    private static func runShellCommand(_ command: String) -> String? {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", command]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
    
    // MARK: - Date Helper
    
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

    // MARK: - Latest Threads (local conversation databases)

    // Antigravity stores each conversation as a SQLite DB at
    // ~/.gemini/antigravity/conversations/<id>.db. The "Latest Threads" list is built
    // from the newest of those: the title is the first user message (step_type 14,
    // stored as a protobuf blob), last activity is the file's modification time, and a
    // coding/done/idle status is derived from that (mirroring Codex and Claude).
    private static let conversationsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/antigravity/conversations")

    private static let codingWindow: TimeInterval = 60    // active right now
    private static let idleWindow: TimeInterval = 300     // no activity for 5 min

    static func latestThreads(limit: Int = 3, now: Date = Date()) -> [AntigravityThreadUsage] {
        var threads: [AntigravityThreadUsage] = []
        // Pull extra candidates since some conversations have no usable first message.
        for file in recentConversationDBs(candidates: limit * 4) {
            guard let title = conversationTitle(file.url) else { continue }
            threads.append(AntigravityThreadUsage(
                id: file.url.deletingPathExtension().lastPathComponent,
                title: title,
                updatedAt: file.modified,
                status: threadStatus(updatedAt: file.modified, now: now)
            ))
            if threads.count >= limit { break }
        }
        return threads
    }

    private static func recentConversationDBs(candidates: Int) -> [(url: URL, modified: Date)] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: conversationsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(url: URL, modified: Date)] = []
        for url in items where url.pathExtension == "db" {   // excludes the -wal / -shm siblings
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, modified))
        }
        return Array(files.sorted { $0.modified > $1.modified }.prefix(candidates))
    }

    private static func conversationTitle(_ url: URL) -> String? {
        let query = """
            SELECT step_payload FROM steps
            WHERE step_type = 14 AND step_payload IS NOT NULL
            ORDER BY idx ASC LIMIT 1
            """
        guard let (db, stmt) = openReadable(url, query: query) else { return nil }
        defer {
            sqlite3_finalize(stmt)
            sqlite3_close(db)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        guard count > 0 else { return nil }
        let payload = [UInt8](UnsafeRawBufferPointer(start: blob, count: count))
        return firstUserMessage(payload)
    }

    // Antigravity keeps its conversation DBs in WAL mode; a plain read-only open works
    // while the app is running but fails with SQLITE_CANTOPEN once the WAL is
    // checkpointed away, so fall back to `immutable=1` (reads the file directly). Same
    // pattern as CodexScanner.
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

    private static func threadStatus(updatedAt: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(updatedAt)
        if elapsed <= codingWindow { return "coding" }
        if elapsed <= idleWindow { return "done" }
        return "idle"
    }

    // MARK: - Protobuf blob text extraction

    // The user message is a UTF-8 string nested inside the step's protobuf payload.
    // Rather than depend on exact field numbers (which shift across Antigravity
    // versions), recursively walk the wire format collecting string leaves in order,
    // then pick the first natural-language one (skipping UUIDs / paths / ids).
    private static func firstUserMessage(_ payload: [UInt8]) -> String? {
        var strings: [String] = []
        extractStrings(payload, 0, payload.count, depth: 0, into: &strings)
        for raw in strings {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.count >= 3, !isLikelyIdentifier(s) else { continue }
            if s.hasPrefix("/") || s.hasPrefix("$") || s.contains("://")
                || s.lowercased().hasPrefix("file:") { continue }
            return String(s.prefix(80))
        }
        return nil
    }

    private static func isLikelyIdentifier(_ s: String) -> Bool {
        // UUID (8-4-4-4-12 hex) — trajectory / cascade / session ids.
        let parts = s.split(separator: "-")
        return s.count == 36 && parts.count == 5
            && s.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    private static func readVarint(_ b: [UInt8], _ start: Int, _ end: Int) -> (value: UInt64, next: Int)? {
        var shift: UInt64 = 0
        var result: UInt64 = 0
        var i = start
        while i < end {
            let byte = b[i]; i += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (result, i) }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    // True when [start, end) parses cleanly as a protobuf message (every byte consumed
    // by well-formed fields) — used to decide whether a length-delimited field is a
    // nested message to recurse into or a leaf string to capture.
    private static func isProtobufMessage(_ b: [UInt8], _ start: Int, _ end: Int) -> Bool {
        guard start < end else { return false }
        var i = start
        var fields = 0
        while i < end {
            guard let (tag, ni) = readVarint(b, i, end), ni <= end, tag >> 3 != 0 else { return false }
            i = ni
            switch Int(tag & 7) {
            case 0:
                guard let (_, n) = readVarint(b, i, end), n <= end else { return false }
                i = n
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let (len, n) = readVarint(b, i, end) else { return false }
                i = n + Int(len)
            default: return false
            }
            if i > end { return false }
            fields += 1
        }
        return i == end && fields > 0
    }

    private static func extractStrings(_ b: [UInt8], _ start: Int, _ end: Int,
                                       depth: Int, into out: inout [String]) {
        guard depth < 8, start < end else { return }
        var i = start
        while i < end {
            guard let (tag, ni) = readVarint(b, i, end), ni <= end else { return }
            i = ni
            switch Int(tag & 7) {
            case 0:
                guard let (_, n) = readVarint(b, i, end), n <= end else { return }
                i = n
            case 1:
                i += 8; if i > end { return }
            case 5:
                i += 4; if i > end { return }
            case 2:
                guard let (len, n) = readVarint(b, i, end) else { return }
                let chunkStart = n, chunkEnd = n + Int(len)
                if chunkEnd > end { return }
                i = chunkEnd
                if isProtobufMessage(b, chunkStart, chunkEnd) {
                    extractStrings(b, chunkStart, chunkEnd, depth: depth + 1, into: &out)
                } else if let str = String(bytes: b[chunkStart..<chunkEnd], encoding: .utf8) {
                    out.append(str)
                }
            default:
                return
            }
        }
    }
}
