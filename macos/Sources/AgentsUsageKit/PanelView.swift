import AppKit
import SwiftUI

// System colors, so the window's own material shows through and the panel
// follows the appearance in System Settings. Agents keep a fixed hue each.
enum Palette {
    static let ink = Color.primary
    static let muted = Color.secondary
    static let track = Color.primary.opacity(0.13)
    static let green = Color(nsColor: .systemGreen)
    static let amber = Color(nsColor: .systemOrange)
    static let red = Color(nsColor: .systemRed)
    static let hairline = Color.primary.opacity(0.09)

    /// Checked with the dataviz palette validator against both surfaces.
    static func agent(_ kind: AgentKind) -> Color {
        switch kind {
        case .codex: return adaptive(light: 0x2F7BF0, dark: 0x4A8AF0)
        case .claude: return adaptive(light: 0xE8603C, dark: 0xDF6848)
        case .grok: return adaptive(light: 0x3F5597, dark: 0x7A88D0)
        }
    }

    static func level(_ level: String) -> Color {
        switch level {
        case "critical": return red
        case "low": return amber
        default: return green
        }
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            color(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

enum Layout {
    static let panelWidth: CGFloat = 320
    // One size for every state: anything taller scrolls inside, so nothing a
    // click reveals can move the window or the cards above it.
    static let panelHeight: CGFloat = 500
    static let padding: CGFloat = 6
}

public enum PanelPage: Equatable {
    case overview, settings
    case agent(AgentKind)
}

// Not @State: in the current SDK that is a macro whose plugin ships with Xcode
// only, and this package has to build with the Command Line Tools alone.
final class PanelState: ObservableObject {
    @Published var page: PanelPage
    @Published var range = TrendRange.day
    @Published var hoveredBar: Int?
    @Published var hoveredRow: String?
    @Published var showIdleTasks = false
    @Published var budgetText = ""

    init(page: PanelPage) {
        self.page = page
    }

    func setHoveredRow(_ id: String, inside: Bool) {
        if inside {
            hoveredRow = id
        } else if hoveredRow == id {
            hoveredRow = nil
        }
    }
}

public struct PanelView: View {
    public static let caretHeight: CGFloat = 8

    let snapshot: Snapshot?
    let error: String?
    let busy: Bool
    let budget: Double?
    let onBudget: (Double?) -> Void
    let theme: Theme
    let onTheme: (Theme) -> Void
    let language: Language
    let onLanguage: (Language) -> Void
    let onRefresh: () -> Void
    let onQuit: () -> Void
    let maxHeight: CGFloat
    @StateObject private var state: PanelState

    public init(snapshot: Snapshot?, error: String?, busy: Bool,
                budget: Double? = nil, onBudget: @escaping (Double?) -> Void = { _ in },
                theme: Theme = .system, onTheme: @escaping (Theme) -> Void = { _ in },
                language: Language = .system, onLanguage: @escaping (Language) -> Void = { _ in },
                onRefresh: @escaping () -> Void, onQuit: @escaping () -> Void,
                maxHeight: CGFloat = .greatestFiniteMagnitude,
                page: PanelPage = .overview) {
        self.snapshot = snapshot
        self.error = error
        self.busy = busy
        self.budget = budget
        self.onBudget = onBudget
        self.theme = theme
        self.onTheme = onTheme
        self.language = language
        self.onLanguage = onLanguage
        self.onRefresh = onRefresh
        self.onQuit = onQuit
        self.maxHeight = maxHeight
        _state = StateObject(wrappedValue: PanelState(page: page))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelHeader(snapshot: snapshot, error: error, busy: busy, state: state, onRefresh: onRefresh)
            page.frame(maxHeight: .infinity, alignment: .top)
        }
        // Strings are read once per render, so a change of language redraws
        // everything. The state lives above this and survives.
        .id(language)
        .padding(.top, Self.caretHeight + 4)
        .padding(.horizontal, Layout.padding)
        .padding(.bottom, Layout.padding)
        .frame(width: Layout.panelWidth, height: min(Layout.panelHeight, maxHeight), alignment: .top)
        .foregroundStyle(Palette.ink)
    }

    @ViewBuilder
    private var page: some View {
        switch state.page {
        case .overview:
            Dashboard(snapshot: snapshot, error: error, budget: budget, state: state)
        case .agent(let kind):
            if let snapshot {
                AgentPage(kind: kind, snapshot: snapshot, state: state)
            }
        case .settings:
            SettingsPage(budget: budget, onBudget: onBudget, theme: theme, onTheme: onTheme,
                         language: language, onLanguage: onLanguage, onQuit: onQuit, state: state)
        }
    }
}
