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

enum Layout {
    static let panelWidth: CGFloat = 320
    // One size for every state: anything taller scrolls inside, so nothing a
    // click reveals can move the window or the rows above it.
    static let panelHeight: CGFloat = 440
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
    @StateObject private var state: PanelState

    public init(snapshot: Snapshot?, error: String?, busy: Bool,
                budget: Double? = nil, onBudget: @escaping (Double?) -> Void = { _ in },
                theme: Theme = .system, onTheme: @escaping (Theme) -> Void = { _ in },
                language: Language = .system, onLanguage: @escaping (Language) -> Void = { _ in },
                onRefresh: @escaping () -> Void, onQuit: @escaping () -> Void, onDismiss: @escaping () -> Void = {},
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
        _state = StateObject(wrappedValue: PanelState(page: page, onDismiss: onDismiss))
    }

    public var body: some View {
        page
            // Strings are read once per render, so a change of language redraws
            // everything. The state lives above this and survives.
            .id(language)
            .padding(Layout.padding)
            .frame(width: Layout.panelWidth, height: Layout.panelHeight, alignment: .top)
    }

    @ViewBuilder
    private var page: some View {
        switch state.page {
        case .overview:
            Dashboard(snapshot: snapshot, error: error, busy: busy, budget: budget, onRefresh: onRefresh, state: state)
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
