import AgentsUsageKit
import AppKit
import Combine
import SwiftUI

@main
enum AgentsUsageBarApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) { app.run() }
    }
}

// A status item and a panel of our own rather than MenuBarExtra, whose window
// draws a fixed background, or NSPopover, whose arrow cannot be removed.
@MainActor
private final class AppController: NSObject, NSApplicationDelegate {
    // A click on the status item may reach the outside-click monitor before the
    // button's action runs. That action must not open the panel straight back up.
    private static let reopenGuardSeconds: TimeInterval = 0.25
    private static let gapBelowMenuBar: CGFloat = 6
    private static let screenMargin: CGFloat = 8

    private let store = Store()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = FloatingPanel()
    private var hosting: NSHostingController<StorePanel>?
    private var subscription: AnyCancellable?
    private var sizeObservation: NSKeyValueObservation?
    private var outsideClicks: Any?
    private var appSwitches: NSObjectProtocol?
    private var lastClosed = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingController(rootView: StorePanel(store: store))
        hosting.sizingOptions = .preferredContentSize
        hosting.view.autoresizingMask = [.width, .height]
        hosting.view.frame = panel.contentView?.bounds ?? .zero
        panel.contentView?.addSubview(hosting.view)
        self.hosting = hosting
        sizeObservation = hosting.observe(\.preferredContentSize) { [weak self] _, _ in
            DispatchQueue.main.async {
                if self?.panel.isVisible == true { self?.placePanel() }
            }
        }
        panel.onClose = { [weak self] in self?.closePanel() }

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "用量")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(toggle)
        }
        updateTitle()
        subscription = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle() }  // the value changes after this fires
        }
    }

    private func updateTitle() {
        statusItem.button?.title = store.menuTitle
    }

    @objc private func toggle() {
        if panel.isVisible {
            closePanel()
        } else if Date().timeIntervalSince(lastClosed) > Self.reopenGuardSeconds {
            openPanel()
        }
    }

    private func openPanel() {
        placePanel()
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        // Clicks on this app's own views, the status item included, never reach this monitor.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
        appSwitches = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastClosed = Date()
        statusItem.button?.highlight(false)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        if let appSwitches { NSWorkspace.shared.notificationCenter.removeObserver(appSwitches) }
        appSwitches = nil
    }

    /// Under the status item, kept on screen, with the top edge fixed as the height changes.
    private func placePanel() {
        guard let button = statusItem.button, let window = button.window, let hosting else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = hosting.view.fittingSize
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let x = min(max(anchor.midX - size.width / 2, visible.minX + Self.screenMargin),
                    visible.maxX - size.width - Self.screenMargin)
        let top = anchor.minY - Self.gapBelowMenuBar
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }
}

private final class FloatingPanel: NSPanel {
    private static let cornerRadius: CGFloat = 12

    var onClose: () -> Void = {}

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = Self.roundedMask()
        contentView = glass
    }

    // A borderless window declines key by default, and only a key panel takes the first click.
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onClose()
    }

    private static func roundedMask() -> NSImage {
        let side = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }
}

private struct StorePanel: View {
    @ObservedObject var store: Store

    var body: some View {
        PanelView(snapshot: store.snapshot, error: store.error, busy: store.busy,
                  theme: store.theme, onTheme: { store.setTheme($0) },
                  onRefresh: { store.refresh() }, onQuit: { NSApplication.shared.terminate(nil) })
    }
}
