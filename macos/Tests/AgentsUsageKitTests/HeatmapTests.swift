import Foundation
import Testing
@testable import AgentsUsageKit

private func row(_ date: String, _ agent: String, _ amount: Int, requests: Int = 1,
                 model: String = "m", project: String = "p", cacheRead: Int = 0,
                 output: Int = 0, sessions: [Int] = []) -> Snapshot.Row {
    let json = """
    {"date":"\(date)","agent":"\(agent)","model":"\(model)","project":"\(project)","fresh":\(amount),
     "cache_read":\(cacheRead),"cache_write":0,"output":\(output),"requests":\(requests),"sessions":\(sessions)}
    """
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try! decoder.decode(Snapshot.Row.self, from: Data(json.utf8))
}

private func cell(_ map: Heatmap, _ date: String) -> DayCell {
    map.cells(for: YearMonth(date: date)!).compactMap { $0 }.first { $0.date == date }!
}

@Test func statesKeepMissingApartFromZero() {
    let map = Heatmap(rows: [row("2026-10-22", "claude", 100)], firstDate: "2026-10-21", today: "2026-10-24")
    #expect(cell(map, "2026-10-20").state == .noLog)
    #expect(cell(map, "2026-10-21").state == .zero)
    #expect(cell(map, "2026-10-22").state == .level(4))
    #expect(cell(map, "2026-10-25").state == .future)
    #expect(cell(map, "2026-10-24").isToday)
}

@Test func noLogsAtAllIsNotZero() {
    let map = Heatmap(rows: [], firstDate: nil, today: "2026-10-24")
    #expect(cell(map, "2026-10-01").state == .noLog)
}

@Test func agentsAddUpOnOneScale() {
    let rows = [row("2026-10-01", "claude", 60, requests: 2), row("2026-10-01", "codex", 40, requests: 3),
                row("2026-11-01", "claude", 10)]
    let map = Heatmap(rows: rows, firstDate: "2026-10-01", today: "2026-11-02")
    let peak = cell(map, "2026-10-01")
    #expect(peak.usage.total == 100)
    #expect(Heatmap(rows: [row("2026-10-01", "grok", 5)], firstDate: "2026-10-01", today: "2026-10-02")
        .cells(for: YearMonth(year: 2026, month: 10)).compactMap { $0 }.first?.usage.grok == 5)
    #expect(peak.usage.requests == 5)
    #expect(peak.state == .level(4))
    // The scale is shared across months: November's busiest day stays light.
    #expect(cell(map, "2026-11-01").state == .level(0))
    #expect(map.total(for: YearMonth(year: 2026, month: 11)) == 10)
}

@Test func gridStartsOnMondayAndKeepsItsSize() {
    let map = Heatmap(rows: [], firstDate: nil, today: "2026-11-05")
    for month in 1...12 {
        #expect(map.cells(for: YearMonth(year: 2026, month: month)).count == 42)
    }
    // 2026-11-01 is a Sunday, 2026-06-01 a Monday.
    #expect(map.cells(for: YearMonth(year: 2026, month: 11))[6]?.day == 1)
    #expect(map.cells(for: YearMonth(year: 2026, month: 6))[0]?.day == 1)
}

@Test func monthShiftCrossesYears() {
    #expect(YearMonth(year: 2026, month: 1).shifted(by: -1) == YearMonth(year: 2025, month: 12))
    #expect(YearMonth(year: 2026, month: 12).shifted(by: 1) == YearMonth(year: 2027, month: 1))
}

@Test func compactMatchesTheCLI() {
    #expect(compactText(950) == "950")
    #expect(compactText(2_623_998) == "2.62M")
    #expect(compactText(19_680_000) == "19.7M")
    #expect(compactText(150_400) == "150K")
}

@Test func decodesWhatTheBackendSends() throws {
    let json = """
    {"generated_at":1793841332,"most_urgent":{"left_percent":85.6,"level":"ok","label":"每周"},
     "accounts":[{"agent":"codex","name":"Codex","plan":null,"stale":false,"note":null,"email":null,
                  "windows":[{"label":"5 小时","left_percent":12,"level":"critical","resets_at":null}]}],
     "usage":{"first_date":null,"rows":[]}}
    """
    let snapshot = try Snapshot.decode(Data(json.utf8))
    #expect(snapshot.menuTitle == "86%")
    #expect(snapshot.accounts[0].windows[0].resetsAt == nil)
    #expect(levelMark("critical") + percentText(12) == "■ 12%")
}

@Test func historyAddsUpEveryRowOnce() {
    let rows = [row("2026-10-01", "claude", 90, requests: 2, model: "opus", project: "/a/b/c/d", cacheRead: 100, output: 10, sessions: [0, 1]),
                row("2026-10-02", "claude", 40, model: "opus", project: "/a/b/c/d", sessions: [1]),
                row("2026-10-02", "codex", 60, requests: 3, model: "gpt", project: "~/x", output: 5, sessions: [2])]
    let history = UsageHistory(rows: rows, firstDate: "2026-10-01")
    #expect(history.billable == 205)
    #expect(history.total == 305)
    #expect(history.output == 15)
    #expect(history.requests == 6)
    #expect(history.sessions == 3)
    #expect(history.activeDays == 2)
    #expect(history.cacheHit == 100.0 / 290.0)
    #expect(history.agents.map(\.name) == ["Claude Code", "Codex"])
    #expect(history.models.first == UsageHistory.Entry(name: "opus", billable: 140, output: 10, requests: 3))
    #expect(history.projects.map(\.name) == ["…/c/d", "~/x"])
}

@Test func historyWithoutInputHasNoCacheRate() {
    #expect(UsageHistory(rows: [], firstDate: nil).cacheHit == nil)
}

@Test func tablesFoldTheTailWithoutLosingTokens() {
    let rows = (1...9).map { row("2026-10-01", "claude", $0 * 10, model: "m\($0)") }
    let table = UsageHistory.table(rows, limit: 6, key: \.model)
    #expect(table.count == 7)
    #expect(table[0].name == "m9")
    #expect(table[6] == UsageHistory.Entry(name: "其他 3 项", billable: 60, output: 0, requests: 3))
}

@Test func storedThemeFallsBackToTheSystem() {
    #expect(Theme(stored: "dark") == .dark)
    #expect(Theme(stored: "light") == .light)
    #expect(Theme(stored: "sepia") == .system)
    #expect(Theme(stored: nil) == .system)
    #expect(Theme.system.appearanceName == nil)
    #expect(Theme.dark.appearanceName == .darkAqua)
}
