import Foundation

/// The JSON that `agents-usage serve` prints. Missing values stay missing.
public struct Snapshot: Decodable {
    public let generatedAt: Int
    public let accounts: [Account]
    public let usage: Usage
    public let tasks: [AgentTask]?

    public struct Account: Decodable, Identifiable {
        public let agent: String
        public let name: String
        public let email: String?
        public let plan: String?
        public let windows: [QuotaWindow]
        public let stale: Bool
        public let note: String?

        public var id: String { name }
    }

    public struct QuotaWindow: Decodable, Identifiable {
        public let label: String
        public let leftPercent: Double
        public let level: String
        public let resetsAt: Int?

        public var id: String { label }
    }

    public struct Usage: Decodable {
        public let rows: [Row]
        public let hours: [HourRow]?
    }

    public struct AgentTask: Decodable, Identifiable {
        public let agent: String
        public let pid: Int32
        public let title: String?
        public let project: String
        public let cwd: String?
        public let state: String

        public var id: Int32 { pid }
    }

    public struct HourRow: Decodable {
        public let hour: Int
        public let agent: String
        public let fresh: Int
        public let cacheWrite: Int
        public let output: Int

        public var billable: Int { fresh + cacheWrite + output }
    }

    public struct Row: Decodable {
        public let date: String
        public let agent: String
        public let model: String
        public let project: String
        public let fresh: Int
        public let cacheWrite: Int
        public let output: Int
        public let cost: Double?  // nil when the model has no public price

        /// The CLI's default "billable" metric: everything but cache reads.
        public var billable: Int { fresh + cacheWrite + output }
    }

    public static func decode(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Snapshot.self, from: data)
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
