import Foundation
import Observation

enum ClaudeWindow: String, CaseIterable, Identifiable {
    case session   // five-hour window
    case week      // seven-day window

    var id: String { rawValue }
    var title: String { self == .session ? "Session" : "Week" }
}

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case s30 = 30
    case m1 = 60
    case m2 = 120
    case m5 = 300

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }
    var title: String {
        switch self {
        case .s30: return "30s"
        case .m1:  return "1 min"
        case .m2:  return "2 min"
        case .m5:  return "5 min"
        }
    }
}

enum FirstDayOfWeek: String, CaseIterable, Identifiable {
    case sunday
    case monday

    var id: String { rawValue }
    var title: String {
        switch self {
        case .sunday: return "Sunday"
        case .monday: return "Monday"
        }
    }
}


@Observable
final class AppState {
    // Claude — official utilization (0–100) from Anthropic's OAuth usage API
    var claudeSessionPercent: Double = 0
    var claudeSessionResetAt: Date? = nil
    var claudeWeekPercent: Double = 0
    var claudeWeekResetAt: Date? = nil
    var claudeAvailable: Bool = false

    // Provider enable toggles (fetched + shown in the popover)
    var claudeEnabled: Bool {
        didSet { UserDefaults.standard.set(claudeEnabled, forKey: "claudeEnabled") }
    }
    var deepseekEnabled: Bool {
        didSet { UserDefaults.standard.set(deepseekEnabled, forKey: "deepseekEnabled") }
    }
    var antigravityEnabled: Bool {
        didSet { UserDefaults.standard.set(antigravityEnabled, forKey: "antigravityEnabled") }
    }



    // Combine the two Antigravity history graphs (Gemini + Claude/GPT) into one
    var antigravityFusedGraph: Bool {
        didSet { UserDefaults.standard.set(antigravityFusedGraph, forKey: "antigravityFusedGraph") }
    }

    // Side-by-side layout for Antigravity Gemini and Claude & GPT usage rows
    var antigravitySideBySide: Bool {
        didSet { UserDefaults.standard.set(antigravitySideBySide, forKey: "antigravitySideBySide") }
    }

    // Side-by-side layout for Claude Session and Week usage rows
    var claudeSideBySide: Bool {
        didSet { UserDefaults.standard.set(claudeSideBySide, forKey: "claudeSideBySide") }
    }

    // Graph display toggles for each provider
    var claudeShowGraph: Bool {
        didSet { UserDefaults.standard.set(claudeShowGraph, forKey: "claudeShowGraph") }
    }
    var deepseekShowGraph: Bool {
        didSet { UserDefaults.standard.set(deepseekShowGraph, forKey: "deepseekShowGraph") }
    }
    var antigravityShowGraph: Bool {
        didSet { UserDefaults.standard.set(antigravityShowGraph, forKey: "antigravityShowGraph") }
    }

    // Which window the menu bar donut reflects
    var claudeWindow: ClaudeWindow {
        didSet { UserDefaults.standard.set(claudeWindow.rawValue, forKey: "claudeWindow") }
    }

    // Whether to show remaining instead of used usage globally
    var showRemaining: Bool {
        didSet { UserDefaults.standard.set(showRemaining, forKey: "showRemaining") }
    }

    // Whether to show the reduction indicator dot on the brain icon when tokens are consumed
    var showReductionIndicator: Bool {
        didSet { UserDefaults.standard.set(showReductionIndicator, forKey: "showReductionIndicator") }
    }

    // Whether to use highest token for each provider as the max height reference separately
    var useSeparateGraphScale: Bool {
        didSet { UserDefaults.standard.set(useSeparateGraphScale, forKey: "useSeparateGraphScale") }
    }

    // How often to poll providers
    var refreshInterval: RefreshInterval {
        didSet { UserDefaults.standard.set(refreshInterval.rawValue, forKey: "refreshInterval") }
    }

    // First day of the week setting
    var firstDayOfWeek: FirstDayOfWeek {
        didSet { UserDefaults.standard.set(firstDayOfWeek.rawValue, forKey: "firstDayOfWeek") }
    }


    // Provider display order
    var providerOrder: [String] {
        didSet { UserDefaults.standard.set(providerOrder, forKey: "providerOrder") }
    }
    
    func moveProviderUp(at index: Int) {
        guard index > 0 && index < providerOrder.count else { return }
        providerOrder.swapAt(index, index - 1)
    }
    
    func moveProviderDown(at index: Int) {
        guard index >= 0 && index < providerOrder.count - 1 else { return }
        providerOrder.swapAt(index, index + 1)
    }

    // DeepSeek
    var deepseekBalance: Double? = nil
    var deepseekCurrency: String = "USD"
    var deepseekApiKey: String {
        didSet { KeychainHelper.save(deepseekApiKey, key: "deepseekApiKey") }
    }

    // Show the DeepSeek balance converted to Thai Baht.
    var deepseekShowTHB: Bool {
        didSet { UserDefaults.standard.set(deepseekShowTHB, forKey: "deepseekShowTHB") }
    }
    // Cached live rate: THB per 1 unit of `deepseekThbRateBase`. Persisted so THB
    // shows immediately on launch and survives a failed fetch.
    var deepseekThbRate: Double {
        didSet { UserDefaults.standard.set(deepseekThbRate, forKey: "deepseekThbRate") }
    }
    var deepseekThbRateBase: String {
        didSet { UserDefaults.standard.set(deepseekThbRateBase, forKey: "deepseekThbRateBase") }
    }

    var isLoading: Bool = false
    var isReducing: Bool = false
    var lastRefreshed: Date? = nil
    var claudeError: String? = nil
    var deepseekError: String? = nil
    var antigravityError: String? = nil
    
    // Antigravity Metrics
    var antigravityAvailable: Bool = false
    
    var antigravityGeminiWeeklyRemainingPercent: Double = 100
    var antigravityGeminiWeeklyResetAt: Date? = nil
    var antigravityGeminiWeeklyDescription: String = ""
    var antigravityGemini5hRemainingPercent: Double = 100
    var antigravityGemini5hResetAt: Date? = nil
    var antigravityGemini5hDescription: String = ""
    
    var antigravityClaudeGptWeeklyRemainingPercent: Double = 100
    var antigravityClaudeGptWeeklyResetAt: Date? = nil
    var antigravityClaudeGptWeeklyDescription: String = ""
    var antigravityClaudeGpt5hRemainingPercent: Double = 100
    var antigravityClaudeGpt5hResetAt: Date? = nil
    var antigravityClaudeGpt5hDescription: String = ""

    // 7-day usage tracking dictionaries (dateString -> value)
    var claudeHistory: [String: Double] {
        didSet { UserDefaults.standard.set(claudeHistory, forKey: "claudeHistory") }
    }
    var deepseekHistory: [String: Double] {
        didSet { UserDefaults.standard.set(deepseekHistory, forKey: "deepseekHistory") }
    }
    var antigravityGeminiHistory: [String: Double] {
        didSet { UserDefaults.standard.set(antigravityGeminiHistory, forKey: "antigravityGeminiHistory") }
    }
    var antigravityClaudeGptHistory: [String: Double] {
        didSet { UserDefaults.standard.set(antigravityClaudeGptHistory, forKey: "antigravityClaudeGptHistory") }
    }

    // Baselines in memory for session delta calculation
    var lastClaudeSessionPercent: Double? = nil
    var lastDeepseekBalance: Double? = nil
    var lastAntigravityGeminiWeeklyRemaining: Double? = nil
    var lastAntigravityClaudeGptWeeklyRemaining: Double? = nil

    init() {
        let defaults = UserDefaults.standard
        // Default enabled unless explicitly disabled before.
        self.claudeEnabled = defaults.object(forKey: "claudeEnabled") as? Bool ?? true
        self.deepseekEnabled = defaults.object(forKey: "deepseekEnabled") as? Bool ?? true
        self.antigravityEnabled = defaults.object(forKey: "antigravityEnabled") as? Bool ?? true

        self.antigravityFusedGraph = defaults.object(forKey: "antigravityFusedGraph") as? Bool ?? false
        self.antigravitySideBySide = defaults.object(forKey: "antigravitySideBySide") as? Bool ?? false
        self.claudeSideBySide = defaults.object(forKey: "claudeSideBySide") as? Bool ?? false
        self.claudeShowGraph = defaults.object(forKey: "claudeShowGraph") as? Bool ?? true
        self.deepseekShowGraph = defaults.object(forKey: "deepseekShowGraph") as? Bool ?? true
        self.antigravityShowGraph = defaults.object(forKey: "antigravityShowGraph") as? Bool ?? true
        let win = defaults.string(forKey: "claudeWindow")
        self.claudeWindow = win.flatMap(ClaudeWindow.init(rawValue:)) ?? .session
        self.showRemaining = defaults.bool(forKey: "showRemaining")
        self.showReductionIndicator = defaults.object(forKey: "showReductionIndicator") as? Bool ?? true
        self.useSeparateGraphScale = defaults.bool(forKey: "useSeparateGraphScale")
        self.refreshInterval = (defaults.object(forKey: "refreshInterval") as? Int)
            .flatMap(RefreshInterval.init(rawValue:)) ?? .m1
        let fdow = defaults.string(forKey: "firstDayOfWeek")
        self.firstDayOfWeek = fdow.flatMap(FirstDayOfWeek.init(rawValue:)) ?? .sunday

        let defaultOrder = ["claude", "deepseek", "antigravity"]
        var order = defaults.stringArray(forKey: "providerOrder") ?? defaultOrder
        for provider in defaultOrder {
            if !order.contains(provider) {
                order.append(provider)
            }
        }
        self.providerOrder = order
        self.deepseekApiKey = KeychainHelper.load(key: "deepseekApiKey") ?? ""
        self.deepseekShowTHB = defaults.bool(forKey: "deepseekShowTHB")
        self.deepseekThbRate = defaults.double(forKey: "deepseekThbRate")
        self.deepseekThbRateBase = defaults.string(forKey: "deepseekThbRateBase") ?? "USD"

        // Restore last-known Claude usage so a launch whose first fetch is momentarily
        // rate-limited still shows real numbers instead of 0%.
        if defaults.object(forKey: "claudeUsageStoredAt") != nil {
            self.claudeAvailable = true
            self.claudeSessionPercent = defaults.double(forKey: "claudeSessionPercent")
            self.claudeWeekPercent = defaults.double(forKey: "claudeWeekPercent")
            self.claudeSessionResetAt = defaults.object(forKey: "claudeSessionResetAt") as? Date
            self.claudeWeekResetAt = defaults.object(forKey: "claudeWeekResetAt") as? Date
        }

        self.claudeHistory = defaults.dictionary(forKey: "claudeHistory") as? [String: Double] ?? [:]
        self.deepseekHistory = defaults.dictionary(forKey: "deepseekHistory") as? [String: Double] ?? [:]
        self.antigravityGeminiHistory = defaults.dictionary(forKey: "antigravityGeminiHistory") as? [String: Double] ?? [:]
        self.antigravityClaudeGptHistory = defaults.dictionary(forKey: "antigravityClaudeGptHistory") as? [String: Double] ?? [:]

        let hasClaudeHistory = !self.claudeHistory.isEmpty
        let hasDeepseekHistory = !self.deepseekHistory.isEmpty
        let hasGeminiHistory = !self.antigravityGeminiHistory.isEmpty
        let hasClaudeGptHistory = !self.antigravityClaudeGptHistory.isEmpty

        if !hasClaudeHistory {
            self.claudeHistory = AppState.generateMockHistory(range: 10...60)
            defaults.set(self.claudeHistory, forKey: "claudeHistory")
        }
        if !hasDeepseekHistory {
            self.deepseekHistory = AppState.generateMockHistory(range: 0.05...0.75)
            defaults.set(self.deepseekHistory, forKey: "deepseekHistory")
        }
        if !hasGeminiHistory {
            self.antigravityGeminiHistory = AppState.generateMockHistory(range: 15...80)
            defaults.set(self.antigravityGeminiHistory, forKey: "antigravityGeminiHistory")
        }
        if !hasClaudeGptHistory {
            self.antigravityClaudeGptHistory = AppState.generateMockHistory(range: 10...70)
            defaults.set(self.antigravityClaudeGptHistory, forKey: "antigravityClaudeGptHistory")
        }
    }

    // MARK: - Active-window accessors

    var activePercent: Double {
        claudeWindow == .session ? claudeSessionPercent : claudeWeekPercent
    }
    var activeResetAt: Date? {
        claudeWindow == .session ? claudeSessionResetAt : claudeWeekResetAt
    }

    var claudeFraction: Double {
        let used = min(1.0, max(0, activePercent / 100))
        return showRemaining ? (1.0 - used) : used
    }


    var antigravityGeminiFraction: Double {
        let lowestRemaining = min(antigravityGeminiWeeklyRemainingPercent,
                                  antigravityGemini5hRemainingPercent)
        let remaining = min(1.0, max(0.0, lowestRemaining / 100.0))
        return showRemaining ? remaining : (1.0 - remaining)
    }

    var antigravityClaudeGptFraction: Double {
        let lowestRemaining = min(antigravityClaudeGptWeeklyRemainingPercent,
                                  antigravityClaudeGpt5hRemainingPercent)
        let remaining = min(1.0, max(0.0, lowestRemaining / 100.0))
        return showRemaining ? remaining : (1.0 - remaining)
    }

    var claudePercentFormatted: String {
        let percent = showRemaining ? (100.0 - activePercent) : activePercent
        return percent < 1 && percent > 0
            ? String(format: "%.1f%%", percent)
            : "\(Int(percent.rounded()))%"
    }

    // MARK: - DeepSeek display (THB conversion)

    // True when THB display is on and we hold a usable rate for the current currency.
    var deepseekThbActive: Bool {
        deepseekShowTHB && deepseekThbRate > 0 && deepseekThbRateBase == deepseekCurrency
    }
    var deepseekDisplayBalance: Double? {
        guard let b = deepseekBalance else { return nil }
        return deepseekThbActive ? b * deepseekThbRate : b
    }
    var deepseekDisplayCurrency: String {
        deepseekThbActive ? "THB" : deepseekCurrency
    }

    // MARK: - Last-known Claude usage persistence

    // Saves current usage so the next launch can show real numbers even if its first
    // fetch is rate-limited.
    func persistClaudeUsage() {
        let d = UserDefaults.standard
        d.set(claudeSessionPercent, forKey: "claudeSessionPercent")
        d.set(claudeWeekPercent, forKey: "claudeWeekPercent")
        setOrRemove(claudeSessionResetAt, "claudeSessionResetAt")
        setOrRemove(claudeWeekResetAt, "claudeWeekResetAt")
        d.set(Date(), forKey: "claudeUsageStoredAt")
    }

    // Clears stored usage on a hard failure (e.g. logout) so stale numbers don't
    // reappear next launch.
    func clearPersistedClaudeUsage() {
        let d = UserDefaults.standard
        ["claudeSessionPercent", "claudeWeekPercent", "claudeSessionResetAt",
         "claudeWeekResetAt", "claudeUsageStoredAt"].forEach { d.removeObject(forKey: $0) }
    }

    private func setOrRemove(_ date: Date?, _ key: String) {
        let d = UserDefaults.standard
        if let date { d.set(date, forKey: key) } else { d.removeObject(forKey: key) }
    }

    // MARK: - Usage Graph Tracking Logic

    private static func generateMockHistory(range: ClosedRange<Double>) -> [String: Double] {
        var mock: [String: Double] = [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        let now = Date()
        
        for dayOffset in 1...6 {
            if let date = calendar.date(byAdding: .day, value: -dayOffset, to: now) {
                let key = formatter.string(from: date)
                let randomVal = Double.random(in: range)
                mock[key] = (randomVal * 100).rounded() / 100
            }
        }
        
        let todayKey = formatter.string(from: now)
        mock[todayKey] = 0.0
        
        return mock
    }

    func pruneHistory() {
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
        
        claudeHistory = claudeHistory.filter { validKeys.contains($0.key) }
        deepseekHistory = deepseekHistory.filter { validKeys.contains($0.key) }
        antigravityGeminiHistory = antigravityGeminiHistory.filter { validKeys.contains($0.key) }
        antigravityClaudeGptHistory = antigravityClaudeGptHistory.filter { validKeys.contains($0.key) }
    }

    func trackUsageUpdate(
        claudeSession: Double?,
        deepseekBalance: Double?,
        geminiWeeklyRemaining: Double?,
        claudeGptWeeklyRemaining: Double?
    ) -> Bool {
        var reduced = false
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayKey = formatter.string(from: Date())
        
        // Ensure today exists in all dictionaries
        if claudeHistory[todayKey] == nil { claudeHistory[todayKey] = 0.0 }
        if deepseekHistory[todayKey] == nil { deepseekHistory[todayKey] = 0.0 }
        if antigravityGeminiHistory[todayKey] == nil { antigravityGeminiHistory[todayKey] = 0.0 }
        if antigravityClaudeGptHistory[todayKey] == nil { antigravityClaudeGptHistory[todayKey] = 0.0 }
        
        // 1. Claude
        if let claudeSession {
            if let last = lastClaudeSessionPercent {
                if claudeSession > last {
                    let delta = claudeSession - last
                    claudeHistory[todayKey] = (claudeHistory[todayKey] ?? 0.0) + delta
                    reduced = true
                }
            }
            lastClaudeSessionPercent = claudeSession
        }
        
        // 2. DeepSeek
        if let deepseekBalance {
            if let last = lastDeepseekBalance {
                if deepseekBalance < last {
                    let delta = last - deepseekBalance
                    deepseekHistory[todayKey] = (deepseekHistory[todayKey] ?? 0.0) + delta
                    reduced = true
                }
            }
            lastDeepseekBalance = deepseekBalance
        }
        
        // 3a. Antigravity Gemini
        if let geminiWeeklyRemaining {
            if let last = lastAntigravityGeminiWeeklyRemaining {
                if geminiWeeklyRemaining < last {
                    let delta = last - geminiWeeklyRemaining
                    antigravityGeminiHistory[todayKey] = (antigravityGeminiHistory[todayKey] ?? 0.0) + delta
                    reduced = true
                }
            }
            lastAntigravityGeminiWeeklyRemaining = geminiWeeklyRemaining
        }
        
        // 3b. Antigravity Claude & GPT
        if let claudeGptWeeklyRemaining {
            if let last = lastAntigravityClaudeGptWeeklyRemaining {
                if claudeGptWeeklyRemaining < last {
                    let delta = last - claudeGptWeeklyRemaining
                    antigravityClaudeGptHistory[todayKey] = (antigravityClaudeGptHistory[todayKey] ?? 0.0) + delta
                    reduced = true
                }
            }
            lastAntigravityClaudeGptWeeklyRemaining = claudeGptWeeklyRemaining
        }
        
        pruneHistory()
        return reduced
    }
}
