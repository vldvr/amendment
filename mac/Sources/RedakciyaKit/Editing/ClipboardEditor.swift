import AppKit

/// What happened to one copy, for the card and the menu.
public struct EditingEvent: Sendable {
    public let original: String
    public let cleaned: CleanedLink
    /// App the link was copied in: bundle id and display name.
    public let appID: String
    public let appName: String
}

/// Redaktura on the clipboard (spec/link-rules.md, «Делящаяся» программа and «Вернуть хвост»).
///
/// Watches the change counter, which macOS lets anyone read. Contents are read only when the copy
/// happened in a sharing app and the types say it is plain text, so the paste prompt of macOS 15.4+
/// shows up only for links that may need cleaning.
@MainActor
public final class ClipboardEditor {
    public static let cleanedType = NSPasteboard.PasteboardType("com.vldvr.redakciya.cleaned")
    /// Password managers and clipboard tools mark private items this way (nspasteboard.org).
    static let privateTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]

    public private(set) var rules: LinkRules
    private var cleaner: LinkCleaner
    private let pb: NSPasteboard
    private let frontmost: @MainActor () -> (id: String, name: String)?
    private var timer: Timer?
    private var lastCount: Int
    private var appAtLastTick: String?
    private var ownCounts: Set<Int> = []

    /// Bundle ids the person excluded. Stored on the device only.
    public var excludedApps: Set<String> = []
    public var paused = false
    /// Until the first-run window is done, do not read: the paste alert of macOS should come from the
    /// person's click there, not from a random copy before it.
    public var holdUntilAsked = false
    public var onEvent: (EditingEvent) -> Void = { _ in }

    /// The last cleaned copy, kept in memory only: the original may carry the sender's tag.
    public private(set) var last: (event: EditingEvent, snapshot: Snapshot, state: LastState)?
    public enum LastState: Sendable { case cleaned(count: Int), returned(count: Int) }

    /// `pasteboard` and `frontmost` are replaced in checks.
    public init(rules: LinkRules, pasteboard: NSPasteboard = .general,
                frontmost: @escaping @MainActor () -> (id: String, name: String)? = ClipboardEditor.systemFrontmost) {
        self.rules = rules
        self.cleaner = LinkCleaner(rules: rules)
        self.pb = pasteboard
        self.frontmost = frontmost
        self.lastCount = pasteboard.changeCount
        self.appAtLastTick = frontmost()?.id
    }

    public static func systemFrontmost() -> (id: String, name: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier else { return nil }
        return (id, app.localizedName ?? id)
    }

    public func replaceRules(_ new: LinkRules) {
        guard new.version > rules.version else { return }
        rules = new
        cleaner = LinkCleaner(rules: new)
    }

    public func start() {
        guard timer == nil else { return }
        lastCount = pb.changeCount
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func isSharingApp(_ bundleID: String) -> Bool {
        rules.sharingApps.contains { $0.mac.contains(bundleID) }
    }

    /// One look at the clipboard. The timer calls it; checks call it directly.
    public func poll() {
        let app = frontmost()
        // The copy happened somewhere between the previous tick and now. If the active app changed
        // in between, we cannot tell where it was copied: leave it alone.
        let sameApp = app?.id == appAtLastTick
        appAtLastTick = app?.id
        let count = pb.changeCount
        guard count != lastCount else { return }
        lastCount = count
        guard !ownCounts.contains(count), !paused, sameApp, let app,
              isSharingApp(app.id), !excludedApps.contains(app.id) else { return }
        guard let items = pb.pasteboardItems, items.count == 1 else { return }
        let types = Set((pb.types ?? []).map(\.rawValue))
        guard types.contains(NSPasteboard.PasteboardType.string.rawValue),
              !types.contains(Self.cleanedType.rawValue), types.isDisjoint(with: Self.privateTypes) else { return }
        if #available(macOS 15.4, *) {
            if pb.accessBehavior == .alwaysDeny { return }
            if holdUntilAsked, pb.accessBehavior == .default { return }
        }

        let snapshot = Snapshot.read(pb)
        guard snapshot.changeCount == count, let text = pb.string(forType: .string) else { return }
        let result = cleaner.clean(text)
        guard result.kind != .none else { return }
        guard let written = write(result.output, like: snapshot, replacing: count) else { return }
        let event = EditingEvent(original: text, cleaned: result, appID: app.id, appName: app.name)
        last = (event, snapshot, .cleaned(count: written))
        onEvent(event)
    }

    /// «Вернуть хвост»: puts the original back while the clipboard still holds our clean link.
    @discardableResult
    public func returnTail() -> Bool {
        guard let last, case .cleaned(let count) = last.state, pb.changeCount == count else { return false }
        let c = last.snapshot.restore(to: pb)
        noteOwnWrite(c)
        self.last = (last.event, last.snapshot, .returned(count: c))
        return true
    }

    /// «Убрать снова» after a return, while the clipboard still holds the returned original.
    @discardableResult
    public func cleanAgain() -> Bool {
        guard let last, case .returned(let count) = last.state,
              let c = write(last.event.cleaned.output, like: last.snapshot, replacing: count) else { return false }
        self.last = (last.event, last.snapshot, .cleaned(count: c))
        return true
    }

    /// True while the clipboard is still ours, so the card's buttons can work.
    public var lastIsCurrent: Bool {
        guard let last else { return false }
        switch last.state {
        case .cleaned(let c), .returned(let c): return pb.changeCount == c
        }
    }

    /// Writes the clean link. Rich copies (HTML with the old link inside) are dropped: only the
    /// plain text and, if it was there, the URL type remain. Nil if the clipboard changed meanwhile.
    private func write(_ link: String, like snapshot: Snapshot, replacing expected: Int) -> Int? {
        guard pb.changeCount == expected else { return nil }
        let hadURL = snapshot.items.first?[.URL] != nil
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(link, forType: .string)
        if hadURL { item.setString(link, forType: .URL) }
        item.setData(Data(), forType: Self.cleanedType)
        pb.writeObjects([item])
        let c = pb.changeCount
        noteOwnWrite(c)
        return c
    }

    private func noteOwnWrite(_ count: Int) {
        ownCounts.insert(count)
        lastCount = max(lastCount, count)
    }

    /// What was on the clipboard, item by item, so it can be put back exactly.
    public struct Snapshot: Sendable {
        var items: [[NSPasteboard.PasteboardType: Data]]
        var changeCount: Int

        static func read(_ pb: NSPasteboard) -> Snapshot {
            let items = (pb.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
                var out: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types { if let data = item.data(forType: type) { out[type] = data } }
                return out
            }
            return Snapshot(items: items, changeCount: pb.changeCount)
        }

        func restore(to pb: NSPasteboard) -> Int {
            pb.clearContents()
            pb.writeObjects(items.map { dict in
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                return item
            })
            return pb.changeCount
        }
    }
}

extension LinkRules {
    /// The copy built into the app (scripts/sync-spec.sh). Always valid: checks load it.
    public static let bundled: LinkRules = {
        do { return try LinkRules.load(Data(BundledLinkRules.json.utf8)) } catch { fatalError("bundled rules: \(error)") }
    }()

    public static var bundledJSON: String { BundledLinkRules.json }
}
