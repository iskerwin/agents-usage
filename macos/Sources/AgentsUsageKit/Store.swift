import AppKit

@MainActor
public final class Store: ObservableObject {
    static let refreshSeconds: UInt64 = 300
    static let requestTimeoutSeconds: UInt64 = 180
    static let openPanelRefreshSeconds: UInt64 = 15
    static let budgetKey = "monthlyBudget"

    @Published public private(set) var snapshot: Snapshot?
    @Published public private(set) var error: String?
    @Published public private(set) var busy = false
    @Published public private(set) var theme: Theme
    @Published public private(set) var monthlyBudget: Double?
    @Published public private(set) var language: Language

    private var backend: Backend!
    private var watchdog: Task<Void, Never>?
    private var openPanelRefresh: Task<Void, Never>?
    private var inFlight = false

    public init() {
        theme = Theme(stored: UserDefaults.standard.string(forKey: Theme.defaultsKey))
        language = Language(stored: UserDefaults.standard.string(forKey: Language.defaultsKey))
        L10n.language = language
        let budget = UserDefaults.standard.double(forKey: Self.budgetKey)
        monthlyBudget = budget > 0 ? budget : nil
        applyTheme()
        backend = Backend(
            onLine: { [weak self] data in Task { @MainActor in self?.received(data) } },
            onExit: { [weak self] in Task { @MainActor in self?.exited() } }
        )
        refresh(force: false)
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.refreshSeconds * 1_000_000_000)
                self?.refresh(force: false)
            }
        }
    }

    /// Running tasks go out of date in seconds, so an open panel keeps checking.
    /// A plain request is cheap: unchanged logs are not parsed again and quotas
    /// keep their own rate limits.
    public func setPanelOpen(_ open: Bool) {
        openPanelRefresh?.cancel()
        guard open else { return }
        refresh(force: false)
        openPanelRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.openPanelRefreshSeconds * 1_000_000_000)
                if !Task.isCancelled { self?.refresh(force: false) }
            }
        }
    }

    public func setLanguage(_ language: Language) {
        L10n.language = language
        self.language = language
        UserDefaults.standard.set(language.rawValue, forKey: Language.defaultsKey)
    }

    public func setBudget(_ budget: Double?) {
        monthlyBudget = budget
        if let budget {
            UserDefaults.standard.set(budget, forKey: Self.budgetKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.budgetKey)
        }
    }

    public var summaries: [AgentSummary] {
        snapshot?.summaries ?? []
    }

    public func setTheme(_ theme: Theme) {
        self.theme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Theme.defaultsKey)
        applyTheme()
    }

    private func applyTheme() {
        NSApplication.shared.appearance = theme.appearanceName.flatMap(NSAppearance.init(named:))
    }

    public func refresh(force: Bool = true) {
        guard !inFlight else {
            if force { busy = true }  // the answer on its way is what the spinner waits for
            return
        }
        inFlight = true
        busy = force
        do {
            try backend.send(force ? "force" : "get")
        } catch {
            finish(error: error.localizedDescription)
            return
        }
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.requestTimeoutSeconds * 1_000_000_000)
            if !Task.isCancelled { self?.backend.stop() }
        }
    }

    private func received(_ data: Data) {
        if let snapshot = try? Snapshot.decode(data) {
            self.snapshot = snapshot
            finish(error: nil)
        } else {
            let failure = try? JSONDecoder().decode([String: String].self, from: data)
            finish(error: failure?["error"] ?? tr("无法解析后端返回的数据", "Could not parse the backend's response"))
        }
    }

    private func exited() {
        if inFlight { finish(error: tr("后端已退出", "The backend exited")) }
    }

    // A failed refresh keeps the last good data on screen, and says so.
    private func finish(error: String?) {
        watchdog?.cancel()
        self.error = error
        inFlight = false
        busy = false
    }
}
