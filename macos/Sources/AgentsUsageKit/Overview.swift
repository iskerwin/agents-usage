import Foundation

public enum AgentKind: String, CaseIterable, Identifiable, Sendable {
    case codex, claude, grok

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .grok: return "Grok"
        }
    }
}

/// One agent's quota in brief. The tightest window: stale windows only count when nothing
/// fresher exists, the same rule as `most_urgent` in quota.py.
public struct AgentSummary: Identifiable {
    public let kind: AgentKind
    public let accounts: [Snapshot.Account]
    public let window: Snapshot.QuotaWindow?
    public let stale: Bool
    /// What fits on the overview: the windows in the backend's order, never
    /// leaving out the tightest.
    public let glanceWindows: [Snapshot.QuotaWindow]

    public var id: String { kind.id }

    static let glanceLimit = 2

    init(kind: AgentKind, accounts: [Snapshot.Account]) {
        self.kind = kind
        self.accounts = accounts
        let fresh = accounts.filter { !$0.stale }.flatMap(\.windows)
        let windows = fresh.isEmpty ? accounts.flatMap(\.windows) : fresh
        window = windows.min { $0.leftPercent < $1.leftPercent }
        stale = fresh.isEmpty && window != nil
        var byLabel: [Snapshot.QuotaWindow] = []
        for candidate in windows {
            if let index = byLabel.firstIndex(where: { $0.label == candidate.label }) {
                if candidate.leftPercent < byLabel[index].leftPercent { byLabel[index] = candidate }
            } else {
                byLabel.append(candidate)
            }
        }
        var glance = Array(byLabel.prefix(Self.glanceLimit))
        if let window, !glance.contains(where: { $0.leftPercent <= window.leftPercent }) {
            glance[glance.count - 1] = window
        }
        glanceWindows = glance
    }
}

/// API list prices applied to the logged tokens. nil means tokens exist but
/// none has a known price, which is not the same as costing nothing.
public struct CostSummary {
    public let today: Double?
    public let month: Double?
    public let unpricedModels: [String]

    init(rows: [Snapshot.Row], today date: String) {
        let monthPrefix = String(date.prefix(7))
        let monthRows = rows.filter { $0.date.hasPrefix(monthPrefix) }
        today = Self.sum(rows.filter { $0.date == date })
        month = Self.sum(monthRows)
        unpricedModels = Set(monthRows.filter { $0.cost == nil }.map(\.model)).sorted()
    }

    static func sum(_ rows: [Snapshot.Row]) -> Double? {
        let priced = rows.compactMap(\.cost)
        return priced.isEmpty && !rows.isEmpty ? nil : priced.reduce(0, +)
    }
}

/// One agent's costs, and where its month's tokens went.
public struct AgentDetails {
    public struct Entry: Identifiable, Equatable {
        public let name: String
        public let tokens: Int

        public var id: String { name }
    }

    static let rankingLimit = 4

    public let costs: CostSummary
    public let models: [Entry]
    public let projects: [Entry]

    public init(rows: [Snapshot.Row], kind: AgentKind, today: String) {
        let monthPrefix = String(today.prefix(7))
        let own = rows.filter { $0.agent == kind.rawValue }
        let month = own.filter { $0.date.hasPrefix(monthPrefix) }
        costs = CostSummary(rows: own, today: today)
        models = Self.ranking(month, key: \.model)
        projects = Self.ranking(month, key: \.project)
    }

    /// Largest first, the tail folded into one row so the tokens still add up.
    static func ranking(_ rows: [Snapshot.Row], key: (Snapshot.Row) -> String) -> [Entry] {
        let totals = Dictionary(grouping: rows, by: key).map { name, group in
            Entry(name: name, tokens: group.reduce(0) { $0 + $1.billable })
        }
        let sorted = totals.sorted { ($0.tokens, $1.name) > ($1.tokens, $0.name) }
        guard sorted.count > rankingLimit else { return sorted }
        let rest = sorted[rankingLimit...]
        return Array(sorted[..<rankingLimit]) + [Entry(name: tr("其他 \(rest.count) 项", "\(rest.count) others"), tokens: rest.reduce(0) { $0 + $1.tokens })]
    }
}

public enum TrendRange: String, CaseIterable, Identifiable {
    case day, week, month

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .day: return "24h"
        case .week: return "7d"
        case .month: return "30d"
        }
    }
}

public struct TrendBar: Identifiable, Equatable {
    public let id: Int
    public let label: String
    public let total: Int
}

/// One agent's billable metric over a range: by hour for a day, by day otherwise.
public struct Trend {
    public let bars: [TrendBar]
    public let total: Int

    public init(usage: Snapshot.Usage, range: TrendRange, agent: AgentKind, now: Int) {
        var bars: [TrendBar] = []
        switch range {
        case .day:
            let calendar = Calendar.current
            let moment = Date(timeIntervalSince1970: TimeInterval(now))
            let current = Int(calendar.dateInterval(of: .hour, for: moment)?.start.timeIntervalSince1970 ?? TimeInterval(now))
            let hours = (usage.hours ?? []).filter { $0.agent == agent.rawValue }
            for index in 0..<24 {
                let start = current - (23 - index) * 3600
                let rows = hours.filter { $0.hour == start }
                bars.append(TrendBar(id: index, label: hourText(epoch: start, now: now),
                                     total: rows.reduce(0) { $0 + $1.billable }))
            }
        case .week, .month:
            let dates = recentDates(endingAt: localDate(epoch: now), count: range == .week ? 7 : 30)
            let own = usage.rows.filter { $0.agent == agent.rawValue }
            for (index, date) in dates.enumerated() {
                let rows = own.filter { $0.date == date }
                bars.append(TrendBar(id: index, label: dayText(date), total: rows.reduce(0) { $0 + $1.billable }))
            }
        }
        self.bars = bars
        total = bars.reduce(0) { $0 + $1.total }
    }
}

extension Snapshot {
    public var summaries: [AgentSummary] {
        AgentKind.allCases.compactMap { kind in
            let matching = accounts.filter { $0.agent == kind.rawValue }
            return matching.isEmpty ? nil : AgentSummary(kind: kind, accounts: matching)
        }
    }

    public var today: String { localDate(epoch: generatedAt) }

    public var costs: CostSummary { CostSummary(rows: usage.rows, today: today) }
}

extension Snapshot.AgentTask {
    public var kind: AgentKind? { AgentKind(rawValue: agent) }
    public var isRunning: Bool { state == "running" }
    public var projectName: String { project.components(separatedBy: "/").last ?? project }
    /// The folder stands in for a session that has no title yet.
    public var displayTitle: String { title ?? projectName }
}

extension Snapshot.QuotaWindow {
    /// How long the window runs, read off its label. nil for a label that names no length.
    var durationSeconds: Int? {
        guard let token = shortWindowLabel(label).split(separator: " ").first, let unit = token.last,
              let count = Int(token.dropLast()) else { return nil }
        switch unit {
        case "m": return count * 60
        case "h": return count * 3600
        case "d": return count * 86400
        default: return nil
        }
    }

    /// The percent left if use had been even since the window began.
    func evenPaceLeft(now: Int) -> Double? {
        guard let resetsAt, let durationSeconds, durationSeconds > 0 else { return nil }
        return min(max(Double(resetsAt - now) / Double(durationSeconds) * 100, 0), 100)
    }
}

/// A project's folder, if it names one that still exists. Logs outlive folders,
/// and the folded tail of a ranking names none at all.
func projectFolder(_ project: String) -> URL? {
    guard project == "~" || project.hasPrefix("~/") || project.hasPrefix("/") else { return nil }
    let path = NSString(string: project).expandingTildeInPath
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
}

/// `YYYY-MM-DD` in the local timezone, the same day boundary as the log rollup.
public func localDate(epoch: Int) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
}

/// `count` dates ending at `date`, oldest first.
func recentDates(endingAt date: String, count: Int) -> [String] {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    guard let end = formatter.date(from: date) else { return [] }
    return (0..<count).reversed().map { formatter.string(from: end.addingTimeInterval(TimeInterval(-$0 * 86400))) }
}

func dayText(_ date: String) -> String {
    let parts = date.split(separator: "-").compactMap { Int($0) }
    return parts.count == 3 ? "\(parts[1])/\(parts[2])" : date
}

func hourText(epoch: Int, now: Int) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    let moment = Date(timeIntervalSince1970: TimeInterval(epoch))
    let today = Calendar.current.isDate(moment, inSameDayAs: Date(timeIntervalSince1970: TimeInterval(now)))
    return (today ? "" : tr("昨天 ", "Yesterday ")) + formatter.string(from: moment)
}

/// `2h 18m`, `3d 12h`, `48m`.
public func durationText(seconds: Int) -> String {
    let seconds = max(seconds, 0)
    if seconds >= 86400 { return "\(seconds / 86400)d \(seconds % 86400 / 3600)h" }
    if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
    return "\(max(seconds / 60, 1))m"
}

/// `5 小时` as `5h`, `每周 (Opus)` as `7d (Opus)`.
public func shortWindowLabel(_ label: String) -> String {
    label.replacingOccurrences(of: " 小时", with: "h")
        .replacingOccurrences(of: " 分钟", with: "m")
        .replacingOccurrences(of: " 天", with: "d")
        .replacingOccurrences(of: "每周", with: "7d")
        .replacingOccurrences(of: "每日", with: "1d")
        .replacingOccurrences(of: "每月", with: "30d")
}

public func moneyText(_ amount: Double) -> String {
    if amount > 0 && amount < 0.01 { return "<$0.01" }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.numberStyle = .decimal
    let digits = amount >= 100 ? 0 : 2
    formatter.minimumFractionDigits = digits
    formatter.maximumFractionDigits = digits
    return "$" + (formatter.string(from: NSNumber(value: amount)) ?? String(amount))
}

/// What the budget field holds: a positive amount, or none.
public func parseBudget(_ text: String) -> Double? {
    let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
    return Double(cleaned).flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
}
