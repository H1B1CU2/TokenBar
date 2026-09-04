import SwiftUI

struct UsageGraphView: View {
    static let cardCornerRadius: CGFloat = 8

    let history: [String: Double]
    let history2: [String: Double]?
    let tintColor: Color
    let tintColor2: Color?
    let unitFormatter: (Double) -> String
    let yAxisMax: Double
    let showTotal: Bool
    let firstDayOfWeek: FirstDayOfWeek
    /// Extra bar height handed down by the two-column layout so the shorter column
    /// can be grown to match the taller one. Zero everywhere else.
    let extraHeight: CGFloat

    private static let baseBarHeight: CGFloat = 50
    
    @State private var hoveredIndex: Int? = nil
    @State private var animate = false
    
    init(
        history: [String: Double],
        history2: [String: Double]? = nil,
        tintColor: Color,
        tintColor2: Color? = nil,
        unitFormatter: @escaping (Double) -> String,
        yAxisMax: Double,
        showTotal: Bool = true,
        firstDayOfWeek: FirstDayOfWeek = .sunday,
        extraHeight: CGFloat = 0
    ) {
        self.history = history
        self.history2 = history2
        self.tintColor = tintColor
        self.tintColor2 = tintColor2
        self.unitFormatter = unitFormatter
        self.yAxisMax = yAxisMax
        self.showTotal = showTotal
        self.firstDayOfWeek = firstDayOfWeek
        self.extraHeight = extraHeight
    }
    
    private var last7DaysData: [(dateString: String, value: Double)] {
        let calendar = Calendar.current
        let now = Date()
        
        // Find the start of the current week (Sunday or Monday)
        let currentWeekday = calendar.component(.weekday, from: now)
        let daysToSubtract: Int
        switch firstDayOfWeek {
        case .sunday:
            daysToSubtract = currentWeekday - 1
        case .monday:
            daysToSubtract = (currentWeekday + 5) % 7
        }
        
        guard let startOfWeek = calendar.date(byAdding: .day, value: -daysToSubtract, to: now) else { return [] }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        
        return (0..<7).compactMap { dayOffset -> (String, Double)? in
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: startOfWeek) else { return nil }
            let key = formatter.string(from: date)
            return (key, history[key] ?? 0.0)
        }
    }
    
    private var maxValue: Double {
        let maxInHistory = last7DaysData.map { item -> Double in
            let val1 = item.value
            let val2 = history2?[item.dateString] ?? 0.0
            return val1 + val2
        }.max() ?? 0.0
        let effectiveMax = max(yAxisMax, maxInHistory > 0 ? maxInHistory : yAxisMax)
        // Add headroom so the tallest bar never reaches the very top edge
        // (leaves room for the hover scale-up and avoids a "cut off" look).
        return effectiveMax * 1.15
    }
    
    private var todayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("7-Day Usage")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let hoveredIndex, hoveredIndex < last7DaysData.count {
                    let item = last7DaysData[hoveredIndex]
                    let val1 = item.value
                    let val2 = history2?[item.dateString] ?? 0.0
                    Text(unitFormatter(val1 + val2))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(tintColor)
                } else if showTotal {
                    let total = last7DaysData.reduce(0.0) { sum, item in
                        sum + item.value + (history2?[item.dateString] ?? 0.0)
                    }
                    Text(unitFormatter(total))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(0..<last7DaysData.count, id: \.self) { index in
                    let item = last7DaysData[index]
                    let val1 = item.value
                    let val2 = history2?[item.dateString] ?? 0.0
                    let fraction1 = maxValue > 0 ? (val1 / maxValue) : 0.0
                    let fraction2 = maxValue > 0 ? (val2 / maxValue) : 0.0
                    let isToday = item.dateString == todayString
                    
                    VStack(spacing: 4) {
                        GeometryReader { geo in
                            VStack(spacing: 0) {
                                if let tintColor2, val2 > 0 {
                                    Rectangle()
                                        .fill(tintColor2)
                                        .frame(width: 12)
                                        .frame(height: animate ? CGFloat(fraction2) * geo.size.height : 0)
                                }
                                if val1 > 0 {
                                    Rectangle()
                                        .fill(tintColor)
                                        .frame(width: 12)
                                        .frame(height: animate ? CGFloat(fraction1) * geo.size.height : 0)
                                }
                            }
                            .frame(width: 12)
                            .cornerRadius(2)
                            .scaleEffect(hoveredIndex == index ? 1.08 : 1.0, anchor: .bottom)
                            .shadow(color: (hoveredIndex == index ? (val1 > 0 ? tintColor : (tintColor2 ?? tintColor)) : Color.clear).opacity(0.3), radius: 3, x: 0, y: -1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        }
                        .frame(height: Self.baseBarHeight + max(0, extraHeight))
                        
                        Text(weekdayLabel(item.dateString))
                            .font(.system(size: 9, weight: (hoveredIndex == index || isToday) ? .bold : .medium))
                            .foregroundStyle(hoveredIndex == index ? tintColor : (isToday ? .primary : .secondary))
                    }
                    .frame(width: 24)
                    .contentShape(Rectangle())
                    .onHover { isHovering in
                        withAnimation(.easeOut(duration: 0.15)) {
                            hoveredIndex = isHovering ? index : nil
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .padding(.top, 10)
        }
        .padding(8)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(Self.cardCornerRadius)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                animate = true
            }
        }
    }
    
    private func weekdayLabel(_ dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return "" }
        
        let calendar = Calendar.current
        let weekdayNumber = calendar.component(.weekday, from: date)
        
        let isThai = Locale.current.identifier.hasPrefix("th")
        
        if isThai {
            switch weekdayNumber {
            case 1: return "อา."
            case 2: return "จ."
            case 3: return "อ."
            case 4: return "พ."
            case 5: return "พฤ."
            case 6: return "ศ."
            case 7: return "ส."
            default: return ""
            }
        } else {
            switch weekdayNumber {
            case 1: return "Sun"
            case 2: return "Mon"
            case 3: return "Tue"
            case 4: return "Wed"
            case 5: return "Thu"
            case 6: return "Fri"
            case 7: return "Sat"
            default: return ""
            }
        }
    }
    
    private func formatDateLabel(_ dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return dateString }
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "MMM d"
        return displayFormatter.string(from: date)
    }
}
