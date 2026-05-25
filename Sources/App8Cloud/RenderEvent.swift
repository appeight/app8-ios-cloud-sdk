import Foundation

public extension App8Cloud {

    /// Delivered to `onScreenRendered` after a screen renders successfully.
    struct RenderEvent: Sendable {
        public let screenId: String
        /// What the server actually served — may differ from the requested `version`.
        public let servedVersion: String?
        public let durationMs: Int
        public let fromCache: Bool
        /// Locale used to resolve `{"$i18n": "..."}` on this render.
        public let servedLocale: String

        public init(
            screenId: String,
            servedVersion: String?,
            durationMs: Int,
            fromCache: Bool,
            servedLocale: String
        ) {
            self.screenId = screenId
            self.servedVersion = servedVersion
            self.durationMs = durationMs
            self.fromCache = fromCache
            self.servedLocale = servedLocale
        }
    }

    /// Delivered to `onPrefetchCompleted` after every prefetch call —
    /// per-resource and per-screen freshness outcome for the host.
    struct PrefetchEvent: Sendable {
        public enum AppResourceStatus: String, Sendable {
            /// Cheap pre-check passed — cached bytes are still valid, no fetch.
            case cached
            /// Fetched and bytes matched the stored hash — disk untouched.
            case unchanged
            /// Cache was replaced with fresh bytes.
            case refreshed
            /// Refresh threw — cache state unchanged.
            case failed
            /// Manifest only: skipped because `prefetchAll` already refreshed it before BFS.
            case skipped
            /// Refresh never attempted (e.g., prefetch cancelled early).
            case notRun
        }

        public let durationMs: Int
        public let scope: String           // "all" or "specific"
        public let manifest: AppResourceStatus
        public let styles: AppResourceStatus
        public let components: AppResourceStatus
        public let localizations: AppResourceStatus
        /// Set when status is `.refreshed`. One of `"updated_at_changed"`,
        /// `"content_changed"`, `"no_prior_cache"` (plus `"version_changed"`
        /// for screens, but app-level resources have no version).
        public let manifestReason: String?
        public let stylesReason: String?
        public let componentsReason: String?
        public let localizationsReason: String?
        public let screensCount: Int
        public let screensCached: Int      // cachedFresh OR fetched-but-unchanged
        public let screensRefreshed: Int   // bytes were replaced
        public let screensInvalidated: Int // subset of refreshed: precheck wiped first
        public let screensFailed: Int
        public let cancelled: Bool

        public init(
            durationMs: Int,
            scope: String,
            manifest: AppResourceStatus,
            styles: AppResourceStatus,
            components: AppResourceStatus,
            localizations: AppResourceStatus,
            manifestReason: String? = nil,
            stylesReason: String? = nil,
            componentsReason: String? = nil,
            localizationsReason: String? = nil,
            screensCount: Int,
            screensCached: Int,
            screensRefreshed: Int,
            screensInvalidated: Int,
            screensFailed: Int,
            cancelled: Bool
        ) {
            self.durationMs = durationMs
            self.scope = scope
            self.manifest = manifest
            self.styles = styles
            self.components = components
            self.localizations = localizations
            self.manifestReason = manifestReason
            self.stylesReason = stylesReason
            self.componentsReason = componentsReason
            self.localizationsReason = localizationsReason
            self.screensCount = screensCount
            self.screensCached = screensCached
            self.screensRefreshed = screensRefreshed
            self.screensInvalidated = screensInvalidated
            self.screensFailed = screensFailed
            self.cancelled = cancelled
        }
    }
}
