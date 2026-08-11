import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case providers
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .general: return "General"
        case .providers: return "Providers"
        }
    }
    
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .providers: return "cpu"
        }
    }
}

private enum SettingsLayout {
    static let sidebarWidth: CGFloat = 184
    static let contentMaxWidth: CGFloat = 1_040
    static let cardSpacing: CGFloat = 16
    // Concentric corners: the card is inset `cardGutter` inside the window's own
    // rounded corner, so its radius must shrink by that same amount to stay
    // concentric with it — a fixed radius on the inner shape drifts out of true
    // the moment the gutter changes.
    static let windowCornerRadius: CGFloat = 20
    static let cardGutter: CGFloat = 8
    static let cardCornerRadius: CGFloat = windowCornerRadius - cardGutter
}

// The real Liquid Glass surface (macOS 26+): NSGlassEffectView at its defaults —
// no material substitute, no hand-tuned tint — so the window's transparency is
// whatever the running OS defines natively, and tracks system changes across
// releases (macOS 27 included) for free. Shared with the popover (MenuView) so
// both surfaces read as the same glass.
@available(macOS 26.0, *)
struct GlassEffectBackground: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        nsView.cornerRadius = cornerRadius
    }
}

// Pre-Tahoe fallback: `.sidebar`/`.behindWindow` is the closest system material
// on macOS 14–15, where the glass API doesn't exist.
private struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct SettingsView: View {
    @State var state: AppState
    let onLiveChange: () -> Void

    @State private var selectedTab: SettingsTab = .general
    @State private var draggedProvider: String? = nil

    private var cardFillColor: Color { Color(NSColor.windowBackgroundColor) }
    private var hairlineBorderColor: Color { Color.white.opacity(0.12) }

    var body: some View {
        HStack(spacing: 0) {
            sidebarPane
                .frame(width: SettingsLayout.sidebarWidth)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailTitleView(for: selectedTab)
                    detailPaneView(for: selectedTab)
                }
                .frame(maxWidth: SettingsLayout.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 40)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The content pane is a floating card, fully opaque — no material, no
            // vibrancy, so it never picks up window transparency the way the
            // sidebar does. compositingGroup keeps the flat fill clipping cleanly
            // at the rounded corners instead of any edge artifacts.
            .background(cardFillColor)
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SettingsLayout.cardCornerRadius, style: .continuous)
                    .inset(by: 0.5)
                    .strokeBorder(hairlineBorderColor, lineWidth: 1)
            }
            .padding(SettingsLayout.cardGutter)
        }
        // The sidebar draws no fill of its own — this is the only glass in the
        // window, and the sidebar is simply the gap that lets it show through.
        // The content card floats on top of it, inset 8pt on all sides so the
        // glass forms a gutter around the card as well as behind the sidebar.
        .background {
            if #available(macOS 26.0, *) {
                GlassEffectBackground(cornerRadius: SettingsLayout.windowCornerRadius)
            } else {
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                    .overlay(Color.black.opacity(0.10))
            }
        }
        .frame(minWidth: 760, idealWidth: 1_040, minHeight: 560, idealHeight: 720)
        // Extend the glass under the transparent title bar so it reaches the true
        // top edge instead of stopping below the title-bar safe-area inset (which
        // left a blank strip). The sidebar's own top padding keeps its content
        // clear of the floating traffic-light buttons.
        .ignoresSafeArea(.container, edges: .top)
        .controlSize(.regular)
        .applyLiveChangeObservers(state: state, onLiveChange: onLiveChange)
    }

    private var sidebarPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 1) {
                Text("TokenBar")
                    .font(.system(size: 15, weight: .bold))
                Text("Settings")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(SettingsTab.allCases) { tab in
                    sidebarRow(for: tab)
                }
            }
            Spacer()
        }
        .padding(.top, 44)
        .padding([.horizontal, .bottom], 16)
    }
    
    private func sidebarRow(for tab: SettingsTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                    .frame(width: 22, height: 22)
                Text(tab.title)
                    .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .medium))
            }
            .padding(.horizontal, 11)
            .frame(height: 42)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selectedTab == tab ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
    }
    
    @ViewBuilder private func detailTitleView(for tab: SettingsTab) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(tab.title)
                .font(.system(size: 24, weight: .bold))
            Spacer()
            if tab == .providers {
                Text("\(enabledProviders.count) enabled")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }
    
    @ViewBuilder private func detailPaneView(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            generalPane
        case .providers:
            providersPane
        }
    }
    
    @ViewBuilder private var generalPane: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: SettingsLayout.cardSpacing) {
                VStack(spacing: SettingsLayout.cardSpacing) {
                    displaySettingsCard
                    notificationSettingsCard
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: SettingsLayout.cardSpacing) {
                    scheduleSettingsCard
                    providerOrderCard
                }
                .frame(maxWidth: .infinity)
            }
            .frame(minWidth: 680)

            VStack(spacing: SettingsLayout.cardSpacing) {
                displaySettingsCard
                notificationSettingsCard
                scheduleSettingsCard
                providerOrderCard
            }
        }
    }

    private var displaySettingsCard: some View {
        settingsCard(icon: "slider.horizontal.3", title: "Display") {
            settingToggle("Left Mode",
                          "Show left usage/quota instead of used.",
                          isOn: $state.showRemaining)
            Divider()
            settingToggle("Separate Graph Scales",
                          "Scale each provider's usage graph to its own peak instead of sharing a global maximum.",
                          isOn: $state.useSeparateGraphScale)
        }
    }

    private var notificationSettingsCard: some View {
        settingsCard(icon: "bell.badge", title: "Notifications") {
            settingToggle("Token Reduction Indicator",
                          "Show an indicator when token consumption or balance drops.",
                          isOn: $state.showReductionIndicator)
            Divider()
            settingToggle("Limit Reset Notifications",
                          "Notify when a tracked limit resets.",
                          isOn: $state.limitResetNotificationsEnabled)
            if state.limitResetNotificationsEnabled {
                limitResetLeadMinutesControl
            }
            Divider()
            settingToggle("Low Limit Notifications",
                          "Notify when a tracked limit's remaining amount drops at or below a threshold.",
                          isOn: $state.lowLimitNotificationsEnabled)
            if state.lowLimitNotificationsEnabled {
                lowLimitThresholdControl
            }
        }
    }

    private var limitResetLeadMinutesControl: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Also notify before reset")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(LimitResetLeadMinutes.options, id: \.self) { minutes in
                    leadMinuteChip(minutes)
                }
            }
        }
        .padding(.leading, 2)
    }

    private func leadMinuteChip(_ minutes: Int) -> some View {
        let isOn = state.limitResetLeadMinutes.contains(minutes)
        return Button {
            if isOn {
                state.limitResetLeadMinutes.remove(minutes)
            } else {
                state.limitResetLeadMinutes.insert(minutes)
            }
        } label: {
            Text("\(minutes)m")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help("Notify \(minutes) minute\(minutes == 1 ? "" : "s") before a limit resets")
    }

    private var lowLimitThresholdControl: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Remaining threshold")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(state.lowLimitThresholdPercent))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $state.lowLimitThresholdPercent, in: 1...50, step: 1)
        }
        .padding(.leading, 2)
    }

    private var scheduleSettingsCard: some View {
        settingsCard(icon: "clock", title: "Schedule") {
            VStack(alignment: .leading, spacing: 7) {
                Text("Refresh Interval")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $state.refreshInterval) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("Idle Polling")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $state.idlePollRate) {
                    ForEach(IdlePollRate.allCases) { rate in
                        Text(rate.title).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(idlePollCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help("Slows the poll while the popover is closed, when only the menu-bar icon reads it. Opening the popover refreshes immediately. Low-limit notifications fire from a poll, so a slower idle rate can delay them by that much.")
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("First Day of Week")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $state.firstDayOfWeek) {
                    ForEach(FirstDayOfWeek.allCases) { day in
                        Text(day.title).tag(day)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    // Spell out the resulting cadence — a bare multiplier leaves the user to do the
    // arithmetic against whichever refresh interval is selected above.
    private var idlePollCaption: String {
        guard state.idlePollRate != .off else {
            return "Polls at the same rate whether the popover is open or closed."
        }
        let seconds = Int(state.idleRefreshSeconds.rounded())
        let interval = seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds)s"
        return "Polls every \(interval) while the popover is closed."
    }

    private var providerOrderCard: some View {
        settingsCard(icon: "list.number", title: "Provider Order") {
            if enabledProviders.isEmpty {
                Label("No providers enabled", systemImage: "eye.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            } else {
                ForEach(enabledProviders, id: \.self) { provider in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        ProviderIcon(provider: provider, size: 24)
                        Text(providerName(provider))
                            .font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 12)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.secondary.opacity(0.08))
                    )
                    .opacity(draggedProvider == provider ? 0.5 : 1.0)
                    .onDrag {
                        draggedProvider = provider
                        return NSItemProvider(object: provider as NSString)
                    }
                    .onDrop(of: [.text], delegate: ProviderDropDelegate(
                        item: provider,
                        order: $state.providerOrder,
                        draggedItem: $draggedProvider
                    ))
                }
            }
        }
    }

    private var enabledProviders: [String] {
        state.providerOrder.filter(isProviderEnabled)
    }

    private func isProviderEnabled(_ provider: String) -> Bool {
        switch provider {
        case "claude": return state.claudeEnabled
        case "deepseek": return state.deepseekEnabled
        case "antigravity": return state.antigravityEnabled
        case "gemini": return state.geminiEnabled
        case "codex": return state.codexEnabled
        default: return false
        }
    }

    /// Live-reorders `order` as a dragged provider row passes over another row.
    /// Operates on the full provider order (not just the visible/enabled subset)
    /// so disabled providers keep their relative position, just shifted aside.
    private struct ProviderDropDelegate: DropDelegate {
        let item: String
        let order: Binding<[String]>
        let draggedItem: Binding<String?>

        func dropEntered(info: DropInfo) {
            guard let dragged = draggedItem.wrappedValue, dragged != item,
                  let fromIndex = order.wrappedValue.firstIndex(of: dragged),
                  let toIndex = order.wrappedValue.firstIndex(of: item),
                  fromIndex != toIndex else { return }
            withAnimation(.default) {
                order.wrappedValue.move(
                    fromOffsets: IndexSet(integer: fromIndex),
                    toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
                )
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            draggedItem.wrappedValue = nil
            return true
        }
    }

    /// A titled settings group rendered with the same card chrome as the
    /// provider cards: an accent-tinted icon, a title, a divider, then content.
    private func settingsCard<Content: View>(
        icon: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            Divider()
            content()
        }
        .settingsCardStyle()
    }

    private func settingToggle(_ title: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
    
    @ViewBuilder private var providersPane: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: SettingsLayout.cardSpacing) {
                providerColumn(parity: 0)
                providerColumn(parity: 1)
            }
            .frame(minWidth: 776, maxWidth: .infinity, alignment: .leading)

            VStack(spacing: SettingsLayout.cardSpacing) {
                ForEach(state.providerOrder, id: \.self) { provider in
                    providerCard(for: provider)
                }
            }
        }
    }

    private func providerColumn(parity: Int) -> some View {
        VStack(spacing: SettingsLayout.cardSpacing) {
            ForEach(Array(state.providerOrder.enumerated()), id: \.element) { index, provider in
                if index % 2 == parity {
                    providerCard(for: provider)
                }
            }
        }
        .frame(width: 380)
    }

    @ViewBuilder private func providerCard(for provider: String) -> some View {
        if provider == "claude" {
            claudeCard
        } else if provider == "deepseek" {
            deepseekCard
        } else if provider == "antigravity" {
            antigravityCard
        } else if provider == "gemini" {
            geminiCard
        } else if provider == "codex" {
            codexCard
        }
    }

    private var claudeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProviderIcon(provider: "claude")
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Anthropic API Integration")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Toggle("", isOn: $state.claudeEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            
            if state.claudeEnabled {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Menu Bar Displays")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $state.claudeWindow) {
                            ForEach(ClaudeWindow.allCases) { win in
                                Text(win.title).tag(win)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    
                    Toggle(isOn: $state.claudeSideBySide) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Side-by-side usage bars")
                                .font(.system(size: 12))
                            Text("Display Session and Week usage bars in the same row but different columns.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    
                    Toggle("Show usage graph", isOn: $state.claudeShowGraph)
                        .font(.system(size: 12))

                    Toggle("Show latest thread", isOn: $state.claudeShowLatestThread)
                        .font(.system(size: 12))

                    Toggle(isOn: $state.claudeShowFableUsage) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Fable 5 usage")
                                .font(.system(size: 12))
                            Text("Fable 5's own weekly limit, as reported by Anthropic's usage API. Hidden when your account has no Fable-specific limit.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Text("Displays your official Claude usage via your Claude Code access token, which is automatically fetched from your secure keychain or credentials file.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .settingsCardStyle()
    }
    
    private var deepseekCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProviderIcon(provider: "deepseek")
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("DeepSeek")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Platform API Balance & Billing")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Toggle("", isOn: $state.deepseekEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            
            if state.deepseekEnabled {
                Divider()
                
                VStack(alignment: .leading, spacing: 10) {
                    
                    Toggle("Show usage graph", isOn: $state.deepseekShowGraph)
                        .font(.system(size: 12))
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Key")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        SecureField("sk-...", text: $state.deepseekApiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit {
                                state.deepseekApiKey = state.deepseekApiKey
                                    .trimmingCharacters(in: .whitespaces)
                                onLiveChange()
                            }
                        Text("Your key is stored securely in the macOS Keychain and never leaves your computer.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    
                    Toggle(isOn: $state.deepseekShowTHB) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Balance in THB (฿)")
                                .font(.system(size: 12))
                            Text("Convert balance using live ECB reference rates.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .settingsCardStyle()
    }
    
    private var antigravityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProviderIcon(provider: "antigravity")
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Antigravity")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Local Language Server Quotas")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Toggle("", isOn: $state.antigravityEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            
            if state.antigravityEnabled {
                Divider()
                
                VStack(alignment: .leading, spacing: 10) {
                    
                    Toggle("Show usage graphs", isOn: $state.antigravityShowGraph)
                        .font(.system(size: 12))

                    Toggle("Show latest thread", isOn: $state.antigravityShowLatestThread)
                        .font(.system(size: 12))

                    Toggle(isOn: $state.antigravityFusedGraph) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Combine usage graphs")
                                .font(.system(size: 12))
                            Text("Show one fused 7-day graph (Gemini + Claude & GPT) instead of two.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    
                    Toggle(isOn: $state.antigravitySideBySide) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Side-by-side usage bars")
                                .font(.system(size: 12))
                            Text("Display Gemini and Claude/GPT usage bars in the same row but different columns.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    
                    Text("Monitors left model quota and automatic reset times by connecting to your local Antigravity Language Server instance.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .settingsCardStyle()
    }
    

    private var geminiCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProviderIcon(provider: "gemini")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Gemini")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Consumer Web Usage Limits")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $state.geminiEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if state.geminiEnabled {
                Divider()

                VStack(alignment: .leading, spacing: 10) {

                    Toggle(isOn: $state.geminiSideBySide) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Side-by-side usage bars")
                                .font(.system(size: 12))
                            Text("Display Session and Week usage bars in the same row but different columns.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Toggle("Show usage graph", isOn: $state.geminiShowGraph)
                        .font(.system(size: 12))

                    Text("Reads your Google session from Google Chrome to fetch the usage limits shown on gemini.google.com/usage. macOS will ask once for Keychain access to Chrome's encryption key.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .settingsCardStyle()
    }

    private var codexCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProviderIcon(provider: "codex")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Chat GPT")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Local Thread Token Usage")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $state.codexEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if state.codexEnabled {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $state.codexSideBySide) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Side-by-side usage bars")
                                .font(.system(size: 12))
                            Text("Display Today and Week usage bars in the same row but different columns.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Toggle("Show usage graph", isOn: $state.codexShowGraph)
                        .font(.system(size: 12))

                    Toggle("Show latest thread", isOn: $state.codexShowLatestThread)
                        .font(.system(size: 12))

                    Text("Reads local Chat GPT thread token totals from ~/.codex/state_5.sqlite to display usage data.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .settingsCardStyle()
    }

    private func providerName(_ id: String) -> String {
        switch id {
        case "claude": return "Claude"
        case "deepseek": return "DeepSeek"
        case "antigravity": return "Antigravity"
        case "gemini": return "Gemini"
        case "codex": return "Chat GPT"
        default: return id.capitalized
        }
    }

    private func providerColor(_ id: String) -> Color {
        switch id {
        case "claude": return Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
        case "deepseek": return Color(red: 0x4D / 255.0, green: 0x6B / 255.0, blue: 0xFE / 255.0)
        case "antigravity": return Color(red: 0x00 / 255.0, green: 0xB9 / 255.0, blue: 0x5C / 255.0)
        case "gemini": return Color(red: 0xF4 / 255.0, green: 0xB4 / 255.0, blue: 0x00 / 255.0)
        case "codex": return Color(red: 142 / 255.0, green: 142 / 255.0, blue: 147 / 255.0)
        default: return .secondary
        }
    }
}

// MARK: - SVG Drawing Utilities

let ClaudeSVGPath = "M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z"

// Gemini's four-point star (concave arc sides), viewBox 0 0 24 24.
let GeminiSVGPath = "M12 24A14.304 14.304 0 0 0 0 12 14.304 14.304 0 0 0 12 0a14.305 14.305 0 0 0 12 12 14.305 14.305 0 0 0-12 12"

let ChatGPTSVGPath = "M249.176 323.434V298.276C249.176 296.158 249.971 294.569 251.825 293.509L302.406 264.381C309.29 260.409 317.5 258.555 325.973 258.555C357.75 258.555 377.877 283.185 377.877 309.399C377.877 311.253 377.877 313.371 377.611 315.49L325.178 284.771C322.001 282.919 318.822 282.919 315.645 284.771L249.176 323.434ZM367.283 421.415V361.301C367.283 357.592 365.694 354.945 362.516 353.092L296.048 314.43L317.763 301.982C319.617 300.925 321.206 300.925 323.058 301.982L373.639 331.112C388.205 339.586 398.003 357.592 398.003 375.069C398.003 395.195 386.087 413.733 367.283 421.412V421.415ZM233.553 368.452L211.838 355.742C209.986 354.684 209.19 353.095 209.19 350.975V292.718C209.19 264.383 230.905 242.932 260.301 242.932C271.423 242.932 281.748 246.641 290.49 253.26L238.321 283.449C235.146 285.303 233.555 287.951 233.555 291.659V368.455L233.553 368.452ZM280.292 395.462L249.176 377.985V340.913L280.292 323.436L311.407 340.913V377.985L280.292 395.462ZM300.286 475.968C289.163 475.968 278.837 472.259 270.097 465.64L322.264 435.449C325.441 433.597 327.03 430.949 327.03 427.239V350.445L349.011 363.155C350.865 364.213 351.66 365.802 351.66 367.922V426.179C351.66 454.514 329.679 475.965 300.286 475.965V475.968ZM237.525 416.915L186.944 387.785C172.378 379.31 162.582 361.305 162.582 343.827C162.582 323.436 174.763 305.164 193.563 297.485V357.861C193.563 361.571 195.154 364.217 198.33 366.071L264.535 404.467L242.82 416.915C240.967 417.972 239.377 417.972 237.525 416.915ZM234.614 460.343C204.689 460.343 182.71 437.833 182.71 410.028C182.71 407.91 182.976 405.792 183.238 403.672L235.405 433.863C238.582 435.715 241.763 435.715 244.938 433.863L311.407 395.466V420.622C311.407 422.742 310.612 424.331 308.758 425.389L258.179 454.519C251.293 458.491 243.083 460.343 234.611 460.343H234.614ZM300.286 491.854C332.329 491.854 359.073 469.082 365.167 438.892C394.825 431.211 413.892 403.406 413.892 375.073C413.892 356.535 405.948 338.529 391.648 325.552C392.972 319.991 393.766 314.43 393.766 308.87C393.766 271.003 363.048 242.666 327.562 242.666C320.413 242.666 313.528 243.723 306.644 246.109C294.725 234.457 278.307 227.042 260.301 227.042C228.258 227.042 201.513 249.815 195.42 280.004C165.761 287.685 146.694 315.49 146.694 343.824C146.694 362.362 154.638 380.368 168.938 393.344C167.613 398.906 166.819 404.467 166.819 410.027C166.819 447.894 197.538 476.231 233.024 476.231C240.172 476.231 247.058 475.173 253.943 472.788C265.859 484.441 282.278 491.854 300.286 491.854Z"

let DeepSeekSVGPath = "M23.748 4.482c-.254-.124-.364.113-.512.234-.051.039-.094.09-.137.136-.372.397-.806.657-1.373.626-.829-.046-1.537.214-2.163.848-.133-.782-.575-1.248-1.247-1.548-.352-.156-.708-.311-.955-.65-.172-.241-.219-.51-.305-.774-.055-.16-.11-.323-.293-.35-.2-.031-.278.136-.356.276-.313.572-.434 1.202-.422 1.84.027 1.436.633 2.58 1.838 3.393.137.093.172.187.129.323-.082.28-.18.552-.266.833-.055.179-.137.217-.329.14a5.526 5.526 0 01-1.736-1.18c-.857-.828-1.631-1.742-2.597-2.458a11.365 11.365 0 00-.689-.471c-.985-.957.13-1.743.388-1.836.27-.098.093-.432-.779-.428-.872.004-1.67.295-2.687.684a3.055 3.055 0 01-.465.137 9.597 9.597 0 00-2.883-.102c-1.885.21-3.39 1.102-4.497 2.623C.082 8.606-.231 10.684.152 12.85c.403 2.284 1.569 4.175 3.36 5.653 1.858 1.533 3.997 2.284 6.438 2.14 1.482-.085 3.133-.284 4.994-1.86.47.234.962.327 1.78.397.63.059 1.236-.03 1.705-.128.735-.156.684-.837.419-.961-2.155-1.004-1.682-.595-2.113-.926 1.096-1.296 2.746-2.642 3.392-7.003.05-.347.007-.565 0-.845-.004-.17.035-.237.23-.256a4.173 4.173 0 001.545-.475c1.396-.763 1.96-2.015 2.093-3.517.02-.23-.004-.467-.247-.588zM11.581 18c-2.089-1.642-3.102-2.183-3.52-2.16-.392.024-.321.471-.235.763.09.288.207.486.371.739.114.167.192.416-.113.603-.673.416-1.842-.14-1.897-.167-1.361-.802-2.5-1.86-3.301-3.307-.774-1.393-1.224-2.887-1.298-4.482-.02-.386.093-.522.477-.592a4.696 4.696 0 011.529-.039c2.132.312 3.946 1.265 5.468 2.774.868.86 1.525 1.887 2.202 2.891.72 1.066 1.494 2.082 2.48 2.914.348.292.625.514.891.677-.802.09-2.14.11-3.054-.614zm1-6.44a.306.306 0 01.415-.287.302.302 0 01.2.288.306.306 0 01-.31.307.303.303 0 01-.304-.308zm3.11 1.596c-.2.081-.399.151-.59.16a1.245 1.245 0 01-.798-.254c-.274-.23-.47-.358-.552-.758a1.73 1.73 0 01.016-.588c.07-.327-.008-.537-.239-.727-.187-.156-.426-.199-.688-.199a.559.559 0 01-.254-.078c-.11-.054-.2-.19-.114-.358.028-.054.16-.186.192-.21.356-.202.767-.136 1.146.016.352.144.618.408 1.001.782.391.451.462.576.685.914.176.265.336.537.445.848.067.195-.019.354-.25.452z"

struct SVGPathShape: Shape {
    let d: String
    
    func path(in rect: CGRect) -> Path {
        let originalPath = parseSVGPath(d)
        let originalBounds = originalPath.boundingRect
        guard originalBounds.width > 0, originalBounds.height > 0 else { return originalPath }
        
        let scale = min(rect.width / originalBounds.width, rect.height / originalBounds.height)
        let dx = (rect.width - originalBounds.width * scale) / 2
        let dy = (rect.height - originalBounds.height * scale) / 2
        
        let transform = CGAffineTransform(translationX: dx, y: dy)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -originalBounds.minX, y: -originalBounds.minY)
        
        return originalPath.applying(transform)
    }
    
    private struct SVGPathScanner {
        let characters: [Character]
        var index = 0
        
        init(_ d: String) {
            self.characters = Array(d)
        }
        
        var isAtEnd: Bool {
            return index >= characters.count
        }
        
        mutating func skipWhitespaceAndCommas() {
            while index < characters.count {
                let c = characters[index]
                if c.isWhitespace || c == "," {
                    index += 1
                } else {
                    break
                }
            }
        }
        
        mutating func nextFlag() -> CGFloat? {
            skipWhitespaceAndCommas()
            guard index < characters.count else { return nil }
            let c = characters[index]
            if c == "0" || c == "1" {
                index += 1
                return c == "1" ? 1.0 : 0.0
            }
            return nil
        }
        
        mutating func nextNumber() -> CGFloat? {
            skipWhitespaceAndCommas()
            guard index < characters.count else { return nil }
            
            let start = index
            var hasDecimal = false
            var hasExponent = false
            
            if characters[index] == "-" || characters[index] == "+" {
                index += 1
            }
            
            while index < characters.count {
                let c = characters[index]
                if c.isNumber {
                    index += 1
                } else if c == "." && !hasDecimal && !hasExponent {
                    hasDecimal = true
                    index += 1
                } else if (c == "e" || c == "E") && !hasExponent {
                    hasExponent = true
                    index += 1
                    if index < characters.count && (characters[index] == "-" || characters[index] == "+") {
                        index += 1
                    }
                } else {
                    break
                }
            }
            
            guard index > start else { return nil }
            let substring = String(characters[start..<index])
            if let val = Double(substring) {
                return CGFloat(val)
            }
            return nil
        }
    }
    
    private func parseSVGPath(_ d: String) -> Path {
        var path = Path()
        var scanner = SVGPathScanner(d)
        var currentPoint = CGPoint.zero
        var lastCommand: Character? = nil
        
        while !scanner.isAtEnd {
            scanner.skipWhitespaceAndCommas()
            guard !scanner.isAtEnd else { break }
            
            var cmd: Character = " "
            let firstChar = scanner.characters[scanner.index]
            if firstChar.isLetter {
                cmd = firstChar
                scanner.index += 1
                lastCommand = cmd
            } else if let last = lastCommand {
                cmd = last
            } else {
                break
            }
            
            switch cmd {
            case "M":
                if let x = scanner.nextNumber(), let y = scanner.nextNumber() {
                    let p = CGPoint(x: x, y: y)
                    path.move(to: p)
                    currentPoint = p
                }
            case "m":
                if let dx = scanner.nextNumber(), let dy = scanner.nextNumber() {
                    currentPoint = CGPoint(x: currentPoint.x + dx, y: currentPoint.y + dy)
                    path.move(to: currentPoint)
                }
            case "L":
                if let x = scanner.nextNumber(), let y = scanner.nextNumber() {
                    let p = CGPoint(x: x, y: y)
                    path.addLine(to: p)
                    currentPoint = p
                }
            case "l":
                if let dx = scanner.nextNumber(), let dy = scanner.nextNumber() {
                    currentPoint = CGPoint(x: currentPoint.x + dx, y: currentPoint.y + dy)
                    path.addLine(to: currentPoint)
                }
            case "H":
                if let x = scanner.nextNumber() {
                    currentPoint = CGPoint(x: x, y: currentPoint.y)
                    path.addLine(to: currentPoint)
                }
            case "h":
                if let dx = scanner.nextNumber() {
                    currentPoint = CGPoint(x: currentPoint.x + dx, y: currentPoint.y)
                    path.addLine(to: currentPoint)
                }
            case "V":
                if let y = scanner.nextNumber() {
                    currentPoint = CGPoint(x: currentPoint.x, y: y)
                    path.addLine(to: currentPoint)
                }
            case "v":
                if let dy = scanner.nextNumber() {
                    currentPoint = CGPoint(x: currentPoint.x, y: currentPoint.y + dy)
                    path.addLine(to: currentPoint)
                }
            case "C":
                while let cp1x = scanner.nextNumber(), let cp1y = scanner.nextNumber(),
                      let cp2x = scanner.nextNumber(), let cp2y = scanner.nextNumber(),
                      let px = scanner.nextNumber(), let py = scanner.nextNumber() {
                    let cp1 = CGPoint(x: cp1x, y: cp1y)
                    let cp2 = CGPoint(x: cp2x, y: cp2y)
                    let p = CGPoint(x: px, y: py)
                    path.addCurve(to: p, control1: cp1, control2: cp2)
                    currentPoint = p
                }
            case "c":
                while let cp1x = scanner.nextNumber(), let cp1y = scanner.nextNumber(),
                      let cp2x = scanner.nextNumber(), let cp2y = scanner.nextNumber(),
                      let px = scanner.nextNumber(), let py = scanner.nextNumber() {
                    let cp1 = CGPoint(x: currentPoint.x + cp1x, y: currentPoint.y + cp1y)
                    let cp2 = CGPoint(x: currentPoint.x + cp2x, y: currentPoint.y + cp2y)
                    let p = CGPoint(x: currentPoint.x + px, y: currentPoint.y + py)
                    path.addCurve(to: p, control1: cp1, control2: cp2)
                    currentPoint = p
                }
            case "A", "a":
                while let rx = scanner.nextNumber(),
                      let ry = scanner.nextNumber(),
                      let xAxisRotation = scanner.nextNumber(),
                      let largeArcFlag = scanner.nextFlag(),
                      let sweepFlag = scanner.nextFlag(),
                      let x = scanner.nextNumber(),
                      let y = scanner.nextNumber() {
                    let p = CGPoint(x: x, y: y)
                    let endPoint = cmd == "A" ? p : CGPoint(x: currentPoint.x + p.x, y: currentPoint.y + p.y)
                    Self.addArc(to: &path,
                                from: currentPoint,
                                to: endPoint,
                                rx: rx,
                                ry: ry,
                                xAxisRotation: xAxisRotation,
                                largeArc: largeArcFlag != 0,
                                sweep: sweepFlag != 0)
                    currentPoint = endPoint
                }
            case "Z", "z":
                path.closeSubpath()
            default:
                scanner.index += 1
            }
        }
        return path
    }

    /// Appends an SVG elliptical arc to `path`, approximating it with cubic Bézier
    /// segments. Implements the endpoint-to-center conversion from the SVG spec
    /// (Appendix F.6) so that `rx`, `ry`, `xAxisRotation`, `largeArc`, and `sweep`
    /// all affect the rendered curve.
    private static func addArc(to path: inout Path,
                               from start: CGPoint,
                               to end: CGPoint,
                               rx: CGFloat,
                               ry: CGFloat,
                               xAxisRotation: CGFloat,
                               largeArc: Bool,
                               sweep: Bool) {
        // Coincident endpoints: nothing to draw (per spec F.6.2).
        guard start != end else { return }

        var rx = abs(rx)
        var ry = abs(ry)

        // A zero radius degenerates to a straight line (per spec F.6.2).
        guard rx != 0, ry != 0 else {
            path.addLine(to: end)
            return
        }

        let phi = xAxisRotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        // Step 1: midpoint in the rotated coordinate system.
        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1 =  cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        // Scale up radii that are too small to span the endpoints (per spec F.6.6).
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }

        // Step 2: center in the rotated coordinate system.
        let rxSq = rx * rx
        let rySq = ry * ry
        let numerator = max(0, rxSq * rySq - rxSq * y1 * y1 - rySq * x1 * x1)
        let denominator = rxSq * y1 * y1 + rySq * x1 * x1
        var coef = denominator == 0 ? 0 : sqrt(numerator / denominator)
        if largeArc == sweep { coef = -coef }
        let cx1 =  coef * rx * y1 / ry
        let cy1 = -coef * ry * x1 / rx

        // Step 3: center in the original coordinate system.
        let cx = cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2

        // Step 4: start angle and sweep angle.
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(max(-1, min(1, len == 0 ? 1 : dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var sweepAngle = angle((x1 - cx1) / rx, (y1 - cy1) / ry,
                               (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, sweepAngle > 0 {
            sweepAngle -= 2 * .pi
        } else if sweep, sweepAngle < 0 {
            sweepAngle += 2 * .pi
        }

        // Approximate with one cubic Bézier per <= 90° segment.
        let segments = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2))))
        let delta = sweepAngle / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(delta / 4)

        func point(_ angle: CGFloat) -> CGPoint {
            let ex = rx * cos(angle)
            let ey = ry * sin(angle)
            return CGPoint(x: cosPhi * ex - sinPhi * ey + cx,
                           y: sinPhi * ex + cosPhi * ey + cy)
        }
        func tangent(_ angle: CGFloat) -> CGVector {
            let ex = -rx * sin(angle)
            let ey =  ry * cos(angle)
            return CGVector(dx: cosPhi * ex - sinPhi * ey,
                            dy: sinPhi * ex + cosPhi * ey)
        }

        var theta = theta1
        for _ in 0..<segments {
            let nextTheta = theta + delta
            let p1 = point(theta)
            let p2 = point(nextTheta)
            let d1 = tangent(theta)
            let d2 = tangent(nextTheta)
            let control1 = CGPoint(x: p1.x + t * d1.dx, y: p1.y + t * d1.dy)
            let control2 = CGPoint(x: p2.x - t * d2.dx, y: p2.y - t * d2.dy)
            path.addCurve(to: p2, control1: control1, control2: control2)
            theta = nextTheta
        }
    }
}

struct ProviderIcon: View {
    let provider: String
    var size: CGFloat = 28
    
    private static let antigravityLogo: NSImage? = {
        let base64_1x = "iVBORw0KGgoAAAANSUhEUgAAABYAAAAWCAYAAADEtGw7AAAACXBIWXMAAAPoAAAD6AG1e1JrAAABFUlEQVR4nO2UsU4CQRRFzywGC0KNgnYQafgDO0z8Bhr8EQsNrdHEj7GhsKLARGgNBSS2hFDQkHUNZpJLskw2y85Kpzd5uTPv3bl5+3Z34B+eCAAjtnEQmIS9m/NGIL4G3oAh0HZquU2bwALYKOZA/TfmBfGzDNcKu350NJlhxGVgKrNvhV1/qBbXenV7JaMICBWRcpd5xlEQ92QSxmb8Jb53tF4YyGQEdIEbYKzca0yXaRyBuKWZzoBqrH4OfGokF86ZVByJ79RZR/tjBerc1m6dM3u7PQNWwEvCo27XfWAJnCZodmDEJeAdmAAnKcY1fYr2byymmQfiBvAEVJx8ktaaP2juqV37XDbel5HRyzAH1vJH8QNvPjVRxtmeAQAAAABJRU5ErkJggg=="
        let base64_2x = "iVBORw0KGgoAAAANSUhEUgAAACwAAAAsCAYAAAAehFoBAAAACXBIWXMAAAPoAAAD6AG1e1JrAAACPUlEQVR4nO2XvWsUYRCHn71NsIhFiE0EQ0ilGALRIoWQ0kqxkEBSGQsRPTAJ+IH5K2yshPQ2EtHKwiAIQkiRFIlBUNQ0gRQKQoTkvsLCjAzDedxddvdOeR8YXtjdmfd38/HeLgQCgUDgfyICYqBHLJZrXUnhL+KibhStgk4BD4Fl4CVwH+g3P6grUCFngW2gBlTEasAGMCTPdDzTKqAPWBOBB0BJ7FCuvQdOOJ+OkAxVwqIRW3N2KOu888kdzdQA8M20ghdckfUTcNL55opm6oYIKtcRW3Oip5xvR4btVROCS7I+d765iz0D/BQx1SYyvCtHX+5toSWdadC71qrmmSsuRq6Cn7mSN7KyrE/yFqylTM7Vj3UyXBFxar4t1k2MKM/+nTAiqmL1Bq9s7ms1xlysTNFSPjICbI9uAi/kfWLLZNf+oHsuVqZoGd+6/t0HbjkRPUAR+O2efZ1XhnWDcyLQ9ua03IudJdx0g/dDjsTM+1gFLLh3h6dyvdcJiCTLCUvO57aLmTp2sj+YodoBBt0z9aoyDOwZv5UGPqmgmbjs+vGuu9/I94HznWzCt200U29Mlt41uVlkzu5V47/sYqeG9uGsOXd/ARda2LAg6yU5Nfyw6h7HRje6KNOtfwCJ+FbLGct6x2Q5eSEadXsdW+wI8NUcY8U2xOJ8HhvRn4HTaQyhlmlOAn8BrrqN2yGW9TrwXWJfSyHuH5JPm/GUP9kL5hPrfJo9bIlSnug4q3NYhUb/QBICgUAgQHYcAQWt04kND889AAAAAElFTkSuQmCC"
        
        guard let data1 = Data(base64Encoded: base64_1x),
              let rep1 = NSBitmapImageRep(data: data1) else { return nil }
        
        let image = NSImage(size: NSSize(width: 22, height: 22))
        rep1.size = NSSize(width: 22, height: 22)
        image.addRepresentation(rep1)
        
        if let data2 = Data(base64Encoded: base64_2x),
           let rep2 = NSBitmapImageRep(data: data2) {
            rep2.size = NSSize(width: 22, height: 22)
            image.addRepresentation(rep2)
        }
        
        image.isTemplate = true
        return image
    }()

    var body: some View {
        switch provider {
        case "claude":
            ZStack {
                Circle()
                    .fill(Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0).opacity(0.12))
                    .frame(width: size, height: size)
                SVGPathShape(d: ClaudeSVGPath)
                    .fill(Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0))
                    .frame(width: size * 0.55, height: size * 0.55)
            }
        case "deepseek":
            ZStack {
                Circle()
                    .fill(Color(red: 0x4D / 255.0, green: 0x6B / 255.0, blue: 0xFE / 255.0).opacity(0.12))
                    .frame(width: size, height: size)
                SVGPathShape(d: DeepSeekSVGPath)
                    .fill(Color(red: 0x4D / 255.0, green: 0x6B / 255.0, blue: 0xFE / 255.0))
                    .frame(width: size * 0.55, height: size * 0.55)
            }
        case "antigravity":
            ZStack {
                Circle()
                    .fill(Color(red: 0x00 / 255.0, green: 0xB9 / 255.0, blue: 0x5C / 255.0).opacity(0.12))
                    .frame(width: size, height: size)
                if let logo = Self.antigravityLogo {
                    Image(nsImage: logo)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color(red: 0x00 / 255.0, green: 0xB9 / 255.0, blue: 0x5C / 255.0))
                        .frame(width: size * 0.55, height: size * 0.55)
                } else {
                    Image(systemName: "infinity")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(Color(red: 0x00 / 255.0, green: 0xB9 / 255.0, blue: 0x5C / 255.0))
                }
            }
        case "gemini":
            ZStack {
                Circle()
                    .fill(Color(red: 0xF4 / 255.0, green: 0xB4 / 255.0, blue: 0x00 / 255.0).opacity(0.12))
                    .frame(width: size, height: size)
                SVGPathShape(d: GeminiSVGPath)
                    .fill(Color(red: 0xF4 / 255.0, green: 0xB4 / 255.0, blue: 0x00 / 255.0))
                    .frame(width: size * 0.55, height: size * 0.55)
            }
        case "codex":
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: size, height: size)
                SVGPathShape(d: ChatGPTSVGPath)
                    .fill(Color.primary)
                    .frame(width: size * 0.55, height: size * 0.55)
            }
        default:
            EmptyView()
        }
    }
}

// Shared card chrome for the settings window: rounded, softly filled, and
// hairline-stroked so provider cards and general setting groups read alike.
private extension View {
    func settingsCardStyle() -> some View {
        self
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
    }
}

extension View {
    func applyLiveChangeObservers(state: AppState, onLiveChange: @escaping () -> Void) -> some View {
        self
            .applyClaudeObservers(state: state, onLiveChange: onLiveChange)
            .applyDeepSeekObservers(state: state, onLiveChange: onLiveChange)
            .applyAntigravityObservers(state: state, onLiveChange: onLiveChange)
            .applyGeminiObservers(state: state, onLiveChange: onLiveChange)
            .applyCodexObservers(state: state, onLiveChange: onLiveChange)
            .applyGeneralObservers(state: state, onLiveChange: onLiveChange)
    }

    private func applyClaudeObservers(state: AppState, onLiveChange: @escaping () -> Void) -> some View {
        self
            .onChange(of: state.claudeEnabled) { onLiveChange() }
            .onChange(of: state.claudeWindow) { onLiveChange() }
            .onChange(of: state.claudeSideBySide) { onLiveChange() }
            .onChange(of: state.claudeShowGraph) { onLiveChange() }
            .onChange(of: state.claudeShowLatestThread) { onLiveChange() }
            .onChange(of: state.claudeShowFableUsage) { onLiveChange() }
    }

    private func applyDeepSeekObservers(state: AppState, onLiveChange: @escaping () -> Void) -> some View {
        self
            .onChange(of: state.deepseekEnabled) { onLiveChange() }
            .onChange(of: state.deepseekShowTHB) { onLiveChange() }
            .onChange(of: state.deepseekShowGraph) { onLiveChange() }
    }

    private func applyAntigravityObservers(state: AppState, onLiveChange: @escaping () -> Void) -> some View {
        self
            .onChange(of: state.antigravityEnabled) { onLiveChange() }
            .onChange(of: state.antigravityFusedGraph) { onLiveChange() }
            .onChange(of: state.antigravitySideBySide) { onLiveChange() }
            .onChange(of: state.antigravityShowGraph) { onLiveChange() }
            .onChange(of: state.antigravityShowLatestThread) { onLiveChange() }
    }

    private func applyGeminiObservers(state: AppState, onLiveChange: @escaping () -> Void) -> some View {
        self
            .onChange(of: state.geminiEnabled) { onLiveChange() }
            .onChange(of: state.geminiSideBySide) { onLiveChange() }
            .onChange(of: state.geminiShowGraph) { onLiveChange() }
    }

    private func applyCodexObservers(state: AppState, onLiveChange: @escaping () -> Void) -> some View {
        self
            .onChange(of: state.codexEnabled) { onLiveChange() }
            .onChange(of: state.codexShowGraph) { onLiveChange() }
            .onChange(of: state.codexShowLatestThread) { onLiveChange() }
            .onChange(of: state.codexSideBySide) { onLiveChange() }
    }

    private func applyGeneralObservers(state: AppState, onLiveChange: @escaping () -> Void) -> some View {
        self
            .onChange(of: state.showRemaining) { onLiveChange() }
            .onChange(of: state.showReductionIndicator) { onLiveChange() }
            .onChange(of: state.limitResetNotificationsEnabled) { onLiveChange() }
            .onChange(of: state.limitResetLeadMinutes) { onLiveChange() }
            .onChange(of: state.lowLimitNotificationsEnabled) { onLiveChange() }
            .onChange(of: state.lowLimitThresholdPercent) { onLiveChange() }
            .onChange(of: state.useSeparateGraphScale) { onLiveChange() }
            .onChange(of: state.providerOrder) { onLiveChange() }
            .onChange(of: state.refreshInterval) { onLiveChange() }
            .onChange(of: state.idlePollRate) { onLiveChange() }
            .onChange(of: state.firstDayOfWeek) { onLiveChange() }
    }
}
