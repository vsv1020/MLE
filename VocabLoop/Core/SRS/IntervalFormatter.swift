import Foundation

/// Turns an interval in days into the short label shown on the rating buttons.
///
/// Compact by design — four of these sit side by side on a 375pt-wide screen, so
/// "10m" and "4mo" are the whole budget. Longer forms exist separately for VoiceOver
/// and for detail screens, because "4mo" read aloud is not a sentence.
public enum IntervalFormatter {
    /// e.g. `"<1m"`, `"10m"`, `"3h"`, `"4d"`, `"3w"`, `"5mo"`, `"2.4y"`
    public static func short(days: Double) -> String {
        guard days.isFinite, days > 0 else { return "<1 分钟" }
        let minutes = days * 24 * 60

        if minutes < 1 { return "<1 分钟" }
        if minutes < 60 { return "\(Int(minutes.rounded())) 分钟" }
        if days < 1 { return "\(Int((days * 24).rounded())) 小时" }
        if days < 21 { return "\(Int(days.rounded())) 天" }
        if days < 60 { return "\(Int((days / 7).rounded())) 周" }
        if days < 365 { return "\(Int((days / 30.44).rounded())) 个月" }

        let years = days / 365.25
        return years < 10
            ? String(format: "%.1f 年", years)
            : "\(Int(years.rounded())) 年"
    }

    /// Spelled out for VoiceOver and detail rows: `"in 4 days"`, `"in about 3 months"`.
    public static func spoken(days: Double) -> String {
        guard days.isFinite, days > 0 else { return "不到 1 分钟后" }
        let minutes = days * 24 * 60

        if minutes < 60 {
            let m = max(1, Int(minutes.rounded()))
            return "\(m) 分钟后"
        }
        if days < 1 {
            let h = max(1, Int((days * 24).rounded()))
            return "\(h) 小时后"
        }
        if days < 30 {
            let d = Int(days.rounded())
            return "\(d) 天后"
        }
        if days < 365 {
            let mo = Int((days / 30.44).rounded())
            return "大约 \(mo) 个月后"
        }
        let y = (days / 365.25 * 10).rounded() / 10
        return "大约 \(y == y.rounded() ? String(Int(y)) : String(y)) 年后"
    }

    /// Relative description of a due date: `"Due now"`, `"Due in 3 hours"`,
    /// `"Overdue by 2 days"`.
    public static func dueDescription(due: Date, now: Date = Date()) -> String {
        let seconds = due.timeIntervalSince(now)
        if abs(seconds) < 60 { return "现在就该复习" }
        let days = abs(seconds) / 86_400
        return seconds > 0
            ? "\(spoken(days: days))复习"
            : "已超期 \(spoken(days: days).replacingOccurrences(of: "后", with: ""))"
    }
}
