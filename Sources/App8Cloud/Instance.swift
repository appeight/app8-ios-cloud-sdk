import Foundation
import UIKit
import Combine
import App8Engine

public extension App8Cloud {

    /// The main SDK interface: renders screens/apps, manages identity
    /// attributes, prefetching, caching, and telemetry callbacks. Create one
    /// with ``App8Cloud/instance(token:appId:environment:diskCache:telemetry:maxSupportedDslVersion:)``.
    @MainActor
    protocol Instance: AnyObject, Sendable {

        // MARK: Identity (analytics passthrough only)

        /// Reserved keys (`$` prefix) are dropped. Attributes are sent to the
        /// backend for analytics only — they do not drive variant selection.
        func setAttributes(_ attributes: [String: String])

        func clearAttributes()

        var currentAttributes: [String: String] { get }

        // MARK: Locale

        /// Override the locale used when rendering `{"$i18n": "..."}` text in
        /// the DSL. Passing nil reverts to the device's first preferred
        /// language (`Locale.preferredLanguages.first`).
        ///
        /// The change applies to **subsequent renders** — already-visible
        /// screens are not re-resolved in v1. Pop and re-push the current
        /// screen if you need it to refresh immediately.
        ///
        /// Negotiation is client-side: the SDK has the full `{locale: {key:
        /// value}}` map loaded at app boot, so flipping `setLocale` is an
        /// in-memory pointer change — no network call.
        func setLocale(_ locale: String?)

        /// The locale string the SDK will use on the next render. Reflects
        /// the most recent override; otherwise the device's first preferred
        /// language; otherwise `"en"`.
        var currentLocale: String { get }

        // MARK: Render

        /// version: nil → latest published; parameters seed DSL variables.
        func screen(
            id: String,
            version: String?,
            parameters: [String: Any]
        ) async throws -> UIViewController

        /// Never throws — calls `fallback(error)` on failure.
        func screen(
            id: String,
            version: String?,
            parameters: [String: Any],
            fallback: @escaping ScreenFallback
        ) async -> UIViewController

        /// `version` is reserved for future app-level version pinning and is
        /// currently ignored — the engine always starts the latest app.
        func startApp(version: String?) async throws -> UIViewController

        /// `version` is reserved (see `startApp(version:)`). Never throws —
        /// calls `fallback(error)` on failure.
        func startApp(
            version: String?,
            fallback: @escaping AppFallback
        ) async -> UIViewController

        func stopApp()

        // MARK: Telemetry

        var onScreenRendered: ((RenderEvent) -> Void)? { get set }

        var onFallbackInvoked: ((FallbackEvent) -> Void)? { get set }

        /// Fire-and-forget — buffered + POSTed in batches. No-op when `telemetry: .disabled`.
        func track(name: String, context: [String: Any])

        // MARK: Preload

        /// `screens: []` → app-level state only. `includingAssets` → asset manifest (not blobs).
        func prefetch(
            screens: [PrefetchTarget],
            includingAssets: Bool
        ) async

        func prefetchAll(includingAssets: Bool) async

        func cancelPrefetch()

        // MARK: Cache

        func clearCache(scope: CacheScope) async

        // MARK: Engine pass-through

        @_spi(Advanced)
        var engine: App8.Instance { get }
    }
}
