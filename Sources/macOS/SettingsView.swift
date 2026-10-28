import SwiftUI
import AppKit
import Carbon.HIToolbox

struct SettingsView: View {
    let panel: PanelController
    let store: ClipStore
    let sync: SyncStatus

    var body: some View {
        TabView {
            GeneralSettings(panel: panel, store: store, sync: sync)
                .tabItem { Label("General", systemImage: "gearshape") }
            IgnoredAppsSettings()
                .tabItem { Label("Ignored Apps", systemImage: "hand.raised") }
        }
        .frame(width: 460, height: 340)
    }
}

private struct GeneralSettings: View {
    let panel: PanelController
    let store: ClipStore
    @ObservedObject var sync: SyncStatus

    @AppStorage(Prefs.historyLimit) private var historyLimit = Prefs.defaultHistoryLimit
    @AppStorage(Prefs.autoPaste) private var autoPaste = false
    @AppStorage(Prefs.expiryDays) private var expiryDays = 0
    // @State is a macro and CLT lacks its plugin, so State is used directly.
    private let launchAtLogin = State(initialValue: LaunchAtLogin.isEnabled)
    private let launchError = State<String?>(initialValue: nil)
    private let trusted = State(initialValue: AutoPaster.isTrusted)

    var body: some View {
        Form {
            LabeledContent("Show history") {
                ShortcutRecorder(panel: panel)
            }

            Picker("Keep history", selection: $historyLimit) {
                ForEach([100, 250, 500, 1000, 2500], id: \.self) { Text("\($0) items").tag($0) }
            }
            .onChange(of: historyLimit) { store.applyHistoryLimit() }

            Picker("Delete unpinned items after", selection: $expiryDays) {
                Text("Never").tag(0)
                Text("1 day").tag(1)
                Text("1 week").tag(7)
                Text("1 month").tag(30)
            }
            .onChange(of: expiryDays) { store.applyHistoryLimit() }

            Toggle("Paste automatically after choosing an item", isOn: $autoPaste)
                .onChange(of: autoPaste) { if autoPaste && !AutoPaster.isTrusted { AutoPaster.requestTrust() } }
            if autoPaste && !trusted.wrappedValue {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Needs Accessibility permission.").font(.callout)
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .controlSize(.small)
                }
            }

            Toggle("Launch at login", isOn: launchAtLogin.projectedValue)
                .onChange(of: launchAtLogin.wrappedValue) {
                    do {
                        try LaunchAtLogin.set(launchAtLogin.wrappedValue)
                        launchError.wrappedValue = nil
                    } catch {
                        launchError.wrappedValue = error.localizedDescription
                        launchAtLogin.wrappedValue = LaunchAtLogin.isEnabled
                    }
                }
            if let message = launchError.wrappedValue {
                Text(message).font(.caption).foregroundStyle(.red)
            }

            LabeledContent("iCloud sync") { SyncStatusLabel(state: sync.state) }
        }
        .formStyle(.grouped)
        // Permission can be granted while Settings is open; recheck periodically.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            trusted.wrappedValue = AutoPaster.isTrusted
        }
    }
}

private struct ShortcutRecorder: View {
    let panel: PanelController

    private let shortcut = State(initialValue: Shortcut.saved)
    private let recording = State(initialValue: false)
    private let error = State<String?>(initialValue: nil)
    private let monitor = State<Any?>(initialValue: nil)

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(recording.wrappedValue ? "Type shortcut…" : shortcut.wrappedValue.displayString) {
                    recording.wrappedValue ? stopRecording() : startRecording()
                }
                .frame(minWidth: 110)
                if shortcut.wrappedValue != .defaultShortcut {
                    Button { apply(.defaultShortcut) } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless)
                        .help("Reset to \(Shortcut.defaultShortcut.displayString)")
                }
            }
            if let message = error.wrappedValue {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        error.wrappedValue = nil
        recording.wrappedValue = true
        // Unregister while recording so pressing the current shortcut doesn't open the panel.
        panel.unregister()
        monitor.wrappedValue = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !modifiers.subtracting(.shift).isEmpty else {
                error.wrappedValue = "Include ⌘, ⌥ or ⌃."
                return nil
            }
            apply(Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers))
            return nil
        }
    }

    private func stopRecording() {
        if let token = monitor.wrappedValue { NSEvent.removeMonitor(token) }
        monitor.wrappedValue = nil
        if recording.wrappedValue {
            recording.wrappedValue = false
            panel.register(shortcut.wrappedValue)
        }
    }

    private func apply(_ candidate: Shortcut) {
        if panel.register(candidate) {
            candidate.save()
            shortcut.wrappedValue = candidate
            error.wrappedValue = nil
        } else {
            error.wrappedValue = "\(candidate.displayString) is used by another app."
            panel.register(shortcut.wrappedValue)
        }
        if let token = monitor.wrappedValue { NSEvent.removeMonitor(token) }
        monitor.wrappedValue = nil
        recording.wrappedValue = false
    }
}

private struct IgnoredAppsSettings: View {
    @AppStorage(Prefs.ignoredApps) private var ignoredRaw = ""
    private let selection = State<String?>(initialValue: nil)

    private var bundleIDs: [String] {
        ignoredRaw.split(separator: "\n").map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Copies made in these apps are never saved.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List(bundleIDs, id: \.self, selection: selection.projectedValue) { id in
                AppRow(bundleID: id)
            }
            .listStyle(.bordered)
            HStack(spacing: 0) {
                Button { addApp() } label: { Image(systemName: "plus") }
                Button { remove() } label: { Image(systemName: "minus") }
                    .disabled(selection.wrappedValue == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
        }
        .padding()
    }

    private func addApp() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.application]
        open.directoryURL = URL(fileURLWithPath: "/Applications")
        open.allowsMultipleSelection = true
        guard open.runModal() == .OK else { return }
        var ids = bundleIDs
        for url in open.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !ids.contains(id) { ids.append(id) }
        }
        ignoredRaw = ids.joined(separator: "\n")
    }

    private func remove() {
        guard let id = selection.wrappedValue else { return }
        ignoredRaw = bundleIDs.filter { $0 != id }.joined(separator: "\n")
        selection.wrappedValue = nil
    }
}

private struct AppRow: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            } else {
                Image(systemName: "app.dashed").frame(width: 18, height: 18)
                Text(bundleID).foregroundStyle(.secondary)
            }
        }
        .tag(bundleID)
    }
}

extension Shortcut {
    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + Self.keyName(for: keyCode)
    }

    private static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        default: break
        }
        // Translate via the current keyboard layout so non-QWERTY layouts show the right letter.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw in
            UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(keyCode),
                           UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

private struct SyncStatusLabel: View {
    let state: SyncStatus.State

    var body: some View {
        switch state {
        case .disabled:
            Text("Off — needs an iCloud-signed build")
                .foregroundStyle(.secondary)
                .help("Sign with an Apple Developer provisioning profile to enable sync. See build.sh.")
        case .idle(let lastSync):
            if let lastSync {
                Text("Synced \(lastSync, format: .relative(presentation: .named))")
            } else {
                Text("On")
            }
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Syncing…")
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.icloud")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}
