import AppKit
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers
import ZamazkaKit

enum ReprintText {
    static let title = "Перепечатка"
    static let action = "Перепечатать…"
    static let purpose = "Для"
    static let purposeHint = "аренда, Петров"
    static let fields = "Закрыть Замазкой"
    static let noFields = "Замазка не нашла полей."
    static let searching = "Замазка ищет поля…"
    static let drag = "Перетащите копию в чат или в любое окно."
    static let downloads = "В Загрузки"
    static let done = "Готово"
    static let opening = "Открываю документ…"
    static func issued(_ code: String, _ purpose: String) -> String { "Выдана № \(code): \(purpose)." }
    static let deskOn = "Стол уберёт копию из Загрузок через сутки."
    static let deskOff = "Копия останется в Загрузках: Стол выключен."
    static let issuesTab = "Выдачи"
    static let docsTab = "Документы"
    static let showIssues = "Показать выдачи"
    static let issuesLocked = "Журнал выдач зашифрован, как документы. Открыть — с Touch ID."
    static let issuesEmpty = "Выдач ещё не было. Копию даёт «Перепечатать…» в меню документа."
    static let search = "Код, кому или документ"
    static let findByCopy = "Найти по копии…"
    static let dropCopy = "Бросьте копию сюда: код найдётся на ней."
    static let notFound = "Код не найден."
    static func several(_ codes: [String]) -> String { "Несколько похожих: \(codes.joined(separator: ", "))." }
    static let reading = "Читаю копию…"
}

// MARK: - Model

@MainActor
final class ReprintModel: ObservableObject, Identifiable {
    enum Stage { case opening, ready, failed }
    @Published var stage = Stage.opening
    @Published var purposeText = ""
    @Published var fields: [ReprintField] = []
    @Published var detecting = true
    @Published var preview: NSImage?
    @Published var code = ""
    @Published var error: String?
    @Published var note: String?
    @Published var recent: [String] = []

    let doc: ArchiveDocument
    let store: ArchiveStore
    let deskCleans: Bool
    private(set) var journal: IssueJournal?
    private var source: ReprintSource?
    /// The copy as it is now, rendered on demand.
    private(set) var current: (data: Data, ext: String, purpose: String)?

    nonisolated static var dragFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.vldvr.redakciya/Reprint", isDirectory: true)
    }

    init(doc: ArchiveDocument, store: ArchiveStore, deskCleans: Bool) {
        self.doc = doc
        self.store = store
        self.deskCleans = deskCleans
    }

    /// Test hook: a ready source and journal, no Touch ID.
    init(doc: ArchiveDocument, store: ArchiveStore, deskCleans: Bool, source: ReprintSource, journal: IssueJournal) {
        self.doc = doc
        self.store = store
        self.deskCleans = deskCleans
        self.source = source
        self.journal = journal
        recent = journal.recentPurposes
        code = (try? ReprintRules.newCode(journal: journal.codes)) ?? ""
        stage = .ready
        detecting = false
    }

    func open() async {
        do {
            // The context opens the document and the journal, then goes: appending only encrypts.
            let context = try await store.confirm(reason: "перепечатать «\(doc.title)»")
            defer { context?.invalidate() }
            let plain = try store.decrypt(doc, context: context)
            source = try ReprintSource(data: plain, name: doc.original)
            journal = try IssueJournal(store: store, context: context)
            recent = journal!.recentPurposes
            code = try ReprintRules.newCode(journal: journal!.codes)
            stage = .ready
            refresh()
            if let source { fields = await ReprintRender.fields(source) }
            detecting = false
            refresh()
        } catch ArchiveError.cancelled {
            stage = .failed
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            stage = .failed
        }
    }

    var purpose: Result<String, ReprintRules.PurposeError> { ReprintRules.purpose(purposeText) }

    func refresh() {
        guard let source else { return }
        let p = (try? purpose.get()) ?? "…"
        let r = ReprintRender(purpose: p, code: code, date: Date())
        let first = r.page(source.pages[0], hiding: fields.filter { $0.hidden && $0.page == 0 }.flatMap(\.rects))
        preview = NSImage(cgImage: first, size: NSSize(width: first.width, height: first.height))
        current = nil
    }

    /// The finished copy for the current purpose; nil and an error when the purpose is not valid.
    func copy() -> (data: Data, ext: String, purpose: String)? {
        guard let source else { return nil }
        switch purpose {
        case .failure(let e):
            error = e.errorDescription
            return nil
        case .success(let p):
            if let current, current.purpose == p { return current }
            let c = ReprintRender(purpose: p, code: code, date: Date()).copy(source, fields: fields)
            current = (c.data, c.ext, p)
            return current
        }
    }

    /// Writes the copy where the drag hands it out; the mark goes on the file.
    func dragFile() -> URL? {
        guard let c = copy() else { return nil }
        let dir = Self.dragFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(ReprintRules.fileName(code: code, ext: c.ext) { _ in false })
        do {
            try c.data.write(to: url, options: .atomic)
            ReprintMark.write(url, code: code, at: Date())
            return url
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func toDownloads(_ folder: URL) -> URL? {
        guard let c = copy() else { return nil }
        let name = ReprintRules.fileName(code: code, ext: c.ext) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let url = folder.appendingPathComponent(name)
        do {
            try c.data.write(to: url, options: .withoutOverwriting)
            let at = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            ReprintMark.write(url, code: code, at: at)
            issued(via: "downloads", app: nil, file: name, at: at)
            return url
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// The copy went out: one journal record, then a fresh code.
    func issued(via: String, app: String?, file: String, at: Date = Date()) {
        guard let journal, let c = current else { return }
        // Whole seconds: the journal keeps ISO 8601 without fractions.
        let at = Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded(.down))
        do {
            try journal.append(Issue(code: code, doc: doc.id, title: doc.title, purpose: c.purpose, at: at, via: via, app: app, file: file))
            note = ReprintText.issued(code, c.purpose) + (via == "downloads" ? " " + (deskCleans ? ReprintText.deskOn : ReprintText.deskOff) : "")
            error = nil
            recent = journal.recentPurposes
            code = try ReprintRules.newCode(journal: journal.codes)
            refresh()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Drag copies are ours: gone a day later (spec/reprint.md, «Порча копии»).
    nonisolated static func purgeDragCopies(now: Date = Date()) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dragFolder, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for u in items {
            let created = (try? u.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if now.timeIntervalSince(created) >= ReprintRules.life { try? fm.removeItem(at: u) }
        }
    }
}

/// Bundle id of the app whose window is under a screen point (AppKit coordinates).
func appUnder(_ p: NSPoint) -> String? {
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    let q = CGPoint(x: p.x, y: top - p.y)
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    let me = ProcessInfo.processInfo.processIdentifier
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(q) else { continue }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
    return nil
}

// MARK: - Drag source («Оба»: promise plus a ready file URL)

final class PromiseWithFile: NSFilePromiseProvider {
    var fileURL: URL?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if fileURL != nil { types.append(.fileURL) }
        return types
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .fileURL ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL, let fileURL { return (fileURL as NSURL).pasteboardPropertyList(forType: .fileURL) }
        return super.pasteboardPropertyList(forType: type)
    }
}

final class CopyDragView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var model: ReprintModel?
    var image: NSImage? { didSet { needsDisplay = true } }
    private var downAt: NSPoint?
    private var file: URL?

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let s = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * s, height: image.size.height * s)
        let r = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        image.draw(in: r)
        NSColor(white: 0, alpha: 0.18).setStroke()
        NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let downAt, hypot(event.locationInWindow.x - downAt.x, event.locationInWindow.y - downAt.y) > 3,
              let model, let image else { return }
        self.downAt = nil
        guard let url = MainActor.assumeIsolated({ model.dragFile() }) else { return }
        file = url
        let item = PromiseWithFile(fileType: url.pathExtension == "pdf" ? UTType.pdf.identifier : UTType.jpeg.identifier, delegate: self)
        item.fileURL = url
        let w: CGFloat = 180
        let h = w * image.size.height / image.size.width
        let p = convert(event.locationInWindow, from: nil)
        let di = NSDraggingItem(pasteboardWriter: item)
        di.setDraggingFrame(NSRect(x: p.x - 12, y: p.y - h + 12, width: w, height: h), contents: image)
        beginDraggingSession(with: [di], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard operation != [], let file, let model else { return }
        let app = appUnder(screenPoint)
        MainActor.assumeIsolated { model.issued(via: "drag", app: app, file: file.lastPathComponent) }
    }

    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String { file?.lastPathComponent ?? "Копия.jpg" }

    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do {
            guard let file else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.copyItem(at: file, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }
}

struct CopyDrag: NSViewRepresentable {
    let model: ReprintModel
    let image: NSImage?
    func makeNSView(context: Context) -> CopyDragView {
        let v = CopyDragView()
        v.model = model
        v.image = image
        return v
    }
    func updateNSView(_ v: CopyDragView, context: Context) { v.image = image }
}

// MARK: - Sheet

struct ReprintSheet: View {
    @ObservedObject var model: ReprintModel
    var onClose: () -> Void
    var onDownloads: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(ReprintText.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(model.doc.title).font(.system(size: 13)).foregroundStyle(Theme.graphite).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
            Divider()
            switch model.stage {
            case .opening:
                Text(ReprintText.opening).font(.system(size: 13)).foregroundStyle(Theme.graphite)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                Text(model.error ?? "Отменено.").font(.system(size: 13)).foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 8) {
                        CopyDrag(model: model, image: model.preview)
                            .frame(width: 280, height: 330)
                            .accessibilityLabel("Копия \(model.code), перетащите в чат")
                        Text(ReprintText.drag).font(.system(size: 11)).foregroundStyle(Theme.graphite)
                            .multilineTextAlignment(.center).frame(width: 280)
                    }
                    controls
                }
                .padding(24)
            }
            Divider()
            HStack {
                if let n = model.note {
                    Text(n).font(.system(size: 12)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.stage == .ready {
                    Button(ReprintText.downloads) {
                        let d = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                        if let u = model.toDownloads(d) { onDownloads(u) }
                    }
                    .buttonStyle(CardButtonStyle())
                }
                Button(ReprintText.done, action: onClose).buttonStyle(CardButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 640, height: 520)
        .background(Theme.sheet)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ReprintText.purpose).font(.system(size: 12)).foregroundStyle(Theme.graphite)
            TextField(ReprintText.purposeHint, text: $model.purposeText)
                .textFieldStyle(.roundedBorder).font(.system(size: 14))
                .onChange(of: model.purposeText) { model.error = nil; model.refresh() }
            if !model.recent.isEmpty {
                FlowRow(items: model.recent) { p in
                    Button(p) { model.purposeText = p }.buttonStyle(ChipStyle(on: model.purposeText == p))
                }
            }
            if let e = model.error { Text(e).font(.system(size: 12)).foregroundStyle(Theme.ink) }
            HStack(spacing: 6) {
                Text("№").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Theme.graphite)
                Text(model.code).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 5).background(RoundedRectangle(cornerRadius: 3).fill(Theme.markerFill))
            }
            .padding(.top, 6)
            Text(ReprintText.fields).font(.system(size: 12)).foregroundStyle(Theme.graphite).padding(.top, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if model.detecting {
                        Text(ReprintText.searching).font(.system(size: 12)).foregroundStyle(Theme.graphite)
                    } else if model.fields.isEmpty {
                        Text(ReprintText.noFields).font(.system(size: 12)).foregroundStyle(Theme.graphite)
                    }
                    ForEach($model.fields) { $f in
                        Toggle(isOn: $f.hidden) {
                            Text(f.kind.title + (model.fields.contains { $0.page > 0 } ? ", стр. \(f.page + 1)" : ""))
                                .font(.system(size: 13)).foregroundStyle(Theme.ink)
                        }
                        .toggleStyle(.checkbox)
                        .onChange(of: f.hidden) { model.refresh() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ChipStyle: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .lineLimit(1)
            .padding(.horizontal, 8).frame(height: 22)
            .foregroundStyle(Theme.ink)
            .background(RoundedRectangle(cornerRadius: 11).fill(on ? Theme.markerFill : Theme.secondaryFill))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Chips that wrap to the next line.
struct FlowRow<Item: Hashable, V: View>: View {
    let items: [Item]
    let content: (Item) -> V
    var body: some View {
        FlowLayout(spacing: 6) { ForEach(items, id: \.self) { content($0) } }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x + z.width > w, x > 0 { x = 0; y += line + spacing; line = 0 }
            x += z.width + spacing; line = max(line, z.height)
        }
        return CGSize(width: w, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x + z.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += z.width + spacing; line = max(line, z.height)
        }
    }
}
