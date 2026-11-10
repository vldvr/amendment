import AppKit

/// «Вставка из других программ» (macOS 15.4+). Before the first alert macOS reports `.notAsked`;
/// the first programmatic read shows the alert and moves the app to `.asks`; System Settings can then
/// set always allow or always deny. Older macOS never asks.
public enum ClipboardAccess: Equatable, Sendable {
    case notNeeded, notAsked, asks, allowed, denied

    @MainActor
    public static func current(_ pb: NSPasteboard = .general) -> ClipboardAccess {
        guard #available(macOS 15.4, *) else { return .notNeeded }
        switch pb.accessBehavior {
        case .default: return .notAsked
        case .ask: return .asks
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .denied
        @unknown default: return .asks
        }
    }

    /// Links can be cleaned without asking every time.
    public var works: Bool { self == .allowed || self == .notNeeded }

    /// Settings window, row «Вставка из других программ».
    public var status: String {
        switch self {
        case .notNeeded: return "не нужна в этой версии macOS"
        case .notAsked: return "macOS ещё не спрашивала"
        case .asks: return "macOS спрашивает при каждой ссылке"
        case .allowed: return "разрешена"
        case .denied: return "запрещена"
        }
    }

    /// The disabled first line in the menu when Editing cannot work quietly; nil when all is well.
    public var menuWarning: String? {
        switch self {
        case .denied: return "Вставка запрещена: ссылки не чистятся"
        case .asks: return "macOS спрашивает про каждую ссылку"
        case .notNeeded, .notAsked, .allowed: return nil
        }
    }

    /// What to do about it, as the menu item that opens System Settings.
    public var menuFix: String? {
        switch self {
        case .denied, .asks: return "Разрешить вставку в настройках macOS…"
        case .notNeeded, .notAsked, .allowed: return nil
        }
    }

    /// One look at the clipboard on a click of the person, so the alert of macOS appears right then.
    /// The data is read and dropped. Returns false when the clipboard is empty: macOS has nothing to ask about.
    @MainActor
    @discardableResult
    public static func request(_ pb: NSPasteboard = .general) -> Bool {
        guard let item = pb.pasteboardItems?.first, let type = item.types.first else { return false }
        _ = item.data(forType: type)
        return true
    }

    /// System Settings → Privacy & Security → Paste from Other Apps.
    public static func openSystemSettings() {
        let urls = ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard",
                    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }
}
