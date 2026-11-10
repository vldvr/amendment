import AppKit
import SwiftUI

/// Clipboard access as the windows show it. Read on demand and every half second while a window is open:
/// macOS has no change notification for it.
@MainActor
final class AccessModel: ObservableObject {
    @Published var access: ClipboardAccess
    /// The person pressed «Разрешить», but the clipboard was empty and macOS had nothing to ask about.
    @Published var emptyClipboard = false
    @Published var folders: DeskAccess.State
    private var timer: Timer?
    private let fixed: Bool

    init(fixed: ClipboardAccess? = nil) {
        access = fixed ?? ClipboardAccess.current()
        folders = fixed == nil ? DeskAccess.state() : (fixed == .allowed ? .granted : .notAsked)
        self.fixed = fixed != nil
    }

    func start() {
        guard !fixed, timer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !fixed else { return }
        let now = ClipboardAccess.current()
        if now != access { access = now }
        let f = DeskAccess.state()
        if f != folders { folders = f }
        if now != .notAsked { emptyClipboard = false }
    }

    func requestFolders() {
        DeskAccess.request()
        refresh()
    }

    func request() {
        emptyClipboard = !ClipboardAccess.request()
        refresh()
    }
}

enum OnboardingText {
    static let title = "Редакция"
    static let lead = "Убирает из скопированных ссылок хвосты, по которым сервис связывает ссылку с тем, кто ей поделился, и следит за сроками файлов на столе."
    static let scope = "Работает со ссылками из браузеров, Telegram, Discord и Spotify. Из Терминала, редакторов и остальных программ ссылки не трогает. Всё считается на этом Mac, ссылки никуда не уходят и не сохраняются."
    static let stepTitle = "Вставка из других программ"
    static let foldersTitle = "Загрузки, Рабочий стол и скриншоты"
    static func foldersText(_ s: DeskAccess.State) -> String {
        switch s {
        case .notAsked: return "Для Стола: у файлов в этих папках есть срок, старое переезжает в «Редакция/Убрано со стола». macOS спросит про каждую папку."
        case .granted: return "Разрешено. Ничего не удаляется: старое переезжает в «Редакция/Убрано со стола»."
        case .denied: return "Доступа нет, Стол не работает. Разрешите Редакции эти папки в разделе «Файлы и папки» настроек macOS."
        }
    }

    static func stepText(_ a: ClipboardAccess, emptyClipboard: Bool) -> String {
        if emptyClipboard { return "Буфер пуст, macOS не о чем спрашивать. Скопируйте любой текст и нажмите ещё раз." }
        switch a {
        case .notAsked: return "macOS спросит, можно ли Редакции читать буфер обмена. Разрешите: Редакция заглядывает в буфер, только когда текст скопирован в одной из этих программ."
        case .asks: return "macOS будет спрашивать про каждую скопированную ссылку. Чтобы не спрашивала, выберите «Разрешить» для Редакции в настройках macOS."
        case .denied: return "Вставка запрещена в настройках macOS, ссылки не чистятся. Разрешите её для Редакции в разделе «Вставка из других программ»."
        case .allowed: return "Разрешена. Редакция заглядывает в буфер, только когда текст скопирован в одной из этих программ."
        case .notNeeded: return "В этой версии macOS разрешение не нужно."
        }
    }
}

/// First run: what Editing does, and the one permission it needs. The person presses the button,
/// Redakciya reads the clipboard once, and macOS shows its paste alert right then, not on a random copy later.
struct OnboardingView: View {
    @ObservedObject var access: AccessModel
    var onDemo: () -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: AppIcon.image)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(OnboardingText.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(OnboardingText.lead)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 14)

            example
                .padding(.bottom, 12)

            Text(OnboardingText.scope)
                .font(.system(size: 12))
                .foregroundStyle(Theme.graphite)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)

            VStack(spacing: 0) {
                step
                Divider()
                foldersStep
            }
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.secondaryFill))

            HStack(spacing: 8) {
                Button("Показать на примере", action: onDemo).buttonStyle(CardButtonStyle())
                Spacer()
                Button("Готово", action: onDone)
                    .buttonStyle(CardButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 18)
        }
        .padding(22)
        .frame(width: 480, alignment: .leading)
        .background(Theme.sheet)
        .onAppear { access.start() }
        .onDisappear { access.stop() }
    }

    /// The same marked link as on the card: the tail under the marker, struck out.
    private var example: some View {
        var s = AttributedString()
        for p in EditingText.marked(Demo.event) {
            var a = AttributedString(p.text)
            if p.removed {
                a.backgroundColor = Theme.markerFill
                a.underlineStyle = Text.LineStyle(pattern: .solid, color: Theme.markerEdge)
                a.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Theme.ink)
            }
            s += a
        }
        return Text(s)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.ink)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
            .accessibilityLabel("Пример: ссылка Instagram, хвост igsh зачёркнут")
    }

    private var foldersStep: some View {
        let f = access.folders
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: f == .granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(f == .granted ? Theme.ink : Theme.graphite)
                .padding(.top, 1)
                .accessibilityLabel(f == .granted ? "Готово" : "Не сделано")
            VStack(alignment: .leading, spacing: 3) {
                Text(OnboardingText.foldersTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(OnboardingText.foldersText(f))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.graphite)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch f {
            case .notAsked: Button("Разрешить") { access.requestFolders() }.buttonStyle(CardButtonStyle())
            case .denied: Button("Открыть настройки") { DeskAccess.openSystemSettings() }.buttonStyle(CardButtonStyle())
            case .granted: EmptyView()
            }
        }
        .padding(.vertical, 12)
    }

    private var step: some View {
        let a = access.access
        let done = a.works
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(done ? Theme.ink : Theme.graphite)
                .padding(.top, 1)
                .accessibilityLabel(done ? "Готово" : "Не сделано")
            VStack(alignment: .leading, spacing: 3) {
                Text(OnboardingText.stepTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(OnboardingText.stepText(a, emptyClipboard: access.emptyClipboard))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.graphite)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch a {
            case .notAsked:
                Button("Разрешить") { access.request() }.buttonStyle(CardButtonStyle())
            case .asks, .denied:
                Button("Открыть настройки") { ClipboardAccess.openSystemSettings() }.buttonStyle(CardButtonStyle())
            case .allowed, .notNeeded:
                EmptyView()
            }
        }
        .padding(.vertical, 12)
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let access = AccessModel()
    var onDemo: () -> Void = {}
    var onClose: () -> Void = {}

    func show() {
        if window == nil {
            let view = OnboardingView(access: access, onDemo: { [weak self] in self?.onDemo() }) { [weak self] in
                Prefs.shared.onboardingDone = true
                self?.window?.close()
            }
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Редакция"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closing with the red button also counts: the window is not forced on the person twice.
    func windowWillClose(_ notification: Notification) {
        Prefs.shared.onboardingDone = true
        DispatchQueue.main.async { [weak self] in self?.onClose() }
    }
}
