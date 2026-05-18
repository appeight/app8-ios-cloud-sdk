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

        public init(
            rootDirectory: URL? = nil,
            assetByteBudget: Int64 = 50 * 1024 * 1024,
            versionsToKeep: Int = 2
        ) {
            self.rootDirectory = rootDirectory
            self.assetByteBudget = assetByteBudget
            self.versionsToKeep = versionsToKeep
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
}
