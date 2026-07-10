import SwiftUI

// Nested corner radii are concentric: inner radius = outer radius − inset,
// so every rounded rect shares the same corner center as the one around it.
// The system popover corner measures as a CIRCULAR arc of 20pt (pixel-fitted
// from a screenshot), so the shapes below use .circular, not .continuous —
// a continuous corner of the right radius still leaves an uneven gap.
private enum CardMetrics {
    static let popoverRadius: CGFloat = 20
    static let gutter: CGFloat = 8                            // padding around/between cards
    static let cardRadius: CGFloat = popoverRadius - gutter
    static let cardPaddingH: CGFloat = 12
    static let cardPaddingV: CGFloat = 10
    static let footerInset: CGFloat = 4                       // buttons inside the footer card
    static let footerButtonRadius: CGFloat = cardRadius - footerInset
    // The threads panel sits cardPaddingH from the corner, so the strict rule
    // bottoms out at 0; clamp to keep a hint of rounding on a mid-card element.
    // Matches the 7-Day Usage graph card's corner radius so inner panels read as one family.
    static let panelRadius: CGFloat = UsageGraphView.cardCornerRadius
}

struct MenuView: View {
    @State var state: AppState
    let onRefresh: (Bool) async -> Void   // force: bypass rate-limit backoff/coalescing
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CardMetrics.gutter) {
            providerCards
            footerButtons
        }
        .padding(CardMetrics.gutter)
        .frame(width: 320)
        // No explicit background: the popover frame already draws its own material
        // (spanning the arrow too). Layering another material here only covers the
        // content rect, and its top edge shows as a flat full-width seam right at
        // the arrow's base line.
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

    private var providerCards: some View {
        VStack(alignment: .leading, spacing: CardMetrics.gutter) {
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
                    .providerCard()
            }
        }
    }

    @ViewBuilder private var claudeBlock: some View {
        if state.claudeEnabled {
            claudeSection.providerCard()
        }
    }

    @ViewBuilder private var deepseekBlock: some View {
        if state.deepseekEnabled {
            deepseekSection.providerCard()
        }
    }

    @ViewBuilder private var antigravityBlock: some View {
        if state.antigravityEnabled {
            antigravitySection.providerCard()
        }
    }

    @ViewBuilder private var geminiBlock: some View {
        if state.geminiEnabled {
            geminiSection.providerCard()
        }
    }

    @ViewBuilder private var codexBlock: some View {
        if state.codexEnabled {
            codexSection.providerCard()
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
                    claudeGroupColumn
                    if showFablePanel {
                        Divider()
                        fableGroupColumn
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                claudeGroupRow
                if showFablePanel {
                    Divider()
                    fableGroupRow
                }
            }

            if state.claudeShowLatestThread && !state.claudeLatestThreads.isEmpty {
                latestThreadsPanel(state.claudeLatestThreads.map {
                    ThreadDisplay(id: $0.id, title: $0.title, status: $0.status)
                })
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
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: CardMetrics.panelRadius, style: .circular)
                        .fill(Color.primary.opacity(0.045))
                )
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
                latestThreadsPanel(state.antigravityLatestThreads.map {
                    ThreadDisplay(id: $0.id, title: $0.title, status: $0.status)
                })
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
    }

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderIcon(provider: "codex", size: 18)
                Text("Chat GPT")
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
                    latestThreadsPanel(state.codexLatestThreads.map {
                        ThreadDisplay(id: $0.id, title: $0.title, status: $0.status)
                    })
                }
            }

            if let err = state.codexError {
                Text(err).font(.system(size: 10)).foregroundStyle(Color.codexAccent)
            } else if !state.codexAvailable {
                Text("Reading local Chat GPT usage…")
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

    private struct ThreadDisplay: Identifiable {
        let id: String
        let title: String
        let status: String
    }

    private func latestThreadsPanel(_ threads: [ThreadDisplay]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Latest Threads")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(threads) { thread in
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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CardMetrics.panelRadius, style: .circular)
                .fill(Color.primary.opacity(0.045))
        )
    }

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

    // MARK: - Claude/Fable 5 Layout Modes
    //
    // Mirrors Antigravity's group layout (antigravityRow / antigravitySideBlock):
    // "Claude" and "Fable 5" are two model groups, each showing its own Session+Week.
    // claudeSideBySide flips the axis — side-by-side arranges the two GROUPS as
    // columns (Session/Week stacked within each column, one Divider between groups);
    // stacked arranges the two groups vertically (Session/Week side-by-side within
    // each group, one Divider between groups).

    private var claudeGroupRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude")
                .font(.system(size: 11, weight: .bold))
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
        }
    }

    // Fable's weekly limit comes from the API's model-scoped limits — only some
    // accounts have one, so the panel hides when the API doesn't report it.
    private var showFablePanel: Bool {
        state.claudeShowFableUsage && state.claudeFableWeekPercent != nil
    }

    private var fableGroupRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Fable 5")
                .font(.system(size: 11, weight: .bold))
            claudeWindowRow("Week",
                            percent: state.claudeFableWeekPercent ?? 0,
                            reset: state.claudeFableWeekResetAt)
        }
    }

    private var claudeGroupColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude")
                .font(.system(size: 11, weight: .bold))
            claudeWindowRow("Session",
                            percent: state.claudeSessionPercent,
                            reset: state.claudeSessionResetAt)
            claudeWindowRow("Week",
                            percent: state.claudeWeekPercent,
                            reset: state.claudeWeekResetAt)
        }
    }

    private var fableGroupColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fable 5")
                .font(.system(size: 11, weight: .bold))
            claudeWindowRow("Week",
                            percent: state.claudeFableWeekPercent ?? 0,
                            reset: state.claudeFableWeekResetAt)
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
        return HStack(spacing: 4) {
            Text("\(percentText(normalizedPercent)) \(suffix)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let resetStr = resetText(reset, compact: compact, showDuration: isSession) {
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
        HStack(spacing: 4) {
            footerButton("arrow.clockwise", "Refresh") {
                Task { await onRefresh(true) }
            }
            footerButton("gearshape", "Settings") {
                onSettings()
            }
            footerButton("power", "Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(CardMetrics.footerInset)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: CardMetrics.cardRadius, style: .circular)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CardMetrics.cardRadius, style: .circular)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func footerButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(FooterButtonStyle())
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

// Card container for each provider in the popover: rounded, softly filled, and
// hairline-stroked so it reads in both light and dark on the popover's material.
private extension View {
    func providerCard() -> some View {
        self
            .padding(.horizontal, CardMetrics.cardPaddingH)
            .padding(.vertical, CardMetrics.cardPaddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CardMetrics.cardRadius, style: .circular)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CardMetrics.cardRadius, style: .circular)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
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
        FooterButtonLabel(configuration: configuration)
    }

    // Hover state needs real View storage; a ButtonStyle struct is recreated on
    // every render, so @State directly on it would reset.
    private struct FooterButtonLabel: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: CardMetrics.footerButtonRadius, style: .circular)
                        .fill(configuration.isPressed
                              ? Color.primary.opacity(0.12)
                              : (hovering ? Color.primary.opacity(0.06) : Color.clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: CardMetrics.footerButtonRadius, style: .circular))
                .onHover { hovering = $0 }
        }
    }
}
