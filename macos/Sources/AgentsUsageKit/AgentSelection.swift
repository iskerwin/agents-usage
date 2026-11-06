import Foundation

/// Which agent the detail panel shows: the one under the pointer, else the one
/// clicked. It stays while the pointer is inside the panel, and small delays let
/// the pointer cross the rows and the gap between the panels without flicker.
@MainActor
public final class AgentSelection: ObservableObject {
    @Published public private(set) var shown: AgentKind?

    private let openDelay: TimeInterval
    private let closeDelay: TimeInterval
    private var hovered: AgentKind?
    private var pinned: AgentKind?
    private var inDetail = false
    private var pending: Task<Void, Never>?

    public init(openDelay: TimeInterval = 0.12, closeDelay: TimeInterval = 0.25) {
        self.openDelay = openDelay
        self.closeDelay = closeDelay
    }

    public func hover(_ kind: AgentKind, inside: Bool) {
        if inside {
            hovered = kind
            if shown == nil {
                settle(after: openDelay)
            } else {
                pending?.cancel()
                update()
            }
        } else if hovered == kind {
            hovered = nil
            settle(after: closeDelay)
        }
    }

    public func pointerInDetail(_ inside: Bool) {
        inDetail = inside
        if inside {
            pending?.cancel()
        } else {
            settle(after: closeDelay)
        }
    }

    /// The first click keeps the panel open, the second closes it.
    public func click(_ kind: AgentKind) {
        pending?.cancel()
        if pinned == kind {
            pinned = nil
            hovered = nil
        } else {
            pinned = kind
        }
        update()
    }

    public func clear() {
        pending?.cancel()
        hovered = nil
        pinned = nil
        inDetail = false
        shown = nil
    }

    private func settle(after delay: TimeInterval) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if !Task.isCancelled { self?.update() }
        }
    }

    private func update() {
        let next = hovered ?? (inDetail ? shown : nil) ?? pinned
        if next != shown { shown = next }
    }
}
