import Foundation
import CryptoKit

/// App-level meta at `meta.json`. `appResources` tracks freshness for the
/// non-versioned endpoints (manifest, styles, components, localizations).
struct CacheMeta: Codable, Sendable {
    let schemaVersion: String
    let sdkVersion: String
    let appResources: [String: ResourceMeta]?
    let fetchedAt: Date
    let dslVersion: String?

    init(
        schemaVersion: String = CacheLayout.schemaVersion,
        sdkVersion: String,
        appResources: [String: ResourceMeta]? = nil,
        fetchedAt: Date = Date(),
        dslVersion: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sdkVersion = sdkVersion
        self.appResources = appResources
        self.fetchedAt = fetchedAt
        self.dslVersion = dslVersion
    }
}

/// `updatedAt` is the opaque server timestamp; nil means we're relying on
/// `contentHash` alone (old backend or BFS-only screen).
struct ResourceMeta: Codable, Sendable {
    let updatedAt: String?
    let contentHash: String
    let fetchedAt: Date
}

/// Persisted at `screens/{id}/_meta.json`.
struct ScreenMeta: Codable, Sendable {
    let schemaVersion: String
    let servedVersion: String?
    let requestedVersion: String?
    let updatedAt: String?
    let contentHash: String
    let fetchedAt: Date

    init(
        schemaVersion: String = CacheLayout.schemaVersion,
        servedVersion: String?,
        requestedVersion: String?,
        updatedAt: String?,
        contentHash: String,
        fetchedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.servedVersion = servedVersion
        self.requestedVersion = requestedVersion
        self.updatedAt = updatedAt
        self.contentHash = contentHash
        self.fetchedAt = fetchedAt
    }
}

struct ScreenFreshness: Sendable, Equatable {
    let version: String?
    let updatedAt: String?
}

enum MetaStore {

    static func readApp(at url: URL) -> CacheMeta? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(CacheMeta.self, from: data)
    }

    @discardableResult
    static func writeApp(_ meta: CacheMeta, to url: URL) -> Bool {
        guard let data = try? encoder.encode(meta) else { return false }
        return atomicWrite(data, to: url)
    }

    static func readScreen(at url: URL) -> ScreenMeta? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(ScreenMeta.self, from: data)
    }

    @discardableResult
    static func writeScreen(_ meta: ScreenMeta, to url: URL) -> Bool {
        guard let data = try? encoder.encode(meta) else { return false }
        return atomicWrite(data, to: url)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// SHA-256 of a response body as lowercase hex.
enum ContentHash {
    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Atomic write. `Data.write(.atomic)` already performs a temp-file write
/// followed by an atomic rename, so no manual temp/rename dance is needed.
/// Best-effort — returns false on any error.
@discardableResult
func atomicWrite(_ data: Data, to url: URL) -> Bool {
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return true
    } catch {
        return false
    }
}
