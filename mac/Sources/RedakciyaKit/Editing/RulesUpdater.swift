import Foundation

/// Fresh link rules from the public vldvr/redakciya-rules (spec/link-rules.md, «Раздача»).
/// A plain GET without cookies or anything about the person; the file is taken only if it passes the same
/// checks as the bundled copy and its version is greater. Accepted files are cached byte for byte.
@MainActor
public final class RulesUpdater {
    public nonisolated static let url = URL(string: "https://raw.githubusercontent.com/vldvr/redakciya-rules/main/link-rules.json")!
    public nonisolated static let maxBytes = 1 << 20
    public nonisolated static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Redakciya/link-rules.json")
    }

    public enum Outcome: Equatable, Sendable {
        case accepted(version: Int)
        case notNewer(version: Int)
        case rejected(String)
    }

    public typealias Fetch = @Sendable (URL) async throws -> (data: Data, status: Int)

    public let cacheURL: URL
    private let fetch: Fetch

    /// `fetch` and `cacheURL` are replaced in checks.
    public init(cacheURL: URL = RulesUpdater.defaultCacheURL, fetch: @escaping Fetch = RulesUpdater.httpFetch) {
        self.cacheURL = cacheURL
        self.fetch = fetch
    }

    /// The cached rules if they are valid and newer than `version`. A bad cache is left alone, not deleted.
    public func loadCached(newerThan version: Int) -> LinkRules? {
        guard let data = try? Data(contentsOf: cacheURL), let rules = try? LinkRules.load(data),
              rules.version > version else { return nil }
        return rules
    }

    /// Validates a downloaded file and, if it is newer, writes it to the cache.
    public func accept(_ data: Data, status: Int, current: Int) -> (Outcome, LinkRules?) {
        guard status == 200 else { return (.rejected("status \(status)"), nil) }
        guard data.count <= Self.maxBytes else { return (.rejected("too big: \(data.count) bytes"), nil) }
        let rules: LinkRules
        do { rules = try LinkRules.load(data) } catch { return (.rejected("invalid: \(error)"), nil) }
        guard rules.version > current else { return (.notNewer(version: rules.version), nil) }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            return (.rejected("cache: \(error)"), nil)
        }
        return (.accepted(version: rules.version), rules)
    }

    /// One check against the server.
    public func check(current: Int) async -> (Outcome, LinkRules?) {
        do {
            let (data, status) = try await fetch(Self.url)
            return accept(data, status: status, current: current)
        } catch {
            return (.rejected("network: \((error as NSError).domain) \((error as NSError).code)"), nil)
        }
    }

    public nonisolated static let httpFetch: Fetch = { url in
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        config.httpAdditionalHeaders = ["User-Agent": "Redakciya/\(version)"]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
