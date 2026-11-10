import AppKit

/// Access to Downloads, Desktop and the screenshot folder. macOS asks once per folder on the first read,
/// so Desk reads them only after the person pressed «Разрешить» (first-run window or settings).
@MainActor
enum DeskAccess {
    enum State: Equatable { case notAsked, granted, denied }

    static func state(_ folders: DeskFolders = .system()) -> State {
        guard Prefs.shared.deskFoldersAsked else { return .notAsked }
        return folders.folders.allSatisfy(readable) ? .granted : .denied
    }

    /// One read of each folder on a click: the questions of macOS appear right then.
    static func request(_ folders: DeskFolders = .system()) {
        Prefs.shared.deskFoldersAsked = true
        for f in folders.folders { _ = readable(f) }
    }

    static func readable(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    static func status(_ s: State) -> String {
        switch s {
        case .notAsked: return "macOS ещё не спрашивала"
        case .granted: return "есть"
        case .denied: return "нет, Стол не работает"
        }
    }

    static func openSystemSettings() {
        let urls = ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders",
                    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }
}
