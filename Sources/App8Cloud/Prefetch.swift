import Foundation

public extension App8Cloud {

    /// A screen to warm into the cache ahead of render — optionally pinned
    /// to a specific version.
    struct PrefetchTarget: Sendable, Hashable {
        public let id: String
        public let version: String?

        public init(id: String, version: String? = nil) {
            self.id = id
            self.version = version
        }
    }
}

// MARK: - Convenience overloads

public extension App8Cloud.Instance {

    func prefetch() async {
        await prefetchAll(includingAssets: true)
    }

    func prefetch(screens: [App8Cloud.PrefetchTarget]) async {
        await prefetch(screens: screens, includingAssets: true)
    }

    func prefetchAll() async {
        await prefetchAll(includingAssets: true)
    }
}
