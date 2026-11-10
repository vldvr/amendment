import AppKit
import Combine
import Foundation
import RedakciyaKit
import ZamazkaKit

// Shared corpus from spec/. Same verdicts as the Python references in spec/tools/ and `cargo test` on Windows.
//   swift run redakciya-checks            # all suites
//   swift run redakciya-checks links      # one suite

let spec = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("spec")

func readTSV(_ name: String) throws -> (header: [String: Int], rows: [[String]]) {
    let text = try String(contentsOf: spec.appendingPathComponent(name), encoding: .utf8)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        .filter { !$0.allSatisfy(\.isWhitespace) }
        .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    var header: [String: Int] = [:]
    for (i, n) in lines[0].enumerated() { header[n] = i }
    return (header, Array(lines.dropFirst()))
}

/// spec/link-cases.tsv against spec/link-rules.json. Returns the number of problems.
func checkLinks() throws -> Int {
    var failed = 0
    let data = try Data(contentsOf: spec.appendingPathComponent("link-rules.json"))
    let rules: LinkRules
    do {
        rules = try LinkRules.load(data)
    } catch {
        print("FAIL rules: \(error)")
        return 1
    }
    let cleaner = LinkCleaner(rules: rules)
    let (col, rows) = try readTSV("link-cases.tsv")
    var fired = Set<String>()
    var ids = Set<String>()
    for r in rows {
        let id = r[col["id"]!]
        let wantOut = r[col["output"]!], wantKind = r[col["class"]!], wantShow = r[col["show"]!]
        let wantRemoved = r[col["removed"]!].split(separator: ",").map(String.init)
        var problems: [String] = []
        if !ids.insert(id).inserted { problems.append("duplicate id") }
        let got = cleaner.clean(r[col["input"]!], fired: &fired)
        if !got.output.unicodeScalars.elementsEqual(wantOut.unicodeScalars) {
            problems.append("output \(got.output.debugDescription), want \(wantOut.debugDescription)")
        }
        if got.kind.rawValue != wantKind { problems.append("class \(got.kind.rawValue), want \(wantKind)") }
        if got.show.rawValue != wantShow { problems.append("show \(got.show.rawValue), want \(wantShow)") }
        if got.removed != wantRemoved { problems.append("removed \(got.removed), want \(wantRemoved)") }
        let again = cleaner.clean(got.output)
        if again.kind != .none || !again.removed.isEmpty || again.output != got.output {
            problems.append("not idempotent: \(again)")
        }
        if !problems.isEmpty {
            failed += 1
            print("FAIL \(id): " + problems.joined(separator: "; "))
        }
    }
    for key in rules.allRuleKeys.subtracting(fired).sorted() {
        failed += 1
        print("FAIL coverage: no case triggers rule \(key)")
    }
    print("links: \(rows.count) cases, rules v\(rules.version): " + (failed == 0 ? "all passed" : "\(failed) problems"))
    return failed
}

// `redakciya-checks links-stdin`: one input per line → `output<TAB>class<TAB>removed`, for diffing with other implementations.
if CommandLine.arguments.dropFirst().first == "links-stdin" {
    let cleaner = LinkCleaner(rules: try LinkRules.load(Data(contentsOf: spec.appendingPathComponent("link-rules.json"))))
    while let line = readLine(strippingNewline: true) {
        let r = cleaner.clean(line)
        print("\(r.output)\t\(r.kind.rawValue)\t\(r.removed.joined(separator: ","))")
    }
    exit(0)
}

/// The built-in copy of the rules must be spec/link-rules.json byte for byte (scripts/sync-spec.sh).
func checkBundled() throws -> Int {
    let wordsText = try String(contentsOf: spec.appendingPathComponent("recovery-words-ru.txt"), encoding: .utf8)
    if wordsText.trimmingCharacters(in: .newlines) != RecoveryWordsCopy.text.trimmingCharacters(in: .newlines) {
        print("FAIL bundled: recovery words differ from spec/recovery-words-ru.txt, run mac/scripts/sync-spec.sh")
        return 1
    }
    let templates = try String(contentsOf: spec.appendingPathComponent("gazette/ru/templates.txt"), encoding: .utf8)
    if templates.trimmingCharacters(in: .newlines) != GazetteTemplates.bundledText.trimmingCharacters(in: .newlines) {
        print("FAIL bundled: gazette templates differ from spec/gazette/ru/templates.txt, run mac/scripts/sync-spec.sh")
        return 1
    }
    let specText = try String(contentsOf: spec.appendingPathComponent("link-rules.json"), encoding: .utf8)
    let same = LinkRules.bundledJSON == specText || LinkRules.bundledJSON + "\n" == specText
    print("bundled: " + (same ? "rules, recovery words and gazette templates match spec" : "FAIL stale copy, run mac/scripts/sync-spec.sh"))
    return same ? 0 : 1
}

/// The clipboard side of Redaktura on a private pasteboard, with a fake active app.
@MainActor
func checkEditor() -> Int {
    var failed = 0
    func expect(_ ok: Bool, _ what: String) {
        if !ok { failed += 1; print("FAIL editor: \(what)") }
    }
    let pb = NSPasteboard(name: NSPasteboard.Name("redakciya-checks-\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    var app: (id: String, name: String)? = ("com.apple.Safari", "Safari")
    let editor = ClipboardEditor(rules: .bundled, pasteboard: pb, frontmost: { app })
    var events: [EditingEvent] = []
    editor.onEvent = { events.append($0) }

    func copy(_ s: String, html: Bool = false, extra: String? = nil) {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(s, forType: .string)
        if html { item.setString("<a href=\"\(s)\">x</a>", forType: .html) }
        if let extra { item.setData(Data(), forType: NSPasteboard.PasteboardType(extra)) }
        pb.writeObjects([item])
    }
    let ig = "https://www.instagram.com/reel/C9x/?igsh=MXd2"
    let clean = "https://www.instagram.com/reel/C9x/"

    copy(ig, html: true)
    editor.poll()
    expect(pb.string(forType: .string) == clean, "Safari link is cleaned")
    expect(pb.data(forType: .html) == nil, "rich copy with the old link is dropped")
    expect(events.count == 1 && events.last?.cleaned.show == .card, "one card event")
    editor.poll()
    expect(events.count == 1, "own write is not handled again")

    expect(editor.returnTail(), "return works while the clean link is on the clipboard")
    expect(pb.string(forType: .string) == ig && pb.data(forType: .html) != nil, "original comes back with all types")
    editor.poll()
    expect(events.count == 1 && pb.string(forType: .string) == ig, "returned original is not cleaned again")
    expect(editor.cleanAgain() && pb.string(forType: .string) == clean, "clean again")

    copy("something else")
    editor.poll()
    expect(!editor.returnTail() && pb.string(forType: .string) == "something else", "return never overwrites a new copy")
    expect(!editor.lastIsCurrent, "card goes stale")

    app = ("com.apple.Terminal", "Terminal")
    editor.poll()
    copy(ig)
    editor.poll()
    expect(pb.string(forType: .string) == ig, "terminal link is untouched")

    app = ("ru.keepcoder.Telegram", "Telegram")
    editor.poll()
    copy("https://youtu.be/abc?si=XYZ&t=4")
    editor.poll()
    expect(pb.string(forType: .string) == "https://youtu.be/abc?t=4", "Telegram (native) link is cleaned")

    copy("https://example.com/?utm_source=a")
    editor.poll()
    expect(pb.string(forType: .string) == "https://example.com/" && events.last?.cleaned.show == .silent, "tracks only is silent")

    copy(ig, extra: "org.nspasteboard.ConcealedType")
    editor.poll()
    expect(pb.string(forType: .string) == ig, "concealed item is untouched")

    copy("смотри " + ig)
    editor.poll()
    expect(pb.string(forType: .string) == "смотри " + ig, "text with a link inside is untouched")

    // The copy happened while the person switched apps: cannot tell where, leave it.
    copy(ig)
    app = ("com.apple.Safari", "Safari")
    editor.poll()
    expect(pb.string(forType: .string) == ig, "copy during an app switch is untouched")
    editor.poll()

    editor.excludedApps = ["com.apple.Safari"]
    copy(ig)
    editor.poll()
    expect(pb.string(forType: .string) == ig, "excluded app is untouched")
    editor.excludedApps = []

    editor.paused = true
    copy(ig)
    editor.poll()
    expect(pb.string(forType: .string) == ig, "paused")
    editor.paused = false

    copy(ig)
    editor.poll()
    expect(pb.string(forType: .string) == clean, "works again after pause and exclusion")

    print("editor: " + (failed == 0 ? "all passed" : "\(failed) problems"))
    return failed
}

/// Prefs on a private UserDefaults domain: counter, exclusions, pause, first run. Nothing else is stored.
@MainActor
func checkPrefs() -> Int {
    var failed = 0
    func expect(_ ok: Bool, _ what: String) {
        if !ok { failed += 1; print("FAIL prefs: \(what)") }
    }
    let name = "redakciya.checks.prefs"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    defer { d.removePersistentDomain(forName: name) }
    let p = Prefs(defaults: d)
    expect(p.tailsRemoved == 0 && !p.editingPaused && !p.onboardingDone && p.excludedApps.isEmpty, "fresh defaults")
    var changes = 0
    let sink = p.objectWillChange.sink { changes += 1 }
    p.tailsRemoved += 1
    p.tailsRemoved += 1
    expect(Prefs(defaults: d).tailsRemoved == 2, "counter survives a restart")
    p.tailsRemoved = 0
    expect(Prefs(defaults: d).tailsRemoved == 0, "counter reset")
    p.excludedApps.insert("ru.keepcoder.Telegram")
    p.excludedApps.insert("com.apple.Safari")
    expect(d.stringArray(forKey: "editing.excludedApps") == ["com.apple.Safari", "ru.keepcoder.Telegram"], "exclusions stored sorted")
    p.excludedApps.remove("com.apple.Safari")
    expect(Prefs(defaults: d).excludedApps == ["ru.keepcoder.Telegram"], "exclusion removed")
    p.editingPaused = true
    expect(Prefs(defaults: d).editingPaused, "pause stored")
    p.onboardingDone = true
    expect(Prefs(defaults: d).onboardingDone, "first run remembered")
    expect(changes == 8, "every write notifies the editor and the icon (\(changes) of 8)")
    sink.cancel()
    let keys = Set(d.dictionaryRepresentation().keys.filter { $0.hasPrefix("editing.") || $0.hasPrefix("onboarding.") })
    expect(keys == ["editing.tailsRemoved", "editing.excludedApps", "editing.paused", "onboarding.done"], "only known keys: \(keys.sorted())")
    print("prefs: " + (failed == 0 ? "all passed" : "\(failed) problems"))
    return failed
}

/// Wording for clipboard access: a warning in the menu always comes with a way to fix it.
func checkAccess() -> Int {
    var failed = 0
    func expect(_ ok: Bool, _ what: String) {
        if !ok { failed += 1; print("FAIL access: \(what)") }
    }
    let all: [ClipboardAccess] = [.notNeeded, .notAsked, .asks, .allowed, .denied]
    for a in all {
        expect((a.menuWarning == nil) == (a.menuFix == nil), "\(a): warning and fix go together")
        expect(!a.status.isEmpty, "\(a): status")
        for t in [a.status, a.menuWarning ?? "", a.menuFix ?? ""] where t.contains("—") || t.contains("!") {
            expect(false, "\(a): dry text without dashes and exclamations: \(t)")
        }
    }
    expect(ClipboardAccess.denied.menuWarning != nil, "denied shows in the menu")
    expect(ClipboardAccess.allowed.menuWarning == nil && ClipboardAccess.notAsked.menuWarning == nil, "quiet when fine or not asked yet")
    expect(all.filter(\.works) == [.notNeeded, .allowed], "works only without asking")
    print("access: " + (failed == 0 ? "all passed" : "\(failed) problems"))
    return failed
}

/// The app icon: transparent corners, paper in the middle, one marker line.
func checkIcon() -> Int {
    var failed = 0
    func expect(_ ok: Bool, _ what: String) {
        if !ok { failed += 1; print("FAIL icon: \(what)") }
    }
    for side in [16, 1024] {
        let img = AppIcon.draw(side: side)
        expect(img.width == side && img.height == side, "\(side): size")
    }
    let rep = NSBitmapImageRep(cgImage: AppIcon.draw(side: 1024))
    func px(_ x: Int, _ y: Int) -> NSColor { rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)! }
    expect(px(4, 4).alphaComponent < 0.01, "corner is transparent")
    let paper = px(700, 250)
    expect(abs(paper.redComponent - 0xED / 255.0) < 0.02 && abs(paper.blueComponent - 0xE7 / 255.0) < 0.02, "sheet is newspaper paper")
    var marker = 0
    for x in stride(from: 0, to: 1024, by: 4) {
        for y in stride(from: 0, to: 1024, by: 4) {
            let c = px(x, y)
            if c.redComponent > 0.95, (0.70...0.86).contains(c.greenComponent), c.blueComponent < 0.25 { marker += 1 }
        }
    }
    expect(marker > 100, "marker is there")
    print("icon: " + (failed == 0 ? "all passed" : "\(failed) problems"))
    return failed
}

/// Rules from the server (spec/link-rules.md, «Раздача»): only valid and newer files are taken and cached.
@MainActor
func checkUpdater() async -> Int {
    var failed = 0
    func expect(_ ok: Bool, _ what: String) {
        if !ok { failed += 1; print("FAIL updater: \(what)") }
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("redakciya-updater-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = dir.appendingPathComponent("Redakciya/link-rules.json")
    let base = LinkRules.bundledJSON
    let current = LinkRules.bundled.version
    func bumped(_ v: Int) -> Data {
        Data(base.replacingOccurrences(of: "\"version\": \(current),", with: "\"version\": \(v),").utf8)
    }
    let newer = bumped(current + 1)
    let u = RulesUpdater(cacheURL: cache, fetch: { _ in (newer, 200) })

    expect(u.loadCached(newerThan: current) == nil, "no cache at first")
    var (o, r) = u.accept(Data(base.utf8), status: 200, current: current)
    expect(o == .notNewer(version: current) && r == nil, "same version is ignored: \(o)")
    expect(!FileManager.default.fileExists(atPath: cache.path), "same version is not cached")
    (o, r) = u.accept(newer, status: 404, current: current)
    expect(o == .rejected("status 404"), "non-200 rejected: \(o)")
    (o, _) = u.accept(Data("{".utf8), status: 200, current: current)
    if case .rejected = o {} else { expect(false, "broken JSON rejected: \(o)") }
    (o, _) = u.accept(Data(base.replacingOccurrences(of: "\"format\": 1,", with: "\"format\": 2,").replacingOccurrences(of: "\"version\": \(current),", with: "\"version\": \(current + 5),").utf8), status: 200, current: current)
    if case .rejected = o {} else { expect(false, "unknown format rejected: \(o)") }
    (o, _) = u.accept(Data(count: RulesUpdater.maxBytes + 1), status: 200, current: current)
    if case .rejected = o {} else { expect(false, "too big rejected: \(o)") }
    expect(!FileManager.default.fileExists(atPath: cache.path), "nothing cached after rejections")

    (o, r) = await u.check(current: current)
    expect(o == .accepted(version: current + 1) && r?.version == current + 1, "newer accepted: \(o)")
    expect((try? Data(contentsOf: cache)) == newer, "cached byte for byte")
    expect(u.loadCached(newerThan: current)?.version == current + 1, "cache loaded on next launch")
    expect(u.loadCached(newerThan: current + 1) == nil, "cache not newer than what we have is not used")
    (o, _) = await u.check(current: current + 1)
    expect(o == .notNewer(version: current + 1), "second check: nothing new")

    try? Data("not json".utf8).write(to: cache)
    expect(u.loadCached(newerThan: current) == nil, "broken cache ignored")
    expect(FileManager.default.fileExists(atPath: cache.path), "broken cache left in place, not deleted")

    let offline = RulesUpdater(cacheURL: cache, fetch: { _ in throw URLError(.notConnectedToInternet) })
    (o, r) = await offline.check(current: current)
    if case .rejected = o, r == nil {} else { expect(false, "offline keeps rules: \(o)") }

    print("updater: " + (failed == 0 ? "all passed" : "\(failed) problems"))
    return failed
}

/// `redakciya-checks updater-live`: the published file must equal spec/link-rules.json. Needs the network.
func checkUpdaterLive() async -> Int {
    do {
        let (data, status) = try await RulesUpdater.httpFetch(RulesUpdater.url)
        let spec = try Data(contentsOf: spec.appendingPathComponent("link-rules.json"))
        let ok = status == 200 && data == spec
        print("updater-live: " + (ok ? "published file matches spec" : "FAIL status \(status), \(data == spec ? "same" : "differs from spec")"))
        return ok ? 0 : 1
    } catch {
        print("FAIL updater-live: \(error)")
        return 1
    }
}

func runAsync(_ f: @escaping @MainActor () async -> Int) -> Int {
    var result = 1
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in
        result = await f()
        done.signal()
    }
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    return result
}

/// spec/desk-cases.tsv: terms and stages of Desk.
func checkDeskCases() throws -> Int {
    var failed = 0
    let (col, rows) = try readTSV("desk-cases.tsv")
    let policy = DeskPolicy()
    func day(_ s: String) -> DateComponents {
        let p = s.split(separator: "-").map { Int($0)! }
        return DateComponents(year: p[0], month: p[1], day: p[2])
    }
    var ids = Set<String>()
    for r in rows {
        let id = r[col["id"]!]
        var problems: [String] = []
        if !ids.insert(id).inserted { problems.append("duplicate id") }
        var flags: DeskPolicy.Flags = []
        for f in r[col["flags"]!].split(separator: ",") {
            if let v = DeskPolicy.Flags.names[String(f)] { flags.insert(v) } else { problems.append("unknown flag \(f)") }
        }
        let v = policy.evaluate(name: r[col["name"]!], flags: flags, added: day(r[col["added"]!]),
                                enabled: day(r[col["enabled"]!]), modified: day(r[col["modified"]!]),
                                today: day(r[col["today"]!]))
        let want = "\(r[col["term"]!]) \(r[col["stage"]!]) \(r[col["action"]!])"
        let got = "\(v.term) \(v.stage.rawValue) \(v.action.rawValue)"
        if got != want { problems.append("got \(got), want \(want)") }
        if !problems.isEmpty {
            failed += 1
            print("FAIL desk \(id): " + problems.joined(separator: "; "))
        }
    }
    print("desk: \(rows.count) cases: " + (failed == 0 ? "all passed" : "\(failed) problems"))
    return failed
}

/// Desk on temporary folders: what moves, what stays, names, journal, return. Never touches real folders.
@MainActor
func checkDeskFiles() -> Int {
    var failed = 0
    func expect(_ ok: Bool, _ what: String) {
        if !ok { failed += 1; print("FAIL desk-files: \(what)") }
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("redakciya-desk-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let downloads = root.appendingPathComponent("Downloads"), shots = root.appendingPathComponent("Shots")
    let dest = root.appendingPathComponent("Убрано со стола"), journal = root.appendingPathComponent("journal.jsonl")
    for d in [downloads, shots] { try! fm.createDirectory(at: d, withIntermediateDirectories: true) }
    let now = Date()
    let later = now.addingTimeInterval(40 * 86400)
    let old = now.addingTimeInterval(-400 * 86400)
    func file(_ dir: URL, _ name: String, modified: Date = old) -> URL {
        let u = dir.appendingPathComponent(name)
        try! Data("x".utf8).write(to: u)
        try! fm.setAttributes([.modificationDate: modified], ofItemAtPath: u.path)
        return u
    }
    let report = file(downloads, "отчёт.pdf")
    let notes = file(downloads, "заметки.txt", modified: later)
    let hidden = file(downloads, ".секрет")
    let partial = file(downloads, "video.mp4.crdownload")
    let excluded = file(downloads, "keep.iso")
    let passport = file(downloads, "IMG_4021.jpg")
    try! fm.createDirectory(at: downloads.appendingPathComponent("Папка"), withIntermediateDirectories: true)
    try! fm.createSymbolicLink(at: downloads.appendingPathComponent("ссылка"), withDestinationURL: report)
    let shot = file(shots, "Снимок экрана.png")
    let month = DateFormatter.deskMonthForChecks.string(from: later)
    try! fm.createDirectory(at: dest.appendingPathComponent(month), withIntermediateDirectories: true)
    try! Data("other".utf8).write(to: dest.appendingPathComponent(month).appendingPathComponent("отчёт.pdf"))

    let desk = Desk(folders: DeskFolders(folders: [downloads, shots], screenshotsOnly: shots), destination: dest,
                    journal: journal, enabledAt: now)
    desk.excludedExtensions = ["iso"]
    desk.isPersonal = { $0.lastPathComponent == "IMG_4021.jpg" }

    // Grace: Desk turned on 30 days from now, so at +40 days ordinary files are only 10 days old.
    desk.enabledAt = now.addingTimeInterval(30 * 86400)
    let graced = desk.scan(now: later).filter { $0.verdict.action == .move }.map { $0.url.lastPathComponent }
    expect(graced == ["IMG_4021.jpg"], "grace from the day Desk was turned on, only the 3-day file is due: \(graced)")
    desk.enabledAt = now

    // At +10 days: screenshot and passport (14 and 3 days) differ.
    let early = desk.scan(now: now.addingTimeInterval(10 * 86400))
    func stage(_ items: [DeskItem], _ u: URL) -> String? {
        items.first { $0.url.standardizedFileURL.path == u.standardizedFileURL.path }.map { "\($0.verdict.stage.rawValue) \($0.verdict.action.rawValue)" }
    }
    expect(stage(early, shot) == "aging none", "screenshot ages at day 10: \(stage(early, shot) ?? "nil")")
    expect(stage(early, passport) == "expired move", "personal file expires at day 3: \(stage(early, passport) ?? "nil")")
    expect(stage(early, report) == "fresh none", "plain file fresh at day 10")
    expect(early.first { $0.url.lastPathComponent == "отчёт.pdf" }?.verdict.left == 20, "20 days left at day 10")
    // The window passes the path as the scan saw it.
    desk.excludedPaths = Set(early.filter { $0.url.lastPathComponent == "отчёт.pdf" }.map(\.url.path))
    expect(stage(desk.scan(now: later), report) == "skip none", "«Не трогать» from the Desk window: skipped")
    desk.excludedPaths = []

    let moved = desk.sweep(now: later)
    let names = Set(moved.map { URL(fileURLWithPath: $0.from).lastPathComponent })
    expect(names == ["отчёт.pdf", "IMG_4021.jpg", "Снимок экрана.png"], "moved: \(names.sorted())")
    for u in [notes, hidden, partial, excluded] { expect(fm.fileExists(atPath: u.path), "stays: \(u.lastPathComponent)") }
    expect(fm.fileExists(atPath: downloads.appendingPathComponent("Папка").path), "folder stays")
    expect((try? fm.destinationOfSymbolicLink(atPath: downloads.appendingPathComponent("ссылка").path)) != nil, "link stays")
    let r2 = dest.appendingPathComponent(month).appendingPathComponent("отчёт 2.pdf")
    expect(fm.fileExists(atPath: r2.path), "name taken: goes as «отчёт 2.pdf»")
    expect((try? String(contentsOf: dest.appendingPathComponent(month).appendingPathComponent("отчёт.pdf"), encoding: .utf8)) == "other",
           "existing file in the destination untouched")
    expect(desk.journal().filter { $0.kind == "moved" }.count == 3, "journal: three moves")
    expect(desk.sweep(now: later).isEmpty, "second pass: nothing left to move")

    // A file changed after the scan is not taken.
    let changing = file(downloads, "changing.pdf")
    let items = desk.scan(now: later)
    try! fm.setAttributes([.modificationDate: old.addingTimeInterval(100)], ofItemAtPath: changing.path)
    if let it = items.first(where: { $0.url.lastPathComponent == "changing.pdf" }) {
        expect(desk.take(it, now: later) == nil, "changed since the scan: not taken")
    } else {
        expect(false, "changing.pdf scanned")
    }

    // Return: back where it came from, counting starts again.
    try! Data("new".utf8).write(to: report) // the person put a new file with the same name meanwhile
    let before = Date().addingTimeInterval(-2)
    expect(desk.returnLastSweep(now: later) == 3, "three files back")
    expect(fm.fileExists(atPath: downloads.appendingPathComponent("отчёт 2.pdf").path), "name taken on return: «отчёт 2.pdf»")
    expect(fm.fileExists(atPath: passport.path) && fm.fileExists(atPath: shot.path), "passport and screenshot back")
    var back = shot
    back.removeAllCachedResourceValues()
    let added = (try? back.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
    expect(added.map { $0 >= before } == true, "returned file counts from the day it came back")
    expect(desk.journal().filter { $0.kind == "returned" }.count == 3, "journal: three returns")
    expect(desk.returnLastSweep(now: later) == 0, "nothing to return twice")

    // With an Archive: documents go there, ordinary files still to «Убрано со стола».
    let vault = root.appendingPathComponent("vault")
    try! fm.createDirectory(at: vault, withIntermediateDirectories: true)
    desk.archiver = { url in
        let to = vault.appendingPathComponent(url.lastPathComponent + ".age")
        return (try? fm.moveItem(at: url, to: to)) == nil ? nil : to
    }
    let card = file(downloads, "карта.png")
    let plain = file(downloads, "счёт.txt")
    desk.isPersonal = { $0.lastPathComponent == "карта.png" }
    let swept = desk.sweep(now: later)
    expect(swept.first { $0.from.hasSuffix("карта.png") }?.kind == "archived", "document goes to the Archive")
    expect(swept.first { $0.from.hasSuffix("счёт.txt") }?.kind == "moved", "ordinary file goes to «Убрано со стола»")
    expect(!fm.fileExists(atPath: card.path) && !fm.fileExists(atPath: plain.path), "both left the desk")
    if let archived = swept.first(where: { $0.kind == "archived" }) {
        expect(!desk.bringBack(archived), "archived document is not returned by Desk: Touch ID in the Archive window")
    }

    print("desk-files: " + (failed == 0 ? "all passed" : "\(failed) problems"))
    return failed
}

extension DateFormatter {
    static let deskMonthForChecks: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()
}

/// `redakciya-checks personal`: the Zamazka detector on synthetic images and the cache. Slow (OCR), run by name.
@MainActor
func checkPersonal() async -> Int {
    var failed = 0
    func expect(_ ok: Bool, _ what: String) {
        if !ok { failed += 1; print("FAIL personal: \(what)") }
    }
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("redakciya-personal-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    func png(_ name: String, _ image: CGImage) -> URL {
        let u = dir.appendingPathComponent(name)
        try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: u)
        return u
    }
    let chat = png("chat.png", SyntheticImage.chat())
    let plain = png("plain.png", SyntheticImage.plain())
    let text = dir.appendingPathComponent("notes.txt")
    try! Data("4276 0000 0000 0000".utf8).write(to: text)

    let found = await PersonalScanner.detect(chat) ?? []
    expect(found.contains(.card), "card found on the chat image: \(found.map(\.rawValue))")
    expect(!found.contains(.phone), "phone does not count as a document")
    let none = await PersonalScanner.detect(plain)
    expect(none == [], "plain chat has no documents: \(none.map { $0.map(\.rawValue) } ?? ["unreadable"])")

    let cache = dir.appendingPathComponent("cache.json")
    let s = PersonalScanner(cacheURL: cache)
    var announced: [String] = []
    s.onFound = { url, _ in announced.append(url.lastPathComponent) }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        s.onIdle = { c.resume(); s.onIdle = {} }
        s.check([chat, plain, text])
    }
    expect(s.isPersonal(chat) && !s.isPersonal(plain), "scanner: chat personal, plain not")
    expect(s.kinds(text) == nil, "text files are not images: not checked")
    expect(announced == ["chat.png"], "one card: \(announced)")
    let again = PersonalScanner(cacheURL: cache)
    expect(again.isPersonal(chat) && again.kinds(plain) == [], "answers survive a restart")
    let raw = (try? String(contentsOf: cache, encoding: .utf8)) ?? ""
    expect(!raw.contains("2202") && raw.contains("card"), "cache keeps kinds only, no recognised text")
    try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: chat.path)
    expect(again.kinds(chat) == nil, "changed file is checked again")

    print("personal: " + (failed == 0 ? "all passed" : "\(failed) problems"))
    return failed
}

/// spec/archive-format.md: vectors, age round trips, words, and interop with the reference `age` if installed.
func checkArchiveCrypto() -> Int {
    let cli = ["/opt/homebrew/bin/age", "/usr/local/bin/age"].first { FileManager.default.isExecutableFile(atPath: $0) }
    let (n, failures) = ArchiveSelfTest.run(ageCLI: cli)
    for f in failures { print("FAIL archive-crypto: \(f)") }
    print("archive-crypto: \(n) checks" + (cli == nil ? ", reference age not installed" : ", with reference age") + ": "
          + (failures.isEmpty ? "all passed" : "\(failures.count) problems"))
    return failures.count
}

/// The Archive on temporary folders with software device keys: set up, add, open, return, recover, remove.
@MainActor
func checkArchiveStore() -> Int {
    let (n, failures) = ArchiveStoreSelfTest.run()
    for f in failures { print("FAIL archive: \(f)") }
    print("archive: \(n) checks: " + (failures.isEmpty ? "all passed" : "\(failures.count) problems"))
    return failures.count
}

/// spec/issue-code-cases.tsv with the Swift reader.
func checkIssueCode() throws -> Int {
    let (h, rows) = try readTSV("issue-code-cases.tsv")
    var failed = 0
    for r in rows {
        let journal = Set(r[h["journal"]!].split(separator: ",").map(String.init))
        let got: (String, String)
        switch ReprintRules.find(lines: r[h["lines"]!].components(separatedBy: " | "), journal: journal) {
        case .code(let c, let fuzzy): got = (c, fuzzy ? "fuzzy" : "exact")
        case .ambiguous: got = ("?", "—")
        case .none: got = ("—", "—")
        }
        if got != (r[h["expect"]!], r[h["how"]!]) {
            failed += 1
            print("FAIL issue-code \(r[h["id"]!]): got \(got.0) \(got.1)")
        }
    }
    print("issue-code: \(rows.count - failed)/\(rows.count) passed")
    return failed
}

/// spec/reprint-cases.tsv: purpose, code, name, spoil, search.
func checkReprintCases() throws -> Int {
    let (h, rows) = try readTSV("reprint-cases.tsv")
    var failed = 0
    let iso = ISO8601DateFormatter()
    for r in rows {
        let input = r[h["input"]!], journal = r[h["journal"]!]
        let got: String
        switch r[h["kind"]!] {
        case "purpose":
            got = (try? ReprintRules.purpose(input.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")).get()) ?? "—"
        case "code":
            got = ReprintRules.codeOK(input, journal: journal.split(separator: ",").map(String.init)) ? "ok" : "—"
        case "name":
            let p = input.split(separator: " ").map(String.init)
            let taken = Set(journal.isEmpty ? [] : journal.components(separatedBy: " | "))
            got = ReprintRules.fileName(code: p[0], ext: p[1]) { taken.contains($0) }
        case "spoil":
            let p = input.split(separator: " ").map { iso.date(from: String($0))! }
            got = ReprintRules.spoiled(issued: p[0], now: p[1]) ? "expired" : "fresh"
        case "search":
            let issues = journal.components(separatedBy: " | ").map { e -> Issue in
                let f = e.split(separator: ":", maxSplits: 2).map(String.init)
                return Issue(code: f[0], doc: "", title: f[2], purpose: f[1], at: Date(), via: "drag", app: nil, file: "")
            }
            got = ReprintRules.search(input, in: issues).map { issues[$0].code }.joined(separator: ",")
        default: got = "?"
        }
        let want = r[h["expect"]!]
        if got != want && !(got.isEmpty && want == "—") {
            failed += 1
            print("FAIL reprint \(r[h["id"]!]): got \(got), want \(want)")
        }
    }
    print("reprint: \(rows.count - failed)/\(rows.count) passed")
    return failed
}

@MainActor
func checkReprintFiles() -> Int {
    let (n, failures) = ReprintSelfTest.run()
    for f in failures { print("FAIL reprint-files: \(f)") }
    print("reprint-files: \(n) checks: " + (failures.isEmpty ? "all passed" : "\(failures.count) problems"))
    return failures.count
}

/// spec/gazette-cases.json: placeholders and whole issues, equal to the reference to the letter.
func checkGazette() throws -> Int {
    struct Value: Decodable {
        let value: GazetteValue
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self) { value = .n(n) } else { value = .s(try c.decode(String.self)) }
        }
    }
    struct Phrase: Decodable { let id: String; let template: String; let values: [String: Value]; let expect: String }
    struct Case: Decodable { let id: String; let input: GazetteInput; let expect: GazetteIssue }
    struct Size: Decodable {
        let bytes: Int, text: String
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            bytes = try c.decode(Int.self); text = try c.decode(String.self)
        }
    }
    struct Cases: Decodable { let sizes: [Size]; let phrases: [Phrase]; let issues: [Case] }
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    let cases = try dec.decode(Cases.self, from: Data(contentsOf: spec.appendingPathComponent("gazette-cases.json")))
    let templates = try GazetteTemplates(String(contentsOf: spec.appendingPathComponent("gazette/ru/templates.txt"), encoding: .utf8))
    var failed = 0
    for z in cases.sizes where GazetteComposer.size(z.bytes) != z.text {
        failed += 1
        print("FAIL gazette size \(z.bytes): got \(GazetteComposer.size(z.bytes)), want \(z.text)")
    }
    for p in cases.phrases {
        let got = templates.render(p.template, p.values.mapValues(\.value))
        if got != p.expect {
            failed += 1
            print("FAIL gazette phrase \(p.id): got \(got.debugDescription), want \(p.expect.debugDescription)")
        }
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    for c in cases.issues {
        guard let got = GazetteComposer.compose(c.input, templates: templates) else {
            failed += 1
            print("FAIL gazette \(c.id): no issue")
            continue
        }
        if got != c.expect {
            failed += 1
            print("FAIL gazette \(c.id): issue differs")
            if got.stories != c.expect.stories, let d = try? enc.encode(got.stories) { print("   stories: " + String(decoding: d, as: UTF8.self)) }
            if got.sources != c.expect.sources { print("   sources: \(got.sources)") }
            if got.document != c.expect.document { print("   document: \(got.document)") }
            if got.issued != c.expect.issued { print("   issued: \(got.issued)") }
            for (name, a, b) in [("dateline", got.dateline, c.expect.dateline), ("weather", got.weather, c.expect.weather),
                                 ("week", got.week, c.expect.week), ("date", got.date, c.expect.date),
                                 ("colophon", got.colophon.joined(separator: " | "), c.expect.colophon.joined(separator: " | "))] where a != b {
                print("   \(name): \(a)")
            }
        }
    }
    print("gazette: \(cases.sizes.count) sizes, \(cases.phrases.count) phrases, \(cases.issues.count) issues: " + (failed == 0 ? "all passed" : "\(failed) problems"))
    return failed
}

/// The event journal and the schedule on temporary folders (spec/gazette.md, «Журнал событий», «Когда выходит»).
@MainActor
func checkGazetteFiles() -> Int {
    var failed = 0
    func expect(_ ok: Bool, _ what: String) {
        if !ok { failed += 1; print("FAIL gazette-files: \(what)") }
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("redakciya-gazette-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
    func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }
    let log = EventLog(url: root.appendingPathComponent("events.jsonl"))
    let store = GazetteStore(folder: root.appendingPathComponent("gazette"), log: log)
    let state = GazetteState(archive: false, desk: nil, documents: [])

    // The cut is the last «hour:00» that has come.
    expect(GazetteStore.cut(now: at(9, 7, 59), hour: 8, calendar: cal) == at(8, 8), "before the hour: yesterday's cut")
    expect(GazetteStore.cut(now: at(9, 8), hour: 8, calendar: cal) == at(9, 8), "at the hour: today's cut")
    expect(GazetteStore.cut(now: at(9, 23, 30), hour: 0, calendar: cal) == at(9, 0), "hour 0: midnight today")
    expect(GazetteStore.nextCut(now: at(9, 7, 59), hour: 8, calendar: cal) == at(9, 8), "next cut later today")
    expect(GazetteStore.nextCut(now: at(9, 15), hour: 8, calendar: cal) == at(10, 8), "next cut tomorrow")

    // The journal: what is written and what never is.
    log.enabled = false
    log.write(GazetteEvent(at: at(8, 12), kind: "link", class: "tracks"))
    expect(!fm.fileExists(atPath: log.url.path), "issue turned off: nothing is written")
    log.enabled = true
    log.write(GazetteEvent(at: at(8, 12), kind: "link", class: "gives_away", service: "instagram", tails: ["igsh", "MXd2a2xpbmZ6Z3Q0", "a b"]))
    log.write(GazetteEvent(at: at(8, 14, 18), kind: "issue", title: "Паспорт РФ"))
    log.write(GazetteEvent(at: at(9, 8), kind: "desk", what: "moved", name: "отчёт.pdf"))
    log.write(GazetteEvent(at: at(9, 8, 1), kind: "archive", what: "added", title: "СНИЛС", by: "desk"))
    log.write(GazetteEvent(at: at(1, 12).addingTimeInterval(-40 * 86400), kind: "link", class: "tracks"))
    let raw = (try? String(contentsOf: log.url, encoding: .utf8)) ?? ""
    expect(raw.split(separator: "\n").count == 5 && log.read().count == 5, "five lines, five events")
    expect(log.read().first?.tails == ["igsh", "", ""], "tail names that are not plain are blanked: \(log.read().first?.tails ?? [])")
    expect(!raw.contains("MXd2") && !raw.contains("http") && !raw.contains("/"), "no link, no value, no path in the journal")
    expect(raw.hasPrefix("{\"at\":\"2026-11-08T09:00:00Z\",\"class\":\"gives_away\",\"kind\":\"link\""), "keys sorted, time in UTC seconds")
    try? Data((raw + "not json\n{\"at\":\"2026-11-08T09:30:00Z\",\"kind\":\"net\",\"who\":\"Dropbox\"}\n").utf8).write(to: log.url)
    expect(log.read().count == 6, "broken line skipped, unknown kind kept for later versions")

    // The schedule: nothing on the day the issue was turned on, then one issue a day.
    let started = at(8, 10)
    expect(store.publish(now: at(8, 23), hour: 8, startedAt: started, state: state, calendar: cal) == nil, "no issue on the first day")
    expect(store.latest == nil && store.days().isEmpty, "nothing stored yet")
    guard let first = store.publish(now: at(9, 9, 30), hour: 8, startedAt: started, state: state, calendar: cal) else {
        expect(false, "first issue at the first cut after the start")
        return failed
    }
    expect(first.number == 1 && first.date == "2026-11-09", "first issue: № 1 for 9 November")
    expect(first.from == "2026-11-08T05:00:00Z" && first.to == "2026-11-09T05:00:00Z", "first period: 24 hours to the cut, in UTC")
    expect(first.stories.map(\.rubric) == ["Перепечатка", "Редактура", "Стол"], "stories of the period: \(first.stories.map(\.rubric))")
    expect(first.stories.first?.body.first?.hasPrefix("Вчера в 14:18") == true, "local time of the copy")
    expect(first.colophon.last == "Следующий выпуск завтра в 8:00", "hour in the colophon")
    expect(store.load("2026-11-09") == first && store.latest == first, "stored issue reads back the same")
    expect(log.read().count == 5, "events older than 35 days are dropped: \(log.read().count)")
    let bytes = try? Data(contentsOf: store.folder.appendingPathComponent("2026-11-09.json"))
    expect(store.publish(now: at(9, 22), hour: 8, startedAt: started, state: state, calendar: cal) == nil, "one issue a day")
    expect(store.publish(now: at(9, 22), hour: 20, startedAt: started, state: state, calendar: cal) == nil, "changing the hour gives no second issue that day")
    expect((try? Data(contentsOf: store.folder.appendingPathComponent("2026-11-09.json"))) == bytes, "a stored issue never changes")

    // The next one starts where the first stopped: the archive event at 08:00:01 goes here, once.
    let second = store.publish(now: at(12, 8), hour: 8, startedAt: started, state: state, calendar: cal)
    expect(second?.number == 2 && second?.from == first.to && second?.date == "2026-11-12", "second issue covers the whole gap")
    expect(second?.stories.map(\.rubric) == ["Архив"], "the event after the first cut is in the second issue: \(second?.stories.map(\.rubric) ?? [])")
    expect(store.days() == ["2026-11-09", "2026-11-12"], "issues are kept: \(store.days())")
    expect(store.due(now: at(13, 7), hour: 8, startedAt: started, calendar: cal) == nil
           && store.due(now: at(13, 8), hour: 8, startedAt: started, calendar: cal) == at(13, 8), "due exactly at the hour")

    print("gazette-files: " + (failed == 0 ? "all passed" : "\(failed) problems"))
    return failed
}

/// spec/sources.md: the ASN base, which addresses count, hourly records and acquaintances. No network.
func checkSources() -> Int {
    var failed = 0
    func expect(_ ok: Bool, _ what: String) {
        if !ok { failed += 1; print("FAIL sources: \(what)") }
    }
    func ip(_ s: String) -> UInt32 {
        if case .v4(let x)? = RemoteAddress(v4: s) { return x }
        return 0
    }
    // A base of three ranges and two names, by the format table.
    func le(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    let names: [(String, Bool)] = [("Telegram", false), ("Amazon", true)]
    var blob = Data(), offsets: [UInt32] = []
    for (n, cloud) in names { offsets.append(UInt32(blob.count)); blob.append(cloud ? 1 : 0); blob.append(Data(n.utf8)) }
    offsets.append(UInt32(blob.count))
    let ranges: [(String, String, UInt32)] = [("52.0.0.0", "52.255.255.255", 1), ("149.154.160.0", "149.154.175.255", 0), ("200.0.0.0", "200.0.0.0", 1)]
    var bin = Data("RASN".utf8) + le(1) + le(UInt32(ranges.count)) + le(UInt32(names.count))
    for r in ranges { bin += le(ip(r.0)) }
    for r in ranges { bin += le(ip(r.1)) }
    for r in ranges { bin += le(r.2) }
    for o in offsets { bin += le(o) }
    bin += blob
    guard let base = AsnBase(bin) else { expect(false, "hand-made base reads"); return failed }
    expect(base.lookup(ip("149.154.167.50")) == .init(name: "Telegram", cloud: false), "inside a range")
    expect(base.lookup(ip("149.154.160.0"))?.name == "Telegram" && base.lookup(ip("149.154.175.255"))?.name == "Telegram", "both ends belong")
    expect(base.lookup(ip("149.154.176.0")) == nil && base.lookup(ip("51.255.255.255")) == nil, "gaps and addresses before the first range")
    expect(base.lookup(ip("52.94.236.248")) == .init(name: "Amazon", cloud: true), "cloud flag")
    expect(base.lookup(ip("200.0.0.0"))?.name == "Amazon" && base.lookup(ip("200.0.0.1")) == nil, "range of one address")
    expect(AsnBase(bin.dropLast(1)) == nil && AsnBase(Data("RASX".utf8) + bin.dropFirst(4)) == nil && AsnBase(Data()) == nil, "broken base is refused")

    func reach(_ s: String) -> RemoteAddress.Reach { RemoteAddress(v4: s)!.reach }
    for local in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.10.10", "100.64.0.1", "224.0.0.251", "255.255.255.255", "0.0.0.0"] {
        expect(reach(local) == .local, "\(local) is not the world")
    }
    for world in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "198.20.0.1", "192.167.1.1"] { expect(reach(world) == .world, "\(world) is the world") }
    expect(reach("198.18.0.1") == .vpn && reach("198.19.255.255") == .vpn, "198.18/15 is behind a VPN")
    func v6(_ head: [UInt8]) -> RemoteAddress { .v6(head + [UInt8](repeating: 0, count: 16 - head.count)) }
    expect(v6([0xFE, 0x80]).reach == .local && v6([0xFD, 0x12]).reach == .local && v6([0xFF, 0x02]).reach == .local, "IPv6 link-local, private, multicast")
    expect(RemoteAddress.v6([UInt8](repeating: 0, count: 15) + [1]).reach == .local && v6([0x2A, 0x00]).reach == .world, "IPv6 loopback and the world")

    // Hourly records: three days of getting acquainted, then a new pair is marked.
    let start = Date(timeIntervalSince1970: 1_762_678_800) // 2026-11-09T09:00:00Z
    var a = SourcesAggregator(since: start) { base.lookup($0) }
    let tg = RemoteAddress(v4: "149.154.167.50")!, amazon = RemoteAddress(v4: "52.1.1.1")!
    expect(a.add(app: "Telegram", remote: tg, sent: 100, got: 1000, at: start.addingTimeInterval(60)).isEmpty, "nothing leaves within the hour")
    expect(a.add(app: "Telegram", remote: tg, sent: 50, got: 0, at: start.addingTimeInterval(120)).isEmpty, "same pair adds up")
    expect(a.add(app: "Telegram", remote: RemoteAddress(v4: "192.168.1.5")!, sent: 9, got: 9, at: start.addingTimeInterval(130)).isEmpty, "local network is dropped")
    expect(a.add(app: "Wispr Flow", remote: amazon, sent: 0, got: 0, at: start.addingTimeInterval(140)).isEmpty, "no bytes, no record")
    let firstHour = a.add(app: "Wispr Flow", remote: amazon, sent: 7, got: 7, at: start.addingTimeInterval(3700))
    expect(firstHour.count == 1 && firstHour[0].app == "Telegram" && firstHour[0].to == "Telegram" && firstHour[0].sent == 150
           && firstHour[0].got == 1000 && firstHour[0].at == start && firstHour[0].first == nil && firstHour[0].cloud == nil,
           "the hour turned: one record for the first hour: \(firstHour)")
    let mid = a.flush()
    expect(mid.count == 1 && mid[0].app == "Wispr Flow" && mid[0].cloud == true && mid[0].first == nil
           && mid[0].at == start.addingTimeInterval(3600), "flush before an issue; no acquaintances in the first three days")
    expect(a.flush().isEmpty && a.known == ["Telegram\tTelegram", "Wispr Flow\tAmazon"] && a.knownChanged, "pairs are remembered by names only")

    let later = start.addingTimeInterval(4 * 86400)
    var b = SourcesAggregator(known: a.known, since: start) { base.lookup($0) }
    _ = b.add(app: "Telegram", remote: tg, sent: 1, got: 1, at: later)
    _ = b.add(app: "curl", remote: RemoteAddress(v4: "9.9.9.9")!, sent: 5, got: 5, at: later)
    _ = b.add(app: "Tunnel VPN", remote: RemoteAddress(v4: "198.18.0.7")!, sent: 5, got: 5, at: later)
    _ = b.add(app: "Safari", remote: v6([0x2A, 0x00]), sent: 5, got: 5, at: later)
    let part = b.flush()
    expect(part.map { $0.first == true } == [false, true, true, true], "old pair is not new, three new ones are: \(part.map { $0.first == true })")
    expect(part[1].to == "" && part[2].vpn == true && part[2].to == "" && part[3].to == "", "not in the base, behind a VPN, IPv6 without a base")
    _ = b.add(app: "curl", remote: RemoteAddress(v4: "9.9.9.9")!, sent: 1, got: 0, at: later.addingTimeInterval(600))
    expect(b.flush().first?.first == true, "still new until the hour is over")
    _ = b.add(app: "curl", remote: RemoteAddress(v4: "9.9.9.9")!, sent: 1, got: 0, at: later.addingTimeInterval(4000))
    expect(b.flush().first?.first == nil, "next hour: an old acquaintance")
    expect(b.endHourIfPast(later.addingTimeInterval(4100)).isEmpty && b.endHourIfPast(later.addingTimeInterval(8000)).isEmpty, "nothing left at the hour boundary")

    // The record on disk: names and bytes, no address.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("redakciya-sources-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let line = MainActor.assumeIsolated { () -> String in
        let log = EventLog(url: dir.appendingPathComponent("events.jsonl"))
        part.forEach(log.write)
        return (try? String(contentsOf: log.url, encoding: .utf8)) ?? ""
    }
    expect(line.contains("\"app\":\"curl\"") && line.contains("\"first\":true") && !line.contains("9.9.9") && !line.contains("198.18"), "journal has programs and bytes, no addresses")

    // The real base, if it was built (mac/Resources/asn.bin is not in git).
    let real = spec.deletingLastPathComponent().appendingPathComponent("mac/Resources/asn.bin")
    if let r = AsnBase(url: real) {
        expect(r.lookup(ip("149.154.167.50"))?.name == "Telegram" && r.lookup(ip("8.8.8.8"))?.name == "Google", "real base: Telegram, Google")
        expect(r.lookup(ip("52.94.236.248")) == .init(name: "Amazon", cloud: true) && r.lookup(ip("10.0.0.1")) == nil, "real base: Amazon is a cloud, private is nobody")
    }
    print("sources: " + (failed == 0 ? "all passed" : "\(failed) problems") + (AsnBase(url: real) == nil ? ", real base not built" : ", with the real base"))
    return failed
}

/// `redakciya-checks sources-live`: the kernel subscription and its self-check on the loopback. On demand: private ABI.
func checkSourcesLive() -> Int {
    guard SourcesWatch.selfCheck() else {
        print("FAIL sources-live: self-check")
        return 1
    }
    // The whole chain on one real request: the published rules file, fetched by this process.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("redakciya-sources-live-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let watch = SourcesWatch(knownURL: dir.appendingPathComponent("known.json"))
    watch.start()
    var events: [GazetteEvent] = []
    let fetched = runAsync {
        for _ in 0..<40 where !watch.working { try? await Task.sleep(nanoseconds: 100_000_000) }
        // curl goes through a kernel socket; URLSession in this process uses the user-space stack, which ntstat does not see.
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-s", "-o", "/dev/null", "-w", "%{http_code}", RulesUpdater.url.absoluteString]
        let out = Pipe()
        curl.standardOutput = out
        try? curl.run()
        curl.waitUntilExit()
        let ok = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "200"
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return ok ? 0 : 1
    }
    events = watch.flush()
    watch.stop()
    let mine = events.filter { $0.app == "curl" }
    let ok = fetched == 0 && mine.contains { ($0.sent ?? 0) > 0 && ($0.got ?? 0) > 1000 }
    let known = (try? String(contentsOf: dir.appendingPathComponent("known.json"), encoding: .utf8)) ?? ""
    print("sources-live: self-check passed; " + (ok ? "own request recorded: \(mine.map { "→ \($0.to ?? "")\($0.vpn == true ? "vpn" : ""), \($0.sent ?? 0) / \($0.got ?? 0) bytes" })"
                                                    : "FAIL request \(fetched == 0 ? "done" : "failed"), records \(events.map { $0.app ?? "" })")
          + "; programs seen: \(Set(events.compactMap(\.app)).sorted())")
    return ok && known.contains("curl") ? 0 : 1
}

let suites: [(String, () throws -> Int)] = [
    ("links", checkLinks),
    ("bundled", checkBundled),
    ("editor", { MainActor.assumeIsolated { checkEditor() } }),
    ("prefs", { MainActor.assumeIsolated { checkPrefs() } }),
    ("access", checkAccess),
    ("icon", checkIcon),
    ("archive-crypto", checkArchiveCrypto),
    ("archive", { MainActor.assumeIsolated { checkArchiveStore() } }),
    ("desk", checkDeskCases),
    ("desk-files", { MainActor.assumeIsolated { checkDeskFiles() } }),
    ("issue-code", checkIssueCode),
    ("reprint", checkReprintCases),
    ("reprint-files", { MainActor.assumeIsolated { checkReprintFiles() } }),
    ("gazette", checkGazette),
    ("gazette-files", { MainActor.assumeIsolated { checkGazetteFiles() } }),
    ("sources", checkSources),
    ("sources-live", checkSourcesLive),
    ("screens", { MainActor.assumeIsolated {
        let dir = spec.deletingLastPathComponent().appendingPathComponent("design/screens/mac")
        do { for u in try ReprintScreens.render(to: dir) { print("screens: \(u.lastPathComponent)") }; return 0 }
        catch { print("FAIL screens: \(error)"); return 1 }
    } }),
    ("updater", { runAsync { await checkUpdater() } }),
    ("personal", { runAsync { await checkPersonal() } }),
    ("updater-live", { runAsync { await checkUpdaterLive() } }),
]
let wanted = Set(CommandLine.arguments.dropFirst())
var total = 0
// Suites that need the network run only when asked by name.
let onDemand: Set<String> = ["updater-live", "personal", "screens", "sources-live"]
for (name, run) in suites where wanted.isEmpty ? !onDemand.contains(name) : wanted.contains(name) {
    do { total += try run() } catch {
        print("FAIL \(name): \(error)")
        total += 1
    }
}
exit(total == 0 ? 0 : 1)
