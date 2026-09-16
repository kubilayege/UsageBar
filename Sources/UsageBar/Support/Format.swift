import Foundation

enum Format {
    static func countdown(to date: Date?, from now: Date = Date()) -> String? {
        guard let date else { return nil }
        let s = max(0, date.timeIntervalSince(now))
        if s < 1 { return "now" }
        let total = Int(s)
        let d = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    static func percent(_ p: Double) -> String {
        "\(Int(p.rounded()))%"
    }

    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        switch v {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 10_000...: return String(format: "%.0fk", v / 1_000)
        case 1_000...: return String(format: "%.1fk", v / 1_000)
        default: return "\(n)"
        }
    }

    /// Human label for a rolling window length: 18000 → "5h", 604800 → "7d".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s % 86400 == 0 { return "\(s / 86400)d" }
        if s % 3600 == 0 { return "\(s / 3600)h" }
        if s >= 3600 { return String(format: "%.1fh", seconds / 3600) }
        return "\(s / 60)m"
    }

    static func money(_ value: Double, _ currency: String?) -> String {
        let symbol: String
        switch (currency ?? "USD").uppercased() {
        case "USD": symbol = "$"
        case "EUR": symbol = "€"
        case "GBP": symbol = "£"
        default: symbol = (currency ?? "") + " "
        }
        if value == value.rounded() && value < 1000 { return "\(symbol)\(Int(value))" }
        return symbol + String(format: "%.2f", value)
    }

    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let s = Int(now.timeIntervalSince(date))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    static func interval(_ seconds: Int) -> String {
        if seconds >= 3600 { return "\(seconds / 3600)h" }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses ISO-8601 with any fractional precision (Python emits 6 digits).
    static func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = isoFractional.date(from: s) { return d }
        if let d = iso.date(from: s) { return d }
        // Strip fractional seconds of arbitrary length.
        if let range = s.range(of: #"\.\d+"#, options: .regularExpression) {
            var stripped = s
            stripped.removeSubrange(range)
            return iso.date(from: stripped)
        }
        return nil
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func day(from key: String) -> Date? { dayFormatter.date(from: key) }

    static func clock(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM, HH:mm"
        return f.string(from: date)
    }
}
