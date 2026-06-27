import Foundation
import UIKit
import App8Engine

@MainActor
final class A8CInstance: App8Cloud.Instance, RenderingBridge {

    // MARK: - Public

    var onScreenRendered: ((App8Cloud.RenderEvent) -> Void)?
    var onFallbackInvoked: ((App8Cloud.FallbackEvent) -> Void)?
    var onPrefetchCompleted: ((App8Cloud.PrefetchEvent) -> Void)?

    // MARK: - Event + Analytics passthrough

    var eventBus: App8EventBus { engine.eventBus }
    var analyticsBus: App8AnalyticsBus { engine.analyticsBus }
    var analyticsConfig: App8AnalyticsConfig {
        get { engine.analyticsConfig }
        set { engine.analyticsConfig = newValue }
    }

    // MARK: - Init params

    private let appId: String
    private let token: String
    private let environment: App8Cloud.Environment
    private let log: Diagnostics

    // MARK: - Stable infrastructure

    private let attributeBag: AttributeBag
    private let httpClient: HTTPClient
    private let assetCache: AssetCache?
    private let diskCache: DiskCache?
    private let dataSource: RenderingDataSource
    private(set) var engine: App8.Instance
    private let telemetry: TelemetryClient?
    private let headers: HeaderBuilder
    private let fontRegistry: FontRegistry
    private let maxSupportedDslVersion: String
    private let catalogStore: ScreenCatalogStore
    /// Coalesced background refresh of the screen catalog.
    /// Single in-flight task; concurrent triggers reuse it.
    private var catalogRefreshTask: Task<Void, Never>?

    // MARK: - Per-screen pinned versions (partner-supplied at call time)

    private var pinnedVersions: [String: String] = [:]
    private var lastServedVersions: [String: String?] = [:]
    private var lastServedFromCache: [String: Bool] = [:]

    // MARK: - Active flow render

    /// A published flow renders through its own engine scoped to the flow
    /// channel (see `FlowScopedDataSource`). Retained so it + its data source
    /// outlive the `flow(...)` call; torn down on the next `flow(...)` or
    /// `stopApp()`. The flow engine's event/analytics buses are forwarded to
    /// the main engine's buses so host subscribers see in-flow events too.
    private var flowEngine: App8.Instance?
    private var flowDataSource: FlowScopedDataSource?
    private var flowEventSubscription: App8Subscription?
    private var flowAnalyticsSubscription: App8Subscription?
    /// Synthetic `screenKey` for flow-level render events.
    private let flowRenderScreenKey = "<flow>"

    // MARK: - Init

    init(
        token: String,
        appId: String,
        environment: App8Cloud.Environment,
        diskCachePolicy: App8Cloud.DiskCachePolicy = .default,
        telemetryPolicy: App8Cloud.TelemetryPolicy = .enabled,
        diagnosticLoggingEnabled: Bool = false,
        maxSupportedDslVersion: String = "1.0",
        networkPolicy: App8Cloud.NetworkPolicy = .online,
        requestTimeoutSeconds: TimeInterval = 30,
        urlSessionOverride: URLSession? = nil
    ) {
        let diskCacheConfig: App8Cloud.DiskCacheConfig? = diskCachePolicy.config
        self.appId = appId
        self.token = token
        self.environment = environment
        self.maxSupportedDslVersion = maxSupportedDslVersion
        let log = Diagnostics(enabled: diagnosticLoggingEnabled)
        self.log = log

        if environment.baseURL.scheme?.lowercased() != "https" {
            log.configurationWarning("App8Cloud: base URL is not HTTPS — the SDK token " +
                "will be sent over an insecure connection. Use an https:// URL.")
        }

        let bag = AttributeBag(diagnostics: log)
        self.attributeBag = bag

        if let cfg = diskCacheConfig {
            let layout = CacheLayout(
                cacheRoot: cfg.rootDirectory ?? defaultCacheRoot(),
                appId: appId
            )
            let dc = DiskCache(
                layout: layout,
                versionsToKeep: cfg.versionsToKeep,
                diagnostics: log
            )
            self.diskCache = dc
            self.assetCache = AssetCache(
                blobsDir: layout.assetBlobsDir,
                byteBudget: cfg.assetByteBudget,
                indexFile: layout.lruIndexFile,
                diagnostics: log
            )
        } else {
            self.diskCache = nil
            self.assetCache = nil
        }

        let headerBuilder = HeaderBuilder(
            token: token,
            sdkVersion: SDKVersion.current,
            maxSupportedDslVersion: maxSupportedDslVersion
        )
        self.headers = headerBuilder
        self.httpClient = HTTPClient(
            baseURL: environment.baseURL,
            headers: headerBuilder,
            timeout: requestTimeoutSeconds,
            diagnostics: log,
            offlineOnly: networkPolicy == .offlineOnly,
            sessionOverride: urlSessionOverride
        )

        let fontRegistry = FontRegistry(diagnostics: log)
        self.fontRegistry = fontRegistry

        let ds = RenderingDataSource(
            appId: appId,
            client: httpClient,
            cache: diskCache,
            assetCache: assetCache,
            fontRegistry: fontRegistry,
            diagnostics: log
        )
        self.dataSource = ds
        self.engine = App8.instance(dataSource: ds)
        // Teach both buses the cloud SDK version once. Every subsequent
        // dispatch — engine-fired or cloud-fired — auto-stamps
        // `cloudVersion` on the typed field and merges `cloud_version` into
        // analytics `properties`. Action-bus events get the typed field
        // only (no canonical-property merge on `payload`).
        self.engine.analyticsBus.cloudVersion = SDKVersion.current
        self.engine.eventBus.cloudVersion = SDKVersion.current
        ds.bind(engine: self.engine)

        let catalog = ScreenCatalogStore(
            appId: appId,
            diskCache: diskCache,
            catalogTTL: diskCacheConfig?.catalogTTL ?? (24 * 60 * 60),
            diagnostics: log
        )
        catalog.loadFromDisk()
        self.catalogStore = catalog
        ds.bind(catalog: catalog)

        // Constructed before any `self`-using calls.
        let telemetryClient: TelemetryClient?
        switch telemetryPolicy {
        case .enabled:
            telemetryClient = TelemetryClient(
                client: httpClient,
                appId: appId,
                identityProvider: { bag.snapshot },
                diagnostics: log
            )
        case .disabled:
            telemetryClient = nil
        }
        self.telemetry = telemetryClient

        ds.bind(bridge: self)
        ds.bind(telemetry: telemetryClient)

        telemetryClient?.enqueue(.init(
            type: "sdk_init",
            occurredAt: Date(),
            screenKey: nil,
            context: [
                "hostBundleId": headerBuilder.hostBundleId ?? "unknown",
                "hostVersion": headerBuilder.hostAppVersionString ?? "unknown",
                "sdkVersion": SDKVersion.current
            ]
        ))

        // Kick off a non-blocking catalog refresh so the very next
        // `screen(id:)` call after init can already short-circuit unknown
        // IDs. Cheap: one `GET /apps/{id}/screens` request, coalesced.
        // If the disk catalog was just hydrated this is still cheap on the
        // wire when the backend ships ETag/304 — and the in-memory state
        // remains usable while it's in flight.
        startCatalogRefreshIfNeeded(force: false)
    }

    // MARK: - Identity (Instance protocol)

    func setAttributes(_ attributes: [String: String]) {
        let rejected = attributeBag.setAttributes(attributes)
        guard let telemetry else { return }
        telemetry.enqueue(.init(
            type: "attributes_set",
            occurredAt: Date(),
            screenKey: nil,
            context: [
                "count": attributes.count - rejected.count,
                "droppedReservedCount": rejected.count
            ]
        ))
    }

    func clearAttributes() {
        attributeBag.clearAttributes()
        guard let telemetry else { return }
        telemetry.enqueue(.init(
            type: "attributes_cleared",
            occurredAt: Date(),
            screenKey: nil,
            context: nil
        ))
    }

    var currentAttributes: [String: String] {
        attributeBag.snapshot
    }

    // MARK: - Render — throwing variants

    func screen(
        id: String,
        version: String?,
        parameters: [String: Any]
    ) async throws -> UIViewController {
        pinnedVersions[id] = version
        let started = Date()
        log.info("[Render] screen(id='\(id)') start")

        // Short-circuit unknown screen IDs without a network round-trip.
        // Surfaces the same `.screenNotFound` / `.dslVersionUnsupported`
        // errors the render path would produce after the round-trip — host
        // fallback and `screen_render_failed` telemetry stay identical.
        if let shortCircuitError = shortCircuitError(forScreenId: id, requestedVersion: version) {
            emitShortCircuitTelemetry(screenId: id, error: shortCircuitError)
            emitRenderFailedTelemetry(kind: "screen", screenId: id, requestedVersion: version, error: shortCircuitError)
            throw shortCircuitError
        }

        do {
            let fontsStart = Date()
            await dataSource.ensureScreenFontsRegistered(id: id)
            let fontsMs = Int(Date().timeIntervalSince(fontsStart) * 1000)

            let options = ScreenRenderOptions(
                params: parameters.isEmpty ? nil : parameters,
                missingParamStrategy: .typeDefaults
            )
            let renderStart = Date()
            let vc = try await engine.renderScreen(screenId: id, options: options)
            let renderMs = Int(Date().timeIntervalSince(renderStart) * 1000)
            let totalMs = Int(Date().timeIntervalSince(started) * 1000)
            log.info("[Render] screen(id='\(id)') done — fonts \(fontsMs)ms, render \(renderMs)ms, total \(totalMs)ms")
            fireRenderEvent(kind: "screen", screenId: id, requestedVersion: version, started: started)
            schedulePresentedEvent(vc: vc, kind: "screen", screenId: id)
            return vc
        } catch let cloudError as App8Cloud.Error {
            // The catalog may claim a screen exists that the backend just
            // unpublished. Drop the stale entry so subsequent calls can
            // short-circuit correctly once the next refresh runs.
            if case .screenNotFound = cloudError {
                catalogStore.markStaleIfBackendSays404(id: id)
            }
            emitRenderFailedTelemetry(kind: "screen", screenId: id, requestedVersion: version, error: cloudError)
            throw cloudError
        } catch let e as App8.Error {
            let cloudError = App8Cloud.Error.engine(e)
            emitRenderFailedTelemetry(kind: "screen", screenId: id, requestedVersion: version, error: cloudError)
            throw cloudError
        }
    }

    func startApp(version: String?) async throws -> UIViewController {
        let started = Date()
        do {
            let vc = try await engine.startApp()
            fireRenderEvent(kind: "app", screenId: appRenderScreenKey, requestedVersion: version, started: started)
            schedulePresentedEvent(vc: vc, kind: "app", screenId: appRenderScreenKey)
            return vc
        } catch let cloudError as App8Cloud.Error {
            emitRenderFailedTelemetry(kind: "app", screenId: appRenderScreenKey, requestedVersion: version, error: cloudError)
            throw cloudError
        } catch let e as App8.Error {
            let cloudError = App8Cloud.Error.engine(e)
            emitRenderFailedTelemetry(kind: "app", screenId: appRenderScreenKey, requestedVersion: version, error: cloudError)
            throw cloudError
        }
    }

    func flow(
        id: String,
        version: String?
    ) async throws -> UIViewController {
        let started = Date()
        log.info("[Render] flow(id='\(id)') start")

        tearDownActiveFlow()

        do {
            let manifest = try await dataSource.getFlowManifest(flowKey: id, version: version)

            // DSL gate: a flow requiring a newer DSL than this build supports
            // must surface a clean `.dslVersionUnsupported` (→ FlowFallback)
            // instead of being handed to the engine. Unlike the screen catalog
            // short-circuit, the manifest is fetched per-request, so its
            // `minDslVersion` is authoritative for the served version — gate
            // regardless of whether the request was version-pinned.
            if let minDsl = manifest.minDslVersion,
               !Self.dslVersion(minDsl, isAtMost: maxSupportedDslVersion)
            {
                throw App8Cloud.Error.dslVersionUnsupported(found: minDsl, max: maxSupportedDslVersion)
            }

            // Pin the whole flow session to the version the manifest actually
            // resolved to. For an unpinned ("latest") request this freezes
            // member-screen / styles / components fetches to that concrete
            // version, so a re-publish mid-flow can't drift them to a newer
            // version (which would 404 a screen the manifest promised, or
            // serve cross-version bytes). `servedVersion` is always concrete.
            let resolvedVersion = manifest.servedVersion ?? version

            let scoped = FlowScopedDataSource(
                parent: dataSource,
                flowKey: id,
                version: resolvedVersion,
                manifest: manifest
            )
            let flowEngine = App8.instance(dataSource: scoped)
            flowEngine.analyticsBus.cloudVersion = SDKVersion.current
            flowEngine.eventBus.cloudVersion = SDKVersion.current

            // Forward in-flow events to the main buses host code subscribed to.
            let mainEventBus = engine.eventBus
            let mainAnalyticsBus = engine.analyticsBus
            self.flowEventSubscription = flowEngine.eventBus.subscribe { mainEventBus.dispatch($0) }
            self.flowAnalyticsSubscription = flowEngine.analyticsBus.subscribe { mainAnalyticsBus.dispatch($0) }

            self.flowDataSource = scoped
            self.flowEngine = flowEngine

            // Preload the entry screen's fonts AND named image assets (poster,
            // backgrounds, icons) before first paint — otherwise the screen
            // renders blank and the media pops in afterward (the "blink"). The
            // large background video is skipped (streams behind its now-warmed
            // poster), so launch stays snappy.
            await dataSource.ensureScreenFontsRegistered(id: manifest.startScreen, using: flowEngine)
            await dataSource.ensureScreenImagesWarmed(id: manifest.startScreen, using: flowEngine)

            // Render — start screen paints first; members lazy-load on nav.
            let vc = try await flowEngine.renderFlow(flowId: id)

            // Background-warm fonts AND images for the remaining member screens
            // so a push to any of them paints immediately. Bounded by the data
            // source's own concurrency; skipped on teardown.
            let remaining = manifest.screens.map(\.screenKey).filter { $0 != manifest.startScreen }
            if !remaining.isEmpty {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for screenKey in remaining {
                        guard self.flowEngine === flowEngine else { return } // torn down / replaced
                        await self.dataSource.ensureScreenFontsRegistered(id: screenKey, using: flowEngine)
                        await self.dataSource.ensureScreenImagesWarmed(id: screenKey, using: flowEngine)
                    }
                }
            }

            let totalMs = Int(Date().timeIntervalSince(started) * 1000)
            log.info("[Render] flow(id='\(id)') done — total \(totalMs)ms")
            fireRenderEvent(kind: "flow", screenId: id, requestedVersion: version, started: started)
            schedulePresentedEvent(vc: vc, kind: "flow", screenId: id)
            return vc
        } catch let cloudError as App8Cloud.Error {
            tearDownActiveFlow()
            emitRenderFailedTelemetry(kind: "flow", screenId: id, requestedVersion: version, error: cloudError)
            throw cloudError
        } catch let e as App8.Error {
            tearDownActiveFlow()
            let cloudError = App8Cloud.Error.engine(e)
            emitRenderFailedTelemetry(kind: "flow", screenId: id, requestedVersion: version, error: cloudError)
            throw cloudError
        }
    }

    /// Cancel bus forwarding and release the active flow engine + data source.
    private func tearDownActiveFlow() {
        flowEventSubscription?.cancel()
        flowAnalyticsSubscription?.cancel()
        flowEventSubscription = nil
        flowAnalyticsSubscription = nil
        flowEngine?.stopApp()
        flowEngine = nil
        flowDataSource = nil
        dataSource.clearFlowScreenCache()
    }

    func stopApp() {
        tearDownActiveFlow()
        engine.stopApp()
        if let telemetry {
            Task { await telemetry.shutdown() }
        }
    }

    // MARK: - Custom telemetry (Instance protocol)

    func track(name: String, context: [String: Any]) {
        guard let telemetry else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else {
            log.warning("App8Cloud.track: invalid event name (empty or >128 chars) — dropped.")
            return
        }
        let safeContext = sanitizeJSONDict(context)
        var payload: [String: Any] = ["name": trimmed]
        if !safeContext.isEmpty { payload["data"] = safeContext }
        telemetry.enqueue(.init(
            type: "custom",
            occurredAt: Date(),
            screenKey: nil,
            context: payload
        ))
    }

    // MARK: - Render — fallback variants

    func screen(
        id: String,
        version: String?,
        parameters: [String: Any],
        fallback: @escaping App8Cloud.ScreenFallback
    ) async -> UIViewController {
        do {
            return try await screen(id: id, version: version, parameters: parameters)
        } catch let cloudError as App8Cloud.Error {
            return invokeScreenFallback(cloudError, screenId: id, fallback: fallback)
        } catch let engineError as App8.Error {
            return invokeScreenFallback(.engine(engineError), screenId: id, fallback: fallback)
        } catch {
            return invokeScreenFallback(.engine(.appInitFailed), screenId: id, fallback: fallback)
        }
    }

    func startApp(
        version: String?,
        fallback: @escaping App8Cloud.AppFallback
    ) async -> UIViewController {
        do {
            return try await startApp(version: version)
        } catch let cloudError as App8Cloud.Error {
            return invokeAppFallback(cloudError, fallback: fallback)
        } catch let engineError as App8.Error {
            return invokeAppFallback(.engine(engineError), fallback: fallback)
        } catch {
            return invokeAppFallback(.engine(.appInitFailed), fallback: fallback)
        }
    }

    func flow(
        id: String,
        version: String?,
        fallback: @escaping App8Cloud.FlowFallback
    ) async -> UIViewController {
        do {
            return try await flow(id: id, version: version)
        } catch let cloudError as App8Cloud.Error {
            return invokeFlowFallback(cloudError, flowId: id, fallback: fallback)
        } catch let engineError as App8.Error {
            return invokeFlowFallback(.engine(engineError), flowId: id, fallback: fallback)
        } catch {
            return invokeFlowFallback(.engine(.appInitFailed), flowId: id, fallback: fallback)
        }
    }

    private func invokeFlowFallback(
        _ error: App8Cloud.Error,
        flowId: String,
        fallback: App8Cloud.FlowFallback
    ) -> UIViewController {
        let vc = fallback(error)
        onFallbackInvoked?(App8Cloud.FallbackEvent(
            error: error,
            screenId: flowId,
            source: .flow
        ))
        emitFallbackTelemetry(error: error, screenId: flowRenderScreenKey)
        return vc
    }

    private func invokeScreenFallback(
        _ error: App8Cloud.Error,
        screenId: String,
        fallback: App8Cloud.ScreenFallback
    ) -> UIViewController {
        let vc = fallback(error)
        onFallbackInvoked?(App8Cloud.FallbackEvent(
            error: error,
            screenId: screenId,
            source: .screen
        ))
        emitFallbackTelemetry(error: error, screenId: screenId)
        return vc
    }

    private func invokeAppFallback(
        _ error: App8Cloud.Error,
        fallback: App8Cloud.AppFallback
    ) -> UIViewController {
        let vc = fallback(error)
        onFallbackInvoked?(App8Cloud.FallbackEvent(
            error: error,
            screenId: nil,
            source: .app
        ))
        emitFallbackTelemetry(error: error, screenId: appRenderScreenKey)
        return vc
    }

    /// Synthetic `screenKey` so app-level render events join consistently
    /// across `screen_render`, `screen_render_failed`, and `render_fallback`.
    private let appRenderScreenKey: String = "<app>"

    private func emitRenderFailedTelemetry(
        kind: String,
        screenId: String?,
        requestedVersion: String?,
        error: App8Cloud.Error
    ) {
        // Fire on the host-facing analytics bus independently of the cloud
        // SDK's remote-telemetry POST opt-out (see `telemetry` below). Gated
        // by the engine's `autoCloudEvents` flag — cloud render telemetry now
        // has its own toggle, separate from the engine's screen lifecycle
        // gate (`autoScreenEvents`, which only controls `app8.screen.appeared`
        // / `app8.screen.dismissed`). Hosts who used `autoScreenEvents=false`
        // to silence cloud render failures must migrate to `autoCloudEvents`.
        if engine.analyticsConfig.autoCloudEvents {
            var props: [String: Any] = [
                "kind": kind,
                "reason": telemetryReasonString(error)
            ]
            if let requestedVersion { props["requested_version"] = requestedVersion }
            if case let .dslVersionUnsupported(found, max) = error {
                props["dsl_version_required"] = found
                props["dsl_version_client_max"] = max
            }
            if case let .screenVersionNotFound(_, version) = error {
                props["version"] = version
            }
            if case let .serverError(status, _) = error {
                props["status"] = status
            }
            engine.analyticsBus.dispatch(App8AnalyticsEvent(
                name: App8AnalyticsEvent.Auto.renderFailed,
                screenId: screenId,
                componentId: nil,
                componentType: nil,
                properties: props
            ))
        }

        guard let telemetry else { return }
        var ctx: [String: Any] = [
            "kind": kind,
            "reason": telemetryReasonString(error)
        ]
        if let requestedVersion { ctx["requestedVersion"] = requestedVersion }
        if case let .dslVersionUnsupported(found, max) = error {
            ctx["dslVersionRequired"] = found
            ctx["dslVersionClientMax"] = max
        }
        if case let .screenVersionNotFound(_, version) = error {
            ctx["version"] = version
        }
        if case let .serverError(status, _) = error {
            ctx["status"] = status
        }
        telemetry.enqueue(.init(
            type: "screen_render_failed",
            occurredAt: Date(),
            screenKey: screenId,
            context: ctx
        ))
    }

    private func emitFallbackTelemetry(error: App8Cloud.Error, screenId: String?) {
        // Mirror `app8.render.failed`: hosts want fallback signal on the same
        // bus they get screen-lifecycle events on, independent of the cloud
        // SDK's remote-telemetry POST opt-out below. Gated by `autoCloudEvents`
        // alongside the other cloud render events.
        if engine.analyticsConfig.autoCloudEvents {
            let kind = (screenId == appRenderScreenKey) ? "app" : "screen"
            var props: [String: Any] = [
                "kind": kind,
                "reason": telemetryReasonString(error)
            ]
            if case let .dslVersionUnsupported(found, max) = error {
                props["dsl_version_required"] = found
                props["dsl_version_client_max"] = max
            }
            if case let .screenVersionNotFound(_, version) = error {
                props["version"] = version
            }
            if case let .serverError(status, _) = error {
                props["status"] = status
            }
            engine.analyticsBus.dispatch(App8AnalyticsEvent(
                name: App8AnalyticsEvent.Auto.renderFallback,
                screenId: screenId,
                componentId: nil,
                componentType: nil,
                properties: props
            ))
        }

        guard let telemetry else { return }
        var ctx: [String: Any] = ["reason": telemetryReasonString(error)]
        if case let .dslVersionUnsupported(found, max) = error {
            ctx["required"] = found
            ctx["clientMax"] = max
        }
        if case let .screenVersionNotFound(_, version) = error {
            ctx["version"] = version
        }
        if case let .serverError(status, _) = error {
            ctx["status"] = status
        }
        telemetry.enqueue(.init(
            type: "render_fallback",
            occurredAt: Date(),
            screenKey: screenId,
            context: ctx
        ))
    }

    private func fireRenderEvent(
        kind: String,
        screenId: String,
        requestedVersion: String?,
        started: Date
    ) {
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        let served = lastServedVersions[screenId] ?? nil
        let fromCache = lastServedFromCache[screenId] ?? false
        let event = App8Cloud.RenderEvent(
            screenId: screenId,
            servedVersion: served,
            durationMs: durationMs,
            fromCache: fromCache,
            servedLocale: engine.currentLocale
        )
        onScreenRendered?(event)

        // Fire `app8.screen.rendered` on the analytics bus — the success arm
        // that pairs with `app8.render.failed` / `app8.render.fallback`.
        // Gated by `autoCloudEvents`. Fires after `onScreenRendered?(event)`
        // so the existing `App8Cloud.RenderEvent` callback ordering is
        // preserved. Property keys use the canonical snake_case convention;
        // the bus then merges `screen_id`, `locale`, `engine_version`,
        // `cloud_version` on top.
        if engine.analyticsConfig.autoCloudEvents {
            var props: [String: Any] = [
                "kind": kind,
                "render_ms": durationMs,
                "from_cache": fromCache
            ]
            if let served { props["served_version"] = served }
            if let requestedVersion { props["requested_version"] = requestedVersion }
            engine.analyticsBus.dispatch(App8AnalyticsEvent(
                name: App8AnalyticsEvent.Auto.screenRendered,
                screenId: screenId,
                componentId: nil,
                componentType: nil,
                properties: props
            ))
        }

        guard let telemetry else { return }
        var ctx: [String: Any] = [
            "kind": kind,
            "durationMs": durationMs,
            "fromCache": fromCache
        ]
        if let requestedVersion { ctx["requestedVersion"] = requestedVersion }
        if let served { ctx["servedVersion"] = served }
        telemetry.enqueue(.init(
            type: "screen_render",
            occurredAt: Date(),
            screenKey: screenId,
            context: ctx
        ))
    }

    /// Attaches a one-shot layout sentinel to the returned VC's view so we
    /// can emit `screen_presented` once the host has sized the container.
    /// No-op when telemetry is disabled.
    private func schedulePresentedEvent(
        vc: UIViewController,
        kind: String,
        screenId: String
    ) {
        guard telemetry != nil else { return }
        LayoutSentinelView.attach(to: vc.view) { [weak self] size, traits in
            self?.emitScreenPresented(
                kind: kind,
                screenId: screenId,
                size: size,
                traits: traits
            )
        }
    }

    private func emitScreenPresented(
        kind: String,
        screenId: String,
        size: CGSize,
        traits: UITraitCollection
    ) {
        guard let telemetry else { return }
        let ctx: [String: Any] = [
            "kind": kind,
            "width": Double(size.width),
            "height": Double(size.height),
            "scale": Double(traits.displayScale),
            "horizontalSizeClass": sizeClassString(traits.horizontalSizeClass),
            "verticalSizeClass": sizeClassString(traits.verticalSizeClass),
            "deviceIdiom": deviceIdiomString(traits.userInterfaceIdiom)
        ]
        telemetry.enqueue(.init(
            type: "screen_presented",
            occurredAt: Date(),
            screenKey: screenId,
            context: ctx
        ))
    }

    // MARK: - Preload (Instance protocol)

    private var inFlightPrefetch: Task<PrefetchSummary, Never>?

    func prefetch(
        screens: [App8Cloud.PrefetchTarget],
        includingAssets: Bool
    ) async {
        let previous = inFlightPrefetch
        let started = Date()
        let screenCount = screens.count

        let task = Task { [weak self] () -> PrefetchSummary in
            // Wait for any prior task to settle before writing meta.json /
            // per-screen _meta.json — otherwise rapid calls race them.
            if let previous {
                previous.cancel()
                _ = await previous.value
            }
            guard let self else { return PrefetchSummary() }
            if Task.isCancelled {
                var s = PrefetchSummary()
                s.cancelled = true
                return s
            }

            let snapshot = await self.fetchSnapshotBestEffort()
            let freshnessBy = self.freshnessLookup(snapshot)
            if Task.isCancelled {
                var s = PrefetchSummary()
                s.cancelled = true
                return s
            }

            let ds = self.dataSource
            let log = self.log
            let summary = await Self.runPrefetch(
                dataSource: ds,
                snapshot: snapshot,
                screens: screens,
                freshnessBy: freshnessBy,
                skipManifestRefresh: false,
                includingAssets: includingAssets,
                log: log
            )

            if !Task.isCancelled, includingAssets, !screens.isEmpty {
                await self.engine.prefetchImages(forScreens: screens.map(\.id))
            }
            return summary
        }
        inFlightPrefetch = task
        let summary = await task.value
        if inFlightPrefetch == task { inFlightPrefetch = nil }
        emitPrefetchTelemetry(
            scope: "specific",
            screenCount: screenCount,
            summary: summary,
            includingAssets: includingAssets,
            started: started
        )
    }

    /// Union backend `/screens` + engine BFS; backend wins (has version pins).
    func prefetchAll(includingAssets: Bool) async {
        let previous = inFlightPrefetch
        let started = Date()
        let dslMax = self.maxSupportedDslVersion

        let task = Task { [weak self] () -> PrefetchSummary in
            if let previous {
                previous.cancel()
                _ = await previous.value
            }
            guard let self else { return PrefetchSummary() }
            if Task.isCancelled {
                var s = PrefetchSummary()
                s.cancelled = true
                return s
            }

            let ds = self.dataSource
            let log = self.log
            let engine = self.engine

            let discoveryStarted = Date()

            let snapshot: RenderingDataSource.PublishedSnapshot?
            do {
                snapshot = try await ds.fetchPublishedScreens()
            } catch {
                log.warning("[Prefetch] /screens fetch failed: \(error). Falling back to flow BFS only.")
                snapshot = nil
            }
            if Task.isCancelled {
                var s = PrefetchSummary()
                s.cancelled = true
                return s
            }

            // Manifest must be fresh before BFS — otherwise BFS walks stale nav.
            do {
                _ = try await ds.refreshManifestIfChanged(
                    expectedUpdatedAt: snapshot?.resources?.manifest
                )
            } catch {
                log.warning("[Prefetch] manifest refresh failed: \(error). BFS will run against stale manifest.")
            }
            if Task.isCancelled {
                var s = PrefetchSummary()
                s.cancelled = true
                return s
            }

            var publishedTargets: [App8Cloud.PrefetchTarget] = []
            if let snapshot {
                var skipped = 0
                for p in snapshot.screens {
                    if Self.dslVersion(p.minDslVersion, isAtMost: dslMax) {
                        publishedTargets.append(App8Cloud.PrefetchTarget(id: p.screenKey, version: p.version))
                    } else {
                        skipped += 1
                    }
                }
                log.info("[Prefetch] backend lists \(snapshot.screens.count) published screen(s); kept \(publishedTargets.count), skipped \(skipped) above DSL max \(dslMax).")
            }

            var bfsTargets: [App8Cloud.PrefetchTarget] = []
            do {
                let ids = try await engine.discoverAllReachableScreenIds()
                bfsTargets = ids.map { App8Cloud.PrefetchTarget(id: $0, version: nil) }
            } catch {
                log.warning("[Prefetch] flow BFS failed: \(error)")
            }

            var seen = Set<String>()
            var targets: [App8Cloud.PrefetchTarget] = []
            for t in publishedTargets where seen.insert(t.id).inserted {
                targets.append(t)
            }
            for t in bfsTargets where seen.insert(t.id).inserted {
                targets.append(t)
            }

            let discoveryMs = Int(Date().timeIntervalSince(discoveryStarted) * 1000)
            if targets.isEmpty {
                log.warning("[Prefetch] no screens discovered — only app-level state will be warmed.")
            } else {
                log.info("[Prefetch] discovered \(targets.count) screen(s) in \(discoveryMs)ms (backend \(publishedTargets.count) + BFS \(bfsTargets.count) unioned): \(targets.map(\.id).sorted())")
            }

            let freshnessBy = self.freshnessLookup(snapshot)
            let summary = await Self.runPrefetch(
                dataSource: ds,
                snapshot: snapshot,
                screens: targets,
                freshnessBy: freshnessBy,
                skipManifestRefresh: true,
                includingAssets: includingAssets,
                log: log
            )

            if !Task.isCancelled, includingAssets, !targets.isEmpty {
                await engine.prefetchImages(forScreens: targets.map(\.id))
            }
            return summary
        }
        inFlightPrefetch = task
        let summary = await task.value
        if inFlightPrefetch == task { inFlightPrefetch = nil }
        emitPrefetchTelemetry(
            scope: "all",
            screenCount: summary.targetsCount,
            summary: summary,
            includingAssets: includingAssets,
            started: started
        )
    }

    private func fetchSnapshotBestEffort() async -> RenderingDataSource.PublishedSnapshot? {
        do {
            return try await dataSource.fetchPublishedScreens()
        } catch {
            log.warning("[Prefetch] /screens fetch failed: \(error). Using hash-only freshness.")
            return nil
        }
    }

    private func freshnessLookup(_ snapshot: RenderingDataSource.PublishedSnapshot?) -> [String: ScreenFreshness] {
        guard let snapshot else { return [:] }
        var out: [String: ScreenFreshness] = [:]
        for p in snapshot.screens {
            out[p.screenKey] = ScreenFreshness(version: p.version, updatedAt: p.updatedAt)
        }
        return out
    }

    private func emitPrefetchTelemetry(
        scope: String,
        screenCount: Int,
        summary: PrefetchSummary,
        includingAssets: Bool,
        started: Date
    ) {
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)

        // Fires even when remote telemetry is disabled.
        if let onPrefetchCompleted {
            onPrefetchCompleted(App8Cloud.PrefetchEvent(
                durationMs: durationMs,
                scope: scope,
                manifest: summary.manifestStatus,
                styles: summary.stylesStatus,
                components: summary.componentsStatus,
                localizations: summary.localizationsStatus,
                manifestReason: summary.manifestReason,
                stylesReason: summary.stylesReason,
                componentsReason: summary.componentsReason,
                localizationsReason: summary.localizationsReason,
                screensCount: screenCount,
                screensCached: summary.unchangedCount,
                screensRefreshed: summary.refreshedCount,
                screensInvalidated: summary.invalidatedCount,
                screensFailed: summary.failureCount,
                cancelled: summary.cancelled
            ))
        }

        guard let telemetry else { return }
        let ctx: [String: Any] = [
            "scope": scope,
            "screenCount": screenCount,
            "successCount": summary.successCount,
            "failureCount": summary.failureCount,
            "refreshedCount": summary.refreshedCount,
            "unchangedCount": summary.unchangedCount,
            "invalidatedCount": summary.invalidatedCount,
            "includingAssets": includingAssets,
            "cancelled": summary.cancelled,
            "durationMs": durationMs
        ]
        telemetry.enqueue(.init(
            type: "prefetch_completed",
            occurredAt: Date(),
            screenKey: nil,
            context: ctx
        ))
    }

    /// Fire-and-forget. The next `prefetch()` awaits the cancelled task
    /// internally so the one-writer-at-a-time invariant on `meta.json` holds.
    func cancelPrefetch() {
        inFlightPrefetch?.cancel()
        inFlightPrefetch = nil
    }

    private static func appResourceStatus(
        _ outcome: RenderingDataSource.PrefetchOutcome
    ) -> (App8Cloud.PrefetchEvent.AppResourceStatus, String?) {
        switch outcome {
        case .cachedFresh:           return (.cached, nil)
        case .unchanged:             return (.unchanged, nil)
        case .refreshed(let reason): return (.refreshed, reason.rawValue)
        }
    }

    /// `.numeric` so "1.10" > "1.2". Pre-release tags unsupported.
    private static func dslVersion(_ minRequired: String, isAtMost clientMax: String) -> Bool {
        let result = minRequired.compare(clientMax, options: .numeric)
        return result != .orderedDescending
    }

    /// `refreshedCount` + `unchangedCount` partition `successCount`.
    /// `invalidatedCount` is a subset of `refreshedCount` (precheck wipes only).
    struct PrefetchSummary: Sendable {
        var targetsCount: Int = 0
        var successCount: Int = 0
        var failureCount: Int = 0
        var refreshedCount: Int = 0
        var unchangedCount: Int = 0
        var invalidatedCount: Int = 0
        var cancelled: Bool = false
        var manifestStatus: App8Cloud.PrefetchEvent.AppResourceStatus = .notRun
        var stylesStatus: App8Cloud.PrefetchEvent.AppResourceStatus = .notRun
        var componentsStatus: App8Cloud.PrefetchEvent.AppResourceStatus = .notRun
        var localizationsStatus: App8Cloud.PrefetchEvent.AppResourceStatus = .notRun
        var manifestReason: String?
        var stylesReason: String?
        var componentsReason: String?
        var localizationsReason: String?
    }

    private static func runPrefetch(
        dataSource: RenderingDataSource,
        snapshot: RenderingDataSource.PublishedSnapshot?,
        screens: [App8Cloud.PrefetchTarget],
        freshnessBy: [String: ScreenFreshness],
        skipManifestRefresh: Bool,
        includingAssets: Bool,
        log: Diagnostics
    ) async -> PrefetchSummary {
        let prefetchStart = Date()
        var summary = PrefetchSummary()
        summary.targetsCount = screens.count

        // Cancellation checks between refreshes stop a cancelled task from
        // continuing to write meta.json. Per-resource outcomes land on the
        // summary log line below — no per-call logs.
        if !skipManifestRefresh {
            if Task.isCancelled { summary.cancelled = true; return summary }
            do {
                let outcome = try await dataSource.refreshManifestIfChanged(
                    expectedUpdatedAt: snapshot?.resources?.manifest
                )
                let (status, reason) = appResourceStatus(outcome)
                summary.manifestStatus = status
                summary.manifestReason = reason
            } catch {
                summary.manifestStatus = .failed
                log.warning("Prefetch: manifest refresh failed: \(error)")
            }
        } else {
            summary.manifestStatus = .skipped
        }
        if Task.isCancelled { summary.cancelled = true; return summary }
        do {
            let outcome = try await dataSource.refreshStylesIfChanged(
                expectedUpdatedAt: snapshot?.resources?.styles
            )
            let (status, reason) = appResourceStatus(outcome)
            summary.stylesStatus = status
            summary.stylesReason = reason
        } catch {
            summary.stylesStatus = .failed
            log.warning("Prefetch: styles refresh failed: \(error)")
        }
        if Task.isCancelled { summary.cancelled = true; return summary }
        do {
            let outcome = try await dataSource.refreshComponentsIfChanged(
                expectedUpdatedAt: snapshot?.resources?.components
            )
            let (status, reason) = appResourceStatus(outcome)
            summary.componentsStatus = status
            summary.componentsReason = reason
        } catch {
            summary.componentsStatus = .failed
            log.warning("Prefetch: components refresh failed: \(error)")
        }
        if Task.isCancelled { summary.cancelled = true; return summary }
        // Localizations are non-fatal — backends that haven't shipped the
        // endpoint yet still let the rest of prefetch finish.
        do {
            let outcome = try await dataSource.refreshLocalizationsIfChanged(
                expectedUpdatedAt: snapshot?.resources?.localizations
            )
            let (status, reason) = appResourceStatus(outcome)
            summary.localizationsStatus = status
            summary.localizationsReason = reason
        } catch {
            summary.localizationsStatus = .failed
            log.warning("Prefetch: localizations refresh skipped — \(error)")
        }

        // Always warm the asset manifest — even on `includingAssets: false`,
        // skipping it would re-fetch at first render-time font lookup.
        if Task.isCancelled { summary.cancelled = true; return summary }
        await dataSource.prepareFontsIfNeeded()

        func emitSummary() {
            let totalMs = Int(Date().timeIntervalSince(prefetchStart) * 1000)
            func render(_ s: App8Cloud.PrefetchEvent.AppResourceStatus, _ reason: String?) -> String {
                if s == .refreshed, let reason { return "\(s.rawValue)(\(reason))" }
                return s.rawValue
            }
            log.info("[Prefetch] done in \(totalMs)ms — app: " +
                     "{manifest=\(render(summary.manifestStatus, summary.manifestReason)), " +
                     "styles=\(render(summary.stylesStatus, summary.stylesReason)), " +
                     "components=\(render(summary.componentsStatus, summary.componentsReason)), " +
                     "localizations=\(render(summary.localizationsStatus, summary.localizationsReason))} — screens: " +
                     "cached=\(summary.unchangedCount) refreshed=\(summary.refreshedCount) " +
                     "invalidated=\(summary.invalidatedCount) failed=\(summary.failureCount)" +
                     (summary.cancelled ? " cancelled" : ""))
        }

        guard !screens.isEmpty else { emitSummary(); return summary }
        enum Outcome: Sendable {
            case success(RenderingDataSource.PrefetchOutcome)
            case failure
            case cancelled
        }
        await withTaskGroup(of: Outcome.self) { group in
            let bound = 4
            var iterator = screens.makeIterator()

            func enqueueNext() {
                guard let target = iterator.next() else { return }
                let expected = freshnessBy[target.id]
                group.addTask {
                    if Task.isCancelled { return .cancelled }
                    let screenStart = Date()
                    let dslStart = Date()
                    let outcome: RenderingDataSource.PrefetchOutcome
                    do {
                        outcome = try await dataSource.prefetchScreen(
                            id: target.id, version: target.version, expected: expected
                        )
                    } catch {
                        if Task.isCancelled { return .cancelled }
                        log.warning("[Prefetch] screen '\(target.id)' " +
                                    "(version=\(target.version ?? "latest")) DSL fetch failed: \(error)")
                        return .failure
                    }
                    let dslMs = Int(Date().timeIntervalSince(dslStart) * 1000)
                    if Task.isCancelled { return .cancelled }
                    var assetsMs = 0
                    if includingAssets {
                        let assetsStart = Date()
                        await dataSource.prefetchScreenImages(
                            id: target.id, version: target.version
                        )
                        assetsMs = Int(Date().timeIntervalSince(assetsStart) * 1000)
                    }
                    let totalMs = Int(Date().timeIntervalSince(screenStart) * 1000)
                    log.info("[Prefetch] screen '\(target.id)' \(outcome) — DSL \(dslMs)ms, assets \(assetsMs)ms, total \(totalMs)ms")
                    return .success(outcome)
                }
            }

            for _ in 0..<min(bound, screens.count) { enqueueNext() }
            for await outcome in group {
                switch outcome {
                case .success(let kind):
                    summary.successCount += 1
                    switch kind {
                    case .cachedFresh, .unchanged:
                        summary.unchangedCount += 1
                    case .refreshed(let reason):
                        summary.refreshedCount += 1
                        if reason == .versionChanged || reason == .updatedAtChanged {
                            summary.invalidatedCount += 1
                        }
                    }
                case .failure: summary.failureCount += 1
                case .cancelled: summary.cancelled = true
                }
                if Task.isCancelled { break }
                enqueueNext()
            }
        }
        emitSummary()
        return summary
    }

    // MARK: - Cache (Instance protocol)

    func clearCache(scope: App8Cloud.CacheScope) async {
        let cache = diskCache
        let assetCache = self.assetCache
        await Task.detached {
            switch scope {
            case .all:
                cache?.clearAll()
                assetCache?.reset()
            case .screen(let id):
                cache?.clearScreen(id: id)
            case .assetsOnly:
                assetCache?.reset()
            }
        }.value
        // In-memory cache also needs reset — otherwise next prefetch skips re-fetch.
        dataSource.resetInMemoryState(scope: scope)
        if case .all = scope {
            // `cache?.clearAll()` already wiped `screens_catalog.json` along
            // with the rest of `rootForApp`. Drop the in-memory mirror and
            // kick off a background refresh so the next render isn't stuck
            // with a dead-empty catalog if the host immediately calls
            // `screen(id:)` after `clearCache(.all)`.
            catalogStore.resetForCacheClear()
            startCatalogRefreshIfNeeded(force: true)
        }
    }

    // MARK: - Screen availability (Instance protocol)

    func availability(of screenId: String) -> App8Cloud.ScreenAvailability {
        switch catalogStore.availability(of: screenId) {
        case .known:           return .known
        case .unknownFresh:    return .unknown
        case .unknownStale:    return .catalogNotLoaded
        case .catalogNotLoaded: return .catalogNotLoaded
        }
    }

    var catalog: App8Cloud.ScreenCatalog? {
        catalogStore.publicSnapshot()
    }

    @discardableResult
    func awaitCatalogReady(timeout: TimeInterval) async -> App8Cloud.ScreenCatalog? {
        if let snapshot = catalogStore.publicSnapshot() {
            return snapshot
        }
        startCatalogRefreshIfNeeded(force: false)
        guard let task = catalogRefreshTask else {
            return catalogStore.publicSnapshot()
        }
        // Race the in-flight refresh against the caller-supplied timeout.
        // Returning nil on timeout (vs. partial snapshot) is intentional —
        // partners use this method to assert "catalog is ready", and a
        // nil-on-timeout contract keeps that promise unambiguous.
        let didFinish: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await task.value
                return true
            }
            group.addTask {
                let ns = UInt64(max(0, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return didFinish ? catalogStore.publicSnapshot() : nil
    }

    func refreshCatalog() async {
        startCatalogRefreshIfNeeded(force: true)
        if let task = catalogRefreshTask {
            _ = await task.value
        }
    }

    // MARK: - Catalog internals

    /// Identity token for the currently-installed refresh task. Bumped on
    /// every `startCatalogRefreshIfNeeded` that replaces the slot, so the
    /// finisher in `performCatalogRefresh` can distinguish "I'm still the
    /// owner, clear the slot" from "I've been replaced, leave the new task
    /// alone." Sidesteps the old race where a stale finisher would nil out
    /// a freshly-installed successor.
    private var catalogRefreshTaskId: UUID?

    /// `force=true` always starts a refresh even if one is in flight; the
    /// in-flight task is cancelled and replaced so the slot identity always
    /// points at the freshest refresh. HTTP-level dedup (`InFlightCoalescer`
    /// keyed on `Endpoint.listScreens`) still collapses overlapping GETs.
    /// `force=false` is a no-op when a refresh is already running.
    private func startCatalogRefreshIfNeeded(force: Bool) {
        if !force, catalogRefreshTask != nil { return }
        // On force=true we replace any in-flight task. Cancel the old one so
        // it exits via the cancellation path instead of running to completion
        // (HTTP coalescer still serves it the shared response — cancellation
        // here is about avoiding stale catalog mutations after the new task
        // has already produced a fresher snapshot).
        catalogRefreshTask?.cancel()
        let token = UUID()
        catalogRefreshTaskId = token
        catalogRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.performCatalogRefresh(token: token)
        }
    }

    private func performCatalogRefresh(token: UUID) async {
        do {
            // `fetchPublishedScreens()` updates the catalog as a side effect
            // (replace on success, mark-unsupported on 404). The discard
            // here is intentional — A8CInstance doesn't need the snapshot,
            // it consults the catalog store directly.
            _ = try await dataSource.fetchPublishedScreens()
        } catch {
            log.warning("[Catalog] background refresh failed: \(error). Will retry on next trigger.")
        }
        // Clear the slot ONLY if this task still owns it. A concurrent
        // `force: true` arrived while we were awaiting → token mismatch →
        // the new task owns the slot and is responsible for clearing it.
        if catalogRefreshTaskId == token {
            catalogRefreshTask = nil
            catalogRefreshTaskId = nil
        }
    }

    private func shortCircuitError(
        forScreenId id: String,
        requestedVersion: String?
    ) -> App8Cloud.Error? {
        switch catalogStore.availability(of: id) {
        case .known(let entry, _, _):
            // DSL gate is only meaningful for the "latest" path — for a
            // version-pinned request, the server is the authority on what
            // minDslVersion that specific version requires.
            if requestedVersion == nil,
               let minDsl = entry.minDslVersion,
               !Self.dslVersion(minDsl, isAtMost: maxSupportedDslVersion)
            {
                return .dslVersionUnsupported(found: minDsl, max: maxSupportedDslVersion)
            }
            return nil
        case .unknownFresh:
            return .screenNotFound(screenId: id)
        case .unknownStale:
            // Catalog is older than its TTL — a just-published screen could
            // be missing from it. Fall through to the network and refresh
            // the catalog in the background as a side effect.
            startCatalogRefreshIfNeeded(force: false)
            return nil
        case .catalogNotLoaded:
            // No authoritative answer yet (fresh install, no `/screens`
            // endpoint, or refresh still in flight). Trigger one and fall
            // through to network — best-effort semantics.
            startCatalogRefreshIfNeeded(force: false)
            return nil
        }
    }

    private func emitShortCircuitTelemetry(
        screenId: String,
        error: App8Cloud.Error
    ) {
        let catalogAgeMs = catalogStore.ageSeconds() ?? -1
        let source = catalogStore.currentSource().rawValue
        let count = catalogStore.screenCount()
        if engine.analyticsConfig.autoCloudEvents {
            engine.analyticsBus.dispatch(App8AnalyticsEvent(
                name: App8AnalyticsEvent.Auto.screenShortcircuit,
                screenId: screenId,
                componentId: nil,
                componentType: nil,
                properties: [
                    "reason": telemetryReasonString(error),
                    "catalog_age_ms": catalogAgeMs,
                    "catalog_source": source,
                    "catalog_screen_count": count
                ]
            ))
        }
        guard let telemetry else { return }
        telemetry.enqueue(.init(
            type: "screen_availability_shortcircuit",
            occurredAt: Date(),
            screenKey: screenId,
            context: [
                "reason": telemetryReasonString(error),
                "catalogAge_ms": catalogAgeMs,
                "catalogSource": source,
                "catalogScreenCount": count
            ]
        ))
    }

    // MARK: - RenderingBridge

    var identityAttributes: [String: String] {
        attributeBag.snapshot
    }

    func pinnedVersion(forScreen screenId: String) -> String? {
        pinnedVersions[screenId]
    }

    func recordServed(version: String?, fromCache: Bool, forScreen screenId: String) {
        lastServedVersions[screenId] = version
        lastServedFromCache[screenId] = fromCache
    }
}

/// Stable wire strings — keep in sync with backend schema docs.
func sizeClassString(_ cls: UIUserInterfaceSizeClass) -> String {
    switch cls {
    case .compact:     return "compact"
    case .regular:     return "regular"
    case .unspecified: return "unspecified"
    @unknown default:  return "unspecified"
    }
}

func deviceIdiomString(_ idiom: UIUserInterfaceIdiom) -> String {
    switch idiom {
    case .phone:       return "phone"
    case .pad:         return "pad"
    case .mac:         return "mac"
    case .tv:          return "tv"
    case .carPlay:     return "carPlay"
    case .vision:      return "vision"
    case .unspecified: return "unspecified"
    @unknown default:  return "unspecified"
    }
}

// MARK: - Offline bundle import
// Same file as the class so the importer can reach the private cache stores.

extension A8CInstance {

    @discardableResult
    func importOfflineBundle(at url: URL) async throws -> App8Cloud.OfflineImportSummary {
        try OfflineBundleImporter.importBundle(
            directory: url,
            instanceAppId: appId,
            maxSupportedDslVersion: maxSupportedDslVersion,
            diskCache: diskCache,
            assetCache: assetCache,
            fontRegistry: fontRegistry,
            diagnostics: log
        )
    }

    @discardableResult
    func importBundledPackages() async -> [App8Cloud.OfflineImportSummary] {
        var summaries: [App8Cloud.OfflineImportSummary] = []
        for url in App8Cloud.discoverOfflinePackages(appId: appId) {
            do {
                summaries.append(try await importOfflineBundle(at: url))
            } catch {
                log.warning("importBundledPackages: skipped '\(url.lastPathComponent)': \(error)")
            }
        }
        return summaries
    }
}
