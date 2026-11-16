import Foundation
import SwiftUI
import Testing
@testable import AgentsUsageKit

private func row(_ date: String, _ agent: String, _ amount: Int, requests: Int = 1,
                 model: String = "m", project: String = "p", sessions: [Int] = []) -> Snapshot.Row {
    let json = """
    {"date":"\(date)","agent":"\(agent)","model":"\(model)","project":"\(project)","fresh":\(amount),
     "cache_read":0,"cache_write":0,"output":0,"requests":\(requests),"sessions":\(sessions)}
    """
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try! decoder.decode(Snapshot.Row.self, from: Data(json.utf8))
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
     "usage":{"rows":[]}}
    """
    let snapshot = try Snapshot.decode(Data(json.utf8))
    #expect(snapshot.accounts[0].windows[0].resetsAt == nil)
    #expect(levelMark("critical") + percentText(12) == "■ 12%")
}

@Test func storedThemeFallsBackToTheSystem() {
    #expect(Theme(stored: "dark") == .dark)
    #expect(Theme(stored: "light") == .light)
    #expect(Theme(stored: "sepia") == .system)
    #expect(Theme(stored: nil) == .system)
    #expect(Theme.system.appearanceName == nil)
    #expect(Theme.dark.appearanceName == .darkAqua)
}

private func snapshot(accounts: String = "[]", rows: String = "[]", hours: String = "[]", tasks: String = "[]",
                      now: Int = 1_793_900_000) throws -> Snapshot {
    let json = """
    {"generated_at":\(now),"accounts":\(accounts),
     "usage":{"rows":\(rows),"hours":\(hours)},"tasks":\(tasks)}
    """
    return try Snapshot.decode(Data(json.utf8))
}

private func account(_ agent: String, _ name: String, stale: Bool = false, left: [Double]) -> String {
    let windows = left.enumerated().map { """
        {"label":"w\($0.offset)","left_percent":\($0.element),"level":"ok","resets_at":null}
        """ }.joined(separator: ",")
    return """
    {"agent":"\(agent)","name":"\(name)","plan":null,"stale":\(stale),"note":null,"email":null,"windows":[\(windows)]}
    """
}

private func costRow(_ date: String, _ agent: String, _ model: String, fresh: Int = 0, cacheRead: Int = 0,
                     output: Int = 0, cost: Double?) -> String {
    """
    {"date":"\(date)","agent":"\(agent)","model":"\(model)","project":"p","fresh":\(fresh),"cache_read":\(cacheRead),
     "cache_write":0,"output":\(output),"requests":1,"sessions":[0],"cost":\(cost.map { String($0) } ?? "null")}
    """
}

@Test func summaryTakesTheTightestFreshWindowAcrossAccounts() throws {
    let accounts = "[\(account("codex", "a", left: [80, 40])),\(account("codex", "b", left: [60])),\(account("claude", "c", stale: true, left: [5]))]"
    let summaries = try snapshot(accounts: accounts).summaries
    #expect(summaries.map(\.kind) == [.codex, .claude])
    #expect(summaries[0].window?.leftPercent == 40)
    #expect(summaries[0].stale == false)
    #expect(summaries[1].window?.leftPercent == 5)
    #expect(summaries[1].stale == true)
}

@Test func staleAccountDoesNotBeatAFreshOne() throws {
    let accounts = "[\(account("codex", "a", stale: true, left: [1])),\(account("codex", "b", left: [70]))]"
    let summary = try snapshot(accounts: accounts).summaries[0]
    #expect(summary.window?.leftPercent == 70)
    #expect(summary.stale == false)
}

@Test func agentWithoutWindowsStaysMissing() throws {
    let summary = try snapshot(accounts: "[\(account("grok", "g", left: []))]").summaries[0]
    #expect(summary.window == nil)
    #expect(summary.stale == false)
}

@Test func costKeepsUnpricedApartFromFree() throws {
    let rows = "[" + [costRow("2026-11-05", "grok", "grok-4.7-build", fresh: 10, cost: nil),
                      costRow("2026-11-04", "codex", "gpt-6.1-sol", fresh: 10, cost: 1.5),
                      costRow("2026-10-31", "codex", "gpt-6.1-sol", fresh: 10, cost: 9)].joined(separator: ",") + "]"
    let usage = try snapshot(rows: rows).usage
    let onlyUnpriced = CostSummary(rows: usage.rows, today: "2026-11-05")
    #expect(onlyUnpriced.today == nil)
    #expect(onlyUnpriced.month == 1.5)
    #expect(onlyUnpriced.unpricedModels == ["grok-4.7-build"])
    let nothing = CostSummary(rows: usage.rows, today: "2026-11-03")
    #expect(nothing.today == 0)
}

@Test func dayTrendHasTwentyFourHoursEndingNow() throws {
    let now = 1_793_900_000
    let hour = Int(Calendar.current.dateInterval(of: .hour, for: Date(timeIntervalSince1970: TimeInterval(now)))!.start.timeIntervalSince1970)
    func hourRow(_ start: Int, _ agent: String, _ amount: Int, _ session: Int) -> String {
        """
        {"hour":\(start),"agent":"\(agent)","fresh":\(amount),"cache_read":7,"cache_write":0,"output":0,"requests":1,"sessions":[\(session)]}
        """
    }
    let hours = "[" + [hourRow(hour, "codex", 10, 1), hourRow(hour, "claude", 20, 2),
                       hourRow(hour - 23 * 3600, "codex", 5, 1), hourRow(hour - 24 * 3600, "codex", 99, 3)]
        .joined(separator: ",") + "]"
    let usage = try snapshot(hours: hours, now: now).usage
    let codex = Trend(usage: usage, range: .day, agent: .codex, now: now)
    #expect(codex.bars.count == 24)
    #expect(codex.bars.first?.total == 5)
    #expect(codex.bars.last?.total == 10)
    #expect(codex.total == 15)
    #expect(codex.sessions == 1)
    #expect(Trend(usage: usage, range: .day, agent: .claude, now: now).total == 20)
}

@Test func dayRangesUseTheDailyRows() throws {
    let now = 1_793_900_000
    let today = localDate(epoch: now)
    let rows = "[\(costRow(today, "codex", "m", fresh: 10, cost: nil)),\(costRow("2020-01-01", "codex", "m", fresh: 99, cost: nil))]"
    let usage = try snapshot(rows: rows, now: now).usage
    #expect(Trend(usage: usage, range: .week, agent: .codex, now: now).bars.count == 7)
    #expect(Trend(usage: usage, range: .month, agent: .codex, now: now).bars.count == 30)
    #expect(Trend(usage: usage, range: .month, agent: .codex, now: now).total == 10)
    #expect(Trend(usage: usage, range: .month, agent: .grok, now: now).total == 0)
    #expect(recentDates(endingAt: "2026-03-01", count: 2) == ["2026-02-28", "2026-03-01"])
}

@Test func taskFallsBackToItsFolder() throws {
    let tasks = """
    [{"agent":"claude","pid":1,"title":"修复登录","project":"~/a/web","cwd":"/a/web","state":"running","since":1},
     {"agent":"codex","pid":2,"title":null,"project":"~/a/api","cwd":null,"state":"idle","since":1},
     {"agent":"grok","pid":3,"title":"重构","project":"~/a/web","cwd":null,"state":"idle","since":1}]
    """
    let snap = try snapshot(tasks: tasks)
    let list = try #require(snap.tasks)
    #expect(list[1].displayTitle == "api")
    #expect(list[0].projectName == "web")
    #expect(list[0].isRunning)
    #expect(!list[1].isRunning)
}

@Test func tasksThatCouldNotBeListedAreNotZero() throws {
    let json = """
    {"generated_at":1,"accounts":[],"usage":{"rows":[]}}
    """
    let snap = try Snapshot.decode(Data(json.utf8))
    #expect(snap.tasks == nil)
    #expect(Trend(usage: snap.usage, range: .day, agent: .codex, now: 1).total == 0)
}

@Test func compactTexts() {
    #expect(durationText(seconds: 2 * 3600 + 18 * 60) == "2h 18m")
    #expect(durationText(seconds: 3 * 86400 + 12 * 3600) == "3d 12h")
    #expect(durationText(seconds: 10) == "1m")
    #expect(durationText(seconds: -5) == "1m")
    #expect(moneyText(4.281) == "$4.28")
    #expect(moneyText(0) == "$0.00")
    #expect(moneyText(0.001) == "<$0.01")
    #expect(moneyText(222.33) == "$222")
    #expect(moneyText(1234.4) == "$1,234")
    #expect(shortWindowLabel("5 小时") == "5h")
    #expect(shortWindowLabel("每周 (Opus)") == "7d (Opus)")
    #expect(windowRowLabel("每周 (Fable)") == "Fable")
    #expect(windowRowLabel("5 小时") == "5h")
    #expect(parseBudget(" $100 ") == 100)
    #expect(parseBudget("0") == nil)
    #expect(parseBudget("abc") == nil)
    #expect(parseBudget("") == nil)
}

@Test func logoDataParses() {
    for kind in AgentKind.allCases {
        let box = AgentLogo(kind).path(in: CGRect(x: 0, y: 0, width: 24, height: 24)).boundingRect
        #expect(box.width > 15 && box.width <= 25)
        #expect(box.height > 15 && box.height <= 25)
    }
}

@Test func detailsCoverOnlyThatAgentsMonth() {
    let rows = [row("2026-11-05", "codex", 100, requests: 2, model: "sol", project: "~/a", sessions: [1]),
                row("2026-11-01", "codex", 40, requests: 3, model: "terra", project: "~/a", sessions: [1, 2]),
                row("2026-10-31", "codex", 999, model: "old", project: "~/old", sessions: [9]),
                row("2026-11-05", "claude", 500, model: "opus", project: "~/c", sessions: [3])]
    let details = AgentDetails(rows: rows, kind: .codex, today: "2026-11-05")
    #expect(details.requests == 5)
    #expect(details.sessions == 2)
    #expect(details.today.input == 100)
    #expect(details.models == [AgentDetails.Entry(name: "sol", tokens: 100), AgentDetails.Entry(name: "terra", tokens: 40)])
    #expect(details.projects == [AgentDetails.Entry(name: "~/a", tokens: 140)])
}

@Test func theMarkSuitsBothPlacesItAppears() throws {
    let bar = AppMark.menuBarImage()
    #expect(bar.isTemplate)
    #expect(bar.size == NSSize(width: 18, height: 18))
    let png = try #require(AppMark.appIconPNG(pixels: 64))
    let icon = try #require(NSBitmapImageRep(data: png))
    #expect(icon.pixelsWide == 64 && icon.pixelsHigh == 64)
    #expect(icon.colorAt(x: 0, y: 0)?.alphaComponent == 0)  // the margin macOS icons leave
    #expect(icon.colorAt(x: 32, y: 8)?.alphaComponent == 1)
}

@Test func rankingUsesTheNameTheBackendSends() throws {
    let json = """
    {"date":"2026-11-05","agent":"claude","model":"claude-opus-5-5","model_name":"Claude Opus 5.5","project":"p",
     "fresh":5,"cache_read":0,"cache_write":0,"output":0,"requests":1,"sessions":[]}
    """
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let named = try decoder.decode(Snapshot.Row.self, from: Data(json.utf8))
    let details = AgentDetails(rows: [named], kind: .claude, today: "2026-11-05")
    #expect(details.models == [AgentDetails.Entry(name: "Claude Opus 5.5", tokens: 5)])
    #expect(row("2026-11-05", "claude", 1, model: "raw-id").displayModel == "raw-id")
}

@Test func rankingFoldsTheTailWithoutLosingTokens() {
    let rows = (1...7).map { row("2026-10-01", "claude", $0 * 10, model: "m\($0)") }
    let ranking = AgentDetails.ranking(rows, key: \.model)
    #expect(ranking.count == AgentDetails.rankingLimit + 1)
    #expect(ranking[0].name == "m7")
    #expect(ranking.last?.tokens == 60)
}

@Test func languageFollowsTheSystemUnlessChosen() {
    #expect(Language(stored: "english") == .english)
    #expect(Language(stored: "klingon") == .system)
    #expect(Language(stored: nil) == .system)
    #expect(Language.system.isChinese(preferred: ["zh-Hans-CN", "en"]))
    #expect(!Language.system.isChinese(preferred: ["en-US", "zh-Hans"]))
    #expect(!Language.system.isChinese(preferred: []))
    #expect(Language.chinese.isChinese(preferred: ["en-US"]))
    #expect(!Language.english.isChinese(preferred: ["zh-Hans"]))
}

@Test func modelWindowKeepsItsPaceNotch() throws {
    let now = 1_793_900_000
    let fable = try window("每周 (Fable)", left: 82, resetsAt: now + 3 * 86400)
    #expect(fable.evenPaceLeft(now: now) == Double(3) / 7 * 100)
}

private func window(_ label: String, left: Double, resetsAt: Int? = nil) throws -> Snapshot.QuotaWindow {
    let reset = resetsAt.map(String.init) ?? "null"
    let json = """
    {"generated_at":1,"accounts":[{"agent":"claude","name":"c","stale":false,"windows":[
      {"label":"\(label)","left_percent":\(left),"level":"ok","resets_at":\(reset)}]}],"usage":{"rows":[]}}
    """
    return try Snapshot.decode(Data(json.utf8)).accounts[0].windows[0]
}

@Test func evenPaceComesFromTheLabelAndTheReset() throws {
    let now = 1_000_000
    #expect(try window("5 小时", left: 50, resetsAt: now + 3600).evenPaceLeft(now: now) == 20)
    #expect(try window("每周 (Opus)", left: 50, resetsAt: now + 7 * 43200).evenPaceLeft(now: now) == 50)
    #expect(try window("每周", left: 50, resetsAt: nil).evenPaceLeft(now: now) == nil)
    #expect(try window("w0", left: 50, resetsAt: now + 60).evenPaceLeft(now: now) == nil)
    #expect(try window("5 小时", left: 50, resetsAt: now + 99999).evenPaceLeft(now: now) == 100)
    #expect(try window("5 小时", left: 50, resetsAt: now - 60).evenPaceLeft(now: now) == 0)
}

@Test func glanceFitsThreeWindowsAndKeepsTheTightest() throws {
    let three = "[\(account("claude", "c", left: [80, 70, 60]))]"
    #expect(try snapshot(accounts: three).summaries[0].glanceWindows.map(\.leftPercent) == [80, 70, 60])
    let accounts = "[\(account("claude", "c", left: [80, 70, 60, 10]))]"
    let glance = try snapshot(accounts: accounts).summaries[0].glanceWindows
    #expect(glance.map(\.leftPercent) == [80, 70, 10])
    let across = "[\(account("codex", "a", left: [80])),\(account("codex", "b", left: [60]))]"
    #expect(try snapshot(accounts: across).summaries[0].glanceWindows.map(\.leftPercent) == [60])
    let stale = "[\(account("codex", "a", stale: true, left: [5])),\(account("codex", "b", left: [70]))]"
    #expect(try snapshot(accounts: stale).summaries[0].glanceWindows.map(\.leftPercent) == [70])
}

@Test func processEnvironmentSkipsThePathAndArguments() {
    var data = withUnsafeBytes(of: Int32(2)) { Data($0) }
    data += Data("/bin/claude\0\0\0\0claude\0REX_BLOCK=not-env\0REX_SESSION=session:1\0REX_BLOCK=a=b\0HOME\0\0".utf8)
    let environment = TerminalOpener.environment(fromProcessArguments: data)
    #expect(environment == ["REX_SESSION": "session:1", "REX_BLOCK": "a=b"])
    #expect(TerminalOpener.environment(fromProcessArguments: Data()).isEmpty)
}

@Test func paneNeedsBothSessionAndBlock() {
    let pane = RexPane(environment: ["REX_SESSION": "s", "REX_BLOCK": "b", "REX_SERVER": "unix:///x"])
    #expect(pane?.session == "s")
    #expect(pane?.block == "b")
    #expect(pane?.server == "unix:///x")
    #expect(RexPane(environment: ["REX_SESSION": "s"]) == nil)
    #expect(RexPane(environment: [:]) == nil)
}

@Test func projectFolderOnlyNamesFoldersThatExist() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    #expect(projectFolder("~")?.standardizedFileURL.path == home)
    #expect(projectFolder("/tmp") != nil)
    #expect(projectFolder("/definitely/not/here") == nil)
    #expect(projectFolder("22 others") == nil)
    #expect(projectFolder("~other") == nil)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(projectFolder(file.path) == nil)
}

@Test func detailsKeepManualResetsAndTheirSource() throws {
    let json = """
    {"generated_at":100,"accounts":[{"agent":"codex","name":"c","stale":false,"windows":[],"manual_resets":2,
      "source":"codex app-server","captured_at":40}],"usage":{"rows":[]}}
    """
    let account = try Snapshot.decode(Data(json.utf8)).accounts[0]
    #expect(account.manualResets == 2)
    #expect(account.source == "codex app-server")
    #expect(account.capturedAt == 40)
}

@Test func cacheHitsCountOnlyWhatWasSent() throws {
    let now = 1_793_900_000
    let today = localDate(epoch: now)
    let rows = "[" + [costRow(today, "codex", "m", fresh: 100, cacheRead: 300, output: 5, cost: nil),
                      costRow("2020-01-01", "codex", "m", fresh: 999, cost: nil)].joined(separator: ",") + "]"
    let snap = try snapshot(rows: rows, now: now)
    let details = AgentDetails(rows: snap.usage.rows, kind: .codex, today: today)
    #expect(details.today.input == 100)
    #expect(details.today.output == 5)
    #expect(details.today.cacheHit == 0.75)
    #expect(AgentDetails(rows: snap.usage.rows, kind: .grok, today: today).today.cacheHit == nil)
}

private func settle() async {
    try? await Task.sleep(nanoseconds: 60_000_000)
}

@MainActor private func selection() -> AgentSelection {
    let selection = AgentSelection(delay: 0.01)
    selection.setRows([.codex: CGRect(x: 6, y: 0, width: 300, height: 50),
                       .claude: CGRect(x: 6, y: 50, width: 300, height: 50)])
    return selection
}

private let onCodex = CGPoint(x: 100, y: 25)
private let onClaude = CGPoint(x: 100, y: 75)
private let onTasks = CGPoint(x: 100, y: 200)

@MainActor @Test func theRowUnderThePointerIsTheOneShown() async {
    let selection = selection()
    selection.pointerMoved(to: onCodex)
    #expect(selection.shown == nil)
    await settle()
    #expect(selection.shown == .codex)
    selection.pointerMoved(to: onClaude)
    await settle()
    #expect(selection.shown == .claude)
    selection.pointerMoved(to: onTasks)
    await settle()
    #expect(selection.shown == nil)
}

@MainActor @Test func movingWithinARowDoesNotRestartTheDelay() async {
    let selection = AgentSelection(delay: 0.03)
    selection.setRows([.codex: CGRect(x: 0, y: 0, width: 300, height: 50)])
    for x in 0..<8 {
        selection.pointerMoved(to: CGPoint(x: x * 10, y: 25))
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(selection.shown == .codex)
}

@MainActor @Test func passingOverARowOnTheWayToTheDetailChangesNothing() async {
    let selection = selection()
    selection.click(.codex)
    selection.pointerMoved(to: onClaude)
    selection.pointerEnteredDetail()
    await settle()
    #expect(selection.shown == .codex)
    selection.pointerMoved(to: onCodex)
    await settle()
    #expect(selection.shown == .codex)
}

@MainActor @Test func comingBackToTheShownRowCancelsTheSwitch() async {
    let selection = selection()
    selection.click(.codex)
    selection.pointerMoved(to: onClaude)
    selection.pointerMoved(to: onCodex)
    await settle()
    #expect(selection.shown == .codex)
}

@MainActor @Test func clickShowsItsRowAtOnceAndStaysPut() {
    let selection = selection()
    selection.pointerMoved(to: onCodex)
    selection.click(.claude)
    #expect(selection.shown == .claude)
    selection.click(.claude)
    #expect(selection.shown == .claude)
    selection.clear()
    #expect(selection.shown == nil)
}

@Test func detailTouchesThePanelOnTheRightWhenThereIsRoom() {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 870)
    let panel = NSRect(x: 400, y: 480, width: 320, height: 382)
    let frame = detailFrame(panel: panel, rowTop: 50, size: NSSize(width: 320, height: 480), screen: screen)
    #expect(frame.minX == panel.maxX - 4)
    #expect(frame.maxY == panel.maxY - 50)
}

@Test func detailGoesLeftOnlyWithoutRoomOnTheRight() {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 870)
    let panel = NSRect(x: 1100, y: 480, width: 320, height: 382)
    let frame = detailFrame(panel: panel, rowTop: 0, size: NSSize(width: 320, height: 480), screen: screen)
    #expect(frame.maxX == panel.minX + 4)
}

@Test func detailStaysOnASecondScreenAndAboveTheBottom() {
    let screen = NSRect(x: -1000, y: 0, width: 1000, height: 600)
    let panel = NSRect(x: -340, y: 210, width: 320, height: 382)
    let frame = detailFrame(panel: panel, rowTop: 300, size: NSSize(width: 320, height: 480), screen: screen)
    #expect(frame.maxX == panel.minX + 4)
    #expect(frame.minY == 8)
    #expect(frame.minX >= screen.minX)
}

@Test func pointerIsMeasuredFromThePanelsTopLeft() {
    let panel = NSRect(x: 1000, y: 400, width: 320, height: 382)
    #expect(pointInPanel(mouse: NSPoint(x: 1010, y: 782), panel: panel) == CGPoint(x: 10, y: 0))
    #expect(pointInPanel(mouse: NSPoint(x: 1320, y: 400), panel: panel) == CGPoint(x: 320, y: 382))
}

@MainActor @Test func aRowReachesBothEdgesOfThePanel() async {
    let selection = selection()
    selection.pointerMoved(to: CGPoint(x: 319, y: 75))
    await settle()
    #expect(selection.shown == .claude)
}

@Test func detailOverlapsTheSameOnEitherSide() {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 870)
    let size = NSSize(width: 320, height: 480)
    let onRight = NSRect(x: 400, y: 480, width: 320, height: 382)
    let onLeft = NSRect(x: 1100, y: 480, width: 320, height: 382)
    let right = detailFrame(panel: onRight, rowTop: 0, size: size, screen: screen)
    let left = detailFrame(panel: onLeft, rowTop: 0, size: size, screen: screen)
    #expect(onRight.maxX - right.minX == left.maxX - onLeft.minX)
}
