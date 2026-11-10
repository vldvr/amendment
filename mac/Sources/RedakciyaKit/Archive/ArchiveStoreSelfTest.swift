import Foundation

/// The Archive on temporary folders with software device keys, for `redakciya-checks archive`.
/// Never touches ~/Редакция, the Secure Enclave or the real Trash.
@MainActor
public enum ArchiveStoreSelfTest {
    public static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures.append(what) }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("redakciya-archive-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("Архив"), downloads = root.appendingPathComponent("Downloads")
        let trash = root.appendingPathComponent("Trash"), open = root.appendingPathComponent("Open")
        for d in [downloads, trash] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        func make(_ device: ArchiveDeviceKey) -> ArchiveStore {
            let s = ArchiveStore(folder: folder, keyURL: root.appendingPathComponent("key.bin"), openFolder: open, device: device)
            s.trash = { url in try fm.moveItem(at: url, to: Desk.freeName(url.lastPathComponent, in: trash)) }
            return s
        }

        let first = SoftKey()
        let store = make(first)
        check(!store.isReady && !store.needsRecovery, "no Archive at first")
        let passport = downloads.appendingPathComponent("IMG_4021.jpg")
        let bytes = Data((0..<70_000).map { UInt8($0 % 251) })
        try? bytes.write(to: passport)
        check((try? store.add(passport, title: "Паспорт", kind: "passport")) == nil, "nothing is archived before setting up")

        guard let words = try? store.setUp() else {
            return (checks + 1, failures + ["set up failed"])
        }
        check(words.count == 12 && store.isReady, "set up: 12 words, ready")
        check(store.wordsMatch(words), "typed words match")
        var swapped = words
        swapped.swapAt(0, 11)
        check(swapped == words || !store.wordsMatch(swapped), "words out of order do not match")
        let json = (try? String(contentsOf: store.indexURL, encoding: .utf8)) ?? ""
        check(json.contains("\"recovery\" : \"age1") && !words.contains { json.contains($0) }, "index keeps the recipient, not the words")

        do {
            let doc = try store.add(passport, title: "Паспорт РФ", kind: "passport", expires: "2031-03-01")
            check(doc.file == "IMG_4021.jpg.age" && fm.fileExists(atPath: folder.appendingPathComponent(doc.file).path), "sealed file next to the index")
            check(!fm.fileExists(atPath: passport.path) && fm.fileExists(atPath: trash.appendingPathComponent("IMG_4021.jpg").path),
                  "original went to the Trash, not erased")
            let sealed = try Data(contentsOf: folder.appendingPathComponent(doc.file))
            check(sealed.range(of: bytes.prefix(64)) == nil, "no plain bytes in the sealed file")
            let e = try Recovery.entropy(from: words, list: Recovery.list)
            check(try Age.decrypt(sealed, with: [Recovery.identity(from: e)]) == bytes, "the 12 words open it without the device")
            check(try store.decrypt(doc) == bytes, "this device opens it")

            let back = try store.restore(doc, to: downloads)
            check(back.lastPathComponent == "IMG_4021.jpg" && (try? Data(contentsOf: back)) == bytes, "returned to Downloads under its name")
            let again = try store.restore(doc, to: downloads)
            check(again.lastPathComponent == "IMG_4021 2.jpg", "name taken: «IMG_4021 2.jpg»")
            check(store.documents.count == 1, "the Archive keeps its copy after a return")

            let copy = try store.openCopy(doc)
            check(copy.path.hasPrefix(open.path) && (try? Data(contentsOf: copy)) == bytes, "open: temporary copy in our caches")
            store.purgeOpenCopies(olderThan: 0)
            check(!fm.fileExists(atPath: copy.path), "temporary copies purged")

            var edited = doc
            edited.expires = "2031-04-01"
            try store.update(edited)
            store.reload()
            check(store.documents.first?.expires == "2031-04-01", "expiry saved in the index")

            // Another Mac: no key for this Archive until the words are typed.
            let second = make(SoftKey())
            check(second.needsRecovery && !second.isReady, "new device: needs the words")
            check((try? second.decrypt(doc)) == nil, "new device cannot open before recovery")
            do { try second.recover(words: swapped); check(swapped == words, "wrong words rejected") } catch {
                check((error as? ArchiveError) == .wrongWords, "wrong words: «\(error.localizedDescription)»")
            }
            check((try? second.recover(words: words)) == 1, "recovery seals one document again")
            check(second.isReady && (try? second.decrypt(doc)) == bytes, "new device opens it after recovery")
            check((try? make(first).decrypt(doc)) == nil, "the old device key is no longer in the file")

            try second.remove(doc)
            check(second.documents.isEmpty && fm.fileExists(atPath: trash.appendingPathComponent(doc.file).path),
                  "removed: entry gone, sealed file in the Trash")
        } catch {
            check(false, "archive: \(error)")
        }
        return (checks, failures)
    }
}
