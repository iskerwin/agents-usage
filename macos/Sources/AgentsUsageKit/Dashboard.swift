import SwiftUI

// One column grid for every quota row, here and on the agent page, so numbers
// line up down the whole panel.
private enum Column {
    static let label: CGFloat = 22
    static let percent: CGFloat = 40
    static let reset: CGFloat = 48
    static let rowInset: CGFloat = 8
}

private let edgeFadeHeight: CGFloat = 10

/// Content that moves under soft edges rather than being cut off.
private struct FadingScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            content().padding(.vertical, edgeFadeHeight)
        }
        // An always-visible scroller would narrow the content when it comes and goes.
        .scrollIndicators(.hidden)
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: edgeFadeHeight)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: edgeFadeHeight)
            }
        }
    }
}

private struct SectionDivider: View {
    var body: some View {
        Divider().padding(.horizontal, Column.rowInset)
    }
}

private func barColor(_ level: String) -> Color {
    level == "ok" ? Palette.ink.opacity(0.82) : Palette.level(level)
}

struct LogoMark: View {
    let kind: AgentKind
    var tinted = false

    var body: some View {
        AgentLogo(kind).fill(tinted ? Palette.agent(kind) : Palette.ink, style: FillStyle(eoFill: true))
    }
}

/// A logo beside a level, read like a battery icon. An agent with no reading
/// has no level at all, which is different from an empty one.
public struct StatusMeters: View {
    let summaries: [AgentSummary]

    public init(summaries: [AgentSummary]) {
        self.summaries = summaries
    }

    public var body: some View {
        HStack(spacing: 8) {
            if summaries.isEmpty {
                Text(verbatim: "—")
            }
            ForEach(summaries) { summary in
                HStack(spacing: 2.5) {
                    LogoMark(kind: summary.kind).frame(width: 13, height: 13)
                    if let window = summary.window { meter(window) }
                }
                .opacity(summary.window == nil || summary.stale ? 0.45 : 1)
            }
        }
        .padding(.horizontal, 6)
        .fixedSize()
    }

    private func meter(_ window: Snapshot.QuotaWindow) -> some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(Palette.ink.opacity(0.25))
            Capsule()
                .fill(barColor(window.level))
                .frame(height: max(3.5, 15 * min(max(window.leftPercent, 0), 100) / 100))
        }
        .frame(width: 3.5, height: 15)
    }
}

public struct StatusBarView: View {
    @ObservedObject var store: Store

    public init(store: Store) {
        self.store = store
    }

    public var body: some View {
        StatusMeters(summaries: store.summaries)
    }
}

struct PanelHeader: View {
    let snapshot: Snapshot?
    let error: String?
    let busy: Bool
    @ObservedObject var state: PanelState
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            switch state.page {
            case .overview: overviewTitle
            case .agent(let kind): back { agentTitle(kind) }
            case .settings: back { Text(tr("设置", "Settings")).font(.system(size: 13, weight: .semibold)) }
            }
            Spacer(minLength: 4)
            if busy {
                ProgressView().controlSize(.mini).frame(width: 24, height: 24)
            } else {
                iconButton("arrow.clockwise", help: tr("刷新", "Refresh"), action: onRefresh)
            }
            if state.page != .settings {
                iconButton("gearshape", help: tr("设置", "Settings")) { state.page = .settings }
            }
        }
        .padding(.leading, Column.rowInset)
        .padding(.trailing, 2)
        .frame(height: 26)
    }

    private var overviewTitle: some View {
        HStack(spacing: 6) {
            Text(verbatim: "Agents Usage").font(.system(size: 13, weight: .semibold))
            if let problem = statusProblem {
                Circle().fill(problem.color).frame(width: 6, height: 6)
                Text(problem.text).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
        }
    }

    /// Silent while live: words only when something is off.
    private var statusProblem: (text: String, color: Color)? {
        if error != nil { return (tr("刷新失败", "Refresh failed"), Palette.red) }
        guard let snapshot else { return (tr("读取中", "Loading"), Palette.track) }
        let age = Int(Date().timeIntervalSince1970) - snapshot.generatedAt
        if age < 60 { return nil }
        return (tr("\(durationText(seconds: age))前", "\(durationText(seconds: age)) ago"), Palette.amber)
    }

    private func agentTitle(_ kind: AgentKind) -> some View {
        HStack(spacing: 6) {
            LogoMark(kind: kind).frame(width: 14, height: 14)
            Text(kind.title).font(.system(size: 13, weight: .semibold))
        }
    }

    private func back<Title: View>(@ViewBuilder title: () -> Title) -> some View {
        Button {
            state.page = .overview
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                title()
            }
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.leftArrow, modifiers: .command)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct Dashboard: View {
    let snapshot: Snapshot?
    let error: String?
    let budget: Double?
    @ObservedObject var state: PanelState

    var body: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 6) {
                errorLine
                VStack(spacing: 2) {
                    ForEach(snapshot.summaries) { AgentRow(summary: $0, snapshot: snapshot, state: state) }
                }
                SectionDivider()
                CostRow(snapshot: snapshot, budget: budget).padding(.horizontal, Column.rowInset)
                SectionDivider()
                TrendSection(snapshot: snapshot, agent: nil, state: state).padding(.horizontal, Column.rowInset)
                SectionDivider()
                FadingScroll {
                    TaskList(snapshot: snapshot, agent: nil, state: state)
                }
                .padding(.vertical, -edgeFadeHeight + 4)
                .frame(maxHeight: .infinity)
            }
        } else if let error {
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(Palette.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Column.rowInset)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    @ViewBuilder
    private var errorLine: some View {
        if let error {
            Text(tr("显示上次数据：\(error)", "Showing last data: \(error)"))
                .font(.system(size: 11))
                .foregroundStyle(Palette.red)
                .lineLimit(2)
                .padding(.horizontal, Column.rowInset)
        }
    }
}

private func planText(_ plan: String) -> String {
    plan == plan.lowercased() ? plan.capitalized : plan
}

/// One agent at a glance. The whole row opens its page.
struct AgentRow: View {
    let summary: AgentSummary
    let snapshot: Snapshot
    @ObservedObject var state: PanelState

    private var hoverID: String { "agent-" + summary.id }

    var body: some View {
        Button {
            state.hoveredRow = nil
            state.page = .agent(summary.kind)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                title
                ForEach(summary.glanceWindows) { QuotaRow(window: $0, now: snapshot.generatedAt, stale: summary.stale) }
                if summary.window == nil { missing }
            }
            .padding(.horizontal, Column.rowInset)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background {
                if state.hoveredRow == hoverID {
                    RoundedRectangle(cornerRadius: 10).fill(Palette.track.opacity(0.5))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { state.setHoveredRow(hoverID, inside: $0) }
    }

    private var title: some View {
        HStack(spacing: 0) {
            LogoMark(kind: summary.kind)
                .frame(width: 14, height: 14)
                .frame(width: Column.label, alignment: .leading)
            Text(summary.kind.title).font(.system(size: 13, weight: .medium))
            if let plan = summary.accounts.first?.plan {
                Text(planText(plan)).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.leading, 6)
            }
            if summary.stale {
                Text(tr("已过期", "Stale")).font(.system(size: 11)).foregroundStyle(Palette.amber).padding(.leading, 6)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .opacity(state.hoveredRow == hoverID ? 1 : 0)
        }
    }

    private var missing: some View {
        let note = summary.accounts.first?.note.map(localizedNote) ?? "—"
        return Text(note)
            .font(.system(size: 11))
            .foregroundStyle(Palette.muted)
            .lineLimit(1)
            .padding(.leading, Column.label)
            .help(note)
    }
}

/// `5h  ━━━━━━┃━━──  83%  1h 54m`
struct QuotaRow: View {
    let window: Snapshot.QuotaWindow
    let now: Int
    var stale = false

    var body: some View {
        let label = shortWindowLabel(window.label)
        let pace = window.evenPaceLeft(now: now)
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: Column.label, alignment: .leading)
                .help(label)
            QuotaBar(fraction: window.leftPercent / 100, color: barColor(window.level), pace: pace.map { $0 / 100 })
                .help(pace.map { tr("匀速用量的话，现在应剩 \(percentText($0))", "At an even pace, \(percentText($0)) would be left now") } ?? "")
            Text(levelMark(window.level) + percentText(window.leftPercent))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(window.level == "ok" ? Palette.ink : Palette.level(window.level))
                .lineLimit(1)
                .fixedSize()
                .frame(width: Column.percent, alignment: .trailing)
            Text(window.resetsAt.map { durationText(seconds: $0 - now) } ?? "—")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .frame(width: Column.reset, alignment: .trailing)
        }
        .frame(height: 17)
        .opacity(stale ? 0.5 : 1)
    }
}

/// A level with a notch at where an even pace would have it by now.
struct QuotaBar: View {
    let fraction: Double
    let color: Color
    var pace: Double?
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    Capsule().fill(color).frame(width: width * clamped(fraction))
                    if let pace {
                        Rectangle().frame(width: 3).offset(x: width * clamped(pace) - 1.5).blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
                if let pace {
                    Capsule()
                        .fill(Palette.muted)
                        .frame(width: 1.5, height: height + 4)
                        .offset(x: width * clamped(pace) - 0.75)
                }
            }
        }
        .frame(height: height)
    }

    private func clamped(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, 0), 1))
    }
}

struct CostRow: View {
    let snapshot: Snapshot
    let budget: Double?

    var body: some View {
        let costs = snapshot.costs
        HStack(alignment: .top, spacing: 0) {
            figure(tr("今日 API", "Today API")) { amount(costs.today) }
            figure(tr("本月 API", "Month API")) { month(costs.month) }
        }
        .help(costNote(costs))
    }

    private func figure<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ≈ because these are list prices applied to the logs, not a bill.
    private func amount(_ value: Double?) -> some View {
        Text(value.map { "≈" + moneyText($0) } ?? "—")
            .font(.system(size: 18, weight: .semibold).monospacedDigit())
            .lineLimit(1)
    }

    private func month(_ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                amount(value)
                if let budget {
                    Text(verbatim: "/ \(moneyText(budget))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
            }
            if let budget, let value {
                QuotaBar(fraction: value / budget, color: value > budget ? Palette.red : Palette.ink, height: 3)
            }
        }
    }

    private func costNote(_ costs: CostSummary) -> String {
        let note = tr("按公开 API 价估算，不是账单", "Estimated at public API prices, not a bill")
        guard !costs.unpricedModels.isEmpty else { return note }
        return note + tr("；未计入 ", "; excludes ") + costs.unpricedModels.joined(separator: tr("、", ", "))
    }
}

struct TrendSection: View {
    let snapshot: Snapshot
    let agent: AgentKind?
    @ObservedObject var state: PanelState

    private static let chartHeight: CGFloat = 46

    var body: some View {
        let trend = Trend(usage: snapshot.usage, range: state.range, agent: agent, now: snapshot.generatedAt)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                readout(trend)
                Spacer(minLength: 0)
                rangePicker
            }
            chart(trend)
            axis(trend)
        }
    }

    /// The range's totals, or the bar under the pointer.
    private func readout(_ trend: Trend) -> some View {
        Group {
            if let hovered = state.hoveredBar, trend.bars.indices.contains(hovered) {
                Text(verbatim: "\(trend.bars[hovered].label) · \(compactText(trend.bars[hovered].total)) tokens")
            } else {
                Text(verbatim: "\(compactText(trend.total)) tokens · " + tr("\(trend.sessions) 次会话", "\(trend.sessions) sessions"))
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Palette.muted)
        .lineLimit(1)
    }

    private func axis(_ trend: Trend) -> some View {
        ZStack {
            HStack {
                Text(trend.startLabel)
                Spacer(minLength: 0)
                Text(tr("现在", "Now"))
            }
            if agent == nil { legend }
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(Palette.muted)
    }

    /// The agents' own marks in their chart colors, in stacking order.
    private var legend: some View {
        HStack(spacing: 7) {
            ForEach(AgentKind.allCases) { kind in
                LogoMark(kind: kind, tinted: true).frame(width: 11, height: 11).help(kind.title)
            }
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 0) {
            ForEach(TrendRange.allCases) { range in
                Button {
                    state.range = range
                    state.hoveredBar = nil
                } label: {
                    Text(range.title)
                        .font(.system(size: 11, weight: state.range == range ? .semibold : .regular))
                        .foregroundStyle(state.range == range ? Palette.ink : Palette.muted)
                        .frame(width: 30, height: 18)
                        .background(state.range == range ? Palette.track : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize()
    }

    private func chart(_ trend: Trend) -> some View {
        let peak = max(trend.bars.map(\.total).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(trend.bars) { bar in
                stack(bar, peak: peak)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.chartHeight, alignment: .bottom)
                    .background(state.hoveredBar == bar.id ? Palette.track.opacity(0.6) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 2))
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            state.hoveredBar = bar.id
                        } else if state.hoveredBar == bar.id {
                            state.hoveredBar = nil
                        }
                    }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
    }

    private func stack(_ bar: TrendBar, peak: Int) -> some View {
        // The first agent sits on the baseline, as in the legend's order.
        VStack(spacing: 1) {
            ForEach(AgentKind.allCases.reversed()) { kind in
                let amount = bar.amounts[kind] ?? 0
                if amount > 0 {
                    Rectangle()
                        .fill(Palette.agent(kind))
                        .frame(height: max(1.5, (Self.chartHeight - 3) * CGFloat(amount) / CGFloat(peak)))
                }
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 1.5, topTrailingRadius: 1.5))
    }
}

struct TaskList: View {
    let snapshot: Snapshot
    let agent: AgentKind?
    @ObservedObject var state: PanelState

    private var candidates: [Snapshot.AgentTask] {
        (snapshot.tasks ?? []).filter { agent == nil || $0.kind == agent }
    }

    var body: some View {
        let shown = candidates.filter { state.showIdleTasks || $0.isRunning }
        let idle = candidates.count { !$0.isRunning }
        VStack(alignment: .leading, spacing: 0) {
            if shown.isEmpty {
                Text(snapshot.tasks == nil ? tr("无法读取进程列表", "Could not list processes") : tr("没有运行中的任务", "No running tasks"))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, Column.rowInset)
                    .padding(.vertical, 4)
            }
            ForEach(shown) { row($0) }
            if idle > 0 { idleToggle(idle) }
        }
    }

    private func idleToggle(_ count: Int) -> some View {
        Button {
            state.showIdleTasks.toggle()
        } label: {
            HStack(spacing: 3) {
                Text(tr("\(count) 个空闲", "\(count) idle"))
                Image(systemName: state.showIdleTasks ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.muted)
            .padding(.leading, Column.label + Column.rowInset)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ task: Snapshot.AgentTask) -> some View {
        let hoverID = "task-\(task.pid)"
        return Button {
            TerminalOpener.open(task)
        } label: {
            HStack(spacing: 0) {
                if let kind = task.kind {
                    LogoMark(kind: kind)
                        .frame(width: 14, height: 14)
                        .frame(width: Column.label, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(task.displayTitle).font(.system(size: 12)).lineLimit(1)
                    Text(subtitle(task)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .opacity(state.hoveredRow == hoverID ? 1 : 0)
            }
            .padding(.horizontal, Column.rowInset)
            .frame(height: 34)
            .opacity(task.isRunning ? 1 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background {
                if state.hoveredRow == hoverID {
                    RoundedRectangle(cornerRadius: 10).fill(Palette.track.opacity(0.5))
                }
            }
        }
        .buttonStyle(.plain)
        .help(tr("打开所在终端：\(task.project)", "Open its terminal: \(task.project)"))
        .onHover { state.setHoveredRow(hoverID, inside: $0) }
    }

    private func subtitle(_ task: Snapshot.AgentTask) -> String {
        let state = task.isRunning ? durationText(seconds: snapshot.generatedAt - task.since) : tr("空闲", "Idle")
        return "\(task.projectName) · \(state)"
    }
}

/// Everything known about one agent.
struct AgentPage: View {
    let kind: AgentKind
    let snapshot: Snapshot
    @ObservedObject var state: PanelState

    var body: some View {
        let details = AgentDetails(rows: snapshot.usage.rows, kind: kind, today: snapshot.today)
        FadingScroll {
            VStack(alignment: .leading, spacing: 10) {
                if let summary = snapshot.summaries.first(where: { $0.kind == kind }) {
                    ForEach(summary.accounts) { account($0).padding(.horizontal, Column.rowInset) }
                    SectionDivider()
                }
                stats(details).padding(.horizontal, Column.rowInset)
                SectionDivider()
                TrendSection(snapshot: snapshot, agent: kind, state: state).padding(.horizontal, Column.rowInset)
                if !details.models.isEmpty || !details.projects.isEmpty {
                    SectionDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        if !details.models.isEmpty { ranking(tr("本月模型", "Models this month"), details.models) }
                        if !details.projects.isEmpty { ranking(tr("本月项目", "Projects this month"), details.projects) }
                    }
                    .padding(.horizontal, Column.rowInset)
                }
                SectionDivider()
                TaskList(snapshot: snapshot, agent: kind, state: state)
            }
        }
    }

    private func account(_ account: Snapshot.Account) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let identity = [account.plan.map(planText), account.email].compactMap { $0 }.joined(separator: " · ")
            if !identity.isEmpty {
                Text(identity)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(account.windows) { QuotaRow(window: $0, now: snapshot.generatedAt, stale: account.stale) }
            if let manual = account.manualResets, manual > 0 {
                caption(tr("\(manual) 次手动重置可用", "\(manual) manual resets available"), Palette.muted)
            }
            if account.stale, let captured = account.capturedAt {
                let age = durationText(seconds: snapshot.generatedAt - captured)
                caption(tr("数据已过期，\(age)前更新", "Stale, updated \(age) ago"), Palette.amber)
            }
            if let note = account.note {
                caption(localizedNote(note), Palette.muted)
            }
        }
    }

    private func caption(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    private func stats(_ details: AgentDetails) -> some View {
        let tokens = snapshot.tokensToday(agent: kind)
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                stat(tr("今日 API", "Today API"), details.todayCost.map { "≈" + moneyText($0) } ?? "—")
                stat(tr("本月 API", "Month API"), details.monthCost.map { "≈" + moneyText($0) } ?? "—")
                stat(tr("本月请求", "Requests"), compactText(details.requests))
            }
            GridRow {
                stat(tr("今日输入", "Input today"), compactText(tokens.input))
                stat(tr("今日输出", "Output today"), compactText(tokens.output))
                stat(tr("缓存命中", "Cache hits"), tokens.cacheHit.map { percentText($0 * 100) } ?? "—")
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            Text(value).font(.system(size: 14, weight: .semibold).monospacedDigit()).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ranking(_ title: String, _ entries: [AgentDetails.Entry]) -> some View {
        let peak = max(entries.map(\.tokens).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted)
            ForEach(entries) { entry in
                HStack(spacing: 8) {
                    Text(entry.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 118, alignment: .leading)
                        .help(entry.name)
                    QuotaBar(fraction: Double(entry.tokens) / Double(peak), color: Palette.agent(kind), height: 4)
                    Text(compactText(entry.tokens))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Palette.muted)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }
}

struct SettingsPage: View {
    let budget: Double?
    let onBudget: (Double?) -> Void
    let theme: Theme
    let onTheme: (Theme) -> Void
    let language: Language
    let onLanguage: (Language) -> Void
    let onQuit: () -> Void
    @ObservedObject var state: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(tr("月预算", "Monthly budget")) {
                Text(verbatim: "$").font(.system(size: 12)).foregroundStyle(Palette.muted)
                TextField(tr("未设置", "Not set"), text: $state.budgetText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onChange(of: state.budgetText) { _, text in onBudget(parseBudget(text)) }
            }
            SectionDivider()
            row(tr("外观", "Appearance")) {
                Picker(tr("外观", "Appearance"), selection: Binding(get: { theme }, set: onTheme)) {
                    ForEach(Theme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SectionDivider()
            row(tr("语言", "Language")) {
                Picker(tr("语言", "Language"), selection: Binding(get: { language }, set: onLanguage)) {
                    ForEach(Language.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SectionDivider()
            Button(action: onQuit) {
                Text(tr("退出", "Quit"))
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Column.rowInset)
        }
        .padding(.top, 6)
        .onAppear {
            state.budgetText = budget.map { String(format: "%g", $0) } ?? ""
        }
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 0)
            control()
        }
        .padding(.horizontal, Column.rowInset)
    }
}
