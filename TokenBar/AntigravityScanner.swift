import Foundation

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
    var error: String? = nil
}

enum AntigravityScanner {
    
    static func scan() async -> AntigravityUsage {
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
}
