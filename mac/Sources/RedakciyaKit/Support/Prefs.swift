import Combine
import Foundation
import ServiceManagement

/// Small settings kept in UserDefaults on this Mac. No links and no history: only counts and choices.
@MainActor
public final class Prefs: ObservableObject {
    public static let shared = Prefs()
    private let d: UserDefaults

    public init(defaults: UserDefaults = .standard) { d = defaults }

    /// «Убрано хвостов»: one per cleaned copy, not per parameter.
    public var tailsRemoved: Int {
        get { d.integer(forKey: "editing.tailsRemoved") }
        set { objectWillChange.send(); d.set(newValue, forKey: "editing.tailsRemoved") }
    }

    /// Apps whose links are never touched.
    public var excludedApps: Set<String> {
        get { Set(d.stringArray(forKey: "editing.excludedApps") ?? []) }
        set { objectWillChange.send(); d.set(newValue.sorted(), forKey: "editing.excludedApps") }
    }

    public var editingPaused: Bool {
        get { d.bool(forKey: "editing.paused") }
        set { objectWillChange.send(); d.set(newValue, forKey: "editing.paused") }
    }

    /// The first-run window was closed with «Готово».
    public var onboardingDone: Bool {
        get { d.bool(forKey: "onboarding.done") }
        set { objectWillChange.send(); d.set(newValue, forKey: "onboarding.done") }
    }

    /// Zamazka on screenshots inside Redakciya. On unless the person turns it off.
    public var screenshotsEnabled: Bool {
        get { d.object(forKey: "screenshots.enabled") as? Bool ?? true }
        set { objectWillChange.send(); d.set(newValue, forKey: "screenshots.enabled") }
    }

    // MARK: - Desk

    /// When Desk was first turned on; files older than that count from this day. Set once.
    public var deskEnabledAt: Date {
        if let at = d.object(forKey: "desk.enabledAt") as? Date { return at }
        let now = Date()
        d.set(now, forKey: "desk.enabledAt")
        return now
    }

    /// The person pressed «Разрешить» for the folders; before that Desk does not read them.
    public var deskFoldersAsked: Bool {
        get { d.bool(forKey: "desk.foldersAsked") }
        set { objectWillChange.send(); d.set(newValue, forKey: "desk.foldersAsked") }
    }

    public var deskPaused: Bool {
        get { d.bool(forKey: "desk.paused") }
        set { objectWillChange.send(); d.set(newValue, forKey: "desk.paused") }
    }

    public var deskPlainDays: Int {
        get { days("desk.plainDays", 30) }
        set { objectWillChange.send(); d.set(max(1, newValue), forKey: "desk.plainDays") }
    }

    public var deskScreenshotDays: Int {
        get { days("desk.screenshotDays", 14) }
        set { objectWillChange.send(); d.set(max(1, newValue), forKey: "desk.screenshotDays") }
    }

    public var deskPersonalDays: Int {
        get { days("desk.personalDays", 3) }
        set { objectWillChange.send(); d.set(max(1, newValue), forKey: "desk.personalDays") }
    }

    /// Files moved by the last pass, for «Стол убрал: N».
    public var deskLastMoved: Int {
        get { d.integer(forKey: "desk.lastMoved") }
        set { objectWillChange.send(); d.set(newValue, forKey: "desk.lastMoved") }
    }

    /// Files the person chose to keep on the card «Похоже на паспорт»: ordinary term for them.
    public var deskKeptPaths: Set<String> {
        get { Set(d.stringArray(forKey: "desk.keptPaths") ?? []) }
        set { objectWillChange.send(); d.set(newValue.sorted(), forKey: "desk.keptPaths") }
    }

    /// Files the person told Desk never to touch.
    public var deskExcludedPaths: Set<String> {
        get { Set(d.stringArray(forKey: "desk.excludedPaths") ?? []) }
        set { objectWillChange.send(); d.set(newValue.sorted(), forKey: "desk.excludedPaths") }
    }

    // MARK: - Morning issue

    /// Off: no event journal, no issues.
    public var gazetteEnabled: Bool {
        get { d.object(forKey: "gazette.enabled") as? Bool ?? true }
        set { objectWillChange.send(); d.set(newValue, forKey: "gazette.enabled") }
    }

    /// Hour of the issue, local time.
    public var gazetteHour: Int {
        get { (d.object(forKey: "gazette.hour") as? Int).map { min(23, max(0, $0)) } ?? 8 }
        set { objectWillChange.send(); d.set(min(23, max(0, newValue)), forKey: "gazette.hour") }
    }

    /// The card «Вышел выпуск» under the menu bar icon.
    public var gazetteCard: Bool {
        get { d.object(forKey: "gazette.card") as? Bool ?? true }
        set { objectWillChange.send(); d.set(newValue, forKey: "gazette.card") }
    }

    /// The rubric «Источники»: which companies the programs talk to. Only with the issue on.
    public var sourcesEnabled: Bool {
        get { d.object(forKey: "sources.enabled") as? Bool ?? true }
        set { objectWillChange.send(); d.set(newValue, forKey: "sources.enabled") }
    }

    /// When the issue was first turned on: the first issue comes at the first cut after it. Set once.
    public var gazetteStartedAt: Date {
        if let at = d.object(forKey: "gazette.startedAt") as? Date { return at }
        let now = Date()
        d.set(now, forKey: "gazette.startedAt")
        return now
    }

    /// Number of the last issue the person opened.
    public var gazetteReadNumber: Int {
        get { d.integer(forKey: "gazette.readNumber") }
        set { objectWillChange.send(); d.set(newValue, forKey: "gazette.readNumber") }
    }

    private func days(_ key: String, _ fallback: Int) -> Int {
        let v = d.integer(forKey: key)
        return v > 0 ? v : fallback
    }

    /// «Открывать при входе». Kept by macOS, not in UserDefaults; off unless the person turns it on.
    public var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.write("login item: \(error)")
            }
        }
    }
}
