import Foundation

/// The event journal `events.jsonl` (spec/gazette.md, «Журнал событий»): one JSON object per line.
@MainActor
public final class EventLog {
    public let url: URL
    /// Off when the morning issue is turned off in the settings: nothing is written.
    public var enabled = true

    public nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Redakciya/events.jsonl")
    }

    public init(url: URL = EventLog.defaultURL) { self.url = url }

    private static func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return enc
    }

    public func write(_ event: GazetteEvent) {
        guard enabled else { return }
        var e = event
        e.tails = e.tails.map { $0.map(GazetteEvent.plainTail) }
        guard var line = try? Self.encoder().encode(e) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// The journal in file order. Lines that do not read are skipped.
    public func read() -> [GazetteEvent] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? dec.decode(GazetteEvent.self, from: Data($0.utf8)) }
    }

    /// Drops records older than `date`. Only this journal: it holds nothing the person made.
    public func trim(olderThan date: Date) {
        let all = read()
        let kept = all.filter { $0.at >= date }
        guard kept.count != all.count else { return }
        let enc = Self.encoder()
        var data = Data()
        for e in kept {
            guard let line = try? enc.encode(e) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: url, options: .atomic)
    }
}

/// Issues on disk and the schedule (spec/gazette.md, «Когда выходит»).
@MainActor
public final class GazetteStore {
    public let folder: URL
    public let log: EventLog
    public var templates = GazetteTemplates.bundled
    /// Events older than this many days are dropped when an issue is composed.
    static let keepDays = 35

    public nonisolated static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Redakciya/gazette", isDirectory: true)
    }

    public init(folder: URL = GazetteStore.defaultFolder, log: EventLog) {
        self.folder = folder
        self.log = log
    }

    /// The last moment «hour:00» of local time that has come.
    public nonisolated static func cut(now: Date, hour: Int, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        return today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }

    /// The next moment «hour:00» after `now`, for «Первый выпуск выйдет…».
    public nonisolated static func nextCut(now: Date, hour: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: cut(now: now, hour: hour, calendar: calendar)) ?? now
    }

    nonisolated static func day(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Days that have an issue, oldest first.
    public func days() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    public func load(_ day: String) -> GazetteIssue? {
        (try? Data(contentsOf: folder.appendingPathComponent(day + ".json")))
            .flatMap { try? JSONDecoder().decode(GazetteIssue.self, from: $0) }
    }

    public var latest: GazetteIssue? { days().last.flatMap(load) }

    /// The cut an issue is due for, or nil: one issue per day, the first no earlier than the first cut
    /// after the issue was turned on.
    public func due(now: Date, hour: Int, startedAt: Date, calendar: Calendar = .current) -> Date? {
        let cut = Self.cut(now: now, hour: hour, calendar: calendar)
        guard cut > startedAt else { return nil }
        let last = days().last
        if let last, last >= Self.day(cut, calendar: calendar) { return nil }
        return cut
    }

    /// Composes and stores the issue if one is due. The stored issue never changes.
    @discardableResult
    public func publish(now: Date = Date(), hour: Int, startedAt: Date, state: GazetteState,
                        calendar: Calendar = .current) -> GazetteIssue? {
        guard let cut = due(now: now, hour: hour, startedAt: startedAt, calendar: calendar) else { return nil }
        let previous = latest
        let from = previous.flatMap { GazetteComposer.instant($0.to) }.flatMap { $0 < cut ? $0 : nil } ?? cut.addingTimeInterval(-86400)
        let input = GazetteInput(number: (previous?.number ?? 0) + 1, from: GazetteComposer.stamp(from), to: GazetteComposer.stamp(cut),
                                 tz: calendar.timeZone.secondsFromGMT(for: cut) / 60, hour: hour, events: log.read(), state: state)
        guard let issue = GazetteComposer.compose(input, templates: templates) else { return nil }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try enc.encode(issue).write(to: folder.appendingPathComponent(issue.date + ".json"), options: .atomic)
        } catch {
            Log.write("gazette: write failed: \((error as NSError).code)")
            return nil
        }
        log.trim(olderThan: cut.addingTimeInterval(-Double(Self.keepDays) * 86400))
        return issue
    }
}
