import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut via Carbon's RegisterEventHotKey, which needs no
/// Accessibility or Input Monitoring permission (unlike NSEvent global monitors).
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags

    static let defaultShortcut = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: [.command, .shift])

    private static let keyCodeKey = "hotKeyCode"
    private static let modifiersKey = "hotKeyModifiers"

    static var saved: Shortcut {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeKey) != nil else { return defaultShortcut }
        return Shortcut(keyCode: UInt32(defaults.integer(forKey: keyCodeKey)),
                        modifiers: NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: modifiersKey))))
    }

    func save() {
        UserDefaults.standard.set(Int(keyCode), forKey: Self.keyCodeKey)
        UserDefaults.standard.set(Int(modifiers.rawValue), forKey: Self.modifiersKey)
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}

@MainActor
final class GlobalHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var eventHandlerInstalled = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// Returns nil if another app already owns the shortcut.
    init?(_ shortcut: Shortcut, action: @escaping () -> Void) {
        Self.installEventHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C5053) /* "CLPS" */, id: id)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        Self.handlers[id] = action
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.handlers[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
