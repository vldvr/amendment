import Darwin
import Foundation

/// Hourly sums per «program, company» and first acquaintances (spec/sources.md). No addresses are kept:
/// an address turns into a company name here and is gone. Not thread-safe: the owner calls it from one queue.
public struct SourcesAggregator {
    struct Key: Hashable {
        let app: String
        let to: String
        let cloud: Bool
        let vpn: Bool
    }

    public static let learning: TimeInterval = 3 * 86400

    private var hour: Date?
    private var sums: [Key: (sent: UInt64, got: UInt64)] = [:]
    private var order: [Key] = []
    private var fresh: Set<Key> = []
    /// Pairs seen before, as «program<TAB>company»; `since` starts the three days of getting acquainted.
    public private(set) var known: Set<String>
    public let since: Date
    public private(set) var knownChanged = false
    private let lookup: (UInt32) -> AsnBase.Company?

    public init(known: Set<String> = [], since: Date, lookup: @escaping (UInt32) -> AsnBase.Company?) {
        self.known = known
        self.since = since
        self.lookup = lookup
    }

    static func hourStart(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    /// Adds bytes of one flow. Returns the records of the finished hour when the hour has turned.
    public mutating func add(app: String, remote: RemoteAddress, sent: UInt64, got: UInt64, at: Date) -> [GazetteEvent] {
        guard sent > 0 || got > 0, remote.reach != .local else { return [] }
        var out: [GazetteEvent] = []
        let h = Self.hourStart(at)
        if let hour, hour != h { out = flush(); fresh = [] }
        hour = h
        let key: Key
        if remote.reach == .vpn {
            key = Key(app: app, to: "", cloud: false, vpn: true)
        } else if case .v4(let ip) = remote, let c = lookup(ip) {
            key = Key(app: app, to: c.name, cloud: c.cloud, vpn: false)
        } else {
            key = Key(app: app, to: "", cloud: false, vpn: false)
        }
        let pair = app + "\t" + (key.vpn ? "vpn" : key.to)
        if known.insert(pair).inserted {
            knownChanged = true
            if at.timeIntervalSince(since) >= Self.learning { fresh.insert(key) }
        }
        if sums[key] == nil { order.append(key) }
        let old = sums[key] ?? (0, 0)
        sums[key] = (old.sent + sent, old.got + got)
        return out
    }

    /// Records of the current hour so far; sums start again, acquaintances of this hour stay marked.
    public mutating func flush() -> [GazetteEvent] {
        guard let hour else { return [] }
        let out = order.map { k -> GazetteEvent in
            var e = GazetteEvent(at: hour, kind: "net")
            e.app = k.app; e.to = k.to
            e.cloud = k.cloud ? true : nil; e.vpn = k.vpn ? true : nil; e.first = fresh.contains(k) ? true : nil
            e.sent = Int(clamping: sums[k]!.sent); e.got = Int(clamping: sums[k]!.got)
            return e
        }
        sums = [:]
        order = []
        return out
    }

    /// The hour is over: its acquaintances are no longer new.
    public mutating func endHourIfPast(_ now: Date) -> [GazetteEvent] {
        guard let hour, Self.hourStart(now) != hour else { return [] }
        let out = flush()
        fresh = []
        self.hour = nil
        return out
    }

    public mutating func markSaved() { knownChanged = false }
}

/// Watches the network of this user's programs and hands hourly records to the event journal.
public final class SourcesWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "redakciya.sources")
    private var stat: NetStat?
    private var aggregator: SourcesAggregator?
    private var names: [Int32: String] = [:]
    private var timer: DispatchSourceTimer?
    private let knownURL: URL
    private var _working = false
    /// Hourly records; called on the main queue.
    public var onEvents: ([GazetteEvent]) -> Void = { _ in }

    public static var defaultKnownURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Redakciya/sources-known.json")
    }

    public init(knownURL: URL = SourcesWatch.defaultKnownURL) { self.knownURL = knownURL }

    /// The self-check passed and records are being kept.
    public var working: Bool { queue.sync { _working } }

    private struct Known: Codable {
        var since: Date
        var pairs: [String]
    }

    public func start() {
        queue.async { [self] in
            guard stat == nil, let s = NetStat() else { return }
            s.start()
            guard s.selfTest() else {
                s.stop()
                Log.write("sources: self-check failed, the network is not recorded")
                return
            }
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let saved = (try? Data(contentsOf: knownURL)).flatMap { try? dec.decode(Known.self, from: $0) }
            let base = AsnBase.installed()
            aggregator = SourcesAggregator(known: Set(saved?.pairs ?? []), since: saved?.since ?? Date()) { base?.lookup($0) }
            if saved == nil { save() }
            s.onDelta = { [weak self] d in self?.queue.async { self?.take(d) } }
            stat = s
            _working = true
            Log.write("sources: watching, base \(base.map { "\($0.ranges) ranges" } ?? "missing")")
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 60, repeating: 60)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    public func stop() {
        let rest = flush()
        if !rest.isEmpty { onEvents(rest) }
        queue.sync {
            timer?.cancel()
            timer = nil
            stat?.stop()
            stat = nil
            _working = false
        }
        queue.sync { aggregator = nil }
    }

    private func take(_ d: NetStat.Delta) {
        guard aggregator != nil else { return }
        let app = names[d.pid] ?? {
            let n = Self.appName(pid: d.pid, process: d.process)
            names[d.pid] = n
            return n
        }()
        deliver(aggregator!.add(app: app, remote: d.remote, sent: d.sent, got: d.got, at: Date()))
    }

    /// Once a minute: fresh counters of live flows, the hour boundary, the list of acquaintances.
    private func tick() {
        stat?.refresh()
        if let out = aggregator?.endHourIfPast(Date()), !out.isEmpty {
            deliver(out)
            names = [:]
        }
        if aggregator?.knownChanged == true { save() }
    }

    private func deliver(_ events: [GazetteEvent]) {
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [self] in onEvents(events) }
    }

    /// What the current hour has so far, before an issue is composed or the app quits. Returns on the caller's thread.
    public func flush() -> [GazetteEvent] {
        // The kernel reports a live flow only when asked: ask, and give the answers a moment to arrive.
        if queue.sync(execute: { stat?.refresh(); return stat != nil }) { Thread.sleep(forTimeInterval: 0.3) }
        return queue.sync {
            let out = aggregator?.flush() ?? []
            if aggregator?.knownChanged == true { save() }
            return out
        }
    }

    private func save() {
        guard let a = aggregator else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        try? FileManager.default.createDirectory(at: knownURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? enc.encode(Known(since: a.since, pairs: a.known.sorted())) {
            try? data.write(to: knownURL, options: .atomic)
            aggregator?.markSaved()
        }
    }

    /// The subscription and its self-check, without keeping anything: for checks.
    public static func selfCheck() -> Bool {
        guard let s = NetStat() else { return false }
        s.start()
        defer { s.stop() }
        return s.selfTest()
    }

    /// The program as a person knows it: the outermost `.app` on the path of the process, so helpers fold
    /// into their program; a bare tool keeps its process name.
    static func appName(pid: Int32, process: String) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let path = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
        return appName(path: path, process: process)
    }

    static func appName(path: String, process: String) -> String {
        for part in path.split(separator: "/") where part.hasSuffix(".app") && part.count > 4 {
            return String(part.dropLast(4))
        }
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        return process.isEmpty ? (last.isEmpty ? "?" : last) : process
    }
}
