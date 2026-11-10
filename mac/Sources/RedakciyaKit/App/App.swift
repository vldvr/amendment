import AppKit
import Combine
import SwiftUI
import ZamazkaKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let editor = ClipboardEditor(rules: .bundled)
    let card = EditingCardController()
    let status = StatusItemController()
    let settings = SettingsWindowController()
    let onboarding = OnboardingWindowController()
    private var prefsSink: AnyCancellable?
    let updater = RulesUpdater()
    lazy var desk = Desk(folders: .system(), enabledAt: Prefs.shared.deskEnabledAt)
    private var deskTimer: Timer?
    let personal = PersonalScanner()
    let deskCard = DeskCardController()
    let screenshots = Screenshots()
    let deskWindow = DeskWindowController()
    let archive = ArchiveStore()
    lazy var archiveWindow = ArchiveWindowController(store: archive)
    private var rulesTimer: Timer?
    let events = EventLog()
    lazy var gazette = GazetteStore(log: events)
    lazy var gazetteWindow = GazetteWindowController(store: gazette)
    let gazetteCard = GazetteCardController()
    private var gazetteTimer: Timer?
    let sources = SourcesWatch()
    private var sourcesOn = false
    /// Set while Desk hands a document to the Archive, so the journal says who did it.
    private var archivingByDesk = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let prefs = Prefs.shared
        if let cached = updater.loadCached(newerThan: editor.rules.version) {
            editor.replaceRules(cached)
            Log.write("rules: cached v\(cached.version)")
        }
        scheduleRulesCheck()
        applyPrefs()
        // Menu and settings window write to Prefs; the editor and the icon follow.
        prefsSink = prefs.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPrefs() }
        }
        card.editor = editor
        card.anchorScreen = { [weak self] in self?.status.buttonScreen }
        editor.onEvent = { [weak self] event in
            Prefs.shared.tailsRemoved += 1
            Log.write("cleaned \(event.cleaned.kind.rawValue) in \(event.appID): \(event.cleaned.removed)")
            // For the morning issue: the service and the names of the tails, never the link.
            if let self, event.cleaned.kind != .none {
                self.events.write(GazetteEvent(at: Date(), kind: "link", class: event.cleaned.kind.rawValue, service: event.cleaned.domain,
                                               tails: EditingText.givingAway(event, rules: self.editor.rules)))
            }
            if event.cleaned.show == .card { self?.card.show(event) }
        }
        status.editor = editor
        status.desk = desk
        status.screenshots = screenshots
        deskWindow.desk = desk
        archive.purgeOpenCopies()
        ReprintModel.purgeDragCopies()
        let suggest: (URL) -> (title: String, kind: String) = { [weak self] url in
            if let k = self?.personal.kinds(url)?.first {
                let kind = k.rawValue
                return (ArchiveText.kindTitle(kind), kind)
            }
            return (url.deletingPathExtension().lastPathComponent, "other")
        }
        archiveWindow.suggest = suggest
        archiveWindow.deskCleans = { !Prefs.shared.deskPaused && Prefs.shared.deskFoldersAsked }
        status.onArchive = { [weak self] in self?.archiveWindow.show() }
        desk.archiver = { [weak self] url in
            guard let self, self.archive.isReady else { return nil }
            let s = suggest(url)
            self.archivingByDesk = true
            defer { self.archivingByDesk = false }
            do {
                let doc = try self.archive.add(url, title: s.title, kind: s.kind)
                Log.write("desk: archived \(doc.kind)")
                return self.archive.folder.appendingPathComponent(doc.file)
            } catch {
                Log.write("desk: archive failed: \(error)")
                return nil
            }
        }
        deskCard.archiveReady = { [weak self] in self?.archive.isReady ?? false }
        status.onDesk = { [weak self] in self?.deskWindow.show() }
        desk.isPersonal = { [weak self] in self?.personal.isPersonal($0) ?? false }
        deskCard.desk = desk
        deskCard.anchorScreen = { [weak self] in self?.status.buttonScreen }
        deskCard.onKeep = { url in Prefs.shared.deskKeptPaths.insert(url.path) }
        personal.onFound = { [weak self] url, kinds in
            guard let self, !Prefs.shared.deskPaused else { return }
            Log.write("desk: personal file found: \(kinds.map(\.rawValue))")
            self.deskCard.show(url: url, folder: FileManager.default.displayName(atPath: url.deletingLastPathComponent().path),
                               kinds: kinds, days: Prefs.shared.deskPersonalDays)
        }
        scheduleDesk()
        wireGazette()
        status.onSettings = { [weak self] in self?.settings.show() }
        status.install()
        screenshots.onChange = { [weak self] in self?.settings.refresh() }
        screenshots.install(anchorScreen: { [weak self] in self?.status.buttonScreen },
                            anchorFrame: { [weak self] in self?.status.buttonFrame })
        editor.start()
        onboarding.onDemo = { [weak self] in self?.card.show(Demo.event) }
        // Then Zamazka's own steps (screenshot folder, thumbnail), if it runs here.
        onboarding.onClose = { [weak self] in
            if self?.screenshots.running == true { ZamazkaEmbedded.showOnboardingIfNeeded() }
        }
        settings.screenshots = screenshots

        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.card.show(Demo.event)
            }
        }
        if !prefs.onboardingDone || CommandLine.arguments.contains("--onboarding") {
            onboarding.show()
        }
        if CommandLine.arguments.contains("--settings") { settings.show() }
    }

    /// A minute after launch, then once a day (spec/link-rules.md, «Раздача»).
    private func scheduleRulesCheck() {
        let first = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkRules()
                let daily = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkRules() }
                }
                RunLoop.main.add(daily, forMode: .common)
                self?.rulesTimer = daily
            }
        }
        RunLoop.main.add(first, forMode: .common)
        rulesTimer = first
    }

    private func checkRules() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let (outcome, rules) = await self.updater.check(current: self.editor.rules.version)
            if let rules { self.editor.replaceRules(rules) }
            Log.write("rules: \(outcome)")
        }
    }

    /// The journal of the morning issue hears every module; the issue comes at the cut (spec/gazette.md).
    private func wireGazette() {
        _ = Prefs.shared.gazetteStartedAt
        desk.onRecord = { [weak self] move, copy in
            switch move.kind {
            case "moved":
                self?.events.write(GazetteEvent(at: move.at, kind: "desk", what: "moved",
                                                name: URL(fileURLWithPath: move.from).lastPathComponent, copy: copy ? true : nil))
            case "returned":
                self?.events.write(GazetteEvent(at: move.at, kind: "desk", what: "returned",
                                                name: URL(fileURLWithPath: move.to).lastPathComponent))
            default: break // archived: the Archive writes its own record
            }
        }
        archive.onChange = { [weak self] what, doc in
            guard let self else { return }
            self.events.write(GazetteEvent(at: Date(), kind: "archive", what: what, title: doc.title,
                                           by: what == "added" ? (self.archivingByDesk ? "desk" : "hand") : nil))
        }
        // The document and the time only: the purpose and the code stay in the sealed journal.
        IssueJournal.onAppend = { [weak self] issue in
            self?.events.write(GazetteEvent(at: issue.at, kind: "issue", title: issue.title))
        }
        sources.onEvents = { [weak self] list in list.forEach { self?.events.write($0) } }
        status.gazette = gazette
        status.onGazette = { [weak self] in self?.gazetteWindow.show() }
        gazetteCard.anchorScreen = { [weak self] in self?.status.buttonScreen }
        gazetteCard.onRead = { [weak self] in self?.gazetteWindow.show() }
        let first = Timer(timeInterval: 20, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkGazette()
                let every = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkGazette() }
                }
                RunLoop.main.add(every, forMode: .common)
                self?.gazetteTimer = every
            }
        }
        RunLoop.main.add(first, forMode: .common)
        gazetteTimer = first
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkGazette() }
        }
    }

    private func checkGazette() {
        let prefs = Prefs.shared
        guard prefs.gazetteEnabled, prefs.onboardingDone,
              gazette.due(now: Date(), hour: prefs.gazetteHour, startedAt: prefs.gazetteStartedAt) != nil,
              // The hour so far goes to the journal first, so the issue reaches up to its cut.
              { sources.flush().forEach(events.write); return true }(),
              let issue = gazette.publish(hour: prefs.gazetteHour, startedAt: prefs.gazetteStartedAt, state: gazetteState()) else { return }
        Log.write("gazette: issue \(issue.number), \(issue.stories.count) stories")
        if prefs.gazetteCard { gazetteCard.show(issue) }
    }

    /// The modules at the cut (spec/gazette.md, «Состояние на момент среза»).
    private func gazetteState() -> GazetteState {
        let prefs = Prefs.shared
        var deskState: GazetteState.Desk?
        if !prefs.deskPaused, prefs.deskFoldersAsked {
            let items = desk.scan().filter { $0.verdict.stage != .skip }
            let next = items.filter { $0.flags.contains(.personal) && !$0.flags.contains(.kept) && !$0.flags.contains(.reprint) }
                .min { ($0.verdict.left, $0.url.lastPathComponent) < ($1.verdict.left, $1.url.lastPathComponent) }
            deskState = .init(files: items.count,
                              week: items.filter { $0.verdict.stage == .expired || $0.verdict.left <= 7 }.count,
                              next: next.map { .init(name: $0.url.lastPathComponent, left: $0.verdict.left, to: archive.isReady ? "archive" : "moved") })
        }
        let ready = archive.isReady
        return GazetteState(archive: ready, desk: deskState, documents: ready ? archive.documents.map {
            .init(title: $0.title, expires: $0.expires, added: GazetteStore.day($0.added, calendar: .current))
        } : [], sources: sources.working)
    }

    /// At launch (after a short pause) and once an hour (spec/desk.md, «Перенос»).
    private func scheduleDesk() {
        let first = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sweepDesk()
                let hourly = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sweepDesk() }
                }
                RunLoop.main.add(hourly, forMode: .common)
                self?.deskTimer = hourly
            }
        }
        RunLoop.main.add(first, forMode: .common)
        deskTimer = first
    }

    private func sweepDesk() {
        archive.purgeOpenCopies(olderThan: 3600)
        ReprintModel.purgeDragCopies()
        // Not before the person pressed «Разрешить» for the folders: macOS would ask out of the blue.
        guard !Prefs.shared.deskPaused, Prefs.shared.deskFoldersAsked else { return }
        // Images on the desk go to the detector; a card only for files that appeared in the last day.
        let now = Date()
        let items = desk.scan(now: now).filter { $0.verdict.stage != .skip }
        personal.check(items.map(\.url)) { url in
            items.first { $0.url == url }.map { now.timeIntervalSince($0.added) < 86400 } ?? false
        }
        let moved = desk.sweep()
        if !moved.isEmpty {
            Prefs.shared.deskLastMoved = moved.count
            Log.write("desk: moved \(moved.count)")
        }
    }

    private func applyPrefs() {
        let prefs = Prefs.shared
        desk.policy.plainDays = prefs.deskPlainDays
        desk.policy.screenshotDays = prefs.deskScreenshotDays
        desk.policy.personalDays = prefs.deskPersonalDays
        desk.keptPaths = prefs.deskKeptPaths
        desk.excludedPaths = prefs.deskExcludedPaths
        editor.excludedApps = prefs.excludedApps
        editor.paused = prefs.editingPaused
        editor.holdUntilAsked = !prefs.onboardingDone
        events.enabled = prefs.gazetteEnabled
        // The network is watched only while there is an issue to tell about it, and after the first-run window.
        let watch = prefs.gazetteEnabled && prefs.sourcesEnabled && prefs.onboardingDone
        if watch != sourcesOn {
            sourcesOn = watch
            if watch { sources.start() } else { sources.stop() }
        }
        status.refreshIcon()
        screenshots.apply()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ZamazkaEmbedded.shutdown()
        if sourcesOn { sources.stop() }
        archive.purgeOpenCopies()
    }

    /// A second launch from Finder or Launchpad opens the settings: there is no Dock icon to click.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { settings.show() }
        return true
    }
}

enum Demo {
    static let event: EditingEvent = {
        let original = "https://www.instagram.com/reel/C9xQ2mLp0aB/?igsh=MXd2a2xpbmZ6Z3Q0"
        return EditingEvent(original: original, cleaned: LinkCleaner(rules: .bundled).clean(original),
                            appID: "com.apple.Safari", appName: "Safari")
    }()
}

public enum RedakciyaMain {
    private static var delegate: AppDelegate?

    @MainActor
    public static func run() {
        if CLI.handle(CommandLine.arguments) { return }
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        app.run()
    }
}

/// Command-line helpers that do not start the app.
@MainActor
enum CLI {
    static func handle(_ args: [String]) -> Bool {
        // --card-png OUT.png [light|dark] [returned]: the Editing card as a picture, for review.
        if let i = args.firstIndex(of: "--card-png"), i + 1 < args.count {
            let dark = args.contains("dark")
            let model = EditingCardModel(event: Demo.event, rules: .bundled)
            model.returned = args.contains("returned")
            let view = EditingCardView(model: model, onReturn: {}, onCleanAgain: {}, onClose: {})
                .padding(28)
                .background(dark ? Color(nsColor: Theme.rgb(0x0F1012)) : Color(nsColor: Theme.rgb(0xC9CBC8)))
                .environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: view)
            r.scale = 2
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                }
            }
            print("wrote \(args[i + 1])")
            return true
        }
        // --desk-card-png OUT.png [dark] [moved]: the card «Похоже на паспорт» on a synthetic image.
        if let i = args.firstIndex(of: "--desk-card-png"), i + 1 < args.count {
            let dark = args.contains("dark")
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("IMG_4021.jpg")
            let rep = NSBitmapImageRep(cgImage: SyntheticImage.chat())
            try? rep.representation(using: .jpeg, properties: [:])?.write(to: tmp)
            let model = DeskCardModel(url: tmp, folder: "Загрузки", kinds: [.passport, .card], days: 3)
            if args.contains("moved") { model.state = .moved }
            let view = DeskCardView(model: model, onKeep: {}, onMove: {}, onReturn: {}, onClose: {})
                .padding(28)
                .background(dark ? Color(nsColor: Theme.rgb(0x0F1012)) : Color(nsColor: Theme.rgb(0xC9CBC8)))
                .environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: view)
            r.scale = 2
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                }
            }
            try? FileManager.default.removeItem(at: tmp)
            print("wrote \(args[i + 1])")
            return true
        }
        // --gazette-card-png OUT.png [dark]: the card «Вышел выпуск».
        if let i = args.firstIndex(of: "--gazette-card-png"), i + 1 < args.count {
            let dark = args.contains("dark")
            let view = GazetteCardView(issue: GazetteDemo.issue(), onLater: {}, onRead: {})
                .padding(28)
                .background(dark ? Color(nsColor: Theme.rgb(0x0F1012)) : Color(nsColor: Theme.rgb(0xC9CBC8)))
                .environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: view)
            r.scale = 2
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                }
            }
            print("wrote \(args[i + 1])")
            return true
        }
        // --icon-png OUT.png [side]: the app icon, for scripts/build-app.sh.
        if let i = args.firstIndex(of: "--icon-png"), i + 1 < args.count {
            let side = i + 2 < args.count ? Int(args[i + 2]) ?? 1024 : 1024
            do { try AppIcon.writePNG(args[i + 1], side: side) } catch { print("icon: \(error)"); exit(1) }
            print("wrote \(args[i + 1])")
            return true
        }
        // --window-png OUT.png onboarding|settings [dark] [allowed|asks|denied|empty]: a window as a picture.
        if let i = args.firstIndex(of: "--window-png"), i + 2 < args.count {
            let dark = args.contains("dark")
            let state: ClipboardAccess = args.contains("allowed") ? .allowed
                : args.contains("asks") ? .asks : args.contains("denied") ? .denied : .notAsked
            let access = AccessModel(fixed: state)
            let root: AnyView
            switch args[i + 2] {
            case "onboarding":
                access.emptyClipboard = args.contains("empty")
                root = AnyView(OnboardingView(access: access, onDemo: {}, onDone: {}))
            case "settings":
                let d = UserDefaults(suiteName: "redakciya.picture")!
                d.removePersistentDomain(forName: "redakciya.picture")
                let prefs = Prefs(defaults: d)
                prefs.tailsRemoved = 37
                prefs.editingPaused = args.contains("paused")
                let ids = args.contains("empty") ? [] : ["ru.keepcoder.Telegram", "com.apple.Safari"]
                let rows = ids.map { (id: $0, name: Apps.name($0), icon: Apps.icon($0)) }
                var view = SettingsView(prefs: prefs, access: access, excluded: rows)
                view.standaloneZamazka = args.contains("standalone")
                view.fullHeight = true
                root = AnyView(view)
            case "archive":
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("redakciya-picture-archive")
                try? FileManager.default.removeItem(at: dir)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let json = """
                {"format":1,"recovery":"age1kj6z6syx28wvdt0kejlwrw8wu0j5fjd870256cck7kr0lzc9t9msmjr9h8","devices":["x"],"documents":[
                {"id":"1","file":"IMG_4021.jpg.age","title":"Паспорт РФ","kind":"passport","expires":"2031-03-01","added":"2026-11-09T10:00:00Z","original":"IMG_4021.jpg","size":812345},
                {"id":"2","file":"zagran.pdf.age","title":"Загранпаспорт","kind":"passport","expires":"2027-01-15","added":"2026-11-09T10:00:00Z","original":"zagran.pdf","size":2345678},
                {"id":"3","file":"snils.jpg.age","title":"СНИЛС","kind":"snils","expires":null,"added":"2026-11-09T10:00:00Z","original":"скан СНИЛС.jpg","size":345678},
                {"id":"4","file":"polis.pdf.age","title":"Полис ОМС","kind":"oms","expires":null,"added":"2026-11-09T10:00:00Z","original":"polis.pdf","size":145678}]}
                """
                try? Data(json.utf8).write(to: dir.appendingPathComponent("archive.json"))
                let store = ArchiveStore(folder: dir, keyURL: dir.appendingPathComponent("k"), openFolder: dir, device: nil)
                // The fourth vector of spec/archive-format.md: random-looking bytes, so the picture shows no repeats.
                let words = Recovery.words(for: ArchiveSelfTest.hex("25e3587ccf33b770eab4c3fb60ae7044"), list: Recovery.list)
                let stage: ArchiveWindowModel.Stage = args.contains("intro") ? .intro : args.contains("words") ? .words(words)
                    : args.contains("recover") ? .recover : .list
                root = AnyView(ArchiveWindowView(model: ArchiveWindowModel(store: store, stage: stage), store: store))
            case "desk":
                let home = FileManager.default.homeDirectoryForCurrentUser
                func row(_ name: String, _ folder: String, _ dir: String, _ stage: DeskPolicy.Stage, _ left: Int,
                         _ flags: DeskPolicy.Flags = [], action: DeskPolicy.Action = .none) -> DeskWindowModel.Row {
                    let url = home.appendingPathComponent(dir).appendingPathComponent(name)
                    return DeskWindowModel.Row(id: url.path, url: url, folder: folder,
                                               verdict: DeskPolicy.Verdict(term: 30, stage: stage, action: action, left: left), flags: flags)
                }
                let rows = args.contains("empty") ? [] : [
                    row("IMG_4021.jpg", "Загрузки", "Downloads", .aging, 1, [.personal]),
                    row("Снимок экрана 2026-11-02 в 14.20.11.png", "Рабочий стол", "Desktop", .aging, 4, [.screenshot]),
                    row("заметки к встрече.txt", "Рабочий стол", "Desktop", .expired, 0, action: .hold),
                    row("invoice-2026-10.pdf", "Загрузки", "Downloads", .fresh, 19),
                    row("setup-4.2.1.dmg", "Загрузки", "Downloads", .fresh, 27),
                ]
                let moved = args.contains("empty") ? [] : [
                    DeskWindowModel.Moved(id: "1", move: DeskMove(at: Date().addingTimeInterval(-86400), from: "", to: "", kind: "moved"), name: "скан СНИЛС.pdf"),
                    DeskWindowModel.Moved(id: "2", move: DeskMove(at: Date().addingTimeInterval(-3 * 86400), from: "", to: "", kind: "moved"), name: "Снимок экрана 2026-10-20 в 09.12.40.png"),
                ]
                root = AnyView(DeskWindowView(model: DeskWindowModel(desk: nil, rows: rows, moved: moved)))
            case "gazette":
                // gazette [dark] [empty|first|many]: the issue of the mockup day, a quiet day, no issue yet, several issues.
                let model = GazetteWindowModel(store: nil, issue: args.contains("first") ? nil : GazetteDemo.issue(empty: args.contains("empty")))
                model.now = { GazetteComposer.instant("2026-11-09T12:00:00Z")! }
                if args.contains("many") { model.days = ["2026-11-07", "2026-11-08", "2026-11-09"]; model.index = 2 }
                root = AnyView(GazetteWindowView(model: model, fullHeight: true))
            default:
                print("unknown window \(args[i + 2])")
                exit(1)
            }
            let title = ["settings": SettingsText.windowTitle, "desk": DeskWindowText.title, "archive": ArchiveText.title, "gazette": GazetteText.title][args[i + 2]] ?? OnboardingText.title
            WindowPicture.write(root, title: title,
                                dark: dark, to: args[i + 1])
            print("wrote \(args[i + 1])")
            return true
        }
        return false
    }
}

/// Renders a SwiftUI view inside a real titled window, off screen, so AppKit controls (switches, buttons
/// in a Form) draw as they do in the app. ImageRenderer cannot draw those.
@MainActor
enum WindowPicture {
    static func write(_ view: AnyView, title: String, dark: Bool, to path: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance
        let host = NSHostingController(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable]
        w.title = title
        w.appearance = appearance
        w.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        w.orderFrontRegardless()
        // Let SwiftUI lay out and AppKit draw a few passes.
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        guard let frameView = w.contentView?.superview else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        appearance.performAsCurrentDrawingAppearance { frameView.cacheDisplay(in: bounds, to: rep) }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        w.orderOut(nil)
    }
}
