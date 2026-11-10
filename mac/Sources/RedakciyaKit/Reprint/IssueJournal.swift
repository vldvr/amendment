import Foundation
import LocalAuthentication

/// One record of the issue journal (spec/reprint.md, «Журнал выдач»).
public struct Issue: Codable, Equatable, Identifiable, Sendable {
    public var id: String { code }
    public let code: String
    public let doc: String
    public let title: String
    public let purpose: String
    public let at: Date
    public let via: String
    public let app: String?
    public let file: String

    enum CodingKeys: String, CodingKey { case code, doc, title, purpose = "for", at, via, app, file }

    public init(code: String, doc: String, title: String, purpose: String, at: Date, via: String, app: String?, file: String) {
        self.code = code; self.doc = doc; self.title = title; self.purpose = purpose
        self.at = at; self.via = via; self.app = app; self.file = file
    }
}

struct IssueFile: Codable {
    var format = 1
    var issues: [Issue] = []
}

public enum IssueJournalError: Error, LocalizedError {
    case unreadable
    public var errorDescription: String? { "Журнал выдач не открылся." }
}

/// `issues.age` next to the Archive index. Held in memory while a sheet or the «Выдачи» tab is open.
@MainActor
public final class IssueJournal {
    public static let fileName = "issues.age"
    /// A copy went out: the morning issue hears the document and the time, nothing else.
    public static var onAppend: ((Issue) -> Void)?
    let store: ArchiveStore
    let context: LAContext?
    public private(set) var issues: [Issue]

    var url: URL { store.folder.appendingPathComponent(Self.fileName) }

    /// Opens the journal with a confirmed context; no file yet is an empty journal.
    public init(store: ArchiveStore, context: LAContext?) throws {
        self.store = store
        self.context = context
        let url = store.folder.appendingPathComponent(Self.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { issues = []; return }
        do {
            let plain = try store.decrypt(Data(contentsOf: url), context: context)
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            issues = try dec.decode(IssueFile.self, from: plain).issues
        } catch ArchiveError.cancelled {
            throw ArchiveError.cancelled
        } catch {
            throw IssueJournalError.unreadable
        }
    }

    public var codes: [String] { issues.map(\.code) }

    /// Recent purposes, newest first, up to five.
    public var recentPurposes: [String] {
        var seen = Set<String>(), out: [String] = []
        for i in issues.reversed() where !seen.contains(i.purpose) {
            seen.insert(i.purpose); out.append(i.purpose)
            if out.count == 5 { break }
        }
        return out
    }

    /// Appends a record; the file is rewritten whole, atomically.
    public func append(_ issue: Issue) throws {
        var all = issues
        all.append(issue)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let plain = try enc.encode(IssueFile(issues: all))
        try Age.encrypt(plain, to: try store.recipients()).write(to: url, options: .atomic)
        issues = all
        Self.onAppend?(issue)
    }
}
