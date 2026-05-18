import Foundation

struct CacheMeta: Codable, Sendable {
    let schemaVersion: String
    let sdkVersion: String
    let etag: String?
    let fetchedAt: Date
    let dslVersion: String?

    init(
        schemaVersion: String = CacheLayout.schemaVersion,
        sdkVersion: String,
        etag: String? = nil,
        fetchedAt: Date = Date(),
        dslVersion: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sdkVersion = sdkVersion
        self.etag = etag
        self.fetchedAt = fetchedAt
        self.dslVersion = dslVersion
    }
}

enum MetaStore {

    static func read(at url: URL) -> CacheMeta? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(CacheMeta.self, from: data)
    }

    @discardableResult
    static func write(_ meta: CacheMeta, to url: URL) -> Bool {
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
