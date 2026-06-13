import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case claude
    case deepseek
    case antigravity
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .general: return "General"
        case .claude: return "Claude"
        case .deepseek: return "DeepSeek"
        case .antigravity: return "Antigravity"
        }
    }
    
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .claude: return "sparkles"
        case .deepseek: return "dollarsign.circle"
        case .antigravity: return "infinity"
        }
    }
}

struct SettingsView: View {
    @State var state: AppState
    let onLiveChange: () -> Void
    
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    sidebarRow(for: tab)
                }
                Spacer()
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 140)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Detail pane
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailTitleView(for: selectedTab)
                    detailPaneView(for: selectedTab)
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 520, height: 365)
        // Live-apply: any change redraws the menu bar icon immediately (and refetches).
        .onChange(of: state.claudeEnabled) { onLiveChange() }
        .onChange(of: state.deepseekEnabled) { onLiveChange() }
        .onChange(of: state.antigravityEnabled) { onLiveChange() }
        .onChange(of: state.claudeInMenuBar) { onLiveChange() }
        .onChange(of: state.deepseekInMenuBar) { onLiveChange() }
        .onChange(of: state.antigravityGeminiInMenuBar) { onLiveChange() }
        .onChange(of: state.antigravityClaudeGptInMenuBar) { onLiveChange() }
        .onChange(of: state.antigravityFusedGraph) { onLiveChange() }
        .onChange(of: state.claudeWindow) { onLiveChange() }
        .onChange(of: state.showRemaining) { onLiveChange() }
        .onChange(of: state.useSeparateGraphScale) { onLiveChange() }
        .onChange(of: state.deepseekShowTHB) { onLiveChange() }
        .onChange(of: state.providerOrder) { onLiveChange() }
        .onChange(of: state.refreshInterval) { onLiveChange() }
        .onChange(of: state.firstDayOfWeek) { onLiveChange() }
    }
    
    private func sidebarRow(for tab: SettingsTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 8) {
                if tab == .general {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                } else {
                    Circle()
                        .fill(tabIconColor(for: tab))
                        .frame(width: 7, height: 7)
                        .frame(width: 18)
                }
                Text(tab.title)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
    }
    
    private func tabIconColor(for tab: SettingsTab) -> Color {
        switch tab {
        case .general: return .secondary
        case .claude: return Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
        case .deepseek: return Color(red: 0x4D / 255.0, green: 0x6B / 255.0, blue: 0xFE / 255.0)
        case .antigravity: return Color(red: 0x00 / 255.0, green: 0xB9 / 255.0, blue: 0x5C / 255.0)
        }
    }
    
    @ViewBuilder private func detailTitleView(for tab: SettingsTab) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tab.title)
                .font(.title2.bold())
            Divider()
        }
    }
    
    @ViewBuilder private func detailPaneView(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            generalPane
        case .claude:
            claudePane
        case .deepseek:
            deepseekPane
        case .antigravity:
            antigravityPane
        }
    }
    
    @ViewBuilder private var generalPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $state.showRemaining) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remaining Mode")
                        .font(.system(size: 13, weight: .medium))
                    Text("Show remaining usage/quota instead of used.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Divider()
            
            Toggle(isOn: $state.useSeparateGraphScale) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Separate Graph Scales")
                        .font(.system(size: 13, weight: .medium))
                    Text("Scale each provider's usage graph to its own peak instead of sharing a global maximum.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Refresh Interval")
                    .font(.system(size: 13, weight: .semibold))
                Picker("", selection: $state.refreshInterval) {
                    ForEach(RefreshInterval.allCases) { iv in
                        Text(iv.title).tag(iv)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("First Day of Week")
                    .font(.system(size: 13, weight: .semibold))
                Picker("", selection: $state.firstDayOfWeek) {
                    ForEach(FirstDayOfWeek.allCases) { day in
                        Text(day.title).tag(day)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Provider Order")
                    .font(.system(size: 13, weight: .semibold))
                
                ForEach(state.providerOrder.indices, id: \.self) { idx in
                    HStack {
                        Circle()
                            .fill(providerColor(state.providerOrder[idx]))
                            .frame(width: 6, height: 6)
                        Text(providerName(state.providerOrder[idx]))
                            .font(.system(size: 12))
                        Spacer()
                        Button(action: {
                            state.moveProviderUp(at: idx)
                        }) {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(idx == 0)
                        
                        Button(action: {
                            state.moveProviderDown(at: idx)
                        }) {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(idx == state.providerOrder.count - 1)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
                    .cornerRadius(6)
                }
            }
        }
    }
    
    @ViewBuilder private var claudePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $state.claudeEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Claude Integration")
                        .font(.system(size: 13, weight: .medium))
                    Text("Monitor your official Anthropic API usage.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            if state.claudeEnabled {
                Divider()
                
                Toggle(isOn: $state.claudeInMenuBar) {
                    Text("Show in menu bar").font(.system(size: 12))
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("Menu Bar Displays")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $state.claudeWindow) {
                        ForEach(ClaudeWindow.allCases) { win in
                            Text(win.title).tag(win)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                
                Text("Displays your official Claude usage via your Claude Code access token, which is automatically fetched from your secure keychain or credentials file.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    @ViewBuilder private var deepseekPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $state.deepseekEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable DeepSeek Integration")
                        .font(.system(size: 13, weight: .medium))
                    Text("Track your platform API balance.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            if state.deepseekEnabled {
                Divider()
                
                Toggle(isOn: $state.deepseekInMenuBar) {
                    Text("Show in menu bar").font(.system(size: 12))
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("sk-...", text: $state.deepseekApiKey)
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
                
                Divider()
                
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
    
    @ViewBuilder private var antigravityPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $state.antigravityEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Antigravity Integration")
                        .font(.system(size: 13, weight: .medium))
                    Text("Track local language server usage.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            if state.antigravityEnabled {
                Divider()
                
                Toggle(isOn: $state.antigravityGeminiInMenuBar) {
                    Text("Show Gemini Models (AGY) in menu bar").font(.system(size: 12))
                }
                
                Toggle(isOn: $state.antigravityClaudeGptInMenuBar) {
                    Text("Show Claude & GPT Models (CG) in menu bar").font(.system(size: 12))
                }

                Divider()

                Toggle(isOn: $state.antigravityFusedGraph) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Combine usage graphs")
                            .font(.system(size: 12))
                        Text("Show one fused 7-day graph (Gemini + Claude & GPT) instead of two.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text("Monitors remaining model quota and automatic reset times by connecting to your local Antigravity Language Server instance.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    private func providerName(_ id: String) -> String {
        switch id {
        case "claude": return "Claude"
        case "deepseek": return "DeepSeek"
        case "antigravity": return "Antigravity"
        default: return id.capitalized
        }
    }
    
    private func providerColor(_ id: String) -> Color {
        switch id {
        case "claude": return Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
        case "deepseek": return Color(red: 0x4D / 255.0, green: 0x6B / 255.0, blue: 0xFE / 255.0)
        case "antigravity": return Color(red: 0x00 / 255.0, green: 0xB9 / 255.0, blue: 0x5C / 255.0)
        default: return .secondary
        }
    }
}
