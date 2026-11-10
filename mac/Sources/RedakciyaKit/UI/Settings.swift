import AppKit
import SwiftUI
import ZamazkaKit

enum SettingsText {
    static let windowTitle = "Настройки Редакции"
    static let pause = "Пауза Редактуры"
    static let pauseNote = "На паузе ссылки не чистятся, значок в строке меню приглушён."
    static let counter = "Убрано хвостов"
    static let reset = "Сбросить"
    static let excludedHeader = "Не трогать ссылки из"
    static let excludedEmpty = "Пока ни одной программы. Добавить можно здесь или из меню, когда Редактура сработала в программе."
    static let add = "Добавить программу…"
    static let remove = "Убрать"
    static let access = "Вставка из других программ"
    static let deskHeader = "Стол"
    static let deskPause = "Пауза Стола"
    static let deskNote = "Загрузки, Рабочий стол и скриншоты. Когда срок выходит, файл переезжает в «Редакция/Убрано со стола», вернуть можно из меню. Ничего не удаляется."
    static let deskPlain = "Обычный файл"
    static let deskShot = "Скриншот"
    static let deskPersonal = "С личными данными"
    static let deskFolder = "Убранное"
    static let show = "Показать"
    static func days(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        let word = m10 == 1 && m100 != 11 ? "день" : (2...4).contains(m10) && !(12...14).contains(m100) ? "дня" : "дней"
        return "\(n) \(word)"
    }
    static let openSettings = "Открыть настройки macOS"
    static let login = "Открывать при входе"
    static let shotsHeader = "Скриншоты"
    static let shots = "Замазка на скриншотах"
    static let shotsNote = "Закрывает на новых скриншотах телефон, карту, паспорт, адрес, ключи. Если отдельная Замазка запущена, скриншоты проверяет она."
    static let shotsStandalone = "Сейчас скриншоты проверяет отдельная Замазка."
    static let shotsHere = "Проверять здесь"
    static let shotsSettings = "Настройки Замазки…"
    static let gazetteHeader = "Утренний выпуск"
    static let gazette = "Собирать выпуск"
    static let gazetteHour = "Выходит в"
    static let gazetteCard = "Показывать карточку о новом выпуске"
    static let gazetteSources = "Рубрика «Источники»"
    static let gazetteNote = "Газета о том, что было за сутки. Собирается на этом Mac из записей Редакции: сервис и имя хвоста ссылки, название документа, имя файла. Самих ссылок и назначений копий в записях нет. Для «Источников» Редакция смотрит, с какими компаниями говорят программы и сколько отправляют; адреса и сайты не записываются. Когда выпуск выключен, записи не ведутся."
    static let footer = "Настройки хранятся на этом Mac. Ссылки и история копирования не сохраняются."
}

/// Settings of Editing. Everything lives in Prefs on this Mac; nothing leaves it.
struct SettingsView: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var access: AccessModel
    /// Replaced when rendering pictures, so they do not depend on what is installed.
    var excluded: [(id: String, name: String, icon: NSImage)]? = nil
    var onAdd: () -> Void = {}
    /// Screenshots: whether the standalone Zamazka runs now, and the two buttons.
    var standaloneZamazka = false
    var onQuitZamazka: () -> Void = {}
    var onZamazkaSettings: () -> Void = {}
    /// Pictures show the whole form; the window scrolls, so it fits a 13-inch screen.
    var fullHeight = false

    private func term(_ title: String, _ value: Binding<Int>) -> some View {
        Stepper(value: value, in: 1...365) {
            HStack {
                Text(title).foregroundStyle(Theme.ink)
                Spacer()
                Text(SettingsText.days(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { prefs.editingPaused }, set: { prefs.editingPaused = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SettingsText.pause).foregroundStyle(Theme.ink)
                        Text(SettingsText.pauseNote).font(.system(size: 11)).foregroundStyle(Theme.graphite)
                    }
                }
                LabeledContent {
                    HStack(spacing: 10) {
                        Text("\(prefs.tailsRemoved)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                        Button(SettingsText.reset) { prefs.tailsRemoved = 0 }
                            .disabled(prefs.tailsRemoved == 0)
                    }
                } label: {
                    Text(SettingsText.counter).foregroundStyle(Theme.ink)
                }
            }

            Section {
                let rows = excluded ?? prefs.excludedApps.map { (id: $0, name: Apps.name($0), icon: Apps.icon($0)) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                if rows.isEmpty {
                    Text(SettingsText.excludedEmpty)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(rows, id: \.id) { row in
                    HStack(spacing: 8) {
                        Image(nsImage: row.icon).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
                        Text(row.name).foregroundStyle(Theme.ink)
                        Spacer()
                        Button(SettingsText.remove) { prefs.excludedApps.remove(row.id) }
                            .accessibilityLabel("\(SettingsText.remove) \(row.name)")
                    }
                }
                HStack {
                    Spacer()
                    Button(SettingsText.add, action: onAdd)
                }
            } header: {
                Text(SettingsText.excludedHeader)
            }

            Section {
                Toggle(isOn: Binding(get: { prefs.screenshotsEnabled }, set: { prefs.screenshotsEnabled = $0 })) {
                    Text(SettingsText.shots).foregroundStyle(Theme.ink)
                }
                if prefs.screenshotsEnabled {
                    if standaloneZamazka {
                        LabeledContent {
                            Button(SettingsText.shotsHere, action: onQuitZamazka)
                        } label: {
                            Text(SettingsText.shotsStandalone).foregroundStyle(Theme.graphite)
                        }
                    } else {
                        HStack {
                            Spacer()
                            Button(SettingsText.shotsSettings, action: onZamazkaSettings)
                        }
                    }
                }
            } header: {
                Text(SettingsText.shotsHeader)
            } footer: {
                Text(SettingsText.shotsNote)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.graphite)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle(isOn: Binding(get: { prefs.deskPaused }, set: { prefs.deskPaused = $0 })) {
                    Text(SettingsText.deskPause).foregroundStyle(Theme.ink)
                }
                term(SettingsText.deskPlain, Binding(get: { prefs.deskPlainDays }, set: { prefs.deskPlainDays = $0 }))
                term(SettingsText.deskShot, Binding(get: { prefs.deskScreenshotDays }, set: { prefs.deskScreenshotDays = $0 }))
                term(SettingsText.deskPersonal, Binding(get: { prefs.deskPersonalDays }, set: { prefs.deskPersonalDays = $0 }))
                LabeledContent {
                    HStack(spacing: 10) {
                        Text(DeskAccess.status(access.folders)).foregroundStyle(Theme.graphite)
                        switch access.folders {
                        case .notAsked: Button("Разрешить") { access.requestFolders() }
                        case .denied: Button(SettingsText.openSettings) { DeskAccess.openSystemSettings() }
                        case .granted: EmptyView()
                        }
                    }
                } label: {
                    Text("Доступ к папкам").foregroundStyle(Theme.ink)
                }
                LabeledContent {
                    Button(SettingsText.show) {
                        let url = Desk.defaultDestination
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text(SettingsText.deskFolder).foregroundStyle(Theme.ink)
                }
            } header: {
                Text(SettingsText.deskHeader)
            } footer: {
                Text(SettingsText.deskNote)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.graphite)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle(isOn: Binding(get: { prefs.gazetteEnabled }, set: { prefs.gazetteEnabled = $0 })) {
                    Text(SettingsText.gazette).foregroundStyle(Theme.ink)
                }
                if prefs.gazetteEnabled {
                    Stepper(value: Binding(get: { prefs.gazetteHour }, set: { prefs.gazetteHour = $0 }), in: 0...23) {
                        HStack {
                            Text(SettingsText.gazetteHour).foregroundStyle(Theme.ink)
                            Spacer()
                            Text("\(prefs.gazetteHour):00").monospacedDigit().foregroundStyle(Theme.ink)
                        }
                    }
                    Toggle(isOn: Binding(get: { prefs.sourcesEnabled }, set: { prefs.sourcesEnabled = $0 })) {
                        Text(SettingsText.gazetteSources).foregroundStyle(Theme.ink)
                    }
                    Toggle(isOn: Binding(get: { prefs.gazetteCard }, set: { prefs.gazetteCard = $0 })) {
                        Text(SettingsText.gazetteCard).foregroundStyle(Theme.ink)
                    }
                }
            } header: {
                Text(SettingsText.gazetteHeader)
            } footer: {
                Text(SettingsText.gazetteNote)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.graphite)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                LabeledContent {
                    HStack(spacing: 10) {
                        Text(access.access.status).foregroundStyle(Theme.graphite)
                        if !access.access.works && access.access != .notAsked {
                            Button(SettingsText.openSettings) { ClipboardAccess.openSystemSettings() }
                        }
                    }
                } label: {
                    Text(SettingsText.access).foregroundStyle(Theme.ink)
                }
                Toggle(isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.launchAtLogin = $0 })) {
                    Text(SettingsText.login).foregroundStyle(Theme.ink)
                }
            } footer: {
                Text(SettingsText.footer)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.graphite)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .modifier(SettingsHeight(full: fullHeight))
        .onAppear { access.start() }
        .onDisappear { access.stop() }
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let access = AccessModel()
    var screenshots: Screenshots?
    private var host: NSHostingController<SettingsView>?

    private func makeView() -> SettingsView {
        var view = SettingsView(prefs: .shared, access: access) {
            if let id = Apps.pick() { Prefs.shared.excludedApps.insert(id) }
        }
        view.standaloneZamazka = screenshots?.standaloneRunning ?? false
        view.onQuitZamazka = { [weak self] in self?.screenshots?.quitStandalone() }
        view.onZamazkaSettings = { ZamazkaEmbedded.showSettings() }
        return view
    }

    /// The standalone Zamazka started or quit: the screenshots row changes.
    func refresh() { host?.rootView = makeView() }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: makeView())
            self.host = host
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.title = SettingsText.windowTitle
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        access.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsHeight: ViewModifier {
    let full: Bool
    func body(content: Content) -> some View {
        if full { content.fixedSize(horizontal: false, vertical: true) } else { content.frame(height: 620) }
    }
}
