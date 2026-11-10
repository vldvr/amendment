import Foundation

/// Terms and stages of spec/desk.md. Pure: dates and flags in, stage and action out.
public struct DeskPolicy: Sendable {
    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let dir = Flags(rawValue: 1 << 0)
        public static let link = Flags(rawValue: 1 << 1)
        public static let excluded = Flags(rawValue: 1 << 2)
        public static let screenshot = Flags(rawValue: 1 << 3)
        public static let personal = Flags(rawValue: 1 << 4)
        public static let kept = Flags(rawValue: 1 << 5)
        /// A Reprint copy (spec/reprint.md): 24 hours from issue, no hold, never archived.
        public static let reprint = Flags(rawValue: 1 << 6)

        public static let names: [String: Flags] = [
            "dir": .dir, "link": .link, "excluded": .excluded, "screenshot": .screenshot, "personal": .personal, "kept": .kept,
        ]
    }

    public enum Stage: String, Sendable { case skip, fresh, aging, expired }
    public enum Action: String, Sendable { case none, move, hold }

    public struct Verdict: Equatable, Sendable {
        public let term: Int
        public let stage: Stage
        public let action: Action
        /// Days until the term runs out: 0 when it is due, for the Desk window.
        public var left: Int = 0
    }

    public var plainDays = 30
    public var screenshotDays = 14
    public var personalDays = 3

    static let skipNames: Set<String> = ["desktop.ini", "thumbs.db", "icon\r"]
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload", "tmp"]

    public init() {}

    public func term(_ flags: Flags) -> Int {
        if flags.contains(.personal) && !flags.contains(.kept) { return personalDays }
        return flags.contains(.screenshot) ? screenshotDays : plainDays
    }

    /// Hidden, partial, system and similar names that Desk never touches, whatever their age.
    public static func skipsByName(_ name: String) -> Bool {
        if name.hasPrefix(".") || skipNames.contains(name.lowercased()) { return true }
        guard let dot = name.dropFirst().lastIndex(of: ".") else { return false }
        return partialExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// A Reprint copy: spoiled 24 hours after it was issued.
    public func reprintVerdict(issued: Date, now: Date) -> Verdict {
        ReprintRules.spoiled(issued: issued, now: now)
            ? Verdict(term: 1, stage: .expired, action: .move, left: 0)
            : Verdict(term: 1, stage: .fresh, action: .none, left: 1)
    }

    /// `added`, `enabled`, `modified` and `today` are calendar days in local time.
    public func evaluate(name: String, flags: Flags, added: DateComponents, enabled: DateComponents,
                         modified: DateComponents, today: DateComponents) -> Verdict {
        let term = term(flags)
        if Self.skipsByName(name) || !flags.isDisjoint(with: [.dir, .link, .excluded]) {
            return Verdict(term: term, stage: .skip, action: .none)
        }
        let start = Self.days(added) >= Self.days(enabled) ? added : enabled
        let age = Self.days(today) - Self.days(start)
        let left = max(0, term - age)
        if age * 3 < term * 2 { return Verdict(term: term, stage: .fresh, action: .none, left: left) }
        if age < term { return Verdict(term: term, stage: .aging, action: .none, left: left) }
        let hold = Self.days(modified) >= Self.days(today) - 1
        return Verdict(term: term, stage: .expired, action: hold ? .hold : .move, left: 0)
    }

    /// Day number of a calendar date (days since 1970-01-01), independent of time zones.
    static func days(_ d: DateComponents) -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: DateComponents(year: d.year, month: d.month, day: d.day))!
        return Int((date.timeIntervalSince1970 / 86400).rounded(.down))
    }

    /// The local calendar day of a moment.
    public static func day(_ date: Date, calendar: Calendar = .current) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: date)
    }
}
