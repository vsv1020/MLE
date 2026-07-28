import Foundation

/// Turns an interval in days into the short label shown on the rating buttons.
///
/// Compact by design — four of these sit side by side on a 375pt-wide screen, so
/// "10m" and "4mo" are the whole budget. Longer forms exist separately for VoiceOver
/// and for detail screens, because "4mo" read aloud is not a sentence.
public enum IntervalFormatter {
    /// e.g. `"<1m"`, `"10m"`, `"3h"`, `"4d"`, `"3w"`, `"5mo"`, `"2.4y"`
    public static func short(days: Double) -> String {
        guard days.isFinite, days > 0 else { return "<1m" }
        let minutes = days * 24 * 60

        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(Int(minutes.rounded()))m" }
        if days < 1 { return "\(Int((days * 24).rounded()))h" }
        if days < 21 { return "\(Int(days.rounded()))d" }
        if days < 60 { return "\(Int((days / 7).rounded()))w" }
        if days < 365 { return "\(Int((days / 30.44).rounded()))mo" }

        let years = days / 365.25
        return years < 10
            ? String(format: "%.1fy", years)
            : "\(Int(years.rounded()))y"
    }

    /// Spelled out for VoiceOver and detail rows: `"in 4 days"`, `"in about 3 months"`.
    public static func spoken(days: Double) -> String {
        guard days.isFinite, days > 0 else { return "in less than a minute" }
        let minutes = days * 24 * 60

        if minutes < 60 {
            let m = max(1, Int(minutes.rounded()))
            return "in \(m) minute\(m == 1 ? "" : "s")"
        }
        if days < 1 {
            let h = max(1, Int((days * 24).rounded()))
            return "in \(h) hour\(h == 1 ? "" : "s")"
        }
        if days < 30 {
            let d = Int(days.rounded())
            return "in \(d) day\(d == 1 ? "" : "s")"
        }
        if days < 365 {
            let mo = Int((days / 30.44).rounded())
            return "in about \(mo) month\(mo == 1 ? "" : "s")"
        }
        let y = (days / 365.25 * 10).rounded() / 10
        return "in about \(y == y.rounded() ? String(Int(y)) : String(y)) years"
    }

    /// Relative description of a due date: `"Due now"`, `"Due in 3 hours"`,
    /// `"Overdue by 2 days"`.
    public static func dueDescription(due: Date, now: Date = Date()) -> String {
        let seconds = due.timeIntervalSince(now)
        if abs(seconds) < 60 { return "Due now" }
        let days = abs(seconds) / 86_400
        return seconds > 0
            ? "Due \(spoken(days: days))"
            : "Overdue by \(spoken(days: days).replacingOccurrences(of: "in ", with: ""))"
    }
}
