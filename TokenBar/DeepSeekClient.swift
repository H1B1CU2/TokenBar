import Foundation

struct DeepSeekBalance {
    let totalBalance: Double
    let grantedBalance: Double
    let toppedUpBalance: Double
    let currency: String
    let isAvailable: Bool
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
            toppedUpBalance: toppedUp,
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
