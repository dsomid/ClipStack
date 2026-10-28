import Foundation

/// UserDefaults keys shared by @AppStorage views and non-view code.
enum Prefs {
    static let historyLimit = "historyLimit"
    static let autoPaste = "autoPaste"
    static let ignoredApps = "ignoredApps"
    static let capturePaused = "capturePaused"
    /// Days to keep unpinned items; 0 keeps them until the history limit pushes them out.
    static let expiryDays = "expiryDays"

    static let defaultHistoryLimit = 500

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            historyLimit: defaultHistoryLimit,
            autoPaste: false,
            capturePaused: false,
            expiryDays: 0,
            // Newline-separated bundle IDs so @AppStorage can bind to it.
            ignoredApps: [
                "com.1password.1password",
                "com.agilebits.onepassword7",
                "com.bitwarden.desktop",
                "com.apple.keychainaccess",
                "com.apple.Passwords",
            ].joined(separator: "\n"),
        ])
    }

    static var ignoredBundleIDs: Set<String> {
        Set((UserDefaults.standard.string(forKey: ignoredApps) ?? "").split(separator: "\n").map(String.init))
    }
}
