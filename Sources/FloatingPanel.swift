import AppKit
import SwiftUI

/// A Spotlight-style panel: takes keyboard focus without activating the app,
/// so the frontmost app stays frontmost and can receive the paste.
final class FloatingPanel: NSPanel {
    init<Content: View>(rootView: Content) {
        // Borderless rather than titled: a hidden title bar still adds height above the grid.
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: true)
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: rootView)
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    override var canBecomeKey: Bool { true }

    // Escape closes, as does clicking anywhere outside the panel.
    override func cancelOperation(_ sender: Any?) { close() }
    override func resignKey() {
        super.resignKey()
        close()
    }
}

@MainActor
final class PanelController {
    private let store: ClipStore
    private lazy var panel = FloatingPanel(rootView:
        HistoryGridView(onCopy: { [weak self] in self?.didCopy() })
            .environment(\.managedObjectContext, store.container.viewContext))

    private var hotKey: GlobalHotKey?
    /// The app that was frontmost when the panel opened, so focus and the paste go back to it.
    private var previousApp: NSRunningApplication?

    init(store: ClipStore) {
        self.store = store
    }

    /// Returns false if the shortcut is taken by another app.
    @discardableResult
    func register(_ shortcut: Shortcut = .saved) -> Bool {
        hotKey?.unregister()
        hotKey = GlobalHotKey(shortcut) { [weak self] in self?.toggle() }
        return hotKey != nil
    }

    func unregister() {
        hotKey?.unregister()
        hotKey = nil
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        // Open on the screen the mouse is on, slightly above center like Spotlight.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                         y: visible.midY - size.height / 2 + visible.height * 0.1))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.close()
    }

    private func didCopy() {
        hide()
        // The panel normally never activates us, but if it did, hand focus back first.
        if NSApp.isActive { previousApp?.activate() }
        AutoPaster.pasteIfEnabled()
    }
}
