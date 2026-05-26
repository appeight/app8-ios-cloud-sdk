import Foundation

public extension App8Cloud {

    /// Result of asking the SDK whether a given screen ID exists on the
    /// backend without making a network call.
    ///
    /// Returned by ``App8Cloud/Instance/availability(of:)``. The tri-state
    /// distinguishes a confirmed negative (`unknown`) — where the SDK has a
    /// loaded catalog that does not contain the ID — from a "we don't know
    /// yet" state (`catalogNotLoaded`), so host UI can gate buttons/links
    /// without confusing "the screen isn't published" with "we haven't
    /// fetched the catalog".
    enum ScreenAvailability: Sendable, Equatable {
        /// The catalog lists this screen ID as published.
        case known
        /// The catalog is loaded and does NOT list this ID.
        case unknown
        /// No catalog yet (fresh install, backend doesn't expose `/screens`,
        /// or the first refresh hasn't completed). Call
        /// ``App8Cloud/Instance/awaitCatalogReady(timeout:)`` to wait.
        case catalogNotLoaded
    }

    /// Snapshot of the set of screen IDs the backend has published.
    ///
    /// Populated from `GET /apps/{appId}/screens` during init / `prefetchAll`
    /// / explicit refresh, and seeded opportunistically from successful
    /// renders (so even backends that don't expose the listing endpoint
    /// accumulate a partial positive-only catalog over time).
    struct ScreenCatalog: Sendable, Equatable {

        /// The published screen IDs. For backends that don't expose
        /// `/apps/{id}/screens`, this contains only IDs the host has already
        /// rendered successfully in this or a previous session.
        public let screenIds: [String]

        /// When the snapshot was captured. Combine with
        /// ``DiskCacheConfig/catalogTTL`` to decide whether the catalog is
        /// fresh enough for your UI-gating purposes.
        public let fetchedAt: Date

        /// `true` if the backend served a `/apps/{id}/screens` response;
        /// `false` if the catalog is comprised only of opportunistically-
        /// seeded entries from successful renders. When `false`, `unknown`
        /// from ``Instance/availability(of:)`` is unreliable — the SDK falls
        /// back to network for unknown IDs in that case.
        public let backendSupportsEnumeration: Bool

        public init(
            screenIds: [String],
            fetchedAt: Date,
            backendSupportsEnumeration: Bool
        ) {
            self.screenIds = screenIds
            self.fetchedAt = fetchedAt
            self.backendSupportsEnumeration = backendSupportsEnumeration
        }
    }
}
