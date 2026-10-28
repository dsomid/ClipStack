import AppKit
import Combine
import SwiftUI

/// A full-width shelf along the bottom of the screen. It takes keyboard focus
/// without activating the app, so the frontmost app stays frontmost for the paste.
final class FloatingPanel: NSPanel {
    /// Called on Esc.
    var onDismiss: () -> Void = {}
    /// Called when the panel loses key status; the controller decides whether that means dismiss.
    var onResignKey: () -> Void = {}

    init<Content: View>(rootView: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1200, height: ShelfLayout.height),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: true)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
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

    override func cancelOperation(_ sender: Any?) { onDismiss() }
    override func resignKey() {
        super.resignKey()
        onResignKey()
    }
}

enum ShelfLayout {
    static let height: CGFloat = 340
}

@MainActor
final class PanelController {
    private let store: ClipStore
    let model = ShelfModel()
    private lazy var panel: FloatingPanel = {
        let panel = FloatingPanel(rootView:
            ShelfView(model: model)
                .environment(\.managedObjectContext, store.container.viewContext))
        panel.onDismiss = { [weak self] in self?.hide() }
        panel.onResignKey = { [weak self] in self?.panelResignedKey() }
        return panel
    }()

    private var hotKey: GlobalHotKey?
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var draftObserver: AnyCancellable?
    /// Context menus are open; losing key to them must not close the shelf.
    private var openMenus = 0
    private var isShown = false
    /// The app that was frontmost when the panel opened, so focus and the paste go back to it.
    private var previousApp: NSRunningApplication?

    init(store: ClipStore) {
        self.store = store
        model.onCopy = { [weak self] in self?.didCopy() }
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.openMenus += 1 }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.openMenus = max(0, self.openMenus - 1)
                    // A menu (e.g. a card's context menu) took key status; give it back so
                    // whatever the menu opened, like the category name field, gets typing.
                    if self.openMenus == 0, self.isShown {
                        DispatchQueue.main.async {
                            guard self.isShown else { return }
                            self.panel.makeKey()
                            self.focusEditingField()
                        }
                    }
                }
            },
        ]
        // SwiftUI's focus request is lost when the field appears while a context menu
        // still holds focus (and menu actions run after the menu closes), so focus the
        // name field directly whenever a draft starts.
        draftObserver = model.$categoryDraft.map { $0 != nil }
            .merge(with: model.$renaming.map { $0 != nil })
            .filter { $0 }
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.focusEditingField() }
            }
    }

    /// Focuses the card-title or category-name field, whichever is open. Retries for a
    /// moment because the card row can rebuild (and replace the field) right after it appears.
    private func focusEditingField(attempt: Int = 0) {
        let matches: (NSTextField) -> Bool
        if let item = model.renaming {
            let placeholder = ClipCardView.defaultTitle(for: item)
            matches = { $0.placeholderString == placeholder }
        } else if model.categoryDraft != nil {
            matches = { $0.placeholderString == "Category name" }
        } else {
            return
        }
        if focusTextField(where: matches) || attempt >= 8 { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.focusEditingField(attempt: attempt + 1)
        }
    }

    /// Returns true once a matching field has keyboard focus.
    private func focusTextField(where matches: (NSTextField) -> Bool) -> Bool {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable, matches(field) { return field }
            for subview in view.subviews { if let field = find(subview) { return field } }
            return nil
        }
        guard let content = panel.contentView, let field = find(content) else { return false }
        if field.currentEditor() != nil { return true }
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
        return false // confirm on the next attempt that focus stuck
    }

    /// Losing key status used to close the shelf, but a context menu or a drag in a
    /// background app also takes it. Only clicks elsewhere (see the outside-click
    /// monitor) and losing key with nothing in progress dismiss it.
    private func panelResignedKey() {
        guard isShown, openMenus == 0 else { return }
        if NSEvent.pressedMouseButtons != 0 {
            // Probably a drag from a card: decide once the button is released.
            waitForMouseUp()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.isShown, self.openMenus == 0, !self.panel.isKeyWindow else { return }
            self.hide()
        }
    }

    private func waitForMouseUp() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.isShown else { return }
            if NSEvent.pressedMouseButtons != 0 { return self.waitForMouseUp() }
            // Dropped on the shelf (e.g. a category tab): keep it open and focused.
            if self.panel.frame.contains(NSEvent.mouseLocation) {
                self.panel.makeKey()
            } else if !self.panel.isKeyWindow {
                self.hide()
            }
        }
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
        isShown ? hide() : show()
    }

    func show() {
        guard !isShown else { return }
        isShown = true
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        model.reset()

        // Open on the screen the mouse is on, sliding up from its bottom edge (above the Dock).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let target = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: ShelfLayout.height)
        panel.setFrame(target.offsetBy(dx: 0, dy: -ShelfLayout.height), display: false)
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(target, display: true)
        }
        installKeyMonitor()
        // Global mouse monitors need no permission; they only see clicks in other apps.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.openMenus == 0 else { return }
                self.hide()
            }
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        removeKeyMonitor()
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        let frame = panel.frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(frame.offsetBy(dx: 0, dy: -frame.height), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func didCopy() {
        hide()
        // The panel normally never activates us, but if it did, hand focus back first.
        if NSApp.isActive { previousApp?.activate() }
        AutoPaster.pasteIfEnabled()
    }

    /// Arrow keys move between cards, Return copies, Esc backs out one level.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        let model = self.model
        switch event.keyCode {
        case 53: // Esc
            if model.qrItem != nil { model.qrItem = nil }
            else if model.renaming != nil { model.renaming = nil }
            else if model.recoloring != nil { model.recoloring = nil }
            else if model.categoryDraft != nil { model.categoryDraft = nil }
            else if model.searchActive { model.closeSearch() }
            else { hide() }
            return true
        case _ where model.categoryDraft != nil || model.renaming != nil:
            return false // typing a name
        case 123: // ←
            model.moveSelection(by: -1)
            return true
        case 124: // →
            model.moveSelection(by: 1)
            return true
        case 36, 76: // Return, Enter
            if let item = model.selectedItem { model.copy(item) }
            return true
        default:
            // Typing anywhere on the shelf opens search with that text.
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            guard !model.searchActive, modifiers.isEmpty,
                  let characters = event.characters, !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
            else { return false }
            model.beginSearch(with: characters)
            return true
        }
    }
}
