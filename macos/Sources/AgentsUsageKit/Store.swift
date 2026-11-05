import AppKit

@MainActor
public final class Store: ObservableObject {
    static let refreshSeconds: UInt64 = 300
    static let requestTimeoutSeconds: UInt64 = 180

    @Published public private(set) var snapshot: Snapshot?
    @Published public private(set) var error: String?
    @Published public private(set) var busy = false
    @Published public private(set) var theme: Theme

    private var backend: Backend!
    private var watchdog: Task<Void, Never>?

    public init() {
        theme = Theme(stored: UserDefaults.standard.string(forKey: Theme.defaultsKey))
        applyTheme()
        backend = Backend(
            onLine: { [weak self] data in Task { @MainActor in self?.received(data) } },
            onExit: { [weak self] in Task { @MainActor in self?.exited() } }
        )
        refresh(force: false)
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.refreshSeconds * 1_000_000_000)
                self?.refresh()
            }
        }
    }

    public func setTheme(_ theme: Theme) {
        self.theme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Theme.defaultsKey)
        applyTheme()
    }

    private func applyTheme() {
        NSApplication.shared.appearance = theme.appearanceName.flatMap(NSAppearance.init(named:))
    }

    public var menuTitle: String {
        snapshot?.menuTitle ?? "—"
    }

    public func refresh(force: Bool = true) {
        guard !busy else { return }
        busy = true
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
            finish(error: failure?["error"] ?? "无法解析后端返回的数据")
        }
    }

    private func exited() {
        if busy { finish(error: "后端已退出") }
    }

    // A failed refresh keeps the last good data on screen, and says so.
    private func finish(error: String?) {
        watchdog?.cancel()
        self.error = error
        busy = false
    }
}
