import Foundation

public enum Language: String, CaseIterable, Identifiable {
    case system, chinese, english

    static let defaultsKey = "language"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return tr("跟随系统", "System")
        case .chinese: return "中文"
        case .english: return "English"
        }
    }

    init(stored: String?) {
        self = stored.flatMap(Language.init(rawValue:)) ?? .system
    }

    func isChinese(preferred: [String]) -> Bool {
        switch self {
        case .chinese: return true
        case .english: return false
        case .system: return preferred.first?.hasPrefix("zh") ?? false
        }
    }
}

/// Strings live beside their use rather than in `.lproj` tables: the app is a
/// bare executable that build.sh wraps by hand, with no resource bundle.
enum L10n {
    nonisolated(unsafe) static var language = Language.system
    static var isChinese: Bool { language.isChinese(preferred: Locale.preferredLanguages) }
}

func tr(_ chinese: String, _ english: String) -> String {
    L10n.isChinese ? chinese : english
}

/// The backend writes its notes in Chinese for the CLI. Known ones are
/// translated here; a detail it passes along from an agent stays as it came.
func localizedNote(_ note: String) -> String {
    guard !L10n.isChinese else { return note }
    let known = [
        ("尚未接入配额：配置 statusLine 快照，或用 --claude-live 启动（见 README）",
         "Quota not connected: set up the statusLine snapshot, or start with --claude-live (see README)"),
        ("快照中的窗口都已重置，打开 Claude Code 完成一次回复后更新",
         "All snapshot windows have reset. Get one reply from Claude Code to update"),
        ("未登录：运行 grok login", "Not logged in: run grok login"),
        ("登录凭据已过期且未能续期：运行一次 grok 后恢复", "Login expired and could not renew: run grok once to restore"),
        ("接口没有返回每周配额", "The API returned no weekly quota"),
        ("未找到 codex 命令", "codex command not found"),
        ("无法读取实时配额", "Live quota unavailable"),
        ("Claude statusLine 快照", "Claude statusLine snapshot"),
        ("Claude OAuth 用量接口", "Claude OAuth usage API"),
        ("未找到 Claude OAuth 登录凭据", "Claude OAuth credentials not found"),
        ("用量接口返回", "Usage API returned"),
        ("读取实时配额失败", "Live quota read failed"),
        ("读取配额失败", "Quota read failed"),
        ("Codex 会话日志", "Codex session log"),
        ("Grok CLI 用量接口", "Grok CLI usage API"),
        ("（", " ("), ("）", ")"), ("；", "; "),
    ]
    return known.reduce(note) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
}
