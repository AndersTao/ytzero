import Foundation

/// "4:05" or "1:02:03": the clock a video player shows, the same in every
/// language (Danish formatting would otherwise write "4.05").
nonisolated enum PlaybackTime {
    static func text(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600, minutes = total % 3600 / 60, rest = total % 60
        let paddedSeconds = rest < 10 ? "0\(rest)" : "\(rest)"
        if hours > 0 {
            let paddedMinutes = minutes < 10 ? "0\(minutes)" : "\(minutes)"
            return "\(hours):\(paddedMinutes):\(paddedSeconds)"
        }
        return "\(minutes):\(paddedSeconds)"
    }
}
