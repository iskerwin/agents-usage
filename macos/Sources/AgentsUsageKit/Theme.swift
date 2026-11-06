import AppKit

public enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark

    static let defaultsKey = "theme"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return tr("跟随系统", "System")
        case .light: return tr("亮色", "Light")
        case .dark: return tr("暗色", "Dark")
        }
    }

    /// nil lets the app follow the system again.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    init(stored: String?) {
        self = stored.flatMap(Theme.init(rawValue:)) ?? .system
    }
}
