import Foundation
import Security
import CommonCrypto
import SQLite3

// Consumer Gemini usage from gemini.google.com/usage — the same data shown
// in Gemini → Settings → Usage limits. Reads Google session cookies from a
// Chromium-based browser's cookie database and fetches the usage page.
struct GeminiWebUsage {
    var available: Bool = false
    var sessionPercent: Double = 0       // current 5-hour window usage (0–100)
    var sessionResetAt: Date? = nil
    var weekPercent: Double = 0          // weekly usage (0–100)
    var weekResetAt: Date? = nil
    var transient: Bool = false          // temporary failure — keep last data
    var error: String? = nil
}

enum GeminiScanner {
    private static let usageURL = URL(string: "https://gemini.google.com/usage")!

    static func scan() async -> GeminiWebUsage {
        // 1. Read Google session cookies from a supported Chromium browser.
        guard let cookies = readBrowserCookies(), !cookies.isEmpty else {
            return GeminiWebUsage(error: "No Google cookies found — sign in to Google in Dia or Chrome")
        }

        // 2. Fetch the usage page
        let (html, statusCode, finalURL) = await fetchUsagePage(cookies: cookies)

        // 3. A redirect to accounts.google.com means the session is no longer valid.
        // (Don't substring-match the HTML — the logged-in SPA bundle itself contains
        // "v3/signin"/"ServiceLogin" strings, which would be a false positive.)
        if let host = finalURL?.host, host.contains("accounts.google.com") {
            return GeminiWebUsage(error: "Google session expired — sign in again in your browser")
        }

        guard let html else {
            if statusCode == 401 || statusCode == 403 {
                return GeminiWebUsage(error: "Google session expired — sign in again in your browser")
            }
            if statusCode >= 500 {
                return GeminiWebUsage(transient: true, error: "Google service error (HTTP \(statusCode))")
            }
            return GeminiWebUsage(transient: true, error: "Could not fetch usage page")
        }

        // 4. Parse usage from HTML
        return parseUsage(html: html)
    }

    // MARK: - Browser Cookie Reading

    // A Chromium-based browser's on-disk profile location and its Keychain
    // "Safe Storage" item (service + account), used to decrypt that browser's
    // cookies.
    private struct ChromiumBrowser {
        let name: String
        let dataDir: String          // relative to ~/Library/Application Support
        let keychainService: String
        let keychainAccount: String
    }

    // Tried in order; the first one with a readable cookie DB containing Google
    // cookies wins. Dia is first since that's what the user runs.
    private static let browsers: [ChromiumBrowser] = [
        ChromiumBrowser(name: "Dia", dataDir: "Dia/User Data",
                        keychainService: "Dia Safe Storage", keychainAccount: "Dia"),
        ChromiumBrowser(name: "Chrome", dataDir: "Google/Chrome",
                        keychainService: "Chrome Safe Storage", keychainAccount: "Chrome"),
        ChromiumBrowser(name: "Brave", dataDir: "BraveSoftware/Brave-Browser",
                        keychainService: "Brave Safe Storage", keychainAccount: "Brave"),
        ChromiumBrowser(name: "Edge", dataDir: "Microsoft Edge",
                        keychainService: "Microsoft Edge Safe Storage", keychainAccount: "Microsoft Edge"),
        ChromiumBrowser(name: "Arc", dataDir: "Arc/User Data",
                        keychainService: "Arc Safe Storage", keychainAccount: "Arc"),
        ChromiumBrowser(name: "Vivaldi", dataDir: "Vivaldi",
                        keychainService: "Vivaldi Safe Storage", keychainAccount: "Vivaldi"),
        ChromiumBrowser(name: "Chromium", dataDir: "Chromium",
                        keychainService: "Chromium Safe Storage", keychainAccount: "Chromium"),
    ]

    private static func readBrowserCookies() -> [HTTPCookie]? {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")

        for browser in browsers {
            let base = appSupport.appendingPathComponent(browser.dataDir)
            guard FileManager.default.fileExists(atPath: base.path) else { continue }

            // Locate a cookie DB before touching the Keychain, so we only prompt
            // for the browser we actually read from.
            guard let dbPath = locateCookieDB(base: base) else { continue }
            guard let key = encryptionKey(service: browser.keychainService,
                                          account: browser.keychainAccount) else { continue }

            if let cookies = readCookieDB(at: dbPath, key: key), !cookies.isEmpty {
                return cookies
            }
        }
        return nil
    }

    // Finds the cookie SQLite file across profiles. Newer Chromium stores it under
    // "<Profile>/Network/Cookies"; older builds use "<Profile>/Cookies".
    private static func locateCookieDB(base: URL) -> URL? {
        let profiles = ["Default", "Profile 1", "Profile 2", "Profile 3"]
        for profile in profiles {
            for sub in ["Network/Cookies", "Cookies"] {
                let path = base.appendingPathComponent(profile).appendingPathComponent(sub)
                if FileManager.default.fileExists(atPath: path.path) { return path }
            }
        }
        return nil
    }

    private static func readCookieDB(at dbPath: URL, key: Data) -> [HTTPCookie]? {
        // Copy the DB to a temp file (the browser locks it while running).
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar_cookies_\(ProcessInfo.processInfo.processIdentifier)_\(abs(dbPath.path.hashValue)).db")
        try? FileManager.default.removeItem(at: tempDB)
        do {
            try FileManager.default.copyItem(at: dbPath, to: tempDB)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tempDB) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tempDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }

        let neededCookies: Set<String> = [
            "__Secure-1PSID", "__Secure-1PSIDTS", "__Secure-1PSIDCC",
            "__Secure-3PSID", "__Secure-3PSIDTS",
            "SID", "HSID", "SSID", "APISID", "SAPISID", "NID"
        ]

        let query = "SELECT host_key, name, encrypted_value, path, is_secure FROM cookies WHERE host_key LIKE '%google.com'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var result: [HTTPCookie] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let hostCStr = sqlite3_column_text(stmt, 0),
                  let nameCStr = sqlite3_column_text(stmt, 1) else { continue }
            let host = String(cString: hostCStr)
            let name = String(cString: nameCStr)

            guard neededCookies.contains(name) else { continue }

            let encPtr = sqlite3_column_blob(stmt, 2)
            let encLen = sqlite3_column_bytes(stmt, 2)
            guard let encPtr, encLen > 0 else { continue }
            let encData = Data(bytes: encPtr, count: Int(encLen))

            guard let value = decryptCookieValue(encData, key: key),
                  !value.isEmpty else { continue }

            let path = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "/"
            let isSecure = sqlite3_column_int(stmt, 4) != 0

            var props: [HTTPCookiePropertyKey: Any] = [
                .domain: host,
                .name: name,
                .value: value,
                .path: path,
            ]
            if isSecure { props[.secure] = "TRUE" }

            if let cookie = HTTPCookie(properties: props) {
                result.append(cookie)
            }
        }

        return result
    }

    // Reads a Chromium browser's encryption key from the macOS Keychain and
    // derives the AES-128 key via PBKDF2 (salt: "saltysalt", 1003 iterations,
    // 16-byte key). The first read of a given browser's item triggers a one-time
    // macOS Keychain access prompt.
    private static func encryptionKey(service: String, account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service as CFString,
            kSecAttrAccount: account as CFString,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let passwordData = result as? Data else { return nil }

        let salt: [UInt8] = Array("saltysalt".utf8)
        var derivedKey = [UInt8](repeating: 0, count: 16)

        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            (passwordData as NSData).bytes.assumingMemoryBound(to: Int8.self),
            passwordData.count,
            salt,
            salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1003,
            &derivedKey,
            16
        )
        guard status == kCCSuccess else { return nil }
        return Data(derivedKey)
    }

    // Decrypts a Chromium-encrypted cookie value. Encrypted values are prefixed
    // with "v10"/"v11" (3 bytes), followed by AES-128-CBC ciphertext with PKCS7
    // padding; the IV is 16 space bytes (0x20). Newer Chromium (≈ v24+) prepends a
    // 32-byte SHA-256 hash of the cookie's host to the plaintext as an integrity
    // check — stripped here when the leading bytes aren't printable.
    private static func decryptCookieValue(_ encrypted: Data, key: Data) -> String? {
        guard encrypted.count > 3 else { return nil }

        let prefix = String(data: encrypted.prefix(3), encoding: .utf8)
        guard prefix == "v10" || prefix == "v11" else {
            // Might be unencrypted
            return String(data: encrypted, encoding: .utf8)
        }

        let ciphertext = Array(encrypted.dropFirst(3))
        guard !ciphertext.isEmpty else { return nil }

        let iv: [UInt8] = Array(repeating: 0x20, count: 16)
        var decrypted = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var decryptedLength = 0

        let status = key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
            CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding),
                keyBytes.baseAddress, 16,
                iv,
                ciphertext, ciphertext.count,
                &decrypted, decrypted.count,
                &decryptedLength
            )
        }

        guard status == kCCSuccess, decryptedLength > 0 else { return nil }

        let plain = Array(decrypted.prefix(decryptedLength))
        // If the first bytes aren't printable ASCII, a 32-byte host hash was
        // prepended — drop it. Google session cookies are printable strings.
        let leadingPrintable = plain.prefix(4).allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
        let valueBytes = (leadingPrintable || plain.count <= 32) ? plain : Array(plain.dropFirst(32))
        return String(bytes: valueBytes, encoding: .utf8)
    }

    // MARK: - Page Fetch

    private static func fetchUsagePage(cookies: [HTTPCookie]) async -> (String?, Int, URL?) {
        var request = URLRequest(url: usageURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            let finalURL = http?.url
            guard code == 200 else { return (nil, code, finalURL) }
            return (String(data: data, encoding: .utf8), code, finalURL)
        } catch {
            return (nil, 0, nil)
        }
    }

    // MARK: - HTML Parsing

    private static func parseUsage(html: String) -> GeminiWebUsage {
        // Strategy 1: Parse AF_initDataCallback data blocks
        if let fromCallbacks = parseFromAFCallbacks(html) {
            return fromCallbacks
        }

        // Strategy 2: Regex-based extraction from HTML text
        if let fromRegex = parseFromHTMLPatterns(html) {
            return fromRegex
        }

        return GeminiWebUsage(error: "Could not parse usage data from page")
    }

    // Extracts AF_initDataCallback blocks and looks for usage data.
    private static func parseFromAFCallbacks(_ html: String) -> GeminiWebUsage? {
        let pattern = #"AF_initDataCallback\(\{[^}]*?data:(\[.*?\])\s*\}\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }

        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, options: [], range: range)

        for match in matches {
            guard let dataRange = Range(match.range(at: 1), in: html) else { continue }
            let dataStr = String(html[dataRange])
            if let usage = tryExtractUsageFromData(dataStr) {
                return usage
            }
        }

        return nil
    }

    // Attempts to interpret an AF_initDataCallback data string as usage data.
    private static func tryExtractUsageFromData(_ dataStr: String) -> GeminiWebUsage? {
        let numberPattern = #"(?:^|[,\[\s])(-?\d+\.?\d*)(?=[,\]\s]|$)"#
        guard let numRegex = try? NSRegularExpression(pattern: numberPattern) else { return nil }
        let numRange = NSRange(dataStr.startIndex..., in: dataStr)
        let numMatches = numRegex.matches(in: dataStr, range: numRange)

        var numbers: [Double] = []
        for m in numMatches {
            guard let r = Range(m.range(at: 1), in: dataStr),
                  let num = Double(dataStr[r]) else { continue }
            numbers.append(num)
        }

        var percentages: [(percent: Double, timestamp: Double?)] = []
        for (i, num) in numbers.enumerated() {
            if num >= 0, num <= 100, num == num.rounded() {
                var timestamp: Double? = nil
                if i + 1 < numbers.count {
                    let next = numbers[i + 1]
                    if next > 1_700_000_000_000, next < 2_000_000_000_000 {
                        timestamp = next
                    }
                    if next > 1_700_000_000, next < 2_000_000_000 {
                        timestamp = next * 1000
                    }
                }
                percentages.append((num, timestamp))
            }
        }

        if percentages.count >= 2 {
            let sessionPct = percentages[0].percent
            let weekPct = percentages[1].percent
            let sessionReset = percentages[0].timestamp.map {
                Date(timeIntervalSince1970: $0 / 1000)
            }
            let weekReset = percentages[1].timestamp.map {
                Date(timeIntervalSince1970: $0 / 1000)
            }

            let now = Date()
            let sessionResetOK = sessionReset.map { $0.timeIntervalSince(now) > -3600 } ?? true
            let weekResetOK = weekReset.map { $0.timeIntervalSince(now) > -86400 } ?? true

            if sessionResetOK || weekResetOK {
                return GeminiWebUsage(
                    available: true,
                    sessionPercent: sessionPct,
                    sessionResetAt: sessionReset,
                    weekPercent: weekPct,
                    weekResetAt: weekReset
                )
            }
        }

        return nil
    }

    // Fallback: look for percentage patterns in the raw HTML.
    private static func parseFromHTMLPatterns(_ html: String) -> GeminiWebUsage? {
        let pctPattern = #"(\d{1,3})\s*%"#
        guard let pctRegex = try? NSRegularExpression(pattern: pctPattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        let pctMatches = pctRegex.matches(in: html, range: range)

        var percentValues: [Double] = []
        for m in pctMatches {
            guard let r = Range(m.range(at: 1), in: html),
                  let val = Double(html[r]),
                  val >= 0, val <= 100 else { continue }
            percentValues.append(val)
        }

        var seen: Set<Double> = []
        var unique: [Double] = []
        for v in percentValues {
            if !seen.contains(v) {
                seen.insert(v)
                unique.append(v)
            }
        }

        guard unique.count >= 2 else {
            if unique.count == 1 {
                return GeminiWebUsage(available: true, sessionPercent: unique[0])
            }
            return nil
        }

        return GeminiWebUsage(
            available: true,
            sessionPercent: unique[0],
            weekPercent: unique[1]
        )
    }
}
