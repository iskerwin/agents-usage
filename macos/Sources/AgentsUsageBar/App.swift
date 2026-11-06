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
// draws a fixed background, or NSPopover, whose arrow and insets cannot be styled.
@MainActor
private final class AppController: NSObject, NSApplicationDelegate {
    // A click on the status item may reach the outside-click monitor before the
    // button's action runs. That action must not open the panel straight back up.
    private static let reopenGuardSeconds: TimeInterval = 0.25
    private static let gapBelowMenuBar: CGFloat = 2
    private static let screenMargin: CGFloat = 8

    private let store = Store()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = FloatingPanel()
    private var hosting: NSHostingController<StorePanel>?
    private var subscription: AnyCancellable?
    private var outsideClicks: Any?
    private var appSwitches: NSObjectProtocol?
    private var lastClosed = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingController(rootView: StorePanel(store: store, onDismiss: { [weak self] in self?.closePanel() }))
        hosting.sizingOptions = .preferredContentSize
        hosting.view.autoresizingMask = [.width, .height]
        hosting.view.frame = panel.contentView?.bounds ?? .zero
        panel.contentView?.addSubview(hosting.view)
        self.hosting = hosting
        panel.onClose = { [weak self] in self?.closePanel() }

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Agents Usage")
            button.target = self
            button.action = #selector(toggle)
        }
        updateStatusItem()
        subscription = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }  // the value changes after this fires
        }
    }

    private func updateStatusItem() {
        // The icon carries no numbers, so hover and VoiceOver get them in words.
        let description = store.summaries.map { summary in
            "\(summary.kind.title) \(summary.window.map { percentText($0.leftPercent) } ?? "—")"
        }.joined(separator: ", ")
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel(description)
    }

    @objc private func toggle() {
        if panel.isVisible {
            closePanel()
        } else if Date().timeIntervalSince(lastClosed) > Self.reopenGuardSeconds {
            openPanel()
        }
    }

    private func openPanel() {
        store.setPanelOpen(true)
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
        store.setPanelOpen(false)
        panel.orderOut(nil)
        lastClosed = Date()
        statusItem.button?.highlight(false)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        if let appSwitches { NSWorkspace.shared.notificationCenter.removeObserver(appSwitches) }
        appSwitches = nil
    }

    /// Under the status item, kept on screen.
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

        let surface = NSVisualEffectView()
        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.maskImage = Self.roundedMask()
        contentView = surface
    }

    // A borderless window declines key by default, and only a key panel takes the first click.
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onClose()
    }

    /// Stretches to any size, keeping its corners.
    private static func roundedMask() -> NSImage {
        let radius = cornerRadius
        let image = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private struct StorePanel: View {
    @ObservedObject var store: Store
    let onDismiss: () -> Void

    var body: some View {
        PanelView(snapshot: store.snapshot, error: store.error, busy: store.busy,
                  budget: store.monthlyBudget, onBudget: { store.setBudget($0) },
                  theme: store.theme, onTheme: { store.setTheme($0) },
                  language: store.language, onLanguage: { store.setLanguage($0) },
                  onRefresh: { store.refresh() }, onQuit: { NSApplication.shared.terminate(nil) }, onDismiss: onDismiss)
    }
}
