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
                } else if provider == "gemini" {
                    geminiBlock
                } else if provider == "codex" {
                    codexBlock
                }
            }
            if !state.claudeEnabled && !state.deepseekEnabled && !state.antigravityEnabled && !state.geminiEnabled && !state.codexEnabled {
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
        .onChange(of: state.geminiEnabled) {
            Task { await onRefresh(false) }
        }
        .onChange(of: state.codexEnabled) {
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

    @ViewBuilder private var geminiBlock: some View {
        if state.geminiEnabled {
            geminiSection
            Divider()
        }
    }

    @ViewBuilder private var codexBlock: some View {
        if state.codexEnabled {
            codexSection
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

            if state.claudeShowLatestThread && !state.claudeLatestThreads.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Latest Threads")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(state.claudeLatestThreads, id: \.id) { thread in
                        HStack(spacing: 6) {
                            Text(thread.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(threadStatusColor(thread.status))
                                    .frame(width: 5, height: 5)
                                Text(thread.status)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .fixedSize()
                        }
                    }
                }
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

    private var deepseekSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderIcon(provider: "deepseek", size: 18)
                Text("DeepSeek")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            if let balance = state.deepseekDisplayBalance {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Balance Left")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(balanceDisplay(balance, currency: state.deepseekDisplayCurrency))
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            if let err = state.deepseekError {
                Text(err).font(.system(size: 10)).foregroundStyle(Color.deepseekAccent)
            } else if !state.deepseekAvailable {
                Text("Fetching DeepSeek balance…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if state.deepseekAvailable && state.deepseekShowGraph {
                UsageGraphView(
                    history: state.deepseekHistory.mapValues { $0 * 2_000_000.0 },
                    tintColor: .deepseekAccent,
                    unitFormatter: { formatTokens($0) },
                    yAxisMax: state.useSeparateGraphScale ? deepseekTokenMax : globalTokenMax,
                    showTotal: true,
                    firstDayOfWeek: state.firstDayOfWeek
                )
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var antigravitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProviderIcon(provider: "antigravity", size: 18)
                Text("Antigravity")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            if state.antigravityAvailable {
                if state.antigravitySideBySide {
                    HStack(alignment: .top, spacing: 12) {
                        antigravitySideBlock
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    antigravityStackedBlock
                }
            }

            if let err = state.antigravityError {
                Text(err).font(.system(size: 10)).foregroundStyle(Color.antigravityGreen)
            } else if !state.antigravityAvailable {
                Text("Connecting to Antigravity…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if state.antigravityShowLatestThread && !state.antigravityLatestThreads.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Latest Threads")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(state.antigravityLatestThreads, id: \.id) { thread in
                        HStack(spacing: 6) {
                            Text(thread.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(threadStatusColor(thread.status))
                                    .frame(width: 5, height: 5)
                                Text(thread.status)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .fixedSize()
                        }
                    }
                }
                .padding(.top, 2)
            }

            if state.antigravityAvailable && state.antigravityShowGraph {
                UsageGraphView(
                    history: state.antigravityFusedGraph ? fusedAntigravityHistory : state.antigravityGeminiHistory.mapValues { $0 * 1000.0 },
                    history2: state.antigravityFusedGraph ? nil : state.antigravityClaudeGptHistory.mapValues { $0 * 1000.0 },
                    tintColor: .antigravityGreen,
                    tintColor2: state.antigravityFusedGraph ? nil : .claudeAccent,
                    unitFormatter: { formatTokens($0) },
                    yAxisMax: state.useSeparateGraphScale ? (state.antigravityFusedGraph ? fusedAntigravityTokenMax : max(geminiTokenMax, claudeGptTokenMax)) : globalTokenMax,
                    showTotal: true,
                    firstDayOfWeek: state.firstDayOfWeek
                )
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var geminiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderIcon(provider: "gemini", size: 18)
                Text("Gemini")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            if state.geminiAvailable {
                if state.geminiSideBySide {
                    HStack(alignment: .top, spacing: 12) {
                        geminiWindowRow("Session",
                                        percent: state.geminiSessionPercent,
                                        reset: state.geminiSessionResetAt)
                        Divider()
                        geminiWindowRow("Week",
                                        percent: state.geminiWeekPercent,
                                        reset: state.geminiWeekResetAt)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    geminiWindowRow("Session",
                                    percent: state.geminiSessionPercent,
                                    reset: state.geminiSessionResetAt)
                    geminiWindowRow("Week",
                                    percent: state.geminiWeekPercent,
                                    reset: state.geminiWeekResetAt)
                }
            }

            if let err = state.geminiError {
                Text(err).font(.system(size: 10)).foregroundStyle(Color.geminiAccent)
            } else if !state.geminiAvailable {
                Text("Reading Gemini web usage…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if state.geminiAvailable && state.geminiShowGraph {
                UsageGraphView(
                    history: state.geminiHistory.mapValues { $0 * 2000.0 },
                    tintColor: .geminiAccent,
                    unitFormatter: { formatTokens($0) },
                    yAxisMax: state.useSeparateGraphScale ? geminiWebTokenMax : globalTokenMax,
                    showTotal: true,
                    firstDayOfWeek: state.firstDayOfWeek
                )
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderIcon(provider: "codex", size: 18)
                Text("Codex")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            if state.codexAvailable {
                if state.codexSideBySide {
                    HStack(alignment: .top, spacing: 12) {
                        codexWindowRow("Session",
                                       percent: state.codexSessionPercent,
                                       reset: state.codexSessionResetAt)
                        Divider()
                        codexWindowRow("Week",
                                       percent: state.codexWeekPercent,
                                       reset: state.codexWeekResetAt)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    codexWindowRow("Session",
                                   percent: state.codexSessionPercent,
                                   reset: state.codexSessionResetAt)
                    codexWindowRow("Week",
                                   percent: state.codexWeekPercent,
                                   reset: state.codexWeekResetAt)
                }

                if state.codexShowLatestThread && !state.codexLatestThreads.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Latest Threads")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        ForEach(state.codexLatestThreads, id: \.id) { thread in
                            HStack(spacing: 6) {
                                Text(thread.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                HStack(spacing: 3) {
                                    Circle()
                                        .fill(threadStatusColor(thread.status))
                                        .frame(width: 5, height: 5)
                                    Text(thread.status)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .fixedSize()
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }

            if let err = state.codexError {
                Text(err).font(.system(size: 10)).foregroundStyle(Color.codexAccent)
            } else if !state.codexAvailable {
                Text("Reading local Codex usage…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if state.codexAvailable && state.codexShowGraph {
                UsageGraphView(
                    history: state.codexHistory,
                    tintColor: .codexAccent,
                    unitFormatter: { formatTokens($0) },
                    yAxisMax: state.useSeparateGraphScale ? codexTokenMax : globalTokenMax,
                    showTotal: true,
                    firstDayOfWeek: state.firstDayOfWeek
                )
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func geminiWindowRow(_ title: String, percent: Double, reset: Date?) -> some View {
        let fraction = min(1.0, max(0, percent / 100))
        let displayFraction = state.showRemaining ? (1.0 - fraction) : fraction
        let displayPercent = state.showRemaining ? (100.0 - percent) : percent
        let suffix = state.showRemaining ? "left" : "used"
        
        return VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            progressBar(displayFraction, color: .geminiAccent)
            usageFooterRow(
                displayPercent: displayPercent,
                suffix: suffix,
                reset: reset,
                compact: state.geminiSideBySide,
                isSession: title == "Session"
            )
        }
    }

    private func codexWindowRow(_ title: String, percent: Double, reset: Date?) -> some View {
        let fraction = min(1.0, max(0, percent / 100))
        let displayFraction = state.showRemaining ? (1.0 - fraction) : fraction
        let displayPercent = state.showRemaining ? (100.0 - percent) : percent
        let suffix = state.showRemaining ? "left" : "used"
        
        return VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            progressBar(displayFraction, color: .codexAccent)
            usageFooterRow(
                displayPercent: displayPercent,
                suffix: suffix,
                reset: reset,
                compact: state.codexSideBySide,
                isSession: title == "Session"
            )
        }
    }

    private func codexTokenUsageRow(_ title: String, tokens: Double, maxTokens: Double) -> some View {
        let fraction = maxTokens > 0 ? min(1.0, max(0, tokens / maxTokens)) : 0

        return VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            progressBar(fraction, color: .codexAccent)
            HStack(spacing: 6) {
                Text(formatTokens(tokens))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Spacer()
            }
        }
    }

    private func codexMetric(_ title: String, tokens: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(formatTokens(tokens))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Antigravity Layout Modes

    @ViewBuilder private var antigravityStackedBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            antigravityRow("Gemini Models",
                           session: state.antigravityGeminiSessionPercent,
                           sessionReset: state.antigravityGeminiSessionResetAt,
                           week: state.antigravityGeminiWeekPercent,
                           weekReset: state.antigravityGeminiWeekResetAt,
                           accentColor: .antigravityGreen)

            Divider()

            antigravityRow("Claude & GPT Models",
                           session: state.antigravityClaudeGptSessionPercent,
                           sessionReset: state.antigravityClaudeGptSessionResetAt,
                           week: state.antigravityClaudeGptWeekPercent,
                           weekReset: state.antigravityClaudeGptWeekResetAt,
                           accentColor: .antigravityGreen)
        }
    }

    @ViewBuilder private var antigravitySideBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Gemini Models")
                    .font(.system(size: 11, weight: .bold))
                antigravityWindowRow("Session",
                                    percent: state.antigravityGeminiSessionPercent,
                                    reset: state.antigravityGeminiSessionResetAt,
                                    accentColor: .antigravityGreen)
                antigravityWindowRow("Week",
                                    percent: state.antigravityGeminiWeekPercent,
                                    reset: state.antigravityGeminiWeekResetAt,
                                    accentColor: .antigravityGreen)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Claude & GPT Models")
                    .font(.system(size: 11, weight: .bold))
                antigravityWindowRow("Session",
                                    percent: state.antigravityClaudeGptSessionPercent,
                                    reset: state.antigravityClaudeGptSessionResetAt,
                                    accentColor: .antigravityGreen)
                antigravityWindowRow("Week",
                                    percent: state.antigravityClaudeGptWeekPercent,
                                    reset: state.antigravityClaudeGptWeekResetAt,
                                    accentColor: .antigravityGreen)
            }
        }
    }

    private func antigravityRow(
        _ title: String,
        session: Double,
        sessionReset: Date?,
        week: Double,
        weekReset: Date?,
        accentColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold))

            HStack(alignment: .top, spacing: 12) {
                antigravityWindowRow("Session",
                                    percent: session,
                                    reset: sessionReset,
                                    accentColor: accentColor)
                Divider()
                antigravityWindowRow("Week",
                                    percent: week,
                                    reset: weekReset,
                                    accentColor: accentColor)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func antigravityWindowRow(
        _ title: String,
        percent: Double,
        reset: Date?,
        accentColor: Color
    ) -> some View {
        let fraction = min(1.0, max(0, percent / 100))
        let displayFraction = state.showRemaining ? (1.0 - fraction) : fraction
        let displayPercent = state.showRemaining ? (100.0 - percent) : percent
        let suffix = state.showRemaining ? "left" : "used"

        return VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            progressBar(displayFraction, color: accentColor)
            usageFooterRow(
                displayPercent: displayPercent,
                suffix: suffix,
                reset: reset,
                compact: state.antigravitySideBySide,
                isSession: title == "Session"
            )
        }
    }

    // MARK: - Generic UI Components

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
            usageFooterRow(
                displayPercent: displayPercent,
                suffix: suffix,
                reset: reset,
                compact: state.claudeSideBySide,
                isSession: title == "Session"
            )
        }
    }

    private func progressBar(_ fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width, height: 4)
            }
        }
        .frame(height: 4)
    }

    private func usageFooterRow(
        displayPercent: Double,
        suffix: String,
        reset: Date?,
        compact: Bool,
        isSession: Bool
    ) -> some View {
        let normalizedPercent = normalizedUsageDisplayPercent(displayPercent)
        let shouldShowReset = !isUsageWindowFull(displayPercent)

        return HStack(spacing: 4) {
            Text("\(percentText(normalizedPercent)) \(suffix)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if shouldShowReset,
               let resetStr = resetText(reset, compact: compact, showDuration: isSession) {
                Text(resetStr)
                    .font(.system(size: isSession ? 9.5 : 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
                    .allowsTightening(true)
            }
        }
    }

    private var footerButtons: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                Button(action: {
                    Task { await onRefresh(true) }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(FooterButtonStyle())

                Divider().frame(height: 24)

                Button(action: {
                    onSettings()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape")
                        Text("Settings")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(FooterButtonStyle())

                Divider().frame(height: 24)

                Button(action: {
                    NSApp.terminate(nil)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                        Text("Quit")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(FooterButtonStyle())
            }
            .padding(.vertical, 4)
            .background(.regularMaterial)
        }
    }

    // MARK: - Formatters

    private func percentText(_ percent: Double) -> String {
        return String(format: "%.0f%%", percent)
    }

    private func normalizedUsageDisplayPercent(_ percent: Double) -> Double {
        guard isUsageWindowFull(percent) else { return percent }
        return state.showRemaining ? 100 : 0
    }

    private func isUsageWindowFull(_ percent: Double) -> Bool {
        state.showRemaining ? percent >= 99 : percent <= 1
    }

    private func formatTokens(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000.0)
        } else if value >= 1000 {
            return String(format: "%.0fk", value / 1000.0)
        } else {
            return String(format: "%.0f", value)
        }
    }

    private func balanceDisplay(_ balance: Double, currency: String) -> String {
        String(format: "%@%.2f", CurrencyFormat.symbol(currency), balance)
    }

    private func resetText(_ date: Date?, compact: Bool, showDuration: Bool = false) -> String? {
        guard let date else { return nil }
        if showDuration {
            return "in \(resetDurationText(until: date))"
        }
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return "reset \(formatter.string(from: date))"
        } else {
            formatter.dateFormat = compact ? "E HH:mm" : "EEEE HH:mm"
            return formatter.string(from: date)
        }
    }

    private func resetDurationText(until date: Date) -> String {
        let totalMinutes = max(0, Int(ceil(date.timeIntervalSinceNow / 60.0)))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours) hr \(minutes) min"
    }

    private var claudeTokenMax: Double {
        let maxVal = (state.claudeHistory.values.max() ?? 0.0) * 2000.0
        return max(maxVal, 100_000.0)
    }

    private var deepseekTokenMax: Double {
        let maxVal = (state.deepseekHistory.values.max() ?? 0.0) * 2_000_000.0
        return max(maxVal, 100_000.0)
    }

    private var geminiTokenMax: Double {
        let maxVal = (state.antigravityGeminiHistory.values.max() ?? 0.0) * 1000.0
        return max(maxVal, 100_000.0)
    }

    private var claudeGptTokenMax: Double {
        let maxVal = (state.antigravityClaudeGptHistory.values.max() ?? 0.0) * 1000.0
        return max(maxVal, 100_000.0)
    }

    private var fusedAntigravityTokenMax: Double {
        let maxVal = fusedAntigravityHistory.values.max() ?? 0.0
        return max(maxVal, 100_000.0)
    }

    private var fusedAntigravityHistory: [String: Double] {
        var merged = state.antigravityGeminiHistory.mapValues { $0 * 1000.0 }
        for (key, val) in state.antigravityClaudeGptHistory {
            merged[key, default: 0.0] += val * 1000.0
        }
        return merged
    }

    private var geminiWebTokenMax: Double {
        let maxVal = (state.geminiHistory.values.max() ?? 0.0) * 2000.0
        return max(maxVal, 100_000.0)
    }

    private var codexTokenMax: Double {
        let maxVal = state.codexHistory.values.max() ?? 0.0
        return max(maxVal, 100_000.0)
    }

    private var codexUsageBarMax: Double {
        let latestThreadMax = state.codexLatestThreads.map(\.tokens).max() ?? state.codexActiveThreadTokens
        return max(codexTokenMax, state.codexTodayTokens, state.codexWeekTokens, latestThreadMax)
    }

    private func threadStatusColor(_ status: String) -> Color {
        switch status {
        case "done":
            return Color.green
        case "coding":
            return Color.orange
        default:
            return Color.secondary
        }
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

        let geminiWebMax = state.geminiHistory.values.max() ?? 0.0
        let geminiWebTokenMax = geminiWebMax * 2000.0
        
        let codexTokenMax = state.codexHistory.values.max() ?? 0.0

        let maxVal = max(claudeTokenMax,
                         max(deepseekTokenMax,
                             max(geminiTokenMax,
                                 max(claudeGptTokenMax,
                                     max(geminiWebTokenMax, codexTokenMax)))))
        return max(maxVal, 100_000.0) // baseline minimum of 100k tokens
    }
}

extension Color {
    static let claudeAccent = Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    static let deepseekAccent = Color(red: 0x4D / 255.0, green: 0x6B / 255.0, blue: 0xFE / 255.0)
    static let antigravityGreen = Color(red: 0x00 / 255.0, green: 0xB9 / 255.0, blue: 0x5C / 255.0)
    static let geminiAccent = Color(red: 0xF4 / 255.0, green: 0xB4 / 255.0, blue: 0x00 / 255.0)
    static let codexAccent = Color(red: 142 / 255.0, green: 142 / 255.0, blue: 147 / 255.0)
}

struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? Color.secondary.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
    }
}
