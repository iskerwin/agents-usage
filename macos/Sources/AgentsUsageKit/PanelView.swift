import AppKit
import SwiftUI

// System colors, so the window's own material shows through and the panel
// follows the appearance in System Settings. The heatmap alone keeps a fixed
// hue, Dracula purple.
enum Palette {
    static let ink = Color.primary
    static let muted = Color.secondary
    static let track = Color(nsColor: .tertiaryLabelColor)
    static let zero = Color(nsColor: .quaternaryLabelColor)
    static let green = Color(nsColor: .systemGreen)
    static let amber = Color(nsColor: .systemOrange)
    static let red = Color(nsColor: .systemRed)
    static let heat = [0.22, 0.38, 0.55, 0.75, 1].map { draculaPurple.opacity($0) }
    // The strong steps are light in either appearance, so they take dark text.
    static let heatText: [Color] = [.primary, .primary, .primary, heatDarkText, heatDarkText]
    private static let draculaPurple = Color(red: 0xBD / 255, green: 0x93 / 255, blue: 0xF9 / 255)
    private static let heatDarkText = Color(red: 0x1D / 255, green: 0x1E / 255, blue: 0x27 / 255)

    static func level(_ level: String) -> Color {
        switch level {
        case "critical": return red
        case "low": return amber
        default: return green
        }
    }
}

enum Layout {
    static let panelWidth: CGFloat = 320
    static let padding: CGFloat = 14
    static let inner = panelWidth - padding * 2
}

public struct PanelView: View {
    let snapshot: Snapshot?
    let error: String?
    let busy: Bool
    let theme: Theme
    let onTheme: (Theme) -> Void
    let onRefresh: () -> Void
    let onQuit: () -> Void
    @StateObject private var expansion = HistoryExpansion()

    public init(snapshot: Snapshot?, error: String?, busy: Bool,
                theme: Theme = .system, onTheme: @escaping (Theme) -> Void = { _ in },
                onRefresh: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.snapshot = snapshot
        self.error = error
        self.busy = busy
        self.theme = theme
        self.onTheme = onTheme
        self.onRefresh = onRefresh
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot {
                ForEach(snapshot.accounts) { account in
                    AccountView(account: account, now: snapshot.generatedAt, labelWidth: labelWidth(snapshot))
                }
                let history = UsageHistory(rows: snapshot.usage.rows, firstDate: snapshot.usage.firstDate)
                // The history takes the heatmap's place, in exactly its space,
                // so opening it does not change the panel's size.
                HeatmapView(heatmap: Heatmap(rows: snapshot.usage.rows, firstDate: snapshot.usage.firstDate,
                                             today: localDate(epoch: snapshot.generatedAt)))
                    .opacity(expansion.isOpen ? 0 : 1)
                    .allowsHitTesting(!expansion.isOpen)
                    .overlay {
                        if expansion.isOpen {
                            ScrollView {
                                HistoryDetail(history: history, accounts: snapshot.accounts, now: snapshot.generatedAt)
                                    .padding(.trailing, 2)
                            }
                        }
                    }
                HistoryRow(total: history.billable, expansion: expansion)
            }
            footer
        }
        .padding(Layout.padding)
        .frame(width: Layout.panelWidth, alignment: .leading)
        .foregroundStyle(Palette.ink)
    }

    private func labelWidth(_ snapshot: Snapshot) -> CGFloat {
        snapshot.accounts.contains { $0.windows.contains { $0.label.contains("(") } } ? 88 : 48
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error {
                Text(snapshot == nil ? error : "刷新失败，显示上次数据：\(error)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            themeMenu
            if busy {
                ProgressView().controlSize(.small)
            } else {
                iconButton("arrow.clockwise", help: "刷新", action: onRefresh)
            }
            iconButton("power", help: "退出", action: onQuit)
        }
        .frame(minHeight: 20)
    }

    private var themeMenu: some View {
        Menu {
            Picker("外观", selection: Binding(get: { theme }, set: onTheme)) {
                ForEach(Theme.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("外观")
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct AccountView: View {
    let account: Snapshot.Account
    let now: Int
    let labelWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(account.name).font(.system(size: 13, weight: .semibold))
                if let plan = account.plan {
                    Text(plan.uppercased()).font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                if account.stale {
                    Spacer(minLength: 0)
                    Text("◷ 已过期").font(.system(size: 11)).foregroundStyle(Palette.amber)
                }
            }
            ForEach(account.windows) { window in
                row(window)
            }
            if let note = account.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ window: Snapshot.QuotaWindow) -> some View {
        HStack(spacing: 8) {
            Text(window.label)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .frame(width: labelWidth, alignment: .leading)
            bar(window)
            Text(levelMark(window.level) + percentText(window.leftPercent))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(window.level == "ok" ? Palette.ink : Palette.level(window.level))
                .frame(width: 52, alignment: .trailing)
            Text(window.resetsAt.map { resetText(seconds: $0 - now) } ?? "—")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.muted)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private func bar(_ window: Snapshot.QuotaWindow) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(Palette.level(window.level))
                    .frame(width: geometry.size.width * window.leftPercent / 100)
            }
        }
        .frame(height: 6)
    }
}

// Not @State: in the current SDK that is a macro whose plugin ships with Xcode
// only, and this package has to build with the Command Line Tools alone.
final class HeatmapSelection: ObservableObject {
    @Published var month: YearMonth?
    @Published var hovered: Int?
}

struct HeatmapView: View {
    let heatmap: Heatmap
    @StateObject private var selection = HeatmapSelection()

    private static let gap: CGFloat = 3
    private static let cellSize = (Layout.inner - gap * 6) / 7

    private var month: YearMonth? { selection.month ?? heatmap.latestMonth }

    var body: some View {
        if let month {
            VStack(alignment: .leading, spacing: 8) {
                header(month)
                grid(heatmap.cells(for: month))
            }
        }
    }

    private func header(_ month: YearMonth) -> some View {
        HStack(spacing: 4) {
            navButton("chevron.left", to: month.shifted(by: -1), enabled: heatmap.earliestMonth.map { month > $0 } ?? false)
            Text(verbatim: "\(month.year) 年 \(month.month) 月")
                .font(.system(size: 13, weight: .semibold))
            navButton("chevron.right", to: month.shifted(by: 1), enabled: heatmap.latestMonth.map { month < $0 } ?? false)
            Spacer(minLength: 0)
            Text(compactText(heatmap.total(for: month)))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Palette.muted)
        }
    }

    private func navButton(_ symbol: String, to target: YearMonth, enabled: Bool) -> some View {
        Button {
            selection.hovered = nil
            selection.month = target
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? Palette.ink : Palette.track)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func grid(_ slots: [DayCell?]) -> some View {
        VStack(spacing: Self.gap) {
            HStack(spacing: Self.gap) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { name in
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .frame(width: Self.cellSize)
                }
            }
            ForEach(0..<Heatmap.weeks, id: \.self) { week in
                HStack(spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { column in
                        let index = week * 7 + column
                        cell(slots[index])
                            .frame(width: Self.cellSize, height: Self.cellSize)
                            .onHover { inside in
                                if inside {
                                    selection.hovered = index
                                } else if selection.hovered == index {
                                    selection.hovered = nil
                                }
                            }
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if let hovered = selection.hovered, let cell = slots[hovered], cell.state != .future, cell.state != .noLog {
                tooltip(cell).offset(tooltipOffset(hovered, rows: agentUsage(cell).count + 1))
            }
        }
    }

    @ViewBuilder
    private func cell(_ cell: DayCell?) -> some View {
        if let cell {
            ZStack {
                switch cell.state {
                case .future, .noLog:
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Palette.track, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                case .zero:
                    RoundedRectangle(cornerRadius: 6).fill(Palette.zero)
                case .level(let level):
                    RoundedRectangle(cornerRadius: 6).fill(Palette.heat[level])
                }
                Text(verbatim: "\(cell.day)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(textColor(cell.state))
            }
            .overlay {
                if cell.isToday {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Palette.ink, lineWidth: 1.5)
                        .padding(-2)
                }
            }
        } else {
            Color.clear
        }
    }

    private func textColor(_ state: DayState) -> Color {
        switch state {
        case .future, .noLog, .zero: return Palette.muted
        case .level(let level): return Palette.heatText[level]
        }
    }

    private func tooltip(_ cell: DayCell) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(cell.date.dropFirst(5).prefix(2).drop { $0 == "0" }) 月 \(cell.day) 日")
                .font(.system(size: 12, weight: .semibold))
            ForEach(agentUsage(cell), id: \.name) { tooltipRow($0.name, compactText($0.amount)) }
            tooltipRow("请求", cell.usage.requests.formatted())
        }
        .padding(8)
        .frame(width: Self.tooltipWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.track))
        .allowsHitTesting(false)
    }

    private func agentUsage(_ cell: DayCell) -> [(name: String, amount: Int)] {
        [("Claude Code", cell.usage.claude), ("Codex", cell.usage.codex), ("Grok", cell.usage.grok)]
            .filter { $0.1 > 0 }
    }

    private func tooltipRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 12))
    }

    private static let tooltipWidth: CGFloat = 150

    private func tooltipOffset(_ index: Int, rows: Int) -> CGSize {
        let step = Self.cellSize + Self.gap
        let x = min(CGFloat(index % 7) * step, Layout.inner - Self.tooltipWidth)
        // Above the cell. The weekday row is about one gap plus 14pt tall.
        let tooltipHeight = CGFloat(rows + 1) * 18 + 8
        let y = 17 + CGFloat(index / 7) * step - tooltipHeight - 4
        return CGSize(width: x, height: y)
    }
}

final class HistoryExpansion: ObservableObject {
    @Published var isOpen = false
}

struct HistoryRow: View {
    let total: Int
    @ObservedObject var expansion: HistoryExpansion

    var body: some View {
        Button {
            expansion.isOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Text("历史总量").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text(compactText(total))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Palette.muted)
                Image(systemName: expansion.isOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 14)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct HistoryDetail: View {
    let history: UsageHistory
    let accounts: [Snapshot.Account]
    let now: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let first = history.firstDate {
                Text(verbatim: "\(first) 起 · \(history.activeDays) 天有记录")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            stats
            table("Agent", history.agents)
            table("模型", history.models)
            table("项目", history.projects)
            ForEach(accounts) { account($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stats: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                stat("不含缓存读取", compactText(history.billable))
                stat("全部", compactText(history.total))
                stat("输出", compactText(history.output))
            }
            GridRow {
                stat("缓存命中", history.cacheHit.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                stat("请求", history.requests.formatted())
                stat("会话", history.sessions.formatted())
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 14, weight: .semibold).monospacedDigit())
            Text(label).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func table(_ title: String, _ entries: [UsageHistory.Entry]) -> some View {
        VStack(spacing: 4) {
            tableRow(Text(title), Text("不含缓存"), Text("输出"), Text("请求"))
                .foregroundStyle(Palette.muted)
            ForEach(entries) { entry in
                tableRow(
                    Text(entry.name).foregroundStyle(Palette.ink),
                    Text(compactText(entry.billable)).foregroundStyle(Palette.ink).fontWeight(.semibold),
                    Text(compactText(entry.output)).foregroundStyle(Palette.muted),
                    Text(entry.requests.formatted()).foregroundStyle(Palette.muted)
                )
            }
        }
    }

    private func tableRow(_ name: Text, _ billable: Text, _ output: Text, _ requests: Text) -> some View {
        HStack(spacing: 6) {
            name.lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            billable.frame(width: 54, alignment: .trailing)
            output.frame(width: 46, alignment: .trailing)
            requests.frame(width: 44, alignment: .trailing)
        }
        .font(.system(size: 11).monospacedDigit())
    }

    private func account(_ account: Snapshot.Account) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(account.name).font(.system(size: 12, weight: .semibold))
            Group {
                if let email = account.email { Text(email) }
                ForEach(account.windows) { window in
                    if let resetsAt = window.resetsAt {
                        Text(verbatim: "\(window.label) · \(clockText(epoch: resetsAt, now: now)) 重置")
                    }
                }
                if let manual = account.manualResets, manual > 0 { Text(verbatim: "\(manual) 次手动重置可用") }
                if let source = account.source, let captured = account.capturedAt {
                    Text(verbatim: "\(source) · \(ageText(seconds: now - captured))")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.muted)
        }
    }
}
