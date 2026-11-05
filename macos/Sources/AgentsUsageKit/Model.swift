import Foundation

/// The JSON that `agents-usage serve` prints. Missing values stay missing.
public struct Snapshot: Decodable {
    public let generatedAt: Int
    public let accounts: [Account]
    public let mostUrgent: Urgent?
    public let usage: Usage

    public struct Account: Decodable, Identifiable {
        public let agent: String
        public let name: String
        public let email: String?
        public let plan: String?
        public let windows: [QuotaWindow]
        public let source: String?
        public let capturedAt: Int?
        public let stale: Bool
        public let note: String?
        public let manualResets: Int?

        public var id: String { name }
    }

    public struct QuotaWindow: Decodable, Identifiable {
        public let label: String
        public let leftPercent: Double
        public let level: String
        public let resetsAt: Int?

        public var id: String { label }
    }

    public struct Urgent: Decodable {
        public let leftPercent: Double
        public let level: String
    }

    public struct Usage: Decodable {
        public let rows: [Row]
        public let firstDate: String?
    }

    public struct Row: Decodable {
        public let date: String
        public let agent: String
        public let model: String
        public let project: String
        public let fresh: Int
        public let cacheRead: Int
        public let cacheWrite: Int
        public let output: Int
        public let requests: Int
        public let sessions: [Int]

        /// The CLI's default "billable" metric: everything but cache reads.
        public var billable: Int { fresh + cacheWrite + output }
    }

    public static func decode(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Snapshot.self, from: data)
    }

    public var menuTitle: String {
        guard let urgent = mostUrgent else { return "—" }
        return levelMark(urgent.level) + percentText(urgent.leftPercent)
    }
}

/// Same marks as the CLI, so a level is never told by color alone.
public func levelMark(_ level: String) -> String {
    switch level {
    case "critical": return "■ "
    case "low": return "▲ "
    default: return ""
    }
}

public func percentText(_ percent: Double) -> String {
    "\(Int(percent.rounded()))%"
}

/// Mirrors `compact` in render.py.
public func compactText(_ n: Int) -> String {
    for (size, unit) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where Double(n) >= size {
        let v = Double(n) / size
        let scale = v >= 100 ? 1.0 : v >= 10 ? 10.0 : 100.0
        return String(format: "%g", (v * scale).rounded() / scale) + unit
    }
    return String(n)
}

public func resetText(seconds: Int) -> String {
    let seconds = max(seconds, 0)
    if seconds >= 86400 { return "\(seconds / 86400) 天" }
    if seconds >= 3600 { return "\(seconds / 3600) 小时" }
    return "\(max(seconds / 60, 1)) 分钟"
}
