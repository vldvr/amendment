import Foundation

/// The three folders Desk looks after (spec/desk.md, «Какие файлы»).
public struct DeskFolders: Sendable {
    public var folders: [URL]
    /// A screenshot folder of its own, if it is not Desktop or Downloads: everything in it counts as a screenshot.
    public var screenshotsOnly: URL?

    public init(folders: [URL], screenshotsOnly: URL? = nil) {
        self.folders = folders
        self.screenshotsOnly = screenshotsOnly
    }

    public static func system() -> DeskFolders {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Downloads")
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Desktop")
        var folders = [downloads, desktop]
        var shots: URL?
        if let raw = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            if !folders.contains(where: { $0.standardizedFileURL.path == url.path }) {
                folders.append(url)
                shots = url
            }
        }
        return DeskFolders(folders: folders, screenshotsOnly: shots)
    }
}

/// One file on the desk with its verdict.
public struct DeskItem: Sendable {
    public let url: URL
    public let verdict: DeskPolicy.Verdict
    public let modified: Date?
    /// When the file appeared in the folder.
    public let added: Date
    public let flags: DeskPolicy.Flags
}

/// What Desk did with one file: from where to where, and when. One line of the journal.
public struct DeskMove: Codable, Equatable, Sendable {
    public let at: Date
    public let from: String
    public let to: String
    /// «moved» when Desk took the file away, «returned» when the person brought it back.
    public let kind: String
}

/// Desk: looks at the folders, takes expired files to `~/Редакция/Убрано со стола/ГГГГ-ММ/`, writes a journal,
/// brings files back on request. Never deletes anything. Folders, destination and journal are passed in,
/// so checks run on temporary folders only.
@MainActor
public final class Desk {
    public var policy = DeskPolicy()
    public let folders: DeskFolders
    public let destination: URL
    public let journalURL: URL
    /// When Desk was turned on: files older than that start counting from this day.
    public var enabledAt: Date
    public var excludedNames: Set<String> = []
    public var excludedExtensions: Set<String> = []
    /// Single files the person told Desk not to touch, from the Desk window.
    public var excludedPaths: Set<String> = []
    /// Paths the person chose to keep on the card «Похоже на паспорт».
    public var keptPaths: Set<String> = []
    /// Personal data detector (ZamazkaKit). Nil until it is wired in.
    public var isPersonal: ((URL) -> Bool)?
    public private(set) var lastSweep: [DeskMove] = []
    /// Documents go to the Archive when it is set up: returns the sealed file, or nil to move as usual.
    public var archiver: ((URL) -> URL?)?
    /// Every journal record, with a flag for Reprint copies: for the morning issue.
    public var onRecord: ((DeskMove, Bool) -> Void)?

    public nonisolated static var defaultDestination: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Редакция/Убрано со стола", isDirectory: true)
    }

    public nonisolated static var defaultJournal: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Redakciya/desk-journal.jsonl")
    }

    public init(folders: DeskFolders, destination: URL = Desk.defaultDestination, journal: URL = Desk.defaultJournal,
                enabledAt: Date) {
        self.folders = folders
        self.destination = destination
        self.journalURL = journal
        self.enabledAt = enabledAt
    }

    static let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey,
                                         .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey]

    /// Every top-level file of the folders with its verdict for `now`.
    public func scan(now: Date = Date()) -> [DeskItem] {
        var out: [DeskItem] = []
        let today = DeskPolicy.day(now)
        for folder in folders.folders {
            guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Self.keys) else { continue }
            let shotsFolder = folders.screenshotsOnly.map { $0.standardizedFileURL.path } == folder.standardizedFileURL.path
            for url in urls {
                guard let v = try? url.resourceValues(forKeys: Set(Self.keys)) else { continue }
                var flags: DeskPolicy.Flags = []
                if v.isDirectory == true || v.isPackage == true { flags.insert(.dir) }
                if v.isSymbolicLink == true || v.isAliasFile == true { flags.insert(.link) }
                let name = url.lastPathComponent
                if excludedNames.contains(name) || excludedExtensions.contains(url.pathExtension.lowercased())
                    || excludedPaths.contains(url.path) {
                    flags.insert(.excluded)
                }
                if shotsFolder || Self.isScreenCapture(url) { flags.insert(.screenshot) }
                if keptPaths.contains(url.path) { flags.insert(.kept) }
                let mark = flags.isDisjoint(with: [.dir, .link, .excluded]) ? ReprintMark.read(url) : nil
                if mark != nil {
                    flags.insert(.reprint)
                } else if flags.isDisjoint(with: [.dir, .link, .excluded]), !DeskPolicy.skipsByName(name), isPersonal?(url) == true {
                    flags.insert(.personal)
                }
                let added = v.addedToDirectoryDate ?? v.creationDate ?? now
                let modified = v.contentModificationDate ?? added
                let verdict = mark.map { policy.reprintVerdict(issued: $0.at, now: now) } ?? policy.evaluate(name: name, flags: flags, added: DeskPolicy.day(added),
                                              enabled: DeskPolicy.day(enabledAt), modified: DeskPolicy.day(modified),
                                              today: today)
                out.append(DeskItem(url: url, verdict: verdict, modified: v.contentModificationDate, added: added, flags: flags))
            }
        }
        return out
    }

    /// macOS marks screenshots with this Spotlight attribute, wherever they are saved.
    static func isScreenCapture(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, XATTR_NOFOLLOW) > 0
    }

    /// One pass: every expired file that may move goes away. Returns what moved.
    @discardableResult
    public func sweep(now: Date = Date()) -> [DeskMove] {
        var moved: [DeskMove] = []
        for item in scan(now: now) where item.verdict.action == .move {
            if let m = take(item, now: now) { moved.append(m) }
        }
        if !moved.isEmpty { lastSweep = moved }
        return moved
    }

    /// Moves one file away, after checking it is still there and unchanged since the scan.
    public func take(_ item: DeskItem, now: Date) -> DeskMove? {
        let fm = FileManager.default
        var fresh = item.url
        fresh.removeAllCachedResourceValues()
        guard let v = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
              v.isDirectory != true, v.contentModificationDate == item.modified else { return nil }
        if item.flags.contains(.personal), !item.flags.contains(.kept), !item.flags.contains(.reprint), let sealed = archiver?(item.url) {
            let m = DeskMove(at: now, from: item.url.path, to: sealed.path, kind: "archived")
            record(m)
            return m
        }
        let month = DateFormatter.deskMonth.string(from: now)
        let folder = destination.appendingPathComponent(month, isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = Self.freeName(item.url.lastPathComponent, in: folder)
            try fm.moveItem(at: item.url, to: target)
            let m = DeskMove(at: now, from: item.url.path, to: target.path, kind: "moved")
            record(m, copy: item.flags.contains(.reprint))
            return m
        } catch {
            Log.write("desk: move failed: \((error as NSError).code)")
            return nil
        }
    }

    /// «Убрать сейчас» on the card: moves one file whatever its stage.
    @discardableResult
    public func takeNow(_ url: URL, flags: DeskPolicy.Flags = [], now: Date = Date()) -> DeskMove? {
        var u = url
        u.removeAllCachedResourceValues()
        guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey]) else { return nil }
        let item = DeskItem(url: url, verdict: DeskPolicy.Verdict(term: 0, stage: .expired, action: .move),
                            modified: v.contentModificationDate, added: now, flags: flags)
        return take(item, now: now)
    }

    /// «Вернуть на место» for the last pass. Returns how many came back.
    @discardableResult
    public func returnLastSweep(now: Date = Date()) -> Int {
        var back = 0
        for m in lastSweep where bringBack(m, now: now) { back += 1 }
        lastSweep = []
        return back
    }

    /// Puts a moved file back into the folder it came from, under a free name.
    @discardableResult
    public func bringBack(_ m: DeskMove, now: Date = Date()) -> Bool {
        // Archived documents come back from the Archive window, with Touch ID.
        guard m.kind == "moved" else { return false }
        let from = URL(fileURLWithPath: m.from)
        let source = URL(fileURLWithPath: m.to)
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        let target = Self.freeName(from.lastPathComponent, in: from.deletingLastPathComponent())
        do {
            try FileManager.default.moveItem(at: source, to: target)
            record(DeskMove(at: now, from: source.path, to: target.path, kind: "returned"))
            return true
        } catch {
            Log.write("desk: return failed: \((error as NSError).code)")
            return false
        }
    }

    /// `name`, then `name 2.ext`, `name 3.ext`… as Finder does.
    public static func freeName(_ name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var url = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return url }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        var n = 2
        repeat {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        } while fm.fileExists(atPath: url.path)
        return url
    }

    func record(_ m: DeskMove, copy: Bool = false) {
        onRecord?(m, copy)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? enc.encode(m) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: journalURL) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: journalURL)
        }
    }

    /// The journal, oldest first.
    public func journal() -> [DeskMove] {
        guard let text = try? String(contentsOf: journalURL, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? dec.decode(DeskMove.self, from: Data($0.utf8)) }
    }
}

extension DateFormatter {
    static let deskMonth: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()
}
