import Foundation

/// One line of the event journal (spec/gazette.md, «Журнал событий»). No links, no purposes, no paths.
public struct GazetteEvent: Codable, Equatable, Sendable {
    public var at: Date
    public var kind: String
    public var `class`: String?
    public var service: String?
    public var tails: [String]?
    public var what: String?
    public var name: String?
    public var copy: Bool?
    public var title: String?
    public var by: String?
    public var app: String?
    public var to: String?
    public var cloud: Bool?
    public var vpn: Bool?
    public var first: Bool?
    public var sent: Int?
    public var got: Int?

    public init(at: Date, kind: String, class c: String? = nil, service: String? = nil, tails: [String]? = nil,
                what: String? = nil, name: String? = nil, copy: Bool? = nil, title: String? = nil, by: String? = nil) {
        self.at = at; self.kind = kind; self.class = c; self.service = service; self.tails = tails
        self.what = what; self.name = name; self.copy = copy; self.title = title; self.by = by
    }

    static let known: Set<String> = ["link", "desk", "archive", "issue", "net"]

    /// A tail name goes to disk only if it is plain: Instagram changes names, and a name can be a tag itself.
    public static func plainTail(_ name: String) -> String {
        let ok = (1...32).contains(name.unicodeScalars.count) && name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" || $0 == "."
        }
        return ok ? name : ""
    }
}

/// What the modules look like at the cut (spec/gazette.md, «Состояние на момент среза»).
public struct GazetteState: Codable, Equatable, Sendable {
    public struct Desk: Codable, Equatable, Sendable {
        public struct Next: Codable, Equatable, Sendable {
            public var name: String
            public var left: Int
            public var to: String
            public init(name: String, left: Int, to: String) { self.name = name; self.left = left; self.to = to }
        }
        public var files: Int
        public var week: Int
        public var next: Next?
        public init(files: Int, week: Int, next: Next?) { self.files = files; self.week = week; self.next = next }
    }

    public struct Document: Codable, Equatable, Sendable {
        public var title: String
        public var expires: String?
        public var added: String
        public init(title: String, expires: String?, added: String) { self.title = title; self.expires = expires; self.added = added }
    }

    public var archive: Bool
    public var desk: Desk?
    public var documents: [Document]
    /// The network was being recorded.
    public var sources: Bool?

    public init(archive: Bool, desk: Desk?, documents: [Document], sources: Bool = false) {
        self.archive = archive; self.desk = desk; self.documents = documents; self.sources = sources
    }
}

public struct GazetteInput: Codable, Sendable {
    public var number: Int
    public var from: String
    public var to: String
    /// Offset of local time at the cut, minutes.
    public var tz: Int
    public var hour: Int
    public var platform: String
    public var events: [GazetteEvent]
    public var state: GazetteState

    public init(number: Int, from: String, to: String, tz: Int, hour: Int, platform: String = "mac",
                events: [GazetteEvent], state: GazetteState) {
        self.number = number; self.from = from; self.to = to; self.tz = tz; self.hour = hour
        self.platform = platform; self.events = events; self.state = state
    }
}

/// The issue as data (spec/gazette.md, «Выпуск как данные»). Written once, never changed.
public struct GazetteIssue: Codable, Equatable, Sendable {
    public struct Story: Codable, Equatable, Sendable {
        public var rubric: String
        public var title: String
        public var body: [String]
        public var items: [[String]]
        public var more: String
    }

    public struct Document: Codable, Equatable, Sendable {
        public var rubric: String
        public var title: String
        public var note: String
    }

    public struct Sources: Codable, Equatable, Sendable {
        public var rubric: String
        public var title: String
        public var items: [[String]]
        public var more: String
        public var note: String
    }

    public struct Issued: Codable, Equatable, Sendable {
        public var rubric: String
        public var items: [[String]]
        public var more: String
        public var note: String
    }

    public var format = 1
    public var number: Int
    public var date: String
    public var from: String
    public var to: String
    public var dateline: String
    public var weather: String
    public var week: String
    public var stories: [Story]
    public var sources: Sources
    public var document: Document
    public var issued: Issued
    public var colophon: [String]
}

/// Builds the issue from events and state. Pure; step for step with `compose` in spec/tools/check-gazette.py.
public enum GazetteComposer {
    static let itemLimit = 5
    static let bigSend = 100 * 1024 * 1024
    static let megabyte = 1024 * 1024

    /// Bytes as a person reads them: whole Б, КБ, МБ (half up), ГБ with one decimal.
    public static func size(_ b: Int) -> String {
        if b < 1024 { return "\(b) Б" }
        if b < megabyte { return "\((b * 2 + 1024) / 2048) КБ" }
        if b < 1024 * megabyte { return "\((b * 2 + megabyte) / (2 * megabyte)) МБ" }
        let tenths = (b * 20 + 1024 * megabyte) / (2 * 1024 * megabyte)
        return "\(tenths / 10),\(tenths % 10) ГБ"
    }

    public static func instant(_ s: String) -> Date? { iso.date(from: s) }
    public static func stamp(_ d: Date) -> String { iso.string(from: d) }
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Calendar fields of a moment shifted to local time.
    private static func fields(_ d: Date, tz: Int) -> DateComponents {
        utc.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: d.addingTimeInterval(Double(tz) * 60))
    }

    private static func dayNumber(_ d: Date, tz: Int) -> Int {
        Int(((d.timeIntervalSince1970 + Double(tz) * 60) / 86400).rounded(.down))
    }

    /// `ГГГГ-ММ-ДД` as a day number and its fields.
    private static func day(_ s: String) -> (number: Int, fields: DateComponents)? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let d = utc.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else { return nil }
        return (Int((d.timeIntervalSince1970 / 86400).rounded(.down)), DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    private static func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }

    public static func compose(_ input: GazetteInput, templates: GazetteTemplates = .bundled) -> GazetteIssue? {
        guard let from = instant(input.from), let to = instant(input.to) else { return nil }
        var T = templates
        T.platform = input.platform
        let tz = input.tz
        let today = fields(to, tz: tz), todayNumber = dayNumber(to, tz: tz)
        let months = T.list("month")
        func month(_ c: DateComponents) -> String { months[(c.month ?? 1) - 1] }

        func clock(_ e: GazetteEvent) -> String {
            let c = fields(e.at, tz: tz)
            return "\(two(c.hour)):\(two(c.minute))"
        }
        func dayMonth(_ e: GazetteEvent) -> String {
            let c = fields(e.at, tz: tz)
            return "\(two(c.day)).\(two(c.month))"
        }
        func when(_ e: GazetteEvent) -> String {
            let n = dayNumber(e.at, tz: tz)
            if n == todayNumber { return T("when.today", ["time": .s(clock(e))]) }
            if n == todayNumber - 1 { return T("when.yesterday", ["time": .s(clock(e))]) }
            let c = fields(e.at, tz: tz)
            return T("when.date", ["day": .n(c.day ?? 0), "month": .s(month(c)), "time": .s(clock(e))])
        }
        func capped(_ items: [[String]]) -> (shown: [[String]], more: String) {
            (Array(items.prefix(itemLimit)), items.count > itemLimit ? T("more", ["n": .n(items.count - itemLimit)]) : "")
        }
        func story(_ rubric: String, _ title: String, _ body: [String], _ items: [[String]] = []) -> GazetteIssue.Story {
            let c = capped(items)
            return GazetteIssue.Story(rubric: T("rubric." + rubric), title: title, body: body, items: c.shown, more: c.more)
        }

        // By time, ties in journal order.
        let events = input.events.enumerated().filter { GazetteEvent.known.contains($0.element.kind) }
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        let inPeriod = events.filter { $0.at > from && $0.at <= to }
        let nets = inPeriod.filter { $0.kind == "net" }
        let period = inPeriod.filter { $0.kind != "net" }
        let weekStart = to.addingTimeInterval(-7 * 86400)
        let week = events.filter { $0.at > weekStart && $0.at <= to }
        let desk = input.state.desk

        let issues = period.filter { $0.kind == "issue" }
        let tails = period.filter { $0.kind == "link" && $0.class == "gives_away" }
        let tracks = period.filter { $0.kind == "link" && $0.class == "tracks" }
        let moved = period.filter { $0.kind == "desk" && $0.what == "moved" && $0.copy != true }
        let copies = period.filter { $0.kind == "desk" && $0.what == "moved" && $0.copy == true }
        let returned = period.filter { $0.kind == "desk" && $0.what == "returned" }
        let added = period.filter { $0.kind == "archive" && $0.what == "added" }

        var stories: [GazetteIssue.Story] = []
        if issues.count == 1, let e = issues.first {
            let title = e.title ?? ""
            var body = [T("reprint.one.body", ["when": .s(when(e)), "title": .s(title)]), T("reprint.where")]
            if desk != nil { body.append(T("reprint.spoil")) }
            stories.append(story("reprint", T("reprint.one.title", ["title": .s(title)]), body))
        } else if !issues.isEmpty {
            stories.append(story("reprint", T("reprint.many.title", ["n": .n(issues.count)]),
                                 [T("reprint.many.body"), T("reprint.where")],
                                 issues.map { ["\(dayMonth($0)) \(clock($0))", $0.title ?? ""] }))
        }

        if !tails.isEmpty {
            var order: [String] = [], counts: [String: Int] = [:], pairs: [String: (service: String, name: String)] = [:]
            for e in tails {
                var names: [String] = []
                for t in (e.tails ?? []).map(GazetteEvent.plainTail) where !names.contains(t) { names.append(t) }
                if names.isEmpty { names = [""] }
                for name in names {
                    let service = e.service ?? "other"
                    let key = service + "\u{0}" + name
                    if counts[key] == nil { order.append(key); pairs[key] = (service, name) }
                    counts[key, default: 0] += 1
                }
            }
            let items = order.map { key -> [String] in
                let (service, name) = pairs[key]!
                var what = name.isEmpty ? T("editing.item.unnamed") : T("editing.item", ["tail": .s(name)])
                if counts[key]! > 1 { what += T("editing.item.times", ["n": .n(counts[key]!)]) }
                return [T(T.has("service." + service) ? "service." + service : "service.other"), what]
            }
            var body = [T("editing.body", ["n": .n(tails.count)])]
            if !tracks.isEmpty { body.append(T("editing.also", ["n": .n(tracks.count)])) }
            stories.append(story("editing", T("editing.title", ["n": .n(tails.count)]), body, items))
        }

        if !moved.isEmpty {
            var body = [T("desk.moved.body", ["n": .n(moved.count)])]
            if !copies.isEmpty { body.append(T("desk.copies", ["n": .n(copies.count)])) }
            if !returned.isEmpty { body.append(T("desk.returned", ["n": .n(returned.count)])) }
            stories.append(story("desk", T("desk.moved.title", ["n": .n(moved.count)]), body, moved.map { [$0.name ?? ""] }))
        } else if !copies.isEmpty {
            stories.append(story("desk", T("desk.copies.title", ["n": .n(copies.count)]), [T("desk.copies.body")]))
        } else if let desk, let next = desk.next {
            let within = next.left <= 0 ? T("desk.in.now") : next.left == 1 ? T("desk.in.tomorrow") : T("desk.in.days", ["n": .n(next.left)])
            let body = desk.week > 0 ? T("desk.state", ["files": .n(desk.files), "week": .n(desk.week)])
                : T("desk.state.none", ["files": .n(desk.files)])
            stories.append(story("desk", T("desk.next.\(next.to).title", ["name": .s(next.name), "in": .s(within)]), [body]))
        } else if let desk, desk.week > 0 {
            stories.append(story("desk", T("desk.week.title", ["n": .n(desk.week)]), [T("desk.week.body", ["files": .n(desk.files)])]))
        }

        if added.count == 1, let e = added.first {
            stories.append(story("archive", T("archive.one.title", ["title": .s(e.title ?? "")]),
                                 [T(e.by == "desk" ? "archive.by.desk" : "archive.by.hand"), T("archive.sealed")]))
        } else if !added.isEmpty {
            stories.append(story("archive", T("archive.many.title", ["n": .n(added.count)]), [T("archive.many.body")],
                                 added.map { [$0.title ?? ""] }))
        }

        if !tracks.isEmpty && tails.isEmpty {
            stories.append(story("editing", T("editing.tracks.title", ["n": .n(tracks.count)]), [T("editing.tracks.body")]))
        }

        if stories.isEmpty {
            let first = input.number == 1
            stories.append(story("empty", T(first ? "first.title" : "empty.title"), [T(first ? "first.body" : "empty.body")]))
        }

        func target(_ e: GazetteEvent) -> String {
            if e.vpn == true { return T("sources.to.vpn") }
            guard let to = e.to, !to.isEmpty else { return T("sources.to.unknown") }
            return e.cloud == true ? T("sources.to.cloud", ["company": .s(to)]) : to
        }
        // Stable order: bigger first, ties as recorded.
        let big = nets.enumerated().filter { ($0.element.sent ?? 0) >= bigSend }
            .sorted { ($1.element.sent ?? 0, $0.offset) < ($0.element.sent ?? 0, $1.offset) }.map(\.element)
        var newPairs: [GazetteEvent] = [], seenPairs = Set<String>()
        for e in nets where e.first == true && seenPairs.insert((e.app ?? "") + "\u{0}" + target(e)).inserted { newPairs.append(e) }
        var appOrder: [String] = [], sentBy: [String: Int] = [:]
        for e in nets {
            let app = e.app ?? ""
            if sentBy[app] == nil { appOrder.append(app) }
            sentBy[app, default: 0] += e.sent ?? 0
        }
        var sourceRows = big.prefix(3).map { [clock($0), T("sources.item.big", ["app": .s($0.app ?? ""), "to": .s(target($0)), "size": .s(size($0.sent ?? 0))])] }
        sourceRows += newPairs.prefix(3).map { [T("sources.new.label"), T("sources.item.new", ["app": .s($0.app ?? ""), "to": .s(target($0))])] }
        // The first of equal sums wins, as `max` does in the reference.
        if let top = appOrder.max(by: { sentBy[$0]! < sentBy[$1]! }).flatMap({ t in appOrder.first { sentBy[$0] == sentBy[t] } }),
           sentBy[top]! >= megabyte {
            sourceRows.append([T("sources.top.label"), T("sources.item.top", ["app": .s(top), "size": .s(size(sentBy[top]!))])])
        }
        let sourcesTitle: String
        if let b = big.first {
            let night = (fields(b.at, tz: tz).hour ?? 12) < 6
            sourcesTitle = T(night ? "sources.big.night.title" : "sources.big.title", ["app": .s(b.app ?? ""), "size": .s(size(b.sent ?? 0))])
        } else if let n = newPairs.first {
            sourcesTitle = T("sources.new.title", ["app": .s(n.app ?? ""), "to": .s(target(n))])
        } else if !nets.isEmpty {
            sourcesTitle = T("sources.count.title", ["n": .n(appOrder.count)])
        } else {
            sourcesTitle = ""
        }
        let cappedSources = capped(sourceRows)
        let sources = GazetteIssue.Sources(rubric: T("sources.rubric"), title: sourcesTitle, items: cappedSources.shown, more: cappedSources.more,
                                          note: nets.isEmpty ? T(input.state.sources == true ? "sources.none" : "sources.off") : "")

        let weather: String
        if !issues.isEmpty || !tails.isEmpty {
            var reasons = [T("weather.busy")]
            if !issues.isEmpty { reasons.append(T("weather.issues", ["n": .n(issues.count)])) }
            if !tails.isEmpty { reasons.append(T("weather.tails", ["n": .n(tails.count)])) }
            weather = reasons.joined(separator: ", ")
        } else {
            weather = T(period.isEmpty ? "weather.quiet" : "weather.calm")
        }

        let weekLine = T("week", ["issues": .n(week.filter { $0.kind == "issue" }.count),
                                  "links": .n(week.filter { $0.kind == "link" }.count),
                                  "desk": .n(week.filter { $0.kind == "desk" && $0.what == "moved" }.count)])

        let docs = input.state.documents
        let document: GazetteIssue.Document
        // The first of equal dates wins, as `min` does in the reference.
        let dated = docs.filter { $0.expires != nil }.min { $0.expires! < $1.expires! }
        if !input.state.archive {
            document = .init(rubric: T("doc.rubric.archive"), title: T("doc.none.title"), note: T("doc.none.note"))
        } else if docs.isEmpty {
            document = .init(rubric: T("doc.rubric.archive"), title: T("doc.empty.title"), note: T("doc.empty.note"))
        } else if let d = dated, let day = day(d.expires!) {
            let left = day.number - todayNumber
            let v: [String: GazetteValue] = ["title": .s(d.title), "day": .n(day.fields.day!), "month": .s(month(day.fields)),
                                             "year": .n(day.fields.year!)]
            let suffix = day.fields.year == today.year ? "" : ".year"
            let title: String, note: String
            if left > 0 {
                (title, note) = (T("doc.expires.title" + suffix, v), T("doc.expires.note", ["n": .n(left)]))
            } else if left == 0 {
                (title, note) = (T("doc.today.title", v), "")
            } else {
                (title, note) = (T("doc.expired.title" + suffix, v), T("doc.expired.note", ["n": .n(-left)]))
            }
            document = .init(rubric: T("doc.rubric.expires"), title: title, note: note)
        } else {
            let d = docs.min { $0.added < $1.added }!
            let age = todayNumber - (day(d.added)?.number ?? todayNumber)
            document = .init(rubric: T("doc.rubric.oldest"), title: d.title,
                             note: age > 0 ? T("doc.oldest.note", ["n": .n(age)]) : T("doc.oldest.new"))
        }

        let weekIssues = capped(week.filter { $0.kind == "issue" }.reversed().map { [dayMonth($0), $0.title ?? ""] })
        let issued = GazetteIssue.Issued(rubric: T("issued.rubric"), items: weekIssues.shown, more: weekIssues.more,
                                         note: weekIssues.shown.isEmpty ? T("issued.none") : "")

        return GazetteIssue(
            number: input.number,
            date: String(format: "%04d-%02d-%02d", today.year ?? 0, today.month ?? 0, today.day ?? 0),
            from: input.from, to: input.to,
            dateline: T("dateline", ["weekday": .s(T.list("weekday")[((today.weekday ?? 2) + 5) % 7]), "day": .n(today.day ?? 0),
                                     "month": .s(month(today)), "year": .n(today.year ?? 0)]),
            weather: weather, week: weekLine, stories: stories, sources: sources, document: document, issued: issued,
            colophon: [T("colophon.left"), T("colophon.next", ["hour": .n(input.hour)])])
    }
}
