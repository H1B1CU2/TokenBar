import Foundation

struct DeepSeekBalance {
    let totalBalance: Double
    let grantedBalance: Double
    let balance: Double
    let currency: String
    let isAvailable: Bool
}

enum DeepSeekBillingPeriod: String {
    case peak = "Peak"
    case offPeak = "Off-Peak"

    var detail: String {
        switch self {
        case .peak: return "Peak rates"
        case .offPeak: return "50% lower rates"
        }
    }
}

struct DeepSeekTokenRates {
    let cacheHitInput: Double
    let cacheMissInput: Double
    let output: Double
}

struct DeepSeekBillingStatus {
    let period: DeepSeekBillingPeriod
    let nextTransition: Date
}

// Official V4 API pricing introduced on August 16, 2026. DeepSeek defines peak
// windows in UTC, so the classification must not depend on the Mac's time zone.
enum DeepSeekPricing {
    enum Model {
        case flash
        case pro
    }

    static func rates(for model: Model, period: DeepSeekBillingPeriod) -> DeepSeekTokenRates {
        switch (model, period) {
        case (.flash, .offPeak):
            return DeepSeekTokenRates(cacheHitInput: 0.007, cacheMissInput: 0.22, output: 0.66)
        case (.flash, .peak):
            return DeepSeekTokenRates(cacheHitInput: 0.014, cacheMissInput: 0.44, output: 1.32)
        case (.pro, .offPeak):
            return DeepSeekTokenRates(cacheHitInput: 0.022, cacheMissInput: 0.66, output: 1.98)
        case (.pro, .peak):
            return DeepSeekTokenRates(cacheHitInput: 0.044, cacheMissInput: 1.32, output: 3.96)
        }
    }

    static func status(at date: Date = Date()) -> DeepSeekBillingStatus {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let components = calendar.dateComponents([.weekday, .hour], from: date)
        let weekday = components.weekday ?? 1
        let hour = components.hour ?? 0
        let isWeekday = (2...6).contains(weekday)
        let isPeakHour = (1..<4).contains(hour) || (6..<10).contains(hour)
        let period: DeepSeekBillingPeriod = isWeekday && isPeakHour ? .peak : .offPeak

        return DeepSeekBillingStatus(
            period: period,
            nextTransition: nextTransition(after: date, calendar: calendar)
        )
    }

    private static func nextTransition(after date: Date, calendar: Calendar) -> Date {
        let startOfToday = calendar.startOfDay(for: date)
        let transitionHours = [1, 4, 6, 10]

        // Eight days covers the longest gap: Friday's last peak window to Monday's first.
        for dayOffset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday),
                  let weekday = calendar.dateComponents([.weekday], from: day).weekday,
                  (2...6).contains(weekday)
            else { continue }

            for hour in transitionHours {
                guard let candidate = calendar.date(byAdding: .hour, value: hour, to: day) else {
                    continue
                }
                if candidate > date { return candidate }
            }
        }

        // The loop always finds a weekday boundary, but keep the status usable if
        // Calendar ever fails to construct one.
        return date.addingTimeInterval(24 * 60 * 60)
    }
}

enum DeepSeekClient {
    static func fetchBalance(apiKey: String) async -> DeepSeekBalance? {
        guard !apiKey.isEmpty,
              let url = URL(string: "https://api.deepseek.com/user/balance")
        else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = json["balance_infos"] as? [[String: Any]],
              let first = infos.first
        else { return nil }

        let currency = first["currency"] as? String ?? "USD"
        let total = Double(first["total_balance"] as? String ?? "0") ?? 0
        let granted = Double(first["granted_balance"] as? String ?? "0") ?? 0
        let toppedUp = Double(first["topped_up_balance"] as? String ?? "0") ?? 0
        let available = json["is_available"] as? Bool ?? true

        return DeepSeekBalance(
            totalBalance: total,
            grantedBalance: granted,
            balance: toppedUp,
            currency: currency,
            isAvailable: available
        )
    }
}

// Live currency conversion via frankfurter.app (ECB reference rates — free, no key).
enum FXClient {
    // Returns THB per 1 unit of `from` currency, or nil if the lookup fails.
    static func thbRate(from: String) async -> Double? {
        if from == "THB" { return 1 }
        guard let url = URL(string: "https://api.frankfurter.app/latest?from=\(from)&to=THB")
        else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = json["rates"] as? [String: Any],
              let thb = rates["THB"] as? Double
        else { return nil }

        return thb
    }
}

// Currency symbol for the balances TokenBar displays.
enum CurrencyFormat {
    static func symbol(_ code: String) -> String {
        switch code {
        case "CNY": return "¥"
        case "THB": return "฿"
        default:    return "$"
        }
    }
}
