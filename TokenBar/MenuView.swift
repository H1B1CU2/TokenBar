import SwiftUI

struct MenuView: View {
    @State var state: AppState
    let onRefresh: (Bool) async -> Void   // force: bypass rate-limit backoff/coalescing
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.providerOrder, id: \.self) { provider in
                if provider == "claude" {
                    claudeBlock
                } else if provider == "deepseek" {
                    deepseekBlock
                } else if provider == "antigravity" {
                    antigravityBlock
                }
            }
            if !state.claudeEnabled && !state.deepseekEnabled && !state.antigravityEnabled {
                Text("No providers enabled — open Settings")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                Divider()
            }
            footerButtons
        }
        .frame(width: 320)
        .background(.regularMaterial)
        .onChange(of: state.claudeEnabled) {
            Task { await onRefresh(false) }
        }
        .onChange(of: state.deepseekEnabled) {
            Task { await onRefresh(false) }
        }
        .onChange(of: state.antigravityEnabled) {
            Task { await onRefresh(false) }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var claudeBlock: some View {
        if state.claudeEnabled {
            claudeSection
            Divider()
        }
    }

    @ViewBuilder private var deepseekBlock: some View {
        if state.deepseekEnabled {
            deepseekSection
            Divider()
        }
    }

    @ViewBuilder private var antigravityBlock: some View {
        if state.antigravityEnabled {
            antigravitySection
            Divider()
        }
    }

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderIcon(provider: "claude", size: 18)
                Text("Claude")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            if state.claudeSideBySide {
                HStack(alignment: .top, spacing: 12) {
                    claudeWindowRow("Session",
                                    percent: state.claudeSessionPercent,
                                    reset: state.claudeSessionResetAt)
                    Divider()
                    claudeWindowRow("Week",
                                    percent: state.claudeWeekPercent,
                                    reset: state.claudeWeekResetAt)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                claudeWindowRow("Session",
                                percent: state.claudeSessionPercent,
                                reset: state.claudeSessionResetAt)
                claudeWindowRow("Week",
                                percent: state.claudeWeekPercent,
                                reset: state.claudeWeekResetAt)
            }

            if let err = state.claudeError {
                Text(err).font(.system(size: 10)).foregroundStyle(Color.claudeAccent)
            }

            if state.claudeShowGraph {
                UsageGraphView(
                    history: state.claudeHistory.mapValues { $0 * 2000.0 },
                    tintColor: .claudeAccent,
                    unitFormatter: { formatTokens($0) },
                    yAxisMax: state.useSeparateGraphScale ? claudeTokenMax : globalTokenMax,
                    showTotal: true,
                    firstDayOfWeek: state.firstDayOfWeek
                )
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // One Claude window's usage: label + percent + reset on a line, progress bar below.
    private func claudeWindowRow(_ title: String, percent: Double, reset: Date?) -> some View {
        let fraction = min(1.0, max(0, percent / 100))
        let displayFraction = state.showRemaining ? (1.0 - fraction) : fraction
        let displayPercent = state.showRemaining ? (100.0 - percent) : percent
        let suffix = state.showRemaining ? "left" : "used"
        return VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            progressBar(displayFraction, color: .claudeAccent)
            HStack(spacing: 6) {
                Text("\(percentText(displayPercent)) \(suffix)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .layoutPriority(1)
                Spacer()
                if let resetStr = resetText(reset, compact: state.claudeSideBySide) {
                    Text(resetStr)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func percentText(_ p: Double) -> String {
        p < 1 && p > 0 ? String(format: "%.1f%%", p) : "\(Int(p.rounded()))%"
    }

    private func formatTokens(_ value: Double) -> String {
        let intVal = Int(value.rounded())
        if intVal >= 1_000_000 {
            let doubleVal = Double(intVal) / 1_000_000.0
            return String(format: "%.1fM tokens", doubleVal)
        } else if intVal >= 1_000 {
            let doubleVal = Double(intVal) / 1_000.0
            return String(format: "%.1fk tokens", doubleVal)
        } else {
            return "\(intVal) tokens"
        }
    }

    // Reset line: under 24h shows time left ("resets in 3 hr 44 min"); otherwise the
    // absolute weekday + time ("resets 01:00 on Monday"). No comma between units.
    private func resetText(_ reset: Date?) -> String? {
        resetText(reset, compact: false)
    }

    private func resetText(_ reset: Date?, compact: Bool) -> String? {
        guard let reset else { return nil }
        let secs = reset.timeIntervalSinceNow
        if secs <= 0 { return nil }
        if secs < 24 * 3600 {
            let totalMin = max(1, Int((secs / 60).rounded()))
            let h = totalMin / 60
            let m = totalMin % 60
            if compact {
                let left = h > 0 ? (m > 0 ? "\(h)h \(m)m" : "\(h)h") : "\(m)m"
                return "in \(left)"
            } else {
                let left = h > 0 ? (m > 0 ? "\(h) hr \(m) min" : "\(h) hr") : "\(m) min"
                return "resets in \(left)"
            }
        }
        let time = reset.formatted(.dateTime.hour().minute())
        if compact {
            let day  = reset.formatted(.dateTime.weekday(.abbreviated))
            return "\(day) \(time)"
        } else {
            let day  = reset.formatted(.dateTime.weekday(.wide))
            return "resets \(time) on \(day)"
        }
    }

    // Custom progress bar drawn with explicit shape fills. A SwiftUI ProgressView's
    // .tint() renders in the inactive (grayed) appearance until the popover window
    // becomes key (on click) — an accessory app's transient popover isn't key on show.
    private func progressBar(_ fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 5)
    }

    private var deepseekSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProviderIcon(provider: "deepseek", size: 18)
                Text("DeepSeek")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if state.deepseekApiKey.isEmpty {
                    Text("No API key")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            if let err = state.deepseekError {
                Text(err).font(.caption2).foregroundStyle(.red)
            }

            if !state.deepseekApiKey.isEmpty {
                if state.deepseekShowGraph {
                    UsageGraphView(
                        history: state.deepseekHistory.mapValues { $0 * 2_000_000.0 },
                        tintColor: .deepseekAccent,
                        unitFormatter: { tokens in
                            let usd = tokens / 2_000_000.0
                            let money = state.deepseekThbActive ? usd * state.deepseekThbRate : usd
                            let moneyStr = balanceDisplay(money, currency: state.deepseekDisplayCurrency)
                            return "\(formatTokens(tokens)) (\(moneyStr))"
                        },
                        yAxisMax: state.useSeparateGraphScale ? deepseekTokenMax : globalTokenMax,
                        firstDayOfWeek: state.firstDayOfWeek
                    )
                    .padding(.top, 4)
                }

                deepseekBalanceRow
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // Balance summary shown under the DeepSeek graph, mirroring the label/value
    // layout of the Claude and Antigravity usage rows.
    private var deepseekBalanceRow: some View {
        Group {
            if let balance = state.deepseekDisplayBalance {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Balance Left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(balanceDisplay(balance, currency: state.deepseekDisplayCurrency))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(6)
            } else {
                HStack(spacing: 6) {
                    Text("Balance")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("—")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footerButtons: some View {
        HStack(spacing: 0) {
            Button {
                Task { await onRefresh(true) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)

            Divider().frame(height: 20)

            Button {
                onSettings()
            } label: {
                Label("Settings", systemImage: "gear")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)

            Divider().frame(height: 20)

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Helpers

    // Per-day sum of both Antigravity histories, in graph units (× 1000 like the
    // individual graphs) — used when the "Combine usage graphs" setting is on.
    private var antigravityFusedHistory: [String: Double] {
        var merged = state.antigravityGeminiHistory
        for (day, value) in state.antigravityClaudeGptHistory {
            merged[day, default: 0] += value
        }
        return merged.mapValues { $0 * 1000.0 }
    }

    private var deepseekHistoryDisplay: [String: Double] {
        if state.deepseekThbActive {
            return state.deepseekHistory.mapValues { $0 * state.deepseekThbRate }
        } else {
            return state.deepseekHistory
        }
    }

    private func balanceDisplay(_ balance: Double, currency: String) -> String {
        String(format: "%@%.2f", CurrencyFormat.symbol(currency), balance)
    }

    private var antigravitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderIcon(provider: "antigravity", size: 18)
                Text("Antigravity")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            if state.antigravityAvailable {
                if state.antigravitySideBySide {
                    HStack(alignment: .top, spacing: 12) {
                        // Group 1: Gemini Models
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Gemini Models")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.primary)
                            antigravityModelRow("Session",
                                                 percent: state.antigravityGemini5hRemainingPercent,
                                                 reset: state.antigravityGemini5hResetAt)
                            antigravityModelRow("Week",
                                                 percent: state.antigravityGeminiWeeklyRemainingPercent,
                                                 reset: state.antigravityGeminiWeeklyResetAt)
                        }
                        
                        Divider()
                        
                        // Group 2: Claude & GPT Models
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Claude & GPT Models")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.primary)
                            antigravityModelRow("Session",
                                                 percent: state.antigravityClaudeGpt5hRemainingPercent,
                                                 reset: state.antigravityClaudeGpt5hResetAt)
                            antigravityModelRow("Week",
                                                 percent: state.antigravityClaudeGptWeeklyRemainingPercent,
                                                 reset: state.antigravityClaudeGptWeeklyResetAt)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        // Group 1: Gemini Models
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Gemini Models")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.primary)
                            antigravityModelRow("Session",
                                                 percent: state.antigravityGemini5hRemainingPercent,
                                                 reset: state.antigravityGemini5hResetAt)
                            antigravityModelRow("Week",
                                                 percent: state.antigravityGeminiWeeklyRemainingPercent,
                                                 reset: state.antigravityGeminiWeeklyResetAt)
                        }
                        
                        Divider()
                        
                        // Group 2: Claude & GPT Models
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Claude & GPT Models")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.primary)
                            antigravityModelRow("Session",
                                                 percent: state.antigravityClaudeGpt5hRemainingPercent,
                                                 reset: state.antigravityClaudeGpt5hResetAt)
                            antigravityModelRow("Week",
                                                 percent: state.antigravityClaudeGptWeeklyRemainingPercent,
                                                 reset: state.antigravityClaudeGptWeeklyResetAt)
                        }
                    }
                }
            } else if let err = state.antigravityError {
                Text(err).font(.system(size: 10)).foregroundStyle(Color.antigravityGreen)
            } else {
                Text("Connecting to server...")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if state.antigravityAvailable {
                if state.antigravityShowGraph {
                    if state.antigravityFusedGraph {
                        UsageGraphView(
                            history: antigravityFusedHistory,
                            tintColor: .antigravityGreen,
                            unitFormatter: { formatTokens($0) },
                            yAxisMax: state.useSeparateGraphScale ? antigravityTokenMax : globalTokenMax,
                            showTotal: true,
                            firstDayOfWeek: state.firstDayOfWeek
                        )
                        .padding(.top, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Gemini Models")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                UsageGraphView(
                                    history: state.antigravityGeminiHistory.mapValues { $0 * 1000.0 },
                                    tintColor: .antigravityGreen,
                                    unitFormatter: { formatTokens($0) },
                                    yAxisMax: state.useSeparateGraphScale ? antigravityTokenMax : globalTokenMax,
                                    showTotal: true,
                                    firstDayOfWeek: state.firstDayOfWeek
                                )
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Claude & GPT")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                UsageGraphView(
                                    history: state.antigravityClaudeGptHistory.mapValues { $0 * 1000.0 },
                                    tintColor: .antigravityGreen,
                                    unitFormatter: { formatTokens($0) },
                                    yAxisMax: state.useSeparateGraphScale ? antigravityTokenMax : globalTokenMax,
                                    showTotal: true,
                                    firstDayOfWeek: state.firstDayOfWeek
                                )
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func antigravityModelRow(_ title: String, percent: Double, reset: Date?) -> some View {
        let fraction = min(1.0, max(0.0, percent / 100.0))
        let displayFraction = state.showRemaining ? fraction : (1.0 - fraction)
        let displayPercent = state.showRemaining ? percent : (100.0 - percent)
        let suffix = state.showRemaining ? "left" : "used"

        return VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            progressBar(displayFraction, color: .antigravityGreen)
            HStack(spacing: 6) {
                Text("\(percentText(displayPercent)) \(suffix)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .layoutPriority(1)
                Spacer()
                if let resetStr = resetText(reset, compact: state.antigravitySideBySide) {
                    Text(resetStr)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func progressTint(_ fraction: Double) -> Color {
        if fraction < 0.6 { return .green }
        if fraction < 0.85 { return .orange }
        return .red
    }

    private var claudeTokenMax: Double {
        let maxVal = (state.claudeHistory.values.max() ?? 0.0) * 2000.0
        return max(maxVal, 100_000.0)
    }

    private var deepseekTokenMax: Double {
        let maxVal = (state.deepseekHistory.values.max() ?? 0.0) * 2_000_000.0
        return max(maxVal, 100_000.0)
    }

    private var antigravityTokenMax: Double {
        let geminiMax = (state.antigravityGeminiHistory.values.max() ?? 0.0) * 1000.0
        let claudeGptMax = (state.antigravityClaudeGptHistory.values.max() ?? 0.0) * 1000.0
        let fusedMax = antigravityFusedHistory.values.max() ?? 0.0
        let maxVal = max(geminiMax, max(claudeGptMax, fusedMax))
        return max(maxVal, 100_000.0)
    }

    private var globalTokenMax: Double {
        let claudeMax = state.claudeHistory.values.max() ?? 0.0
        let claudeTokenMax = claudeMax * 2000.0
        
        let deepseekMax = state.deepseekHistory.values.max() ?? 0.0
        let deepseekTokenMax = deepseekMax * 2_000_000.0
        
        let geminiMax = state.antigravityGeminiHistory.values.max() ?? 0.0
        let geminiTokenMax = geminiMax * 1000.0
        
        let claudeGptMax = state.antigravityClaudeGptHistory.values.max() ?? 0.0
        let claudeGptTokenMax = claudeGptMax * 1000.0
        
        let maxVal = max(claudeTokenMax, max(deepseekTokenMax, max(geminiTokenMax, claudeGptTokenMax)))
        return max(maxVal, 100_000.0) // baseline minimum of 100k tokens
    }
}

extension Color {
    static let claudeAccent = Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    static let deepseekAccent = Color(red: 0x4D / 255.0, green: 0x6B / 255.0, blue: 0xFE / 255.0)
    static let antigravityGreen = Color(red: 0x00 / 255.0, green: 0xB9 / 255.0, blue: 0x5C / 255.0)
}
