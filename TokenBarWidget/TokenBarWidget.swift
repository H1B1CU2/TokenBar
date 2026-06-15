import WidgetKit
import SwiftUI

struct WidgetData: Codable {
    var claudeEnabled: Bool
    var claudeSessionPercent: Double
    var claudeWeekPercent: Double
    var claudeWindow: String
    
    var deepseekEnabled: Bool
    var deepseekDisplayBalance: Double?
    var deepseekDisplayCurrency: String
    
    var antigravityEnabled: Bool
    var antigravityGemini5hPercent: Double
    var antigravityGeminiWeeklyPercent: Double
    var antigravityClaudeGpt5hPercent: Double
    var antigravityClaudeGptWeeklyPercent: Double
    
    var showRemaining: Bool
    var lastUpdated: Date
}

extension WidgetData {
    static var preview: WidgetData {
        WidgetData(
            claudeEnabled: true,
            claudeSessionPercent: 42.0,
            claudeWeekPercent: 18.0,
            claudeWindow: "session",
            deepseekEnabled: true,
            deepseekDisplayBalance: 12.45,
            deepseekDisplayCurrency: "USD",
            antigravityEnabled: true,
            antigravityGemini5hPercent: 85.0,
            antigravityGeminiWeeklyPercent: 70.0,
            antigravityClaudeGpt5hPercent: 90.0,
            antigravityClaudeGptWeeklyPercent: 75.0,
            showRemaining: false,
            lastUpdated: Date()
        )
    }
}

enum CurrencyFormat {
    static func symbol(_ code: String) -> String {
        switch code {
        case "CNY": return "¥"
        case "THB": return "฿"
        default:    return "$"
        }
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), data: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> ()) {
        let entry = SimpleEntry(date: Date(), data: readData() ?? .preview)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        let entry = SimpleEntry(date: Date(), data: readData() ?? .preview)
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
    
    private func readData() -> WidgetData? {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("widget_data.json") else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetData.self, from: data)
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let data: WidgetData
}

struct ProgressDonut: View {
    let fraction: Double
    let color: Color
    let size: CGFloat
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.25), lineWidth: size * 0.15)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 0.97)))
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

extension Color {
    static let claudeAccent = Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    static let deepseekAccent = Color(red: 0x4D / 255.0, green: 0x6B / 255.0, blue: 0xFE / 255.0)
    static let antigravityGreen = Color(red: 0x00 / 255.0, green: 0xB9 / 255.0, blue: 0x5C / 255.0)
}

struct SmallWidgetView: View {
    let data: WidgetData
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("TokenBar")
                    .font(.system(size: 11, weight: .bold))
                Spacer()
                Text("🪙")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.primary)
            
            VStack(alignment: .leading, spacing: 5) {
                if data.claudeEnabled {
                    HStack(spacing: 6) {
                        let isSession = data.claudeWindow == "session"
                        let val = isSession ? data.claudeSessionPercent : data.claudeWeekPercent
                        let fraction = min(1.0, max(0.0, val / 100.0))
                        let displayFraction = data.showRemaining ? (1.0 - fraction) : fraction
                        
                        ProgressDonut(fraction: displayFraction, color: .claudeAccent, size: 14)
                        
                        let displayPercent = data.showRemaining ? (100.0 - val) : val
                        let formattedStr = displayPercent < 1 && displayPercent > 0
                            ? String(format: "%.1f%%", displayPercent)
                            : "\(Int(displayPercent.rounded()))%"
                        
                        Text("CLD: \(formattedStr)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    }
                }
                
                if data.deepseekEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "dollarsign.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.deepseekAccent)
                            .frame(width: 14, height: 14)
                        
                        if let bal = data.deepseekDisplayBalance {
                            let sym = CurrencyFormat.symbol(data.deepseekDisplayCurrency)
                            Text("\(sym)\(String(format: "%.2f", bal))")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        } else {
                            Text("DPSK: —")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        }
                    }
                }
                
                if data.antigravityEnabled {
                    HStack(spacing: 6) {
                        let lowestRemaining = min(data.antigravityGeminiWeeklyPercent, data.antigravityGemini5hPercent)
                        let remaining = min(1.0, max(0.0, lowestRemaining / 100.0))
                        let displayFraction = data.showRemaining ? remaining : (1.0 - remaining)
                        
                        ProgressDonut(fraction: displayFraction, color: .antigravityGreen, size: 14)
                        
                        let displayPercent = data.showRemaining ? lowestRemaining : (100.0 - lowestRemaining)
                        let formattedStr = displayPercent < 1 && displayPercent > 0
                            ? String(format: "%.1f%%", displayPercent)
                            : "\(Int(displayPercent.rounded()))%"
                        
                        Text("AGY: \(formattedStr)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    }
                }
                
                if !data.claudeEnabled && !data.deepseekEnabled && !data.antigravityEnabled {
                    Text("No providers enabled")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct MediumWidgetView: View {
    let data: WidgetData
    
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TokenBar 🪙")
                    .font(.system(size: 13, weight: .bold))
                
                Text("Status Dashboard")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Text("Updated")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(data.lastUpdated.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 90, alignment: .leading)
            
            Divider()
            
            HStack(spacing: 8) {
                if data.claudeEnabled {
                    VStack(alignment: .center, spacing: 6) {
                        Text("CLAUDE")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                        
                        let isSession = data.claudeWindow == "session"
                        let val = isSession ? data.claudeSessionPercent : data.claudeWeekPercent
                        let fraction = min(1.0, max(0.0, val / 100.0))
                        let displayFraction = data.showRemaining ? (1.0 - fraction) : fraction
                        
                        ProgressDonut(fraction: displayFraction, color: .claudeAccent, size: 28)
                        
                        let displayPercent = data.showRemaining ? (100.0 - val) : val
                        let formattedStr = displayPercent < 1 && displayPercent > 0
                            ? String(format: "%.1f%%", displayPercent)
                            : "\(Int(displayPercent.rounded()))%"
                        
                        Text(formattedStr)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        Text(data.showRemaining ? "remain" : "used")
                            .font(.system(size: 7))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
                
                if data.deepseekEnabled {
                    VStack(alignment: .center, spacing: 6) {
                        Text("DEEPSEEK")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                        
                        Image(systemName: "dollarsign.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.deepseekAccent)
                            .frame(height: 28)
                        
                        if let bal = data.deepseekDisplayBalance {
                            let sym = CurrencyFormat.symbol(data.deepseekDisplayCurrency)
                            Text("\(sym)\(String(format: "%.2f", bal))")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        } else {
                            Text("—")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        }
                        
                        Text(data.deepseekDisplayCurrency)
                            .font(.system(size: 7))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
                
                if data.antigravityEnabled {
                    VStack(alignment: .center, spacing: 6) {
                        Text("ANTIGRAV")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                        
                        let lowestRemaining = min(data.antigravityGeminiWeeklyPercent, data.antigravityGemini5hPercent)
                        let remaining = min(1.0, max(0.0, lowestRemaining / 100.0))
                        let displayFraction = data.showRemaining ? remaining : (1.0 - remaining)
                        
                        ProgressDonut(fraction: displayFraction, color: .antigravityGreen, size: 28)
                        
                        let displayPercent = data.showRemaining ? lowestRemaining : (100.0 - lowestRemaining)
                        let formattedStr = displayPercent < 1 && displayPercent > 0
                            ? String(format: "%.1f%%", displayPercent)
                            : "\(Int(displayPercent.rounded()))%"
                        
                        Text(formattedStr)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        Text(data.showRemaining ? "remain" : "used")
                            .font(.system(size: 7))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct TokenBarWidgetEntryView : View {
    var entry: Provider.Entry

    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                SmallWidgetView(data: entry.data)
            default:
                MediumWidgetView(data: entry.data)
            }
        }
        .padding(12)
        .containerBackground(for: .widget) {
            Color(NSColor.windowBackgroundColor)
        }
    }
}

struct TokenBarWidget: Widget {
    let kind: String = "TokenBarWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            TokenBarWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("TokenBar Usage")
        .description("Track your AI provider token usage and API balances.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct TokenBarWidgetBundle: WidgetBundle {
    var body: some Widget {
        TokenBarWidget()
    }
}
