import AppKit

/// Which agent the detail panel shows, like a menu and its submenu: the row under
/// the pointer, found from where the pointer is rather than from what entered or
/// left, so any movement puts it right. A short delay lets the pointer cross other
/// rows on its way into the panel.
@MainActor
public final class AgentSelection: ObservableObject {
    @Published public private(set) var shown: AgentKind?

    private let delay: TimeInterval
    private var rows: [AgentKind: CGRect] = [:]
    private var target: AgentKind?
    private var pending: Task<Void, Never>?

    public init(delay: TimeInterval = 0.12) {
        self.delay = delay
    }

    /// In the panel's own coordinates, measured from its top left.
    func setRows(_ rows: [AgentKind: CGRect]) {
        self.rows = rows
    }

    /// Where a row starts, measured down from the top of the panel.
    public func rowTop(_ kind: AgentKind) -> CGFloat {
        rows[kind]?.minY ?? 0
    }

    /// The pointer moved inside the main panel. Leaving it changes nothing, as with a submenu.
    public func pointerMoved(to point: CGPoint) {
        let next = rows.first { $0.value.contains(point) }?.key
        guard next != target else { return }
        target = next
        pending?.cancel()
        guard next != shown else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.delay ?? 0) * 1_000_000_000))
            if !Task.isCancelled { self?.shown = next }
        }
    }

    /// The pointer made it into the detail panel, so what it crossed on the way does not count.
    public func pointerEnteredDetail() {
        pending?.cancel()
        target = shown
    }

    public func click(_ kind: AgentKind) {
        pending?.cancel()
        target = kind
        shown = kind
    }

    public func clear() {
        pending?.cancel()
        target = nil
        shown = nil
    }
}

/// Touching the panel at the row's height: to its right, or to its left when the
/// screen has no room, and moved up rather than running off the bottom.
public func detailFrame(panel: NSRect, rowTop: CGFloat, size: NSSize, screen: NSRect,
                        overlap: CGFloat = 4, margin: CGFloat = 8) -> NSRect {
    let height = min(size.height, screen.height - margin * 2)
    var x = panel.maxX - overlap
    if x + size.width > screen.maxX - margin {
        x = max(panel.minX + overlap - size.width, screen.minX + margin)
    }
    let y = max(panel.maxY - rowTop - height, screen.minY + margin)
    return NSRect(x: x, y: y, width: size.width, height: height)
}
