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
    static let footerInset: CGFloat = 4                       // vertical breathing room under the last card
    // The threads panel sits cardPaddingH from the corner, so the strict rule
    // bottoms out at 0; clamp to keep a hint of rounding on a mid-card element.
    // Matches the 7-Day Usage graph card's corner radius so inner panels read as one family.
    static let panelRadius: CGFloat = UsageGraphView.cardCornerRadius
}

struct MenuView: View {
    @State var state: AppState
    let onRefresh: (Bool) async -> Void   // force: bypass rate-limit backoff/coalescing
    let onSettings: () -> Void
    /// Starts the Claude OAuth flow. Reached only through the error row below —
    /// the moment the user is told they are signed out is the moment the fix
    /// should be one click away, not buried in Settings.
    let onClaudeSignIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CardMetrics.gutter) {
            header
            providerCards
            footerButtons
        }
        .padding(CardMetrics.gutter)
        .frame(width: 320)
        // No background of our own: the popover's native chrome already draws body
        // and arrow as ONE continuous surface. An NSGlassEffectView here covers only
        // the content rect — never the arrow, which AppKit draws above it — so its
        // top edge highlight ran across the arrow's base as a hairline that visually
        // severed the arrow from the popover. On macOS 26+ the built-in popover
        // material is Liquid Glass anyway, so this still reads as the same surface
        // family as the Settings window (which keeps its own GlassEffectBackground,
        // where there is no arrow to cut).
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

    /// Compact notice for weekly limits that rolled over ahead of their announced
    /// reset. It lives in the footer's empty left half rather than in a card of its
    /// own: it is chrome about the data, not a reading, and the footer is the one row
    /// with space to spare. Clicking it dismisses; the tooltip carries the detail the
    /// single line has no room for.
    @ViewBuilder private var earlyResetNotice: some View {
        let events = state.earlyResetEvents.sorted { $0.detectedAt > $1.detectedAt }
        if let latest = events.first {
            Button {
                state.earlyResetEvents.removeAll()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                    Text(latest.bannerText)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // More than one at once is rare (two providers resetting in the
                    // same poll), so a count beats stacking rows in a chrome strip.
                    if events.count > 1 {
                        Text("+\(events.count - 1)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                // Footer grey, matching the gear and power icons beside it: this row is
                // chrome, and an accent-tinted strip here read as an alert competing
                // with the provider cards above.
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(earlyResetTooltip(events))
            .accessibilityLabel(latest.bannerText)
        }
    }

    private func earlyResetTooltip(_ events: [EarlyResetEvent]) -> String {
        let formatter = DateFormatter()
        // Weekly resets land days out, so the day matters as much as the clock time.
        formatter.setLocalizedDateFormatFromTemplate("EEE jm")
        let lines = events.map { event in
            "\(event.detailText) — was not due until \(formatter.string(from: event.expectedResetAt))"
        }
        return (lines + ["Click to dismiss."]).joined(separator: "\n")
    }

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
                claudeErrorRow(err)
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

    // A Claude error is usually just a status line. When it is one sign-in can fix,
    // it becomes the button that fixes it — same position, same size, so nothing in
    // the card moves; only the affordance changes.
    @ViewBuilder
    private func claudeErrorRow(_ err: String) -> some View {
        if ClaudeScanner.requiresSignIn(err) {
            Button(action: onClaudeSignIn) {
                HStack(spacing: 3) {
                    Text(err)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.claudeAccent)
                // Underline is the only thing marking this as actionable at 10 pt —
                // the accent colour alone is already used for plain error text.
                .underline()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help("Sign in to Claude")
        } else {
            Text(err).font(.system(size: 10)).foregroundStyle(Color.claudeAccent)
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

            // The status line sits under the header rather than between panels: once
            // the panels are user-ordered there is no "between" that stays meaningful.
            if let err = state.deepseekError {
                Text(err).font(.system(size: 10)).foregroundStyle(Color.deepseekAccent)
            } else if !state.deepseekAvailable {
                Text("Fetching DeepSeek balance…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            ForEach(state.deepseekPanelOrder, id: \.self) { panel in
                deepseekPanel(panel)
            }
        }
    }

    /// One panel of the DeepSeek card, addressed by the id stored in
    /// `deepseekPanelOrder`. Each keeps its own visibility rule, so reordering never
    /// makes a hidden panel appear.
    @ViewBuilder
    private func deepseekPanel(_ id: String) -> some View {
        switch id {
        case "billing":
            TimelineView(.periodic(from: .now, by: 30)) { context in
                deepseekBillingPanel(at: context.date)
            }

        case "graph":
            if state.deepseekAvailable && state.deepseekShowGraph {
                UsageGraphView(
                    history: state.deepseekHistory.mapValues { $0 * 2_000_000.0 },
                    tintColor: .deepseekAccent,
                    unitFormatter: { deepseekCostText($0) },
                    yAxisMax: state.useSeparateGraphScale ? deepseekTokenMax : globalTokenMax,
                    showTotal: true,
                    firstDayOfWeek: state.firstDayOfWeek
                )
            }

        case "balance":
            if let balance = state.deepseekDisplayBalance {
                // Single row: label left, figure right. Mirrors the graph card's
                // "7-Day Usage / total" header so the two panels read as a pair.
                HStack(spacing: 8) {
                    Text("Balance Left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(balanceDisplay(balance, currency: state.deepseekDisplayCurrency))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: CardMetrics.panelRadius, style: .circular)
                        .fill(Color.primary.opacity(0.045))
                )
            }

        default:
            EmptyView()
        }
    }

    private func deepseekBillingPanel(at date: Date) -> some View {
        let status = DeepSeekPricing.status(at: date)

        return HStack(spacing: 8) {
            Circle()
                .fill(status.period == .peak ? Color.orange : Color.green)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(status.period.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                Text(status.period.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("until \(deepseekBillingChangeText(status.nextTransition, relativeTo: date))")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: CardMetrics.panelRadius, style: .circular)
                .fill(Color.primary.opacity(0.045))
        )
    }

    // Header already reads "Antigravity", so drop a redundant prefix from the
    // scanner message to keep the inline status on one line at 320pt.
    private var antigravityStatusText: String {
        guard let err = state.antigravityError else { return "Connecting…" }
        if err.hasPrefix("Antigravity ") {
            return String(err.dropFirst("Antigravity ".count))
        }
        return err
    }

    private var antigravitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProviderIcon(provider: "antigravity", size: 18)
                Text("Antigravity")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !state.antigravityAvailable {
                    // Offline: keep the card to a single row by folding the status
                    // message into the header instead of stacking it underneath.
                    Text(antigravityStatusText)
                        .font(.system(size: 10))
                        .foregroundStyle(state.antigravityError != nil ? AnyShapeStyle(Color.antigravityGreen) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.85)
                }
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

                if let err = state.antigravityError {
                    Text(err).font(.system(size: 10)).foregroundStyle(Color.antigravityGreen)
                }
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
        // Antigravity anchors each bucket to its FIRST use. Until that happens it
        // keeps re-reporting "now + window" on every poll, so the countdown never
        // counts down — a session that reads 4 hr 59 min forever. Nothing consumed
        // means nothing started, so the reset side of the row stays empty rather than
        // showing a clock that isn't real.
        let started = percent > 0

        return VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            progressBar(displayFraction, color: accentColor)
            usageFooterRow(
                displayPercent: displayPercent,
                suffix: suffix,
                reset: started ? reset : nil,
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text("TokenBar")
                    .font(.system(size: 14, weight: .semibold))

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            // Re-read on a timer so "2 min ago" ages while the menu stays open —
            // the menu can sit open far longer than the poll interval.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .trailing, spacing: 3) {
                    Text(lastRefreshText(at: context.date))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text("last refresh")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        // Deliberately not a card, like the footer: the identity row is chrome, not
        // content. It keeps the cards' horizontal inset so the title lines up with the
        // card contents below it, and sits on the glass with no fill.
        .padding(.horizontal, CardMetrics.cardPaddingH)
        .padding(.vertical, CardMetrics.footerInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Live when at least one provider the user actually enabled is answering.
    /// Losing the network takes every scanner down at once, so this reads as
    /// Inactive without needing a reachability check of its own.
    private var anyProviderLive: Bool {
        (state.claudeEnabled && state.claudeAvailable)
            || (state.deepseekEnabled && state.deepseekAvailable)
            || (state.antigravityEnabled && state.antigravityAvailable)
            || (state.geminiEnabled && state.geminiAvailable)
            || (state.codexEnabled && state.codexAvailable)
    }

    private var noProvidersEnabled: Bool {
        !state.claudeEnabled && !state.deepseekEnabled && !state.antigravityEnabled
            && !state.geminiEnabled && !state.codexEnabled
    }

    private var statusText: String {
        if noProvidersEnabled { return "No providers" }
        // Only call it Connecting before the first answer. After that a refresh in
        // flight shouldn't wipe out a status the user can still see data behind.
        if state.isLoading && state.lastRefreshed == nil { return "Connecting…" }
        return anyProviderLive ? "Active" : "Inactive"
    }

    private var statusColor: Color {
        if noProvidersEnabled { return .secondary }
        if state.isLoading && state.lastRefreshed == nil { return .orange }
        return anyProviderLive ? .green : .red
    }

    private func lastRefreshText(at now: Date) -> String {
        guard let date = state.lastRefreshed else { return "never" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 45 { return "just now" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) hr ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }

    private var footerButtons: some View {
        // No Refresh button: every setting that affects the data already refreshes on
        // change, the poll runs on its own cadence, and opening the menu tops up a
        // stale reading — so the button only ever repeated work that had just happened.
        HStack(spacing: 4) {
            earlyResetNotice

            Spacer(minLength: 9)

            Button {
                onSettings()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
            .accessibilityLabel("Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit TokenBar")
            .accessibilityLabel("Quit TokenBar")
        }
        .font(.system(size: 11, weight: .medium))
        // Deliberately not a card: the footer is chrome, not content. It keeps the
        // cards' horizontal inset so the icons line up with the content above them,
        // but sits directly on the popover's glass with no fill or stroke.
        // Same footer as GhostTyper's menu — shared by copy, not by module.
        .padding(.horizontal, CardMetrics.cardPaddingH)
        .padding(.vertical, CardMetrics.footerInset)
        .frame(maxWidth: .infinity)
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

    // Per-day DeepSeek spend for the 7-Day Usage graph. The graph stores cost scaled
    // into a token-ish range for bar height, so divide back out, apply the live THB
    // rate when that display is on, and show the money in the account's currency.
    // Tiny days keep extra precision so a fraction of a cent isn't shown as 0.00.
    private func deepseekCostText(_ scaledValue: Double) -> String {
        let cost = scaledValue / 2_000_000.0
        let money = state.deepseekThbActive ? cost * state.deepseekThbRate : cost
        let symbol = CurrencyFormat.symbol(state.deepseekDisplayCurrency)
        if money > 0 && money < 0.01 {
            return String(format: "%@%.4f", symbol, money)
        }
        return String(format: "%@%.2f", symbol, money)
    }

    private func deepseekBillingChangeText(_ date: Date, relativeTo now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "E HH:mm"
        return formatter.string(from: date)
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

