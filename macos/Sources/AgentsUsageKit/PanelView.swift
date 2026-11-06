import AppKit
import SwiftUI

// Monochrome on the system material, which keeps text readable on its own.
// Color only ever means a warning.
enum Palette {
    static let muted = Color.secondary
    static let track = Color.primary.opacity(0.12)
    static let bar = Color.primary.opacity(0.7)
    static let warning = adaptive(light: 0xA85B00, dark: 0xF5A524)
    static let critical = adaptive(light: 0xC4281C, dark: 0xFF6B60)

    static func level(_ level: String) -> Color {
        switch level {
        case "critical": return critical
        case "low": return warning
        default: return .primary
        }
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

public enum Layout {
    static let panelWidth: CGFloat = 320
    static let padding: CGFloat = 6
    static let taskRowHeight: CGFloat = 26
    static let visibleTasks = 5
    public static let detailSize = NSSize(width: 320, height: 480)
}

public enum PanelPage: Equatable {
    case overview, settings
}

// Not @State: in the current SDK that is a macro whose plugin ships with Xcode
// only, and this package has to build with the Command Line Tools alone.
final class PanelState: ObservableObject {
    @Published var page: PanelPage
    @Published var range = TrendRange.day
    @Published var hoveredBar: Int?
    @Published var hoveredRow: String?
    @Published var budgetText = ""
    let onDismiss: () -> Void

    init(page: PanelPage, onDismiss: @escaping () -> Void) {
        self.page = page
        self.onDismiss = onDismiss
    }

    func setHoveredRow(_ id: String, inside: Bool) {
        if inside {
            hoveredRow = id
        } else if hoveredRow == id {
            hoveredRow = nil
        }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

public struct PanelView: View {
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
    let onHeight: (CGFloat) -> Void
    @ObservedObject var selection: AgentSelection
    @StateObject private var state: PanelState

    public init(snapshot: Snapshot?, error: String?, busy: Bool,
                budget: Double? = nil, onBudget: @escaping (Double?) -> Void = { _ in },
                theme: Theme = .system, onTheme: @escaping (Theme) -> Void = { _ in },
                language: Language = .system, onLanguage: @escaping (Language) -> Void = { _ in },
                onRefresh: @escaping () -> Void, onQuit: @escaping () -> Void, onDismiss: @escaping () -> Void = {},
                onHeight: @escaping (CGFloat) -> Void = { _ in }, selection: AgentSelection,
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
        self.onHeight = onHeight
        self.selection = selection
        _state = StateObject(wrappedValue: PanelState(page: page, onDismiss: onDismiss))
    }

    public var body: some View {
        page
            // Strings are read once per render, so a change of language redraws
            // everything. The state lives above this and survives.
            .id(language)
            .padding(Layout.padding)
            .frame(width: Layout.panelWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
            .onPreferenceChange(HeightKey.self) { onHeight($0) }
            .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var page: some View {
        switch state.page {
        case .overview:
            Dashboard(snapshot: snapshot, error: error, busy: busy, budget: budget, onRefresh: onRefresh,
                      selection: selection, state: state)
        case .settings:
            SettingsPage(budget: budget, onBudget: onBudget, theme: theme, onTheme: onTheme,
                         language: language, onLanguage: onLanguage, onQuit: onQuit, state: state)
        }
    }
}

/// One agent's details. A single view for all of them, so the chosen range carries over.
public struct DetailPanelView: View {
    let snapshot: Snapshot?
    let kind: AgentKind?
    let language: Language
    @StateObject private var state: PanelState

    public init(snapshot: Snapshot?, kind: AgentKind?, language: Language = .system, onDismiss: @escaping () -> Void = {}) {
        self.snapshot = snapshot
        self.kind = kind
        self.language = language
        _state = StateObject(wrappedValue: PanelState(page: .overview, onDismiss: onDismiss))
    }

    public var body: some View {
        Group {
            if let snapshot, let kind {
                // Each agent starts scrolled to the top.
                AgentPage(kind: kind, snapshot: snapshot, state: state).id(kind)
            }
        }
        .id(language)
        .padding(Layout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
