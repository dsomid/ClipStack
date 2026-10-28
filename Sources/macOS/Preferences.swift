import AppKit
import ApplicationServices
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Sends Cmd+V to the frontmost app after a copy. Requires Accessibility permission.
@MainActor
enum AutoPaster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that opens Privacy & Security > Accessibility.
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func pasteIfEnabled() {
        guard UserDefaults.standard.bool(forKey: Prefs.autoPaste), isTrusted else { return }
        // Small delay so focus has returned to the target app after the panel closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let vKey: CGKeyCode = 9
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: keyDown)
                event?.flags = .maskCommand
                event?.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }
}
