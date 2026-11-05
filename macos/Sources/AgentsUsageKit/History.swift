import Foundation

/// Everything the logs still hold, added up. The tables follow `_table` in
/// render.py: ordered by billable tokens, the tail folded into one row.
public struct UsageHistory {
    public struct Entry: Identifiable, Equatable {
        public let name: String
        public let billable: Int
        public let output: Int
        public let requests: Int

        public var id: String { name }
    }

    public static let agentNames = ["claude": "Claude Code", "codex": "Codex", "grok": "Grok"]

    public let billable: Int
    public let total: Int
    public let output: Int
    public let cacheHit: Double?  // nil without any input tokens
    public let requests: Int
    public let sessions: Int
    public let activeDays: Int
    public let firstDate: String?
    public let agents: [Entry]
    public let models: [Entry]
    public let projects: [Entry]

    public init(rows: [Snapshot.Row], firstDate: String?) {
        let fresh = rows.reduce(0) { $0 + $1.fresh }
        let cacheRead = rows.reduce(0) { $0 + $1.cacheRead }
        let cacheWrite = rows.reduce(0) { $0 + $1.cacheWrite }
        let input = fresh + cacheRead + cacheWrite
        billable = rows.reduce(0) { $0 + $1.billable }
        output = rows.reduce(0) { $0 + $1.output }
        total = input + output
        cacheHit = input > 0 ? Double(cacheRead) / Double(input) : nil
        requests = rows.reduce(0) { $0 + $1.requests }
        sessions = Set(rows.flatMap(\.sessions)).count
        activeDays = Set(rows.map(\.date)).count
        self.firstDate = firstDate
        agents = Self.table(rows, limit: 6) { Self.agentNames[$0.agent] ?? $0.agent }
        models = Self.table(rows, limit: 6, key: \.model)
        projects = Self.table(rows, limit: 8) { shortPath($0.project) }
    }

    static func table(_ rows: [Snapshot.Row], limit: Int, key: (Snapshot.Row) -> String) -> [Entry] {
        func entry(_ name: String, _ rows: [Snapshot.Row]) -> Entry {
            Entry(name: name, billable: rows.reduce(0) { $0 + $1.billable },
                  output: rows.reduce(0) { $0 + $1.output }, requests: rows.reduce(0) { $0 + $1.requests })
        }
        let groups = Dictionary(grouping: rows, by: key).map { entry($0.key, $0.value) }
        let sorted = groups.sorted { ($0.billable, $1.name) > ($1.billable, $0.name) }
        guard sorted.count > limit else { return sorted }
        let rest = sorted[limit...]
        return Array(sorted[..<limit]) + [Entry(
            name: "其他 \(rest.count) 项", billable: rest.reduce(0) { $0 + $1.billable },
            output: rest.reduce(0) { $0 + $1.output }, requests: rest.reduce(0) { $0 + $1.requests })]
    }
}

/// Mirrors `short_path` in render.py.
public func shortPath(_ path: String) -> String {
    let parts = path.components(separatedBy: "/")
    return parts.count > 3 ? "…/" + parts.suffix(2).joined(separator: "/") : path
}

/// Mirrors `clock` in render.py: the date only when it is not today.
public func clockText(epoch: Int, now: Int) -> String {
    let calendar = Calendar.current
    let moment = Date(timeIntervalSince1970: TimeInterval(epoch))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    let today = calendar.isDate(moment, inSameDayAs: Date(timeIntervalSince1970: TimeInterval(now)))
    formatter.dateFormat = today ? "HH:mm" : "M/d HH:mm"
    return formatter.string(from: moment)
}

public func ageText(seconds: Int) -> String {
    seconds < 60 ? "不到 1 分钟前" : resetText(seconds: seconds) + "前"
}
