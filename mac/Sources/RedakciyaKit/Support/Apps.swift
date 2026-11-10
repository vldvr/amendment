import AppKit

/// Names and icons of installed apps by bundle id, for the menu and the settings window.
@MainActor
enum Apps {
    static func url(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    static func name(_ id: String) -> String {
        guard let url = url(id) else { return id }
        if let b = Bundle(url: url),
           let n = b.localizedInfoDictionary?["CFBundleDisplayName"] as? String ?? b.infoDictionary?["CFBundleDisplayName"] as? String
            ?? b.infoDictionary?["CFBundleName"] as? String, !n.isEmpty {
            return n
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ id: String) -> NSImage {
        guard let url = url(id) else { return NSWorkspace.shared.icon(for: .applicationBundle) }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Asks for an app in /Applications; returns its bundle id.
    static func pick() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Не трогать ссылки из программы"
        panel.prompt = "Добавить"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}
