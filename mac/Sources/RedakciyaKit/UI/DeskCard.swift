import AppKit
import SwiftUI
import ZamazkaKit

/// Wording of the card «Похоже на паспорт» (design/mockups, card-desk). Until there is an Archive the file
/// goes to «Убрано со стола», so the card says that and not «в Архиве он будет зашифрован».
enum DeskCardText {
    static func from(_ folder: String) -> String {
        switch folder {
        case "Загрузки": return "Стол, новый файл в Загрузках"
        case "Рабочий стол": return "Стол, новый файл на Рабочем столе"
        default: return "Стол, новый файл в папке «\(folder)»"
        }
    }

    static func title(_ kinds: [FindingKind]) -> String {
        let what: [FindingKind: String] = [
            .passport: "паспорт", .snils: "СНИЛС", .inn: "ИНН", .oms: "полис ОМС",
            .card: "банковскую карту", .account: "номер счёта",
        ]
        return "Похоже на " + (kinds.first.flatMap { what[$0] } ?? "документ")
    }

    static func found(_ kinds: [FindingKind]) -> String {
        let name: [FindingKind: String] = [
            .passport: "паспорт", .snils: "СНИЛС", .inn: "ИНН", .oms: "полис ОМС", .card: "карта", .account: "счёт",
        ]
        return "Найдено: " + kinds.compactMap { name[$0] }.joined(separator: ", ") + "."
    }

    static func body(days: Int) -> String {
        "Стол уберёт его через \(SettingsText.days(days)) в «Редакция/Убрано со стола». Если файл нужен, оставьте его: срок станет обычным."
    }

    static func bodyArchive(days: Int) -> String {
        "Через \(SettingsText.days(days)) Стол сдаст его в Архив: там он будет зашифрован и откроется только с Touch ID. Если файл нужен на столе, оставьте его."
    }
    static let archivedTitle = "Сдано в Архив"
    static let archivedBody = "Файл зашифрован в «Редакция/Архив», оригинал в Корзине. Открыть или вернуть можно в окне Архива."
    static let movedTitle = "Убрано со стола"
    static let movedBody = "Файл в «Редакция/Убрано со стола». Ничего не удалено."
    static let returnedBody = "Файл вернулся на место."
}

@MainActor
final class DeskCardModel: ObservableObject {
    enum State { case found, moved, archived, returned }
    let url: URL
    let folder: String
    let kinds: [FindingKind]
    let days: Int
    let size: String
    let thumbnail: NSImage?
    /// The Archive is set up: documents go there instead of «Убрано со стола».
    var archive = false
    @Published var state = State.found

    init(url: URL, folder: String, kinds: [FindingKind], days: Int, thumbnail: NSImage? = nil) {
        self.url = url
        self.folder = folder
        self.kinds = kinds
        self.days = days
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        self.thumbnail = thumbnail ?? NSImage(contentsOf: url)
    }
}

struct DeskCardView: View {
    @ObservedObject var model: DeskCardModel
    var onKeep: () -> Void
    var onMove: () -> Void
    var onReturn: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "tray").font(.system(size: 12))
                Text(DeskCardText.from(model.folder))
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.graphite)
            .padding(.bottom, 6)

            Text(model.state == .found ? DeskCardText.title(model.kinds)
                 : model.state == .archived ? DeskCardText.archivedTitle : DeskCardText.movedTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.bottom, 8)

            HStack(spacing: 10) {
                Group {
                    if let t = model.thumbnail {
                        Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Theme.paper
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.url.lastPathComponent)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(model.folder), \(model.size). \(DeskCardText.found(model.kinds))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
            .padding(.bottom, 10)

            Text(bodyText)
                .font(.system(size: 13))
                .foregroundStyle(Theme.graphite)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)

            HStack(spacing: 8) {
                Spacer()
                switch model.state {
                case .found:
                    Button("Оставить", action: onKeep).buttonStyle(CardButtonStyle())
                    Button(model.archive ? "Сдать в Архив" : "Убрать сейчас", action: onMove)
                        .buttonStyle(CardButtonStyle(primary: true))
                        .keyboardShortcut(.defaultAction)
                case .moved:
                    Button("Вернуть на место", action: onReturn).buttonStyle(CardButtonStyle())
                    Button("Готово", action: onClose)
                        .buttonStyle(CardButtonStyle(primary: true))
                        .keyboardShortcut(.defaultAction)
                case .returned, .archived:
                    Button("Готово", action: onClose)
                        .buttonStyle(CardButtonStyle(primary: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(width: 364, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.sheet))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.ink.opacity(0.14), lineWidth: 0.5))
        .shadow(color: Color(red: 40 / 255, green: 44 / 255, blue: 40 / 255).opacity(0.18), radius: 16, x: 0, y: 10)
    }

    private var bodyText: String {
        switch model.state {
        case .found: return model.archive ? DeskCardText.bodyArchive(days: model.days) : DeskCardText.body(days: model.days)
        case .archived: return DeskCardText.archivedBody
        case .moved: return DeskCardText.movedBody
        case .returned: return DeskCardText.returnedBody
        }
    }
}

/// The card panel under the menu bar icon, as the Editing card. Stays until the person decides.
@MainActor
final class DeskCardController {
    private var panel: NSPanel?
    private var model: DeskCardModel?
    private var lastMove: DeskMove?
    var anchorScreen: () -> NSScreen? = { nil }
    var desk: Desk?
    var onKeep: (URL) -> Void = { _ in }

    var archiveReady: () -> Bool = { false }

    func show(url: URL, folder: String, kinds: [FindingKind], days: Int) {
        let model = DeskCardModel(url: url, folder: folder, kinds: kinds, days: days)
        model.archive = archiveReady()
        self.model = model
        let view = DeskCardView(
            model: model,
            onKeep: { [weak self] in
                self?.onKeep(url)
                self?.close()
            },
            onMove: { [weak self] in
                guard let self, let m = self.desk?.takeNow(url, flags: [.personal]) else { return }
                self.lastMove = m
                model.state = m.kind == "archived" ? .archived : .moved
                self.layout()
            },
            onReturn: { [weak self] in
                guard let self, let m = self.lastMove, self.desk?.bringBack(m) == true else { return }
                model.state = .returned
                self.layout()
            },
            onClose: { [weak self] in self?.close() }
        )
        let p = panel ?? makePanel()
        panel = p
        p.contentView = NSHostingView(rootView: view.padding(28))
        layout()
        p.alphaValue = 1
        p.orderFrontRegardless()
    }

    private func layout() {
        guard let p = panel, let host = p.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = (anchorScreen() ?? NSScreen.main)?.visibleFrame ?? .zero
        let pad: CGFloat = 28
        p.setFrame(NSRect(x: screen.maxX - 14 + pad - size.width, y: screen.maxY - 6 + pad - size.height,
                          width: size.width, height: size.height), display: true)
    }

    func close() {
        panel?.orderOut(nil)
        model = nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        return p
    }
}
