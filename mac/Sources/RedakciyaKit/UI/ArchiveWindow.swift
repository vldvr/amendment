import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ArchiveText {
    static let title = "Архив"
    static let intro = "Архив хранит документы зашифрованными: паспорт, СНИЛС, полис, карту. Открыть документ можно только с Touch ID на этом Mac или по 12 словам на бумаге. Список документов виден без Touch ID, содержимое — нет."
    static let create = "Создать Архив"
    static let recoverTitle = "Архив с другого Mac"
    static let recoverIntro = "В папке «Редакция/Архив» уже есть документы, но ключа этого Mac у них нет. Введите 12 слов, записанных при создании Архива."
    static let recover = "Открыть по словам"
    static let wordsTitle = "12 слов восстановления"
    static let wordsBody = "Запишите слова на бумагу по порядку. Без них Архив не открыть на другом Mac и после сброса этого. Редакция их не хранит и больше не покажет."
    static let wrote = "Записал"
    static func confirm(_ a: Int, _ b: Int) -> String { "Введите слова № \(a + 1) и № \(b + 1), чтобы проверить запись." }
    static let confirmDone = "Проверить"
    static let confirmWrong = "Слова не совпадают с записанными. Проверьте бумагу."
    static let back = "Показать слова ещё раз"
    static let add = "Сдать в Архив…"
    static let empty = "В Архиве пусто. Сдать документ: кнопка выше или перетащите файл в это окно. Стол сам предлагает сдать файлы, где нашёл паспорт или карту."
    static let open = "Открыть"
    static let restore = "Вернуть в Загрузки"
    static let edit = "Название и срок…"
    static let remove = "Убрать из Архива"
    static let noExpiry = "без срока"
    static let save = "Сохранить"
    static let cancel = "Отмена"
    static let hasExpiry = "Срок действия"

    static let kinds: [(id: String, title: String)] = [
        ("passport", "Паспорт"), ("snils", "СНИЛС"), ("inn", "ИНН"), ("oms", "Полис ОМС"),
        ("card", "Банковская карта"), ("account", "Реквизиты счёта"), ("other", "Документ"),
    ]
    static func kindTitle(_ id: String) -> String { kinds.first { $0.id == id }?.title ?? "Документ" }

    static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// «до марта 2031», «истёк в марте 2026».
    static func expiry(_ s: String?, now: Date = Date()) -> String {
        guard let s, let d = date(s) else { return noExpiry }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "MMMM yyyy"
        return d < now ? "истёк: \(monthYear.string(from: d))" : "до \(f.string(from: d))"
    }

    /// Less than three months left: worth a look.
    static func soon(_ s: String?, now: Date = Date()) -> Bool {
        guard let s, let d = date(s) else { return false }
        return d.timeIntervalSince(now) < 90 * 86400
    }
}

@MainActor
final class ArchiveWindowModel: ObservableObject {
    enum Stage: Equatable { case intro, words([String]), confirm([String], Int, Int), list, recover }
    @Published var stage: Stage
    @Published var error: String?
    @Published var editing: ArchiveDocument?
    @Published var reprint: ReprintModel?
    @Published var issuesTab = false
    let store: ArchiveStore
    let issues: IssuesModel

    init(store: ArchiveStore, stage: Stage? = nil) {
        self.store = store
        issues = IssuesModel(store: store)
        self.stage = stage ?? (store.isReady ? .list : store.needsRecovery ? .recover : .intro)
    }

    func create() {
        do {
            stage = .words(try store.setUp())
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func wrote(_ words: [String]) {
        let a = Int.random(in: 0..<6), b = Int.random(in: 6..<12)
        stage = .confirm(words, a, b)
    }

    func confirm(_ words: [String], _ a: Int, _ b: Int, _ x: String, _ y: String) {
        if Recovery.normalize(x) == words[a] && Recovery.normalize(y) == words[b] {
            stage = .list
            error = nil
        } else {
            error = ArchiveText.confirmWrong
        }
    }

    func recover(_ text: String) {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        do {
            try store.recover(words: words)
            stage = .list
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct ArchiveWindowView: View {
    @ObservedObject var model: ArchiveWindowModel
    @ObservedObject var store: ArchiveStore
    var onAdd: () -> Void = {}
    var onDrop: ([URL]) -> Void = { _ in }
    var onOpen: (ArchiveDocument) -> Void = { _ in }
    var onRestore: (ArchiveDocument) -> Void = { _ in }
    var onRemove: (ArchiveDocument) -> Void = { _ in }
    var onReprint: (ArchiveDocument) -> Void = { _ in }

    var body: some View {
        Group {
            switch model.stage {
            case .intro: intro
            case .words(let w): wordsView(w)
            case .confirm(let w, let a, let b): ConfirmWords(words: w, a: a, b: b, model: model)
            case .list: list
            case .recover: RecoverWords(model: model)
            }
        }
        .frame(width: 640, height: 560)
        .background(Theme.sheet)
        .sheet(item: $model.editing) { doc in
            EditDocument(doc: doc) { edited in
                try? store.update(edited)
                model.editing = nil
            } onCancel: { model.editing = nil }
        }
        .sheet(item: $model.reprint) { r in
            ReprintSheet(model: r) {
                model.issues.adopt(r.journal)
                model.reprint = nil
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ArchiveText.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(ArchiveText.intro).font(.system(size: 13)).foregroundStyle(Theme.graphite)
                .fixedSize(horizontal: false, vertical: true)
            if let e = model.error { Text(e).font(.system(size: 12)).foregroundStyle(Theme.ink) }
            Spacer()
            HStack {
                Spacer()
                Button(ArchiveText.create) { model.create() }
                    .buttonStyle(CardButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    private func wordsView(_ words: [String]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ArchiveText.wordsTitle).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(ArchiveText.wordsBody).font(.system(size: 13)).foregroundStyle(Theme.graphite)
                .fixedSize(horizontal: false, vertical: true)
            // Numbered: the order is part of the key.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 10) {
                ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.graphite)
                            .frame(width: 20, alignment: .trailing)
                        Text(w).font(.system(size: 16, weight: .medium, design: .monospaced)).foregroundStyle(Theme.ink)
                            .textSelection(.disabled)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button(ArchiveText.wrote) { model.wrote(words) }
                    .buttonStyle(CardButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $model.issuesTab) {
                Text(ReprintText.docsTab).tag(false)
                Text(ReprintText.issuesTab).tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            .padding(.top, 12).frame(maxWidth: .infinity)
            if model.issuesTab { IssuesView(model: model.issues) } else { documents }
        }
    }

    private var documents: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(store.documents.count) \(DeskWindowText.plural(store.documents.count, "документ", "документа", "документов"))")
                    .font(.system(size: 13)).foregroundStyle(Theme.graphite)
                Spacer()
                Button(ArchiveText.add, action: onAdd).buttonStyle(CardButtonStyle(primary: true))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            if let e = model.error {
                Text(e).font(.system(size: 12)).foregroundStyle(Theme.ink).padding(.horizontal, 20).padding(.top, 10)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if store.documents.isEmpty {
                        Text(ArchiveText.empty).font(.system(size: 12)).foregroundStyle(Theme.graphite)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(20)
                    }
                    ForEach(store.documents.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }) { doc in
                        row(doc)
                        Divider().padding(.leading, 52)
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { onDrop([url]) } }
                }
            }
            return true
        }
    }

    private func row(_ doc: ArchiveDocument) -> some View {
        let soon = ArchiveText.soon(doc.expires)
        return HStack(spacing: 12) {
            Image(systemName: doc.kind == "card" || doc.kind == "account" ? "creditcard" : "doc.text")
                .font(.system(size: 18))
                .foregroundStyle(Theme.graphite)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title).font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(1)
                Text("\(ArchiveText.kindTitle(doc.kind)), \(doc.original)")
                    .font(.system(size: 11)).foregroundStyle(Theme.graphite).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(ArchiveText.expiry(doc.expires))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(soon ? Theme.ink : Theme.graphite)
                .padding(.horizontal, soon ? 4 : 0)
                .background(soon ? RoundedRectangle(cornerRadius: 3).fill(Theme.markerFill) : nil)
            Button(ArchiveText.open) { onOpen(doc) }
            Menu {
                if ReprintSource.canReprint(doc.original) { Button(ReprintText.action) { onReprint(doc) } }
                Button(ArchiveText.restore) { onRestore(doc) }
                Button(ArchiveText.edit) { model.editing = doc }
                Divider()
                Button(ArchiveText.remove) { onRemove(doc) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Действия с документом \(doc.title)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

private struct ConfirmWords: View {
    let words: [String]
    let a: Int
    let b: Int
    @ObservedObject var model: ArchiveWindowModel
    @State private var x = ""
    @State private var y = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ArchiveText.wordsTitle).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(ArchiveText.confirm(a, b)).font(.system(size: 13)).foregroundStyle(Theme.graphite)
            HStack(spacing: 12) {
                field("№ \(a + 1)", $x)
                field("№ \(b + 1)", $y)
            }
            if let e = model.error { Text(e).font(.system(size: 12)).foregroundStyle(Theme.ink) }
            Spacer()
            HStack {
                Button(ArchiveText.back) { model.stage = .words(words); model.error = nil }.buttonStyle(CardButtonStyle())
                Spacer()
                Button(ArchiveText.confirmDone) { model.confirm(words, a, b, x, y) }
                    .buttonStyle(CardButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.graphite)
            TextField("", text: text).textFieldStyle(.roundedBorder).font(.system(size: 14, design: .monospaced))
                .autocorrectionDisabled()
        }
    }
}

private struct RecoverWords: View {
    @ObservedObject var model: ArchiveWindowModel
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ArchiveText.recoverTitle).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(ArchiveText.recoverIntro).font(.system(size: 13)).foregroundStyle(Theme.graphite)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 14, design: .monospaced))
                .autocorrectionDisabled()
                .frame(height: 90)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
                .accessibilityLabel("12 слов через пробел")
            if let e = model.error { Text(e).font(.system(size: 12)).foregroundStyle(Theme.ink) }
            Spacer()
            HStack {
                Spacer()
                Button(ArchiveText.recover) { model.recover(text) }
                    .buttonStyle(CardButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}

private struct EditDocument: View {
    @State var doc: ArchiveDocument
    var onSave: (ArchiveDocument) -> Void
    var onCancel: () -> Void
    @State private var hasExpiry = false
    @State private var expiry = Date()

    init(doc: ArchiveDocument, onSave: @escaping (ArchiveDocument) -> Void, onCancel: @escaping () -> Void) {
        _doc = State(initialValue: doc)
        self.onSave = onSave
        self.onCancel = onCancel
        _hasExpiry = State(initialValue: doc.expires != nil)
        _expiry = State(initialValue: doc.expires.flatMap(ArchiveText.date) ?? Date())
    }

    var body: some View {
        Form {
            TextField("Название", text: $doc.title)
            Picker("Вид", selection: $doc.kind) {
                ForEach(ArchiveText.kinds, id: \.id) { Text($0.title).tag($0.id) }
            }
            Toggle(ArchiveText.hasExpiry, isOn: $hasExpiry)
            if hasExpiry {
                DatePicker("Действует до", selection: $expiry, displayedComponents: .date)
            }
            HStack {
                Spacer()
                Button(ArchiveText.cancel, action: onCancel)
                Button(ArchiveText.save) {
                    doc.expires = hasExpiry ? ArchiveText.day(expiry) : nil
                    onSave(doc)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding(8)
    }
}

@MainActor
final class ArchiveWindowController {
    private var window: NSWindow?
    private var model: ArchiveWindowModel?
    private var closeObserver: Any?
    let store: ArchiveStore
    /// Title and kind for a file the detector already knows.
    var suggest: (URL) -> (title: String, kind: String) = { ($0.deletingPathExtension().lastPathComponent, "other") }
    /// Desk can take a copy out of Downloads: it is on and has the folder.
    var deskCleans: () -> Bool = { false }

    init(store: ArchiveStore) { self.store = store }

    func show() {
        store.reload()
        if window == nil {
            let model = ArchiveWindowModel(store: store)
            self.model = model
            let view = ArchiveWindowView(
                model: model, store: store,
                onAdd: { [weak self] in self?.pickAndAdd() },
                onDrop: { [weak self] urls in urls.forEach { self?.add($0) } },
                onOpen: { [weak self] doc in self?.run { NSWorkspace.shared.open(try self!.store.openCopy(doc)) } },
                onRestore: { [weak self] doc in
                    self?.run {
                        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                        NSWorkspace.shared.activateFileViewerSelecting([try self!.store.restore(doc, to: downloads)])
                    }
                },
                onRemove: { [weak self] doc in self?.run { try self!.store.remove(doc) } },
                onReprint: { [weak self] doc in
                    guard let self, let model = self.model else { return }
                    let r = ReprintModel(doc: doc, store: self.store, deskCleans: self.deskCleans())
                    model.reprint = r
                    Task { await r.open() }
                }
            )
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = ArchiveText.title
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated { model?.issues.lock() }
            }
            w.center()
            window = w
        } else if let model, model.stage == .intro || model.stage == .recover {
            model.stage = store.isReady ? .list : store.needsRecovery ? .recover : .intro
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func run(_ f: () throws -> Void) {
        do {
            try f()
            model?.error = nil
        } catch ArchiveError.cancelled {
            model?.error = nil
        } catch {
            model?.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func pickAndAdd() {
        let panel = NSOpenPanel()
        panel.title = ArchiveText.add
        panel.prompt = "Сдать"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(add)
    }

    func add(_ url: URL) {
        guard store.isReady else { show(); return }
        let s = suggest(url)
        run {
            let doc = try store.add(url, title: s.title, kind: s.kind)
            Log.write("archive: added \(doc.kind)")
            model?.editing = doc
        }
    }
}
