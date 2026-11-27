import SwiftUI

// One column grid for every quota row, here and in the detail panel, so numbers
// line up.
private enum Column {
    static let label: CGFloat = 22
    static let windowLabel: CGFloat = 40  // room for a model name such as Sonnet
    static let percent: CGFloat = 58
    static let reset: CGFloat = 48
    static let rowInset: CGFloat = 8
}

struct AgentRowFrames: PreferenceKey {
    static let defaultValue: [AgentKind: CGRect] = [:]
    static func reduce(value: inout [AgentKind: CGRect], nextValue: () -> [AgentKind: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct SectionDivider: View {
    var body: some View {
        Divider().padding(.horizontal, Column.rowInset)
    }
}

private extension View {
    /// Highlights under the pointer.
    func rowHover(id: String, state: PanelState, selected: Bool = false) -> some View {
        background {
            if selected || state.hoveredRow == id {
                RoundedRectangle(cornerRadius: 8).fill(Palette.track)
            }
        }
        .onHover { state.setHoveredRow(id, inside: $0) }
    }
}

private struct RowButton<Label: View>: View {
    let id: String
    @ObservedObject var state: PanelState
    var selected = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, Column.rowInset)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .rowHover(id: id, state: state, selected: selected)
    }
}

/// Reveals a project's folder, leaving the panel the way opening a terminal does.
private func openFolder(_ url: URL, state: PanelState) {
    NSWorkspace.shared.open(url)
    state.onDismiss()
}

struct LogoMark: View {
    let kind: AgentKind

    var body: some View {
        AgentLogo(kind).fill(.primary, style: FillStyle(eoFill: true)).frame(width: 14, height: 14)
    }
}

/// Back to the overview.
struct PageHeader<Title: View>: View {
    @ObservedObject var state: PanelState
    @ViewBuilder let title: () -> Title

    var body: some View {
        Button {
            state.page = .overview
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                title().font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            .frame(height: 28)
            .padding(.horizontal, Column.rowInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.leftArrow, modifiers: .command)
    }
}

struct Dashboard: View {
    let snapshot: Snapshot?
    let error: String?
    let busy: Bool
    let budget: Double?
    let onRefresh: () -> Void
    @ObservedObject var selection: AgentSelection
    @ObservedObject var state: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.critical)
                    .lineLimit(3)
                    .padding(.horizontal, Column.rowInset)
            }
            if let snapshot {
                VStack(spacing: 2) {
                    ForEach(snapshot.summaries) { AgentRow(summary: $0, snapshot: snapshot, selection: selection, state: state) }
                }
                tasks(snapshot)
            } else if error == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            }
            SectionDivider()
            footer
        }
    }

    /// Grows with the tasks up to a limit, then scrolls, so the panel only takes the room it needs.
    @ViewBuilder
    private func tasks(_ snapshot: Snapshot) -> some View {
        if let tasks = snapshot.tasks {
            if !tasks.isEmpty {
                SectionDivider()
                ScrollView {
                    TaskList(snapshot: snapshot, agent: nil, state: state).padding(.horizontal, Layout.padding)
                }
                // Out to the panel's edge, so the scroller passes beside the text and not over it.
                .padding(.horizontal, -Layout.padding)
                .frame(height: CGFloat(min(tasks.count, Layout.visibleTasks)) * Layout.taskRowHeight)
            }
        } else {
            SectionDivider()
            TaskList(snapshot: snapshot, agent: nil, state: state)
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            if let snapshot {
                CostLine(costs: snapshot.costs, budget: budget)
            }
            Spacer(minLength: 4)
            if busy {
                ProgressView().controlSize(.mini).frame(width: 24, height: 24)
            } else {
                iconButton("arrow.clockwise", label: tr("刷新", "Refresh"), action: onRefresh)
            }
            iconButton("gearshape", label: tr("设置", "Settings")) {
                selection.clear()
                state.page = .settings
            }
        }
        .padding(.leading, Column.rowInset)
        .padding(.trailing, 2)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// One agent at a glance. Pointing at it or clicking it shows its details beside the panel.
struct AgentRow: View {
    let summary: AgentSummary
    let snapshot: Snapshot
    @ObservedObject var selection: AgentSelection
    @ObservedObject var state: PanelState

    var body: some View {
        RowButton(id: "agent-" + summary.id, state: state, selected: selection.shown == summary.kind) {
            selection.click(summary.kind)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    LogoMark(kind: summary.kind).frame(width: Column.label, alignment: .leading)
                    Text(summary.kind.title).font(.system(size: 13, weight: .medium))
                    if summary.stale { StaleMark().padding(.leading, 6) }
                    Spacer(minLength: 0)
                }
                ForEach(summary.glanceWindows) { QuotaRow(window: $0, now: snapshot.generatedAt, stale: summary.stale) }
                if summary.window == nil {
                    Text(summary.accounts.first?.note.map(localizedNote) ?? "—")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                        .padding(.leading, Column.label)
                }
            }
            .padding(.vertical, 5)
        }
        .background(GeometryReader { geometry in
            Color.clear.preference(key: AgentRowFrames.self,
                                   value: [summary.kind: geometry.frame(in: .named(Layout.panelSpace))])
        })
    }
}

private struct StaleMark: View {
    var body: some View {
        Text(tr("已过期", "Stale")).font(.system(size: 11)).foregroundStyle(Palette.warning)
    }
}

/// `5h  ━━━━━━┃━━──  83%  1h 54m`
struct QuotaRow: View {
    let window: Snapshot.QuotaWindow
    let now: Int
    var stale = false

    var body: some View {
        let label = window.rowLabel
        let pace = window.evenPaceLeft(now: now)
        let percent = levelMark(window.level) + percentText(window.leftPercent)
        let reset = window.resetsAt.map { durationText(seconds: $0 - now) } ?? "—"
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: Column.windowLabel, alignment: .leading)
                .help(window.fullLabel)
            QuotaBar(fraction: window.leftPercent / 100, color: window.level == "ok" ? Palette.bar : Palette.level(window.level), pace: pace.map { $0 / 100 })
            Text(percent)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.level(window.level))
                .lineLimit(1)
                .frame(width: Column.percent, alignment: .trailing)
            Text(reset)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .frame(width: Column.reset, alignment: .trailing)
        }
        .frame(height: 17)
        .opacity(stale ? 0.5 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("\(label)，剩余 \(percent)，\(reset) 后重置", "\(label), \(percent) left, resets in \(reset)"))
        .accessibilityValue(pace.map { tr("匀速用量应剩 \(percentText($0))", "\(percentText($0)) at an even pace") } ?? "")
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

/// `今日 ≈$0.55  本月 ≈$257 / $500`. ≈ because these are list prices applied to
/// the logs, not a bill.
struct CostLine: View {
    let costs: CostSummary
    var budget: Double?

    var body: some View {
        HStack(spacing: 12) {
            figure(tr("今日", "Today"), costs.today)
            figure(tr("本月", "Month"), costs.month, limit: budget)
        }
        .font(.system(size: 12).monospacedDigit())
        .lineLimit(1)
        .help(costs.unpricedModels.isEmpty ? "" : tr("未计入 ", "Excludes ") + costs.unpricedModels.joined(separator: tr("、", ", ")))
    }

    private func figure(_ title: String, _ value: Double?, limit: Double? = nil) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(Palette.muted)
            Text(value.map { "≈" + moneyText($0) } ?? "—")
                .fontWeight(.medium)
                .foregroundStyle(over(value, limit) ? Palette.critical : Color.primary)
            if let limit {
                Text(verbatim: "/ \(moneyText(limit))").foregroundStyle(Palette.muted)
            }
        }
    }

    private func over(_ value: Double?, _ limit: Double?) -> Bool {
        guard let value, let limit else { return false }
        return value > limit
    }
}

struct TrendSection: View {
    let snapshot: Snapshot
    let agent: AgentKind
    @ObservedObject var state: PanelState

    private static let chartHeight: CGFloat = 46

    var body: some View {
        let trend = Trend(usage: snapshot.usage, range: state.range, agent: agent, now: snapshot.generatedAt)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                readout(trend)
                Spacer(minLength: 0)
                rangePicker
            }
            chart(trend)
        }
    }

    /// The range's total, or the bar under the pointer.
    private func readout(_ trend: Trend) -> some View {
        Group {
            if let hovered = state.hoveredBar, trend.bars.indices.contains(hovered) {
                Text(verbatim: "\(trend.bars[hovered].label)  \(compactText(trend.bars[hovered].total))")
            } else {
                Text(verbatim: "\(compactText(trend.total)) tokens · " + tr("\(trend.sessions) 次会话", trend.sessions == 1 ? "1 session" : "\(trend.sessions) sessions"))
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .lineLimit(1)
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
                        .foregroundStyle(state.range == range ? Color.primary : Palette.muted)
                        .frame(width: 30, height: 18)
                        .contentShape(Rectangle())
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
                UnevenRoundedRectangle(topLeadingRadius: 1.5, topTrailingRadius: 1.5)
                    .fill(state.hoveredBar == bar.id ? Color.primary : Palette.bar)
                    .frame(height: bar.total > 0 ? max(1.5, Self.chartHeight * CGFloat(bar.total) / CGFloat(peak)) : 0)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.chartHeight, alignment: .bottom)
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
    }
}

/// Running first, as the backend sends them; idle ones are the faint ones.
struct TaskList: View {
    let snapshot: Snapshot
    let agent: AgentKind?
    @ObservedObject var state: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let tasks = snapshot.tasks {
                ForEach(tasks.filter { agent == nil || $0.kind == agent }) { row($0) }
            } else {
                // Not the same as having no tasks, which shows nothing.
                Text(tr("无法读取进程列表", "Could not list processes"))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, Column.rowInset)
            }
        }
    }

    /// The row goes to the terminal, the folder inside it to Finder: a button
    /// wins over the tap around it, and nesting two buttons would not work.
    /// Details add how long each task has been running.
    private func row(_ task: Snapshot.AgentTask) -> some View {
        HStack(spacing: 0) {
            if let kind = task.kind {
                LogoMark(kind: kind).frame(width: Column.label, alignment: .leading)
            }
            if agent == nil {
                title(task).accessibilityAddTraits(.isButton)
                Spacer(minLength: 8)
                projectLink(task)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    title(task).accessibilityAddTraits(.isButton)
                    HStack(spacing: 4) {
                        projectLink(task)
                        Text(verbatim: "· " + (task.isRunning ? durationText(seconds: snapshot.generatedAt - task.since) : tr("空闲", "Idle")))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: agent == nil ? Layout.taskRowHeight : 40)
        .opacity(task.isRunning ? 1 : 0.5)
        .padding(.horizontal, Column.rowInset)
        .contentShape(Rectangle())
        .onTapGesture {
            TerminalOpener.open(task)
            state.onDismiss()
        }
        .rowHover(id: "task-\(task.pid)", state: state)
    }

    private func title(_ task: Snapshot.AgentTask) -> some View {
        Text(task.displayTitle).font(.system(size: 12)).lineLimit(1)
    }

    @ViewBuilder
    private func projectLink(_ task: Snapshot.AgentTask) -> some View {
        let label = HStack(spacing: 3) {
            Image(systemName: "folder").font(.system(size: 10))
            if task.title != nil || agent != nil { Text(task.projectName).lineLimit(1) }
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.muted)
        .frame(minHeight: 18)
        .contentShape(Rectangle())
        .help(task.project)

        if let folder = projectFolder(task.project) {
            Button { openFolder(folder, state: state) } label: { label }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("打开目录 \(task.project)", "Open folder \(task.project)"))
        } else {
            label
        }
    }
}

/// Everything known about one agent, in a panel of a fixed height that scrolls.
struct AgentPage: View {
    let kind: AgentKind
    let snapshot: Snapshot
    @ObservedObject var state: PanelState

    var body: some View {
        let details = AgentDetails(rows: snapshot.usage.rows, kind: kind, today: snapshot.today)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                LogoMark(kind: kind)
                Text(kind.title).font(.system(size: 13, weight: .semibold))
            }
            .frame(height: 28)
            .padding(.horizontal, Layout.padding + Column.rowInset)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let summary = snapshot.summaries.first(where: { $0.kind == kind }) {
                        ForEach(summary.accounts) { account($0).padding(.horizontal, Column.rowInset) }
                        SectionDivider()
                    }
                    TrendSection(snapshot: snapshot, agent: kind, state: state).padding(.horizontal, Column.rowInset)
                    SectionDivider()
                    // Under the month's cost, the rankings need no title to say which period they cover.
                    VStack(alignment: .leading, spacing: 10) {
                        CostLine(costs: details.costs).padding(.horizontal, Column.rowInset)
                        if !details.models.isEmpty { ranking(details.models, symbol: "cpu") }
                        if !details.projects.isEmpty { ranking(details.projects, symbol: "folder", opens: projectFolder) }
                    }
                    SectionDivider()
                    activity(details).padding(.horizontal, Column.rowInset)
                    if snapshot.tasks?.contains(where: { $0.kind == kind }) != false {
                        SectionDivider()
                        TaskList(snapshot: snapshot, agent: kind, state: state)
                    }
                }
                .padding(.bottom, 6)
                .padding(.horizontal, Layout.padding)
            }
        }
    }

    private func activity(_ details: AgentDetails) -> some View {
        VStack(spacing: 4) {
            fact(tr("本月请求", "Requests this month"), compactText(details.requests))
            fact(tr("本月会话", "Sessions this month"), compactText(details.sessions))
            fact(tr("今日输入", "Input today"), compactText(details.today.input))
            fact(tr("今日输出", "Output today"), compactText(details.today.output))
            fact(tr("今日缓存命中", "Cache hits today"), details.today.cacheHit.map { percentText($0 * 100) } ?? "—")
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(Palette.muted).lineLimit(1)
            Spacer(minLength: 0)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12).monospacedDigit())
    }

    private func account(_ account: Snapshot.Account) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let identity = [account.plan.map(planText), account.email].compactMap { $0 }.joined(separator: " · ")
            if !identity.isEmpty || account.stale {
                HStack(spacing: 6) {
                    Text(identity)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if account.stale { StaleMark() }
                }
            }
            ForEach(account.windows) { QuotaRow(window: $0, now: snapshot.generatedAt, stale: account.stale) }
            if let note = account.note {
                Text(localizedNote(note))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let manual = account.manualResets {
                fact(tr("手动重置", "Manual resets"), tr("\(manual) 次可用", "\(manual) available"))
            }
            if let source = account.source {
                fact(tr("数据来源", "Source"), localizedNote(source))
            }
            if let captured = account.capturedAt {
                let age = durationText(seconds: snapshot.generatedAt - captured)
                fact(tr("更新于", "Updated"), tr("\(age)前", "\(age) ago"))
            }
        }
    }

    private func planText(_ plan: String) -> String {
        plan == plan.lowercased() ? plan.capitalized : plan
    }

    private func ranking(_ entries: [AgentDetails.Entry], symbol: String,
                         opens folder: @escaping (String) -> URL? = { _ in nil }) -> some View {
        let peak = max(entries.map(\.tokens).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                let row = rankingRow(entry, symbol: symbol, peak: peak)
                if let url = folder(entry.name) {
                    RowButton(id: "project-" + entry.id, state: state) {
                        openFolder(url, state: state)
                    } label: {
                        row
                    }
                    .accessibilityLabel(tr("打开目录 \(entry.name)", "Open folder \(entry.name)"))
                } else {
                    row.padding(.horizontal, Column.rowInset)
                }
            }
        }
    }

    private func rankingRow(_ entry: AgentDetails.Entry, symbol: String, peak: Int) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 13)
                Text(entry.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 136, alignment: .leading)
            .help(entry.name)
            QuotaBar(fraction: Double(entry.tokens) / Double(peak), color: Palette.bar, height: 4)
            Text(compactText(entry.tokens))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.muted)
                .frame(width: 40, alignment: .trailing)
        }
        .frame(height: 22)
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
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(state: state) { Text(tr("设置", "Settings")) }
            row(tr("月预算", "Monthly budget")) {
                Text(verbatim: "$").font(.system(size: 12)).foregroundStyle(Palette.muted)
                TextField(tr("月预算", "Monthly budget"), text: $state.budgetText, prompt: Text(verbatim: ""))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onChange(of: state.budgetText) { _, text in onBudget(parseBudget(text)) }
            }
            row(tr("外观", "Appearance")) {
                Picker(tr("外观", "Appearance"), selection: Binding(get: { theme }, set: onTheme)) {
                    ForEach(Theme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
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
