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

        /// Override the locale for `{"$i18n": "..."}` text. Pass nil to revert
        /// to the device default. Applies to subsequent renders only.
        func setLocale(_ locale: String?)

        /// Locale used on the next render: override → device default → bundle's `defaultLocale`.
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

        /// Render a published flow (a gated multi-screen bundle) by its
        /// `flow_key`. `version`: nil → latest published. The start screen
        /// paints first; member screens lazy-load as the user navigates. A
        /// flow's screens are delivered through the flow channel only — they
        /// are not reachable via `screen(id:...)`.
        func flow(
            id: String,
            version: String?
        ) async throws -> UIViewController

        /// Never throws — calls `fallback(error)` on failure.
        func flow(
            id: String,
            version: String?,
            fallback: @escaping FlowFallback
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

        /// Fires after every prefetch with a per-resource freshness summary.
        var onPrefetchCompleted: ((PrefetchEvent) -> Void)? { get set }

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

        // MARK: Screen availability

        /// Synchronous, non-blocking. Reflects the SDK's last known catalog
        /// state (from disk, network refresh, or opportunistic seeding).
        /// Use this to gate UI surfaces (hide CTAs that target screens the
        /// backend hasn't published) and to predetermine whether a render
        /// will succeed without paying a network round-trip.
        func availability(of screenId: String) -> ScreenAvailability

        /// Current catalog snapshot, or `nil` if the SDK has not yet loaded
        /// or received one. Suitable for inspecting the full known-screen
        /// set in host code.
        var catalog: ScreenCatalog? { get }

        /// Resolves when the catalog is loaded (from disk, network refresh,
        /// or a confirmed 404 from the listing endpoint). Returns `nil` on
        /// timeout. Use this on host startup paths that need certainty
        /// before showing navigation surfaces; otherwise the SDK will
        /// best-effort short-circuit on its own once the catalog arrives.
        @discardableResult
        func awaitCatalogReady(timeout: TimeInterval) async -> ScreenCatalog?

        /// Force-refresh the catalog now. No-op when the backend has not
        /// shipped the `/apps/{id}/screens` endpoint (404). Safe to call
        /// from deep-link/push-notification handlers that imply new content
        /// has been published.
        func refreshCatalog() async

        // MARK: Engine pass-through

        @_spi(Advanced)
        var engine: App8.Instance { get }

        // MARK: Event + Analytics buses (forwarded to engine)

        /// Same `App8EventBus` instance the engine uses. Subscribe here OR
        /// on `engine` — there is one bus per cloud Instance.
        var eventBus: App8EventBus { get }

        /// Same `App8AnalyticsBus` instance the engine uses. The cloud SDK
        /// fires its render-lifecycle analytics events onto this bus too —
        /// so a host's `App8AnalyticsHandler` sees `app8.render.failed`,
        /// `app8.render.fallback`, `app8.screen.shortcircuit`, and
        /// `app8.screen.rendered` alongside the engine's
        /// `app8.screen.appeared` / `app8.component.tapped` / etc.
        var analyticsBus: App8AnalyticsBus { get }

        var analyticsConfig: App8AnalyticsConfig { get set }
    }
}

// MARK: - Locale passthrough to the underlying engine

public extension App8Cloud.Instance {
    func setLocale(_ locale: String?) { engine.setLocale(locale) }
    var currentLocale: String { engine.currentLocale }
}

// MARK: - Flow render convenience (default version)

public extension App8Cloud.Instance {
    /// Render the latest published version of a flow.
    func flow(id: String) async throws -> UIViewController {
        try await flow(id: id, version: nil)
    }

    /// Never-throws convenience: latest version.
    func flow(
        id: String,
        fallback: @escaping App8Cloud.FlowFallback
    ) async -> UIViewController {
        await flow(id: id, version: nil, fallback: fallback)
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
