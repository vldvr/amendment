import Foundation
import ImageIO
import ZamazkaKit

/// Finds images with documents on the desk, with the detector of Zamazka (spec/desk.md, «Личные данные»).
/// Runs in the background one image at a time; results are kept by path and modification date in our own
/// folder: only the kinds found, never the recognised text.
@MainActor
public final class PersonalScanner {
    /// Documents, not everyday details: a phone number or a name on a screenshot does not shorten the term.
    public nonisolated static let kinds: Set<FindingKind> = [.passport, .snils, .inn, .oms, .card, .account]
    public nonisolated static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp", "bmp", "gif"]

    struct Entry: Codable {
        /// Seconds since 1970, kept as a number: ISO dates would drop the fraction and never match again.
        var modified: Double?
        var kinds: [String]
    }

    public let cacheURL: URL
    private var cache: [String: Entry]
    private var queue: [URL] = []
    private var running = false
    /// A new image with documents: the card «Похоже на паспорт».
    public var onFound: (URL, [FindingKind]) -> Void = { _, _ in }
    /// Called when the queue is empty, so Desk can look again with the new answers.
    public var onIdle: () -> Void = {}

    public nonisolated static var defaultCache: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Redakciya/desk-personal.json")
    }

    public init(cacheURL: URL = PersonalScanner.defaultCache) {
        self.cacheURL = cacheURL
        cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    /// Known kinds for a file as it is now; nil if not checked yet or changed since.
    public func kinds(_ url: URL) -> [FindingKind]? {
        guard let e = cache[url.path], e.modified == Self.modified(url) else { return nil }
        return e.kinds.compactMap(FindingKind.init(rawValue:))
    }

    public func isPersonal(_ url: URL) -> Bool { !(kinds(url)?.isEmpty ?? true) }

    /// Queues images that are new or changed. `announce` decides which finds get a card (new files only).
    public func check(_ urls: [URL], announce: @escaping (URL) -> Bool = { _ in true }) {
        for url in urls where Self.imageExtensions.contains(url.pathExtension.lowercased())
            && kinds(url) == nil && !queue.contains(url) && ReprintMark.read(url) == nil {
            queue.append(url)
        }
        self.announce = announce
        runNext()
    }

    private var announce: (URL) -> Bool = { _ in true }

    private func runNext() {
        guard !running else { return }
        guard !queue.isEmpty else { onIdle(); return }
        running = true
        let url = queue.removeFirst()
        let modified = Self.modified(url)
        Task { @MainActor in
            let found = await Self.detect(url)
            self.running = false
            if let found {
                self.cache[url.path] = Entry(modified: modified, kinds: found.map(\.rawValue))
                self.save()
                if !found.isEmpty, self.announce(url) { self.onFound(url, found) }
            }
            self.runNext()
        }
    }

    /// Kinds of documents on the image, nil if it could not be read.
    public nonisolated static func detect(_ url: URL) async -> [FindingKind]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        do {
            let a = try await Detector.analyze(image, options: DetectorOptions(enabled: kinds, timeout: 40))
            var seen = Set<FindingKind>()
            return a.findings.map(\.kind).filter { kinds.contains($0) && seen.insert($0).inserted }
        } catch {
            return nil
        }
    }

    static func modified(_ url: URL) -> Double? {
        var u = url
        u.removeAllCachedResourceValues()
        return (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
