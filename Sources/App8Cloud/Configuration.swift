import Foundation

public extension App8Cloud {

    /// Backend the SDK talks to — supply the `/sdk/v1` base URL.
    ///
    /// Only `.custom` exists for now; named environments (`.production`,
    /// `.staging`) will be added once the public endpoints are settled.
    enum Environment: Sendable {
        case custom(URL)

        var baseURL: URL {
            switch self {
            case .custom(let url):
                return url
            }
        }
    }

    /// Whether DSL bundles and assets are persisted to disk between launches.
    enum DiskCachePolicy: Sendable {
        case enabled(DiskCacheConfig)
        case disabled

        public static var `default`: Self { .enabled(.init()) }

        var config: DiskCacheConfig? {
            if case .enabled(let cfg) = self { return cfg }
            return nil
        }
    }

    /// Tunes the on-disk cache: location, asset byte budget, and how many
    /// pinned screen versions to retain.
    struct DiskCacheConfig: Sendable {
        /// `nil` resolves to `Library/Caches/App8Cloud/v1/{appId}/`.
        public var rootDirectory: URL?
        public var assetByteBudget: Int64
        public var versionsToKeep: Int
        /// How long the on-disk screen catalog (from `GET /apps/{id}/screens`)
        /// is trusted to answer `availability(of:)` and short-circuit unknown
        /// screen IDs without a network round-trip. Stale (older than this)
        /// catalogs trigger a background refresh and fall through to the
        /// network on unknown IDs so a just-published screen isn't masked.
        /// Set to `0` to never short-circuit (catalog still populates for
        /// `availability(of:)` queries, but `screen(id:)` always hits network
        /// for unknown IDs).
        public var catalogTTL: TimeInterval

        public init(
            rootDirectory: URL? = nil,
            assetByteBudget: Int64 = 50 * 1024 * 1024,
            versionsToKeep: Int = 2,
            catalogTTL: TimeInterval = 24 * 60 * 60
        ) {
            self.rootDirectory = rootDirectory
            self.assetByteBudget = assetByteBudget
            self.versionsToKeep = versionsToKeep
            self.catalogTTL = catalogTTL
        }
    }

    /// Selects what `clearCache(scope:)` removes.
    enum CacheScope: Sendable {
        case all
        case screen(id: String)
        case assetsOnly
    }

    /// Whether the SDK collects and sends anonymous render/usage telemetry.
    enum TelemetryPolicy: Sendable {
        case enabled
        case disabled
    }

    /// Controls whether the SDK may reach the network.
    ///
    /// - `.online` (default): cache-first, then refresh from the backend — the
    ///   normal behaviour.
    /// - `.offlineOnly`: serve exclusively from the on-disk cache (typically
    ///   seeded via ``Instance/importOfflineBundle(at:)``). Any cache miss
    ///   throws ``App8Cloud/Error/offlineResourceMissing(context:)`` instead of
    ///   hitting the network. Use it to prove a bundle renders fully offline,
    ///   or to ship an offline-first product.
    enum NetworkPolicy: Sendable {
        case online
        case offlineOnly
    }
}
