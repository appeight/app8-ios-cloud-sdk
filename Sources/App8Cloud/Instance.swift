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

        // MARK: Event + Analytics buses (forwarded to engine)

        /// Same `App8EventBus` instance the engine uses. Subscribe here OR
        /// on `engine` — there is one bus per cloud Instance.
        var eventBus: App8EventBus { get }

        /// Same `App8AnalyticsBus` instance the engine uses. The cloud SDK
        /// fires its render/fallback analytics events onto this bus too —
        /// so a host's `App8AnalyticsHandler` sees `app8_render_failed`
        /// alongside the engine's `app8_screen_appeared` etc.
        var analyticsBus: App8AnalyticsBus { get }

        var analyticsConfig: App8AnalyticsConfig { get set }
    }
}

// MARK: - Locale passthrough to the underlying engine

public extension App8Cloud.Instance {
    /// Override the locale used by the underlying engine for `{"$i18n": ...}`
    /// lookups and locale-aware formatters. Pass `nil` to revert to the
    /// device default.
    @MainActor
    func setLocale(_ locale: String?) {
        engine.setLocale(locale)
    }

    /// Active locale on the underlying engine. See `App8.Instance.currentLocale`.
    @MainActor
    var currentLocale: String {
        engine.currentLocale
    }
}

// MARK: - Event + analytics convenience (mirrors App8.Instance)

public extension App8Cloud.Instance {

    // MARK: Action events

    @MainActor
    @discardableResult
    func subscribe(_ handler: @escaping (App8Event) -> Void) -> App8Subscription {
        eventBus.subscribe(handler)
    }

    @MainActor
    @discardableResult
    func subscribe(to eventName: String, _ handler: @escaping (App8Event) -> Void) -> App8Subscription {
        eventBus.subscribe(to: eventName, handler)
    }

    @MainActor
    @discardableResult
    func subscribe(onScreen screenId: String, _ handler: @escaping (App8Event) -> Void) -> App8Subscription {
        eventBus.subscribe(onScreen: screenId, handler)
    }

    var events: AnyPublisher<App8Event, Never> { eventBus.publisher }

    var eventStream: AsyncStream<App8Event> { eventBus.stream }

    @MainActor
    func setEventHandler(_ handler: App8EventHandler?) {
        eventBus.delegate = handler
    }

    // MARK: Analytics events

    @MainActor
    @discardableResult
    func observeAnalytics(_ handler: @escaping (App8AnalyticsEvent) -> Void) -> App8Subscription {
        analyticsBus.subscribe(handler)
    }

    var analytics: AnyPublisher<App8AnalyticsEvent, Never> { analyticsBus.publisher }

    var analyticsStream: AsyncStream<App8AnalyticsEvent> { analyticsBus.stream }

    @MainActor
    func setAnalyticsHandler(_ handler: App8AnalyticsHandler?) {
        analyticsBus.delegate = handler
    }
}
