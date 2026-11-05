import Foundation

public struct YearMonth: Comparable, Hashable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    /// From a `YYYY-MM-DD` string.
    public init?(date: String) {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1])
    }

    public func shifted(by months: Int) -> YearMonth {
        let index = year * 12 + (month - 1) + months
        return YearMonth(year: index / 12, month: index % 12 + 1)
    }

    public static func < (a: YearMonth, b: YearMonth) -> Bool {
        (a.year, a.month) < (b.year, b.month)
    }
}

public struct DayUsage: Equatable {
    public var claude = 0
    public var codex = 0
    public var grok = 0
    public var requests = 0

    public var total: Int { claude + codex + grok }

    public init() {}
}

public enum DayState: Equatable {
    case future
    case noLog
    case zero
    case level(Int)  // 0 lightest ... 4 strongest
}

public struct DayCell: Equatable {
    public let date: String
    public let day: Int
    public let state: DayState
    public let usage: DayUsage
    public let isToday: Bool
}

public struct Heatmap {
    static let levelTops = [0.22, 0.42, 0.62, 0.82]
    public static let weeks = 6

    public let today: String
    public let firstDate: String?
    private let days: [String: DayUsage]
    // One fixed scale, so a color means the same amount in every month.
    private let peak: Int

    public init(rows: [Snapshot.Row], firstDate: String?, today: String) {
        var days: [String: DayUsage] = [:]
        for row in rows {
            var day = days[row.date, default: DayUsage()]
            if row.agent == "claude" { day.claude += row.billable }
            if row.agent == "codex" { day.codex += row.billable }
            if row.agent == "grok" { day.grok += row.billable }
            day.requests += row.requests
            days[row.date] = day
        }
        self.days = days
        self.peak = days.values.map(\.total).max() ?? 0
        self.firstDate = firstDate
        self.today = today
    }

    public var latestMonth: YearMonth? { YearMonth(date: today) }
    public var earliestMonth: YearMonth? { firstDate.flatMap { YearMonth(date: $0) } ?? latestMonth }

    /// Always `weeks * 7` slots from a Monday, so turning the month never
    /// changes the height of the panel. Slots outside the month are nil.
    public func cells(for month: YearMonth) -> [DayCell?] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let first = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1))!
        let count = calendar.range(of: .day, in: .month, for: first)!.count
        let lead = (calendar.component(.weekday, from: first) + 5) % 7
        var slots: [DayCell?] = Array(repeating: nil, count: lead)
        for day in 1...count {
            slots.append(cell(String(format: "%04d-%02d-%02d", month.year, month.month, day), day: day))
        }
        slots += Array(repeating: nil, count: Self.weeks * 7 - slots.count)
        return slots
    }

    public func total(for month: YearMonth) -> Int {
        cells(for: month).compactMap { $0?.usage.total }.reduce(0, +)
    }

    private func cell(_ date: String, day: Int) -> DayCell {
        let usage = days[date] ?? DayUsage()
        return DayCell(date: date, day: day, state: state(date, usage), usage: usage, isToday: date == today)
    }

    private func state(_ date: String, _ usage: DayUsage) -> DayState {
        if date > today { return .future }
        guard let firstDate, date >= firstDate else { return .noLog }
        guard usage.total > 0, peak > 0 else { return .zero }
        let ratio = Double(usage.total) / Double(peak)
        return .level(Self.levelTops.firstIndex { ratio <= $0 } ?? Self.levelTops.count)
    }
}

/// `YYYY-MM-DD` in the local timezone, the same day boundary as the log rollup.
public func localDate(epoch: Int) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
}
