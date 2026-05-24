import Foundation

public extension App8Cloud {

    /// Delivered to `onScreenRendered` after a screen renders successfully.
    struct RenderEvent: Sendable {
        public let screenId: String
        /// What the server actually served — may differ from the requested `version`.
        public let servedVersion: String?
        public let durationMs: Int
        public let fromCache: Bool
        /// Locale used to resolve `{"$i18n": "..."}` values on this render.
        /// Reflects the override set via `setLocale(...)` or the device default.
        /// Useful for debugging which locale the user actually saw.
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
}
