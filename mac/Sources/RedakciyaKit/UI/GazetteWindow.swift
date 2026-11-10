import AppKit
import SwiftUI

/// Wording around the issue that is not part of the issue itself (spec/gazette.md, «Окно выпуска», «Доставка»).
enum GazetteText {
    static let title = "Утренний выпуск"
    static let name = "Редакция"
    static let weather = "Погода приватности:"
    static func number(_ n: Int) -> String { "Выпуск № \(n)" }
    static let previous = "Предыдущий"
    static let next = "Следующий"
    static func position(_ i: Int, of n: Int) -> String { "\(i) из \(n)" }
    static func firstComes(today: Bool, hour: Int) -> String { "Первый выпуск выйдет \(today ? "сегодня" : "завтра") в \(hour):00" }
    static let firstNote = "В нём будет то, что уходит с компьютера: ссылки, копии документов, файлы со стола."
    static let offTitle = "Утренний выпуск выключен"
    static let offNote = "Включить его можно в настройках Редакции."
    static func cardTitle(_ n: Int) -> String { "Вышел выпуск № \(n)" }
    static let later = "Позже"
    static let read = "Читать"
    static let menu = "Утренний выпуск…"
    static let unread = "новый"
}

/// The serif of the paper: Spectral when it ships with the app (Resources/Fonts), the system serif otherwise.
enum GazetteFont {
    static let hasSpectral: Bool = {
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
           let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files where ["ttf", "otf"].contains(f.pathExtension.lowercased()) {
                CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            }
        }
        return NSFontManager.shared.availableMembers(ofFontFamily: "Spectral") != nil
    }()

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        hasSpectral ? .custom("Spectral", size: size).weight(weight) : .system(size: size, weight: weight, design: .serif)
    }
}

enum GazetteMarkup {
    /// `==text==` becomes text under the marker; everything else stays as written.
    static func attributed(_ s: String) -> AttributedString {
        var out = AttributedString()
        for (i, part) in s.components(separatedBy: "==").enumerated() {
            var piece = AttributedString(part)
            if i % 2 == 1 { piece.backgroundColor = Theme.markerFill }
            out += piece
        }
        return out
    }

    static func plain(_ s: String) -> String { s.replacingOccurrences(of: "==", with: "") }
}

/// The printed page: masthead, weather, the lead and the side column, standing rubrics, colophon.
struct GazettePage: View {
    let issue: GazetteIssue
    static let width: CGFloat = 880
    private let pad: CGFloat = 44
    private var inner: CGFloat { Self.width - pad * 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            masthead
            doubleRule.padding(.top, 12)
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                (Text(GazetteText.weather).fontWeight(.semibold).foregroundColor(Theme.ink) + Text(" " + issue.weather))
                Spacer(minLength: 12)
                Text(issue.week).monospacedDigit().fixedSize().layoutPriority(1)
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.graphite)
            .padding(.vertical, 9)
            rule

            front.padding(.top, 22)

            doubleRule.padding(.top, 22)
            HStack(alignment: .top, spacing: 0) {
                sources.padding(.trailing, 24).frame(width: inner * 0.4, alignment: .leading)
                Rectangle().fill(Theme.rule).frame(width: 1)
                document.padding(.horizontal, 24).frame(width: inner * 0.33, alignment: .leading)
                Rectangle().fill(Theme.rule).frame(width: 1)
                issued.padding(.leading, 24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)

            HStack(alignment: .firstTextBaseline) {
                Text(issue.colophon.first ?? "")
                Spacer(minLength: 16)
                Text(issue.colophon.last ?? "").monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.graphite)
            .padding(.top, 26)
        }
        .padding(EdgeInsets(top: 34, leading: pad, bottom: 40, trailing: pad))
        .frame(width: Self.width, alignment: .leading)
        .background(Theme.paper)
        .textSelection(.enabled)
    }

    private var rule: some View { Rectangle().fill(Theme.rule).frame(height: 1) }

    private var doubleRule: some View {
        VStack(spacing: 2) {
            Rectangle().fill(Theme.ink).frame(height: 1)
            Rectangle().fill(Theme.ink).frame(height: 1)
        }
        .accessibilityHidden(true)
    }

    private var masthead: some View {
        HStack(alignment: .lastTextBaseline, spacing: 16) {
            Text(issue.dateline).frame(maxWidth: .infinity, alignment: .leading)
            Text(GazetteText.name)
                .font(GazetteFont.serif(64, .bold))
                .foregroundStyle(Theme.ink)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
            Text(GazetteText.number(issue.number)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.graphite)
    }

    @ViewBuilder
    private var front: some View {
        let lead = issue.stories.first
        let side = Array(issue.stories.dropFirst())
        if let lead {
            if side.isEmpty {
                leadView(lead).frame(maxWidth: 600, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    leadView(lead).padding(.trailing, 32).frame(width: inner * 1.55 / 2.55, alignment: .leading)
                    Rectangle().fill(Theme.rule).frame(width: 1)
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(side.enumerated()), id: \.offset) { i, s in
                            if i > 0 { rule }
                            sideView(s)
                        }
                    }
                    .padding(.leading, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rubric(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.graphite)
    }

    private func paragraph(_ s: String, size: CGFloat) -> some View {
        Text(GazetteMarkup.attributed(s))
            .font(GazetteFont.serif(size))
            .lineSpacing(size * 0.3)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func leadView(_ s: GazetteIssue.Story) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            rubric(s.rubric).padding(.bottom, 6)
            Text(GazetteMarkup.plain(s.title))
                .font(GazetteFont.serif(40, .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 14)
            if let first = s.body.first { paragraph(first, size: 19).padding(.bottom, 14) }
            if !s.items.isEmpty { items(s.items, more: s.more).padding(.bottom, 14) }
            ForEach(Array(s.body.dropFirst().enumerated()), id: \.offset) { _, p in
                paragraph(p, size: 16).padding(.bottom, 10)
            }
        }
    }

    private func sideView(_ s: GazetteIssue.Story) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            rubric(s.rubric).padding(.bottom, 6)
            Text(GazetteMarkup.plain(s.title))
                .font(GazetteFont.serif(23, .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 8)
            if let first = s.body.first { paragraph(first, size: 16).padding(.bottom, 8) }
            if !s.items.isEmpty { items(s.items, more: s.more).padding(.bottom, 8) }
            ForEach(Array(s.body.dropFirst().enumerated()), id: \.offset) { _, p in
                paragraph(p, size: 16).padding(.bottom, 8)
            }
        }
    }

    /// Rows of one or two cells: a label (service, or date and time in monospace) and the text.
    private func items(_ rows: [[String]], more: String, label: CGFloat = 92) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if row.count > 1 {
                        let digits = row[0].first?.isNumber == true
                        Text(row[0])
                            .font(digits ? .system(size: 12, design: .monospaced) : .system(size: 13, weight: .semibold))
                            .frame(width: label, alignment: .leading)
                    }
                    Text(GazetteMarkup.attributed(row.last ?? ""))
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.ink)
                .accessibilityElement(children: .combine)
            }
            if !more.isEmpty {
                Text(more).font(.system(size: 12)).foregroundStyle(Theme.graphite)
            }
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 0) {
            rubric(issue.sources.rubric).padding(.bottom, 6)
            if !issue.sources.title.isEmpty {
                Text(issue.sources.title)
                    .font(GazetteFont.serif(21, .semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 8)
            }
            if !issue.sources.items.isEmpty { items(issue.sources.items, more: issue.sources.more, label: 84) }
            if !issue.sources.note.isEmpty {
                Text(issue.sources.note).font(.system(size: 13)).foregroundStyle(Theme.graphite)
            }
        }
    }

    private var document: some View {
        VStack(alignment: .leading, spacing: 0) {
            rubric(issue.document.rubric).padding(.bottom, 4)
            Text(issue.document.title)
                .font(GazetteFont.serif(26, .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 6)
            if !issue.document.note.isEmpty {
                Text(issue.document.note)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var issued: some View {
        VStack(alignment: .leading, spacing: 0) {
            rubric(issue.issued.rubric).padding(.bottom, 8)
            if issue.issued.items.isEmpty {
                Text(issue.issued.note).font(.system(size: 13)).foregroundStyle(Theme.graphite)
            } else {
                items(issue.issued.items, more: issue.issued.more, label: 44)
            }
        }
    }
}

@MainActor
final class GazetteWindowModel: ObservableObject {
    @Published var days: [String] = []
    @Published var index = 0
    @Published var issue: GazetteIssue?
    let store: GazetteStore?
    /// What to say while there is no issue yet.
    var enabled = true
    var hour = 8
    var now: () -> Date = { Date() }

    init(store: GazetteStore?, issue: GazetteIssue? = nil) {
        self.store = store
        self.issue = issue
    }

    /// Opens on the newest issue.
    func reload() {
        guard let store else { return }
        days = store.days()
        index = max(0, days.count - 1)
        issue = days.last.flatMap(store.load)
    }

    func step(_ by: Int) {
        guard let store, days.indices.contains(index + by) else { return }
        index += by
        issue = store.load(days[index])
    }

    var placeholder: (title: String, note: String) {
        guard enabled else { return (GazetteText.offTitle, GazetteText.offNote) }
        let n = now()
        let next = GazetteStore.nextCut(now: n, hour: hour)
        return (GazetteText.firstComes(today: Calendar.current.isDate(next, inSameDayAs: n), hour: hour), GazetteText.firstNote)
    }
}

struct GazetteWindowView: View {
    @ObservedObject var model: GazetteWindowModel
    /// Pictures show the whole page; the window scrolls.
    var fullHeight = false

    var body: some View {
        VStack(spacing: 0) {
            if let issue = model.issue {
                if fullHeight {
                    GazettePage(issue: issue)
                } else {
                    ScrollView { GazettePage(issue: issue) }
                        .frame(width: GazettePage.width, height: 680)
                        .background(Theme.paper)
                }
            } else {
                let p = model.placeholder
                VStack(spacing: 10) {
                    Text(p.title).font(GazetteFont.serif(28, .semibold)).foregroundStyle(Theme.ink)
                    Text(p.note).font(.system(size: 13)).foregroundStyle(Theme.graphite).multilineTextAlignment(.center)
                }
                .padding(44)
                .frame(width: GazettePage.width, height: 360)
                .background(Theme.paper)
            }
            if model.days.count > 1 {
                Divider()
                HStack(spacing: 10) {
                    Button(GazetteText.previous) { model.step(-1) }.disabled(model.index == 0)
                    Button(GazetteText.next) { model.step(1) }.disabled(model.index >= model.days.count - 1)
                    Spacer()
                    Text(GazetteText.position(model.index + 1, of: model.days.count))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.graphite)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(width: GazettePage.width)
                .background(Theme.sheet)
            }
        }
    }
}

@MainActor
final class GazetteWindowController {
    private var window: NSWindow?
    private var model: GazetteWindowModel?
    let store: GazetteStore

    init(store: GazetteStore) { self.store = store }

    func show() {
        let model = self.model ?? GazetteWindowModel(store: store)
        self.model = model
        model.enabled = Prefs.shared.gazetteEnabled
        model.hour = Prefs.shared.gazetteHour
        model.reload()
        if let n = store.latest?.number, n > Prefs.shared.gazetteReadNumber { Prefs.shared.gazetteReadNumber = n }
        if window == nil {
            let host = NSHostingController(rootView: GazetteWindowView(model: model))
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.title = GazetteText.title
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - The card «Вышел выпуск»

struct GazetteCardView: View {
    let issue: GazetteIssue
    var onLater: () -> Void
    var onRead: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "newspaper").font(.system(size: 12)).accessibilityHidden(true)
                Text("\(GazetteText.title), \(issue.dateline.prefix(1).lowercased() + issue.dateline.dropFirst())")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.graphite)
            .padding(.bottom, 6)

            Text(GazetteText.cardTitle(issue.number))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.bottom, 6)

            Text(GazetteMarkup.plain(issue.stories.first?.title ?? ""))
                .font(.system(size: 13))
                .foregroundStyle(Theme.graphite)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)

            HStack(spacing: 8) {
                Spacer()
                Button(GazetteText.later, action: onLater).buttonStyle(CardButtonStyle())
                Button(GazetteText.read, action: onRead)
                    .buttonStyle(CardButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(width: 364, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.sheet))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.ink.opacity(0.14), lineWidth: 0.5))
        .shadow(color: Color(red: 40 / 255, green: 44 / 255, blue: 40 / 255).opacity(0.18), radius: 16, x: 0, y: 10)
    }
}

/// The card panel under the menu bar icon, as the Editing and Desk cards. Stays until the person decides.
@MainActor
final class GazetteCardController {
    private var panel: NSPanel?
    var anchorScreen: () -> NSScreen? = { nil }
    var onRead: () -> Void = {}

    func show(_ issue: GazetteIssue) {
        let view = GazetteCardView(issue: issue, onLater: { [weak self] in self?.close() },
                                   onRead: { [weak self] in self?.close(); self?.onRead() })
        let p = panel ?? makePanel()
        panel = p
        let host = NSHostingView(rootView: view.padding(28))
        p.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = (anchorScreen() ?? NSScreen.main)?.visibleFrame ?? .zero
        let pad: CGFloat = 28
        p.setFrame(NSRect(x: screen.maxX - 14 + pad - size.width, y: screen.maxY - 6 + pad - size.height,
                          width: size.width, height: size.height), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
    }

    func close() { panel?.orderOut(nil) }

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

/// A sample issue for pictures: the day of the mockup, composed by the real composer.
enum GazetteDemo {
    static func issue(empty: Bool = false) -> GazetteIssue {
        func at(_ s: String) -> Date { GazetteComposer.instant(s)! }
        var events: [GazetteEvent] = [
            GazetteEvent(at: at("2026-11-03T09:10:00Z"), kind: "issue", title: "Диплом"),
            GazetteEvent(at: at("2026-11-05T12:40:00Z"), kind: "issue", title: "СНИЛС"),
        ]
        if !empty {
            events += [
                GazetteEvent(at: at("2026-11-08T11:18:00Z"), kind: "issue", title: "Паспорт РФ"),
                GazetteEvent(at: at("2026-11-08T12:00:00Z"), kind: "link", class: "gives_away", service: "instagram", tails: ["igsh"]),
                GazetteEvent(at: at("2026-11-08T15:30:00Z"), kind: "link", class: "gives_away", service: "spotify", tails: ["si"]),
                GazetteEvent(at: at("2026-11-08T17:00:00Z"), kind: "desk", what: "moved", name: "invoice-2026-10.pdf"),
                GazetteEvent(at: at("2026-11-08T17:00:00Z"), kind: "desk", what: "moved", name: "setup-4.2.1.dmg"),
                GazetteEvent(at: at("2026-11-08T17:00:01Z"), kind: "archive", what: "added", title: "Полис ОМС", by: "desk"),
            ]
            func net(_ at: String, _ app: String, _ to: String, _ sent: Int, cloud: Bool = false, first: Bool = false) -> GazetteEvent {
                var e = GazetteEvent(at: GazetteComposer.instant(at)!, kind: "net")
                e.app = app; e.to = to; e.sent = sent; e.got = 0; e.cloud = cloud ? true : nil; e.first = first ? true : nil
                return e
            }
            events += [
                net("2026-11-09T00:00:00Z", "Dropbox", "Dropbox", 1_288_490_189),
                net("2026-11-08T18:00:00Z", "Wispr Flow", "Amazon", 2_000_000, cloud: true, first: true),
                net("2026-11-08T12:00:00Z", "Telegram", "Telegram", 195_035_136),
            ]
            events += (0..<14).map { GazetteEvent(at: at("2026-11-08T16:00:00Z").addingTimeInterval(Double($0) * 60), kind: "link", class: "tracks") }
        }
        let state = GazetteState(archive: true, desk: .init(files: 23, week: empty ? 0 : 4, next: nil), documents: [
            .init(title: "Паспорт РФ", expires: "2031-03-01", added: "2026-11-01"),
            .init(title: "Загранпаспорт", expires: "2027-03-14", added: "2026-11-02"),
        ], sources: true)
        return GazetteComposer.compose(GazetteInput(number: empty ? 7 : 41, from: "2026-11-08T05:00:00Z", to: "2026-11-09T05:00:00Z",
                                                    tz: 180, hour: 8, events: events, state: state))!
    }
}
