import AppKit
import CryptoKit
import Foundation
import LocalAuthentication

/// One document of the Archive, as in `archive.json` (spec/archive-format.md, «Раскладка»).
public struct ArchiveDocument: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var file: String
    public var title: String
    public var kind: String
    /// ГГГГ-ММ-ДД or nil.
    public var expires: String?
    public let added: Date
    public let original: String
    public let size: Int
}

struct ArchiveIndex: Codable {
    var format = 1
    var recovery: String
    var devices: [String]
    var documents: [ArchiveDocument]
}

/// The key of this device. On a Mac it lives in the Secure Enclave; checks use a software key.
protocol ArchiveDeviceKey {
    var recipient: AgeRecipient { get }
    var tag: String { get }
    func identity(reason: String) -> AgeIdentity
    func identity(context: LAContext) -> AgeIdentity
}

/// Secure Enclave key. Its blob is kept in a file of our own: outside this Mac's enclave it is useless,
/// and the keychain would ask again after every ad hoc signed update.
struct EnclaveKey: ArchiveDeviceKey {
    let device: DeviceIdentity
    var recipient: AgeRecipient { DeviceRecipient(publicKey: device.publicKey) }
    var tag: String { DeviceStanza.tag(device.publicKey) }
    func identity(reason: String) -> AgeIdentity {
        var d = device
        d.reason = reason
        return d
    }
    func identity(context: LAContext) -> AgeIdentity {
        var d = device
        d.context = context
        return d
    }

    static func load(_ url: URL) -> EnclaveKey? {
        guard let blob = try? Data(contentsOf: url),
              let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob, authenticationContext: LAContext())
        else { return nil }
        return EnclaveKey(device: DeviceIdentity(keyData: blob, publicKey: key.publicKey))
    }

    static func create(_ url: URL) throws -> EnclaveKey {
        let d = try DeviceIdentity.create()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.keyData.write(to: url, options: .atomic)
        return EnclaveKey(device: d)
    }
}

/// Software device key for checks: same stanza, no prompt.
struct SoftKey: ArchiveDeviceKey {
    let key = P256.KeyAgreement.PrivateKey()
    var recipient: AgeRecipient { DeviceRecipient(publicKey: key.publicKey) }
    var tag: String { DeviceStanza.tag(key.publicKey) }
    func identity(reason: String) -> AgeIdentity { ArchiveSelfTest.SoftDeviceIdentity(key: key) }
    func identity(context: LAContext) -> AgeIdentity { ArchiveSelfTest.SoftDeviceIdentity(key: key) }
}

public enum ArchiveError: Error, LocalizedError, Equatable {
    case notSetUp
    case alreadySetUp
    case wrongWords
    case cancelled
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .notSetUp: return "Архив ещё не создан."
        case .alreadySetUp: return "Архив уже создан."
        case .wrongWords: return "Одно из слов неверно или не на своём месте."
        case .cancelled: return "Отменено."
        case .unreadable(let name): return "Не удалось открыть «\(name)»."
        }
    }
}

/// The Archive: `~/Редакция/Архив/` with `.age` files and an open `archive.json`.
@MainActor
public final class ArchiveStore: ObservableObject {
    public let folder: URL
    let keyURL: URL
    let openFolder: URL
    @Published public private(set) var documents: [ArchiveDocument] = []
    private var index: ArchiveIndex?
    private var device: ArchiveDeviceKey?
    /// Moves originals to the Trash; checks replace it to keep files in temporary folders.
    var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    /// «added», «removed», «restored» with the document, for the morning issue.
    public var onChange: ((String, ArchiveDocument) -> Void)?

    public nonisolated static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Редакция/Архив", isDirectory: true)
    }

    nonisolated static var defaultKey: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Redakciya/device-key.bin")
    }

    nonisolated static var defaultOpenFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.vldvr.redakciya/Open", isDirectory: true)
    }

    public init(folder: URL = ArchiveStore.defaultFolder) {
        self.folder = folder
        keyURL = Self.defaultKey
        openFolder = Self.defaultOpenFolder
        device = EnclaveKey.load(keyURL)
        reload()
    }

    /// For checks: own folders and a software device key.
    init(folder: URL, keyURL: URL, openFolder: URL, device: ArchiveDeviceKey?) {
        self.folder = folder
        self.keyURL = keyURL
        self.openFolder = openFolder
        self.device = device
        reload()
    }

    var indexURL: URL { folder.appendingPathComponent("archive.json") }

    /// The Archive exists and this device can open it.
    public var isReady: Bool { index != nil && device.map { index!.devices.contains($0.tag) } == true }
    /// There is an Archive here, but this device has no key for it: open by the 12 words.
    public var needsRecovery: Bool { index != nil && !isReady }

    public func reload() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        index = (try? Data(contentsOf: indexURL)).flatMap { try? dec.decode(ArchiveIndex.self, from: $0) }
        documents = index?.documents ?? []
    }

    private func save() throws {
        guard let index else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try enc.encode(index).write(to: indexURL, options: .atomic)
        documents = index.documents
    }

    // MARK: - Setting up

    /// A new Archive: a device key and 12 recovery words. The words are returned once and kept nowhere;
    /// only the recovery recipient is stored.
    public func setUp() throws -> [String] {
        guard index == nil else { throw ArchiveError.alreadySetUp }
        let entropy = Recovery.newEntropy()
        let words = Recovery.words(for: entropy, list: Recovery.list)
        let key = try device ?? EnclaveKey.create(keyURL)
        device = key
        index = ArchiveIndex(recovery: Recovery.identity(from: entropy).recipient.string, devices: [key.tag], documents: [])
        try save()
        return words
    }

    /// Checks typed words against the stored recovery recipient, without keeping them.
    public func wordsMatch(_ words: [String]) -> Bool {
        guard let index, let e = try? Recovery.entropy(from: words, list: Recovery.list) else { return false }
        return Recovery.identity(from: e).recipient.string == index.recovery
    }

    /// On a new Mac: the 12 words open every document, and each is sealed again for this device.
    @discardableResult
    public func recover(words: [String]) throws -> Int {
        guard var index else { throw ArchiveError.notSetUp }
        guard let e = try? Recovery.entropy(from: words, list: Recovery.list) else { throw ArchiveError.wrongWords }
        let recovery = Recovery.identity(from: e)
        guard recovery.recipient.string == index.recovery else { throw ArchiveError.wrongWords }
        let key = try device ?? EnclaveKey.create(keyURL)
        device = key
        var done = 0
        for doc in index.documents {
            let url = folder.appendingPathComponent(doc.file)
            guard let sealed = try? Data(contentsOf: url) else { continue }
            let plain = try Age.decrypt(sealed, with: [recovery])
            try Age.encrypt(plain, to: [recovery.recipient, key.recipient]).write(to: url, options: .atomic)
            done += 1
        }
        let journal = folder.appendingPathComponent(IssueJournal.fileName)
        if let sealed = try? Data(contentsOf: journal) {
            let plain = try Age.decrypt(sealed, with: [recovery])
            try Age.encrypt(plain, to: [recovery.recipient, key.recipient]).write(to: journal, options: .atomic)
        }
        index.devices = [key.tag]
        self.index = index
        try save()
        return done
    }

    // MARK: - Documents

    /// «Сдать в Архив»: encrypts the file for the recovery key and this device, checks the result,
    /// then moves the original to the Trash. Nothing is erased.
    @discardableResult
    public func add(_ url: URL, title: String, kind: String, expires: String? = nil) throws -> ArchiveDocument {
        guard var index, let device, let recovery = X25519Recipient(index.recovery) else { throw ArchiveError.notSetUp }
        let plain = try Data(contentsOf: url)
        let sealed = try Age.encrypt(plain, to: [recovery, device.recipient])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = Desk.freeName(url.lastPathComponent + ".age", in: folder)
        try sealed.write(to: target, options: .atomic)
        // The file must be there and its header must read before the original goes.
        let check = try Age.parseHeader(Data(contentsOf: target))
        guard check.stanzas.count == 2 else { throw ArchiveError.unreadable(target.lastPathComponent) }
        let doc = ArchiveDocument(id: UUID().uuidString, file: target.lastPathComponent, title: title, kind: kind,
                                  expires: expires, added: Date(), original: url.lastPathComponent, size: plain.count)
        index.documents.append(doc)
        self.index = index
        try save()
        try trash(url)
        onChange?("added", doc)
        return doc
    }

    /// Decrypts with this device's key: Touch ID or the login password is asked here.
    public func decrypt(_ doc: ArchiveDocument, reason: String = "открыть документ из Архива") throws -> Data {
        guard let device else { throw ArchiveError.notSetUp }
        let sealed = try Data(contentsOf: folder.appendingPathComponent(doc.file))
        do {
            return try Age.decrypt(sealed, with: [device.identity(reason: reason)])
        } catch let e as LAError where e.code == .userCancel || e.code == .appCancel || e.code == .systemCancel {
            throw ArchiveError.cancelled
        } catch let e as NSError where e.domain == LAErrorDomain {
            throw ArchiveError.cancelled
        }
    }

    /// One Touch ID for a whole sheet: the returned context opens documents and the journal without asking again.
    /// Checks get nil (software key, nothing to confirm).
    public func confirm(reason: String) async throws -> LAContext? {
        guard device is EnclaveKey else { return nil }
        let ctx = LAContext()
        ctx.localizedReason = reason
        do {
            _ = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw ArchiveError.cancelled
        }
        return ctx
    }

    /// Decrypts with a confirmed context (or the check key).
    func decrypt(_ data: Data, context: LAContext?) throws -> Data {
        guard let device else { throw ArchiveError.notSetUp }
        let id = context.map { device.identity(context: $0) } ?? device.identity(reason: "открыть документ из Архива")
        do {
            return try Age.decrypt(data, with: [id])
        } catch let e as NSError where e.domain == LAErrorDomain {
            throw ArchiveError.cancelled
        }
    }

    public func decrypt(_ doc: ArchiveDocument, context: LAContext?) throws -> Data {
        try decrypt(Data(contentsOf: folder.appendingPathComponent(doc.file)), context: context)
    }

    /// Everyone the Archive is sealed for: the recovery key and this device.
    func recipients() throws -> [AgeRecipient] {
        guard let index, let device, let recovery = X25519Recipient(index.recovery) else { throw ArchiveError.notSetUp }
        return [recovery, device.recipient]
    }

    /// «Открыть»: a temporary copy in our caches, opened by the system app. Copies go away at launch,
    /// at quit and an hour later.
    public func openCopy(_ doc: ArchiveDocument) throws -> URL {
        let plain = try decrypt(doc, reason: "открыть «\(doc.title)»")
        let dir = openFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(doc.original)
        try plain.write(to: url, options: .atomic)
        return url
    }

    /// Removes temporary copies older than `age` seconds (all with 0). Our own cache folder only.
    public func purgeOpenCopies(olderThan age: TimeInterval = 0) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: openFolder, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for u in items {
            let created = (try? u.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if Date().timeIntervalSince(created) >= age { try? fm.removeItem(at: u) }
        }
    }

    /// «Вернуть в Загрузки»: a decrypted copy under the original name; the Archive keeps its copy.
    public func restore(_ doc: ArchiveDocument, to folder: URL) throws -> URL {
        let plain = try decrypt(doc, reason: "вернуть «\(doc.title)» в Загрузки")
        let url = Desk.freeName(doc.original, in: folder)
        try plain.write(to: url, options: .atomic)
        onChange?("restored", doc)
        return url
    }

    public func update(_ doc: ArchiveDocument) throws {
        guard var index, let i = index.documents.firstIndex(where: { $0.id == doc.id }) else { return }
        index.documents[i].title = doc.title
        index.documents[i].kind = doc.kind
        index.documents[i].expires = doc.expires
        self.index = index
        try save()
    }

    /// «Убрать из Архива»: the `.age` file goes to the Trash, the entry goes away.
    public func remove(_ doc: ArchiveDocument) throws {
        guard var index else { return }
        let url = folder.appendingPathComponent(doc.file)
        if FileManager.default.fileExists(atPath: url.path) { try trash(url) }
        index.documents.removeAll { $0.id == doc.id }
        self.index = index
        try save()
        onChange?("removed", doc)
    }
}
