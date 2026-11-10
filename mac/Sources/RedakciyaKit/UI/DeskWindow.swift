import AppKit
import SwiftUI

enum DeskWindowText {
    static let title = "Стол"

    static func summary(total: Int, week: Int) -> String {
        if total == 0 { return "На столе пусто." }
        let files = plural(total, "файл", "файла", "файлов")
        return week == 0 ? "На столе \(total) \(files). На этой неделе ничего не уйдёт."
            : "На столе \(total) \(files). На этой неделе уйдут: \(week)."
    }

    static func left(_ v: DeskPolicy.Verdict) -> String {
        switch (v.stage, v.action) {
        case (.expired, .hold): return "ждёт: файл менялся"
        case (.expired, _): return "уйдёт при следующем проходе"
        default: return v.left == 1 ? "уйдёт завтра" : "через \(SettingsText.days(v.left))"
        }
    }

    static func detail(folder: String, flags: DeskPolicy.Flags) -> String {
        var parts = [folder]
        if flags.contains(.personal) && !flags.contains(.kept) { parts.append("документ") }
        else if flags.contains(.screenshot) { parts.append("скриншот") }
        return parts.joined(separator: ", ")
    }

    static let recent = "Убрано недавно"
    static let recentEmpty = "Стол ещё ничего не убирал."
    static let empty = "Файлов со сроком нет. Вложенные папки, скрытые и недокачанные файлы Стол не трогает."
    static let take = "Убрать сейчас"
    static let keep = "Не трогать"
    static let reveal = "Показать в Finder"
    static let bringBack = "Вернуть"
    static let showMoved = "Показать убранное"

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return one }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
        return many
    }

    static let moved: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM"
        return f
    }()
}

/// What the Desk window shows. Read on open and after every action; Desk has no change notifications.
@MainActor
final class DeskWindowModel: ObservableObject {
    struct Row: Identifiable {
        let id: String
        let url: URL
        let folder: String
        let verdict: DeskPolicy.Verdict
        let flags: DeskPolicy.Flags
    }

    struct Moved: Identifiable {
        let id: String
        let move: DeskMove
        let name: String
    }

    @Published var rows: [Row] = []
    @Published var moved: [Moved] = []
    let desk: Desk?

    init(desk: Desk?, rows: [Row] = [], moved: [Moved] = []) {
        self.desk = desk
        self.rows = rows
        self.moved = moved
    }

    var dueThisWeek: Int { rows.filter { $0.verdict.stage == .expired || $0.verdict.left <= 7 }.count }

    func reload() {
        guard let desk else { return }
        rows = desk.scan().filter { $0.verdict.stage != .skip }.map {
            Row(id: $0.url.path, url: $0.url, folder: Self.folderName($0.url), verdict: $0.verdict, flags: $0.flags)
        }.sorted { ($0.verdict.left, $0.url.lastPathComponent) < ($1.verdict.left, $1.url.lastPathComponent) }
        // Moves whose file is still in «Убрано со стола», newest first.
        let journal = desk.journal()
        let returned = Set(journal.filter { $0.kind == "returned" }.map(\.from))
        moved = journal.filter { $0.kind == "moved" && !returned.contains($0.to) && FileManager.default.fileExists(atPath: $0.to) }
            .suffix(12).reversed()
            .map { Moved(id: $0.to, move: $0, name: URL(fileURLWithPath: $0.to).lastPathComponent) }
    }

    static func folderName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
    }
}

struct DeskWindowView: View {
    @ObservedObject var model: DeskWindowModel
    var onTake: (URL) -> Void = { _ in }
    var onKeep: (URL) -> Void = { _ in }
    var onReturn: (DeskMove) -> Void = { _ in }
    var onShowMoved: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(DeskWindowText.summary(total: model.rows.count, week: model.dueThisWeek))
                .font(.system(size: 13))
                .foregroundStyle(Theme.graphite)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.rows.isEmpty {
                        Text(DeskWindowText.empty)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.graphite)
                            .padding(20)
                    }
                    ForEach(model.rows) { row in
                        fileRow(row)
                        Divider().padding(.leading, 52)
                    }
                    recent
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(DeskWindowText.showMoved, action: onShowMoved).buttonStyle(CardButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 520)
        .background(Theme.sheet)
    }

    private func fileRow(_ row: DeskWindowModel.Row) -> some View {
        let soon = row.verdict.stage == .aging || row.verdict.stage == .expired
        return HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: row.url.path))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.url.lastPathComponent)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(DeskWindowText.detail(folder: row.folder, flags: row.flags))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.graphite)
            }
            Spacer(minLength: 12)
            // The marker only on files that are about to go: what is worth a look.
            Text(DeskWindowText.left(row.verdict))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(soon ? Theme.ink : Theme.graphite)
                .padding(.horizontal, soon ? 4 : 0)
                .background(soon ? RoundedRectangle(cornerRadius: 3).fill(Theme.markerFill) : nil)
            Menu {
                Button(DeskWindowText.take) { onTake(row.url) }
                Button(DeskWindowText.keep) { onKeep(row.url) }
                Divider()
                Button(DeskWindowText.reveal) { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Действия с файлом \(row.url.lastPathComponent)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(DeskWindowText.recent)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 6)
            if model.moved.isEmpty {
                Text(DeskWindowText.recentEmpty)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.graphite)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
            ForEach(model.moved) { m in
                HStack(spacing: 12) {
                    Text(m.name)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(DeskWindowText.moved.string(from: m.move.at))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.graphite)
                    Button(DeskWindowText.bringBack) { onReturn(m.move) }
                        .accessibilityLabel("\(DeskWindowText.bringBack) \(m.name)")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }
        }
    }
}

@MainActor
final class DeskWindowController {
    private var window: NSWindow?
    private var model: DeskWindowModel?
    var desk: Desk?

    func show() {
        let model = self.model ?? DeskWindowModel(desk: desk)
        self.model = model
        model.reload()
        if window == nil {
            let view = DeskWindowView(
                model: model,
                onTake: { [weak self] url in self?.desk?.takeNow(url); model.reload() },
                onKeep: { url in
                    Prefs.shared.deskExcludedPaths.insert(url.path)
                    // Prefs reach Desk on the next run loop turn; reload after that.
                    DispatchQueue.main.async { model.reload() }
                },
                onReturn: { [weak self] m in self?.desk?.bringBack(m); model.reload() },
                onShowMoved: { [weak self] in
                    let url = self?.desk?.destination ?? Desk.defaultDestination
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
            )
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = DeskWindowText.title
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
