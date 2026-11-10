import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Reprint on temporary folders with a software device key, for `redakciya-checks reprint-files`.
/// Never touches ~/Редакция, the Secure Enclave or the real Downloads.
@MainActor
public enum ReprintSelfTest {
    public static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures.append(what) }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("redakciya-reprint-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("Архив"), downloads = root.appendingPathComponent("Downloads")
        let trash = root.appendingPathComponent("Trash")
        for d in [downloads, trash] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        func make(_ key: ArchiveDeviceKey) -> ArchiveStore {
            let s = ArchiveStore(folder: folder, keyURL: root.appendingPathComponent("key.bin"),
                                 openFolder: root.appendingPathComponent("Open"), device: key)
            s.trash = { url in try fm.moveItem(at: url, to: Desk.freeName(url.lastPathComponent, in: trash)) }
            return s
        }
        let store = make(SoftKey())
        guard let words = try? store.setUp() else { return (1, ["set up failed"]) }

        // A photo with everything a phone writes: GPS, dates, camera, a name in the description.
        let photo = downloads.appendingPathComponent("IMG_4021.jpg")
        let original = sample(1200, 900)
        let dest = CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, original, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 55.75, kCGImagePropertyGPSLongitude: 37.62],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:01 10:00:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "iPhone", kCGImagePropertyTIFFImageDescription: "Петров паспорт"],
            kCGImagePropertyOrientation: 6,
        ] as CFDictionary)
        CGImageDestinationFinalize(dest)
        guard let doc = try? store.add(photo, title: "Паспорт РФ", kind: "passport"),
              let plain = try? store.decrypt(doc, context: nil),
              let source = try? ReprintSource(data: plain, name: doc.original) else { return (checks + 1, failures + ["add failed"]) }
        check(source.pages[0].width == 900 && source.pages[0].height == 1200, "orientation applied before the copy is drawn")

        // Journal: empty, then records, encrypted for the Archive's recipients.
        guard let journal = try? IssueJournal(store: store, context: nil) else { return (checks + 1, failures + ["journal"]) }
        check(journal.issues.isEmpty, "no journal file is an empty journal")

        var field = ReprintField(page: 0, kind: .passport, rects: [CGRect(x: 100, y: 100, width: 300, height: 80)])
        field.hidden = true
        let model = ReprintModel(doc: doc, store: store, deskCleans: true, source: source, journal: journal)
        model.fields = [field]
        let first = model.code
        check(ReprintRules.codeOK(first, journal: []), "a code from the alphabet")
        model.purposeText = "   "
        check(model.toDownloads(downloads) == nil && model.error == ReprintRules.PurposeError.empty.errorDescription,
              "an empty purpose is not issued")
        model.purposeText = "Для: аренда,\nПетров."
        guard let copy = model.toDownloads(downloads) else { return (checks + 1, failures + ["to Downloads: \(model.error ?? "")"]) }
        check(copy.lastPathComponent == "Копия \(first).jpg", "file name is only the code: \(copy.lastPathComponent)")
        check(journal.issues.count == 1 && journal.issues[0].purpose == "аренда, Петров" && journal.issues[0].via == "downloads"
              && journal.issues[0].code == first && journal.issues[0].title == "Паспорт РФ", "one record per copy")
        check(model.code != first && ReprintRules.codeOK(model.code, journal: [first]), "next copy, next code two places away")
        check(ReprintMark.read(copy)?.code == first, "the copy carries its mark")
        check(model.note?.contains("через сутки") == true, "the sheet says Desk takes the copy away")

        // Metadata: nothing of the original.
        if let src = CGImageSourceCreateWithURL(copy as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            check(props[kCGImagePropertyGPSDictionary] == nil, "no GPS")
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            check(exif[kCGImagePropertyExifDateTimeOriginal] == nil, "no date taken")
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            check(tiff[kCGImagePropertyTIFFModel] == nil && tiff[kCGImagePropertyTIFFImageDescription] == nil, "no camera, no description")
            check((props[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "orientation 1")
            check(CGImageSourceCopyMetadataAtIndex(src, 0, nil).map { CGImageMetadataCopyTags($0) as? [Any] ?? [] }?
                .contains { "\($0)".contains("Петров") } != true, "no XMP with the description")
            let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
            check(img.width == 900 && img.height > 1200, "a band under the document")
            // Zamazka: the hidden field is ink, the open area is not.
            check(isInk(img, 250, 140) && !isInk(img, 600, 700), "the chosen field is painted over")
        } else {
            check(false, "copy reads")
        }
        let raw = (try? Data(contentsOf: copy)) ?? Data()
        check(raw.range(of: Data("IMG_4021".utf8)) == nil && raw.range(of: Data("iPhone".utf8)) == nil, "no original name or camera in the bytes")

        // Reopened with the key: same records.
        let again = try? IssueJournal(store: store, context: nil)
        check(again?.issues == journal.issues, "journal reads back")
        check(again?.recentPurposes == ["аренда, Петров"], "recent purposes")
        let sealed = (try? Data(contentsOf: folder.appendingPathComponent(IssueJournal.fileName))) ?? Data()
        check(sealed.starts(with: Data("age-encryption.org/v1".utf8)) && sealed.range(of: Data("Петров".utf8)) == nil, "journal is an age file")

        // Drag: file in our cache folder, a record only when issued.
        model.purposeText = "банк"
        let code2 = model.code
        if let dragged = model.dragFile() {
            check(journal.issues.count == 1, "no record before the drop")
            model.issued(via: "drag", app: "ru.keepcoder.Telegram", file: dragged.lastPathComponent)
            check(journal.issues.count == 2 && journal.issues[1].app == "ru.keepcoder.Telegram" && journal.issues[1].code == code2, "drop recorded")
            try? fm.removeItem(at: dragged.deletingLastPathComponent())
        } else {
            check(false, "drag file")
        }
        check(ReprintRules.search("петров", in: journal.issues) == [0] && ReprintRules.search(code2.lowercased(), in: journal.issues) == [1],
              "search by text and code")

        // PDF: every page, no document info.
        let pdfDoc = PDFSample.make(pages: 2)
        if let src = try? ReprintSource(data: pdfDoc, name: "скан.pdf") {
            check(src.pages.count == 2 && src.isPDF, "PDF pages rastered")
            let out = ReprintRender(purpose: "банк", code: "H7RK", date: Date()).copy(src, fields: [])
            let p = CGPDFDocument(CGDataProvider(data: out.data as CFData)!)
            check(out.ext == "pdf" && p?.numberOfPages == 2, "PDF copy keeps pages")
            var leak = false
            if let info = p?.info {
                for key in ["Title", "Author", "Subject", "Keywords", "Creator"] {
                    var s: CGPDFStringRef?
                    if CGPDFDictionaryGetString(info, key, &s), let s, let t = CGPDFStringCopyTextString(s) as String?, !t.isEmpty { leak = true }
                }
            }
            check(!leak, "PDF info has no title, author or creator")
            check(out.data.range(of: Data("Секретный".utf8)) == nil, "no text layer of the original")
        } else {
            check(false, "PDF source")
        }

        // Desk: the copy spoils 24 hours after issue, goes to «Убрано», never to the Archive.
        let desk = Desk(folders: DeskFolders(folders: [downloads]), destination: root.appendingPathComponent("Убрано"),
                        journal: root.appendingPathComponent("desk.jsonl"), enabledAt: Date())
        var archived = false
        desk.archiver = { _ in archived = true; return nil }
        desk.isPersonal = { _ in true }
        let issued = ReprintMark.read(copy)!.at
        let soon = desk.scan(now: issued.addingTimeInterval(23 * 3600)).first { $0.url.lastPathComponent == copy.lastPathComponent }
        check(soon?.verdict.stage == .fresh && soon?.flags.contains(.reprint) == true && soon?.flags.contains(.personal) == false,
              "fresh for a day, not personal")
        let moved = desk.sweep(now: issued.addingTimeInterval(24 * 3600 + 1))
        if moved.isEmpty { failures.append("sweep moved nothing: \(desk.scan(now: issued.addingTimeInterval(86401)).map { "\($0.url.lastPathComponent) \($0.verdict.stage) \($0.verdict.action)" })") }
        check(moved.contains { ($0.from as NSString).lastPathComponent == copy.lastPathComponent && $0.kind == "moved" } && !archived && !fm.fileExists(atPath: copy.path),
              "spoiled copy moved to «Убрано», not archived")

        // Recovery seals the journal for the new device.
        let other = make(SoftKey())
        check((try? other.recover(words: words)) != nil, "recover")
        check((try? IssueJournal(store: other, context: nil))?.issues.count == 2, "journal opens on the new device")

        return (checks, failures)
    }

    static func sample(_ w: Int, _ h: Int) -> CGImage {
        let ctx = ReprintRender.context(w, h)
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.9, blue: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.6, green: 0.2, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 40, y: 40, width: 200, height: 120))
        return ctx.makeImage()!
    }

    /// Pixel at top-left coordinates is close to ink #16181B.
    static func isInk(_ img: CGImage, _ x: Int, _ y: Int) -> Bool {
        let rep = NSBitmapImageRep(cgImage: img)
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
        return c.redComponent < 0.2 && c.greenComponent < 0.2 && c.blueComponent < 0.2
    }
}

enum PDFSample {
    /// A PDF with a title, an author and real text, to check none of it reaches the copy.
    static func make(pages: Int) -> Data {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(consumer: CGDataConsumer(data: out)!, mediaBox: &box,
                            [kCGPDFContextTitle: "Секретный скан", kCGPDFContextAuthor: "Петров", kCGPDFContextCreator: "Scanner"] as CFDictionary)!
        for i in 0..<pages {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ("Секретный текст, страница \(i + 1)" as NSString).draw(at: NSPoint(x: 60, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }
}

/// PNGs of the Reprint sheet and the «Выдачи» tab, light and dark: `redakciya-checks screens`.
@MainActor
public enum ReprintScreens {
    public static func render(to dir: URL) throws -> [URL] {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("redakciya-screens-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let store = ArchiveStore(folder: root.appendingPathComponent("Архив"), keyURL: root.appendingPathComponent("k"),
                                 openFolder: root.appendingPathComponent("o"), device: SoftKey())
        store.trash = { try fm.removeItem(at: $0) }
        _ = try store.setUp()
        let photo = downloads.appendingPathComponent("passport.jpg")
        try ReprintRender.jpeg(passport()).write(to: photo)
        let doc = try store.add(photo, title: "Паспорт РФ", kind: "passport", expires: "2031-03-01")
        let source = try ReprintSource(data: store.decrypt(doc, context: nil), name: doc.original)
        let journal = try IssueJournal(store: store, context: nil)
        let base = Date(timeIntervalSince1970: 1_762_600_000)
        for (i, p) in ["банк, ипотека", "работа, отдел кадров", "аренда, Петров"].enumerated() {
            let code = try ReprintRules.newCode(journal: journal.codes)
            try journal.append(Issue(code: code, doc: doc.id, title: doc.title, purpose: p, at: base.addingTimeInterval(Double(i) * 86400 * 3),
                                     via: i == 1 ? "downloads" : "drag", app: i == 1 ? nil : "ru.keepcoder.Telegram", file: "Копия \(code).jpg"))
        }
        let model = ReprintModel(doc: doc, store: store, deskCleans: true, source: source, journal: journal)
        model.purposeText = "аренда, Петров"
        model.fields = [ReprintField(page: 0, kind: .passport, rects: [CGRect(x: 410, y: 610, width: 300, height: 56)], hidden: true),
                        ReprintField(page: 0, kind: .birthdate, rects: [CGRect(x: 410, y: 500, width: 230, height: 56)])]
        model.refresh()

        let archive = ArchiveWindowModel(store: store, stage: .list)
        archive.issuesTab = true
        archive.issues.journal = journal
        var out: [URL] = []
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            out.append(try snap(ReprintSheet(model: model, onClose: {}), CGSize(width: 640, height: 520), dark,
                                dir.appendingPathComponent("reprint-\(suffix).png")))
            out.append(try snap(ArchiveWindowView(model: archive, store: store), CGSize(width: 640, height: 560), dark,
                                dir.appendingPathComponent("archive-issues-\(suffix).png")))
        }
        return out
    }

    static func snap<V: View>(_ view: V, _ size: CGSize, _ dark: Bool, _ url: URL) throws -> URL {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    /// A made-up passport page: shapes and obviously fake text, nothing real.
    static func passport() -> CGImage {
        let w = 1200, h = 860
        let ctx = ReprintRender.context(w, h)
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.88, blue: 0.86, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        func at(_ x: Int, _ y: Int) -> NSPoint { NSPoint(x: x, y: h - y - 40) }
        let ink = NSColor(srgbRed: 0.25, green: 0.2, blue: 0.22, alpha: 1)
        NSColor(srgbRed: 0.78, green: 0.74, blue: 0.72, alpha: 1).setFill()
        NSRect(x: 80, y: h - 620, width: 280, height: 360).fill()
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34, weight: .medium), .foregroundColor: ink]
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: ink.withAlphaComponent(0.7)]
        ("ОБРАЗЕЦ" as NSString).draw(at: at(420, 120), withAttributes: a)
        for (i, (label, value)) in [("Фамилия", "ИВАНОВ"), ("Имя", "ИВАН"), ("Дата рождения", "01.01.1990"), ("Серия и номер", "00 00 000000")].enumerated() {
            (label as NSString).draw(at: at(420, 260 + i * 110), withAttributes: small)
            (value as NSString).draw(at: at(420, 290 + i * 110), withAttributes: a)
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
}
