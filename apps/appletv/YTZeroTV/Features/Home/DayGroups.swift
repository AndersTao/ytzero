import Foundation

/// The main list cut into days by when each video came out: today, then the
/// six days before it by weekday name, then everything older together.
nonisolated struct DaySection: Identifiable, Sendable {
    /// 0 is today, 1–6 the days before it, 7 everything older.
    let daysAgo: Int
    let title: String
    let videos: [Video]

    var id: Int { daysAgo }
}

nonisolated enum DayGroups {
    static let days = 7

    /// Sections newest first; each keeps the order its videos were given in.
    static func sections(_ videos: [Video], now: Date = .now, calendar: Calendar = .current) -> [DaySection] {
        var grouped: [Int: [Video]] = [:]
        for video in videos {
            grouped[daysAgo(video.publishedAt, now: now, calendar: calendar), default: []].append(video)
        }
        return grouped.keys.sorted().map { key in
            DaySection(daysAgo: key, title: title(daysAgo: key, now: now, calendar: calendar), videos: grouped[key] ?? [])
        }
    }

    /// Calendar days back from today; a date ahead (a premiere) counts as
    /// today, and no date or a week or more back as older.
    static func daysAgo(_ date: Date?, now: Date, calendar: Calendar) -> Int {
        guard let date else { return days }
        let back = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? days
        return min(max(back, 0), days)
    }

    static func title(daysAgo: Int, now: Date, calendar: Calendar) -> String {
        switch daysAgo {
        case 0: return String(localized: "Today")
        case days...: return String(localized: "Older")
        default:
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            // "lørdag" in Danish: weekday names are written in lower case there.
            let name = day.formatted(.dateTime.weekday(.wide).locale(calendar.locale ?? .current))
            return name.prefix(1).uppercased() + name.dropFirst()
        }
    }
}
