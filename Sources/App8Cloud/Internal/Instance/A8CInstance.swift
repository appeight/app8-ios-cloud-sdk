import Foundation
import UIKit
import App8Engine

@MainActor
final class A8CInstance: App8Cloud.Instance, RenderingBridge {

    // MARK: - Public

    var onScreenRendered: ((App8Cloud.RenderEvent) -> Void)?
    var onFallbackInvoked: ((App8Cloud.FallbackEvent) -> Void)?

    // MARK: - Init params

    private let appId: String
    private let token: String
    private let environment: App8Cloud.Environment
    private let log: Diagnostics

    // MARK: - Stable infrastructure

    private let attributeBag: AttributeBag
    private let localeBag: LocaleBag
    private let httpClient: HTTPClient
    private let assetCache: AssetCache?
    private let diskCache: DiskCache?
    private let dataSource: RenderingDataSource
    private(set) var engine: App8.Instance
    private let telemetry: TelemetryClient?
    private let headers: HeaderBuilder
    private let fontRegistry: FontRegistry
    private let maxSupportedDslVersion: String

    // MARK: - Per-screen pinned versions (partner-supplied at call time)

    private var pinnedVersions: [String: String] = [:]
    private var lastServedVersions: [String: String?] = [:]
    private var lastServedFromCache: [String: Bool] = [:]

    // MARK: - Init

    init(
        token: String,
        appId: String,
        environment: App8Cloud.Environment,
        diskCachePolicy: App8Cloud.DiskCachePolicy = .default,
        telemetryPolicy: App8Cloud.TelemetryPolicy = .enabled,
        diagnosticLoggingEnabled: Bool = false,
        maxSupportedDslVersion: String = "1.0",
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
        self.localeBag = LocaleBag(diagnostics: log)

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
        ds.bind(engine: self.engine)

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

    // MARK: - Locale (Instance protocol)

    func setLocale(_ locale: String?) {
        localeBag.setOverride(locale)
        // Push into the engine immediately so the next render — even one
        // already in flight — sees the new locale. The translation table
        // itself doesn't change; only the active-locale pointer flips.
        engine.setLocale(locale)
    }

    var currentLocale: String {
        localeBag.currentLocale()
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
            return vc
        } catch let cloudError as App8Cloud.Error {
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

    func stopApp() {
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

    // MARK: - Preload (Instance protocol)

    private var inFlightPrefetch: Task<PrefetchSummary, Never>?

    func prefetch(
        screens: [App8Cloud.PrefetchTarget],
        includingAssets: Bool
    ) async {
        inFlightPrefetch?.cancel()

        let log = self.log
        let ds = self.dataSource
        let started = Date()
        let screenCount = screens.count
        let task = Task.detached { [weak self] in
            guard self != nil else { return PrefetchSummary() }
            return await Self.runPrefetch(
                dataSource: ds,
                screens: screens,
                includingAssets: includingAssets,
                log: log
            )
        }
        inFlightPrefetch = task
        let summary = await task.value
        // Only clear if a later prefetch call hasn't already replaced it.
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
        let log = self.log
        let ds = self.dataSource
        let engine = self.engine
        let dslMax = self.maxSupportedDslVersion
        inFlightPrefetch?.cancel()

        let discoveryStarted = Date()

        // Sequential — `engine` is non-Sendable so async-let'ing trips strict-concurrency.
        var publishedTargets: [App8Cloud.PrefetchTarget] = []
        do {
            if let published = try await ds.fetchPublishedScreens() {
                var skipped = 0
                for p in published {
                    if Self.dslVersion(p.minDslVersion, isAtMost: dslMax) {
                        publishedTargets.append(App8Cloud.PrefetchTarget(id: p.screenKey, version: p.version))
                    } else {
                        skipped += 1
                    }
                }
                log.info("[Prefetch] backend lists \(published.count) published screen(s); kept \(publishedTargets.count), skipped \(skipped) above DSL max \(dslMax).")
            }
        } catch {
            log.warning("[Prefetch] /screens fetch failed: \(error). Falling back to flow BFS only.")
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

        let started = Date()
        let screenCount = targets.count
        let task = Task.detached { [weak self] in
            guard self != nil else { return PrefetchSummary() }
            return await Self.runPrefetch(
                dataSource: ds,
                screens: targets,
                includingAssets: includingAssets,
                log: log
            )
        }
        inFlightPrefetch = task
        let summary = await task.value
        // Only clear if a later prefetch call hasn't already replaced it.
        if inFlightPrefetch == task { inFlightPrefetch = nil }
        emitPrefetchTelemetry(
            scope: "all",
            screenCount: screenCount,
            summary: summary,
            includingAssets: includingAssets,
            started: started
        )
    }

    private func emitPrefetchTelemetry(
        scope: String,
        screenCount: Int,
        summary: PrefetchSummary,
        includingAssets: Bool,
        started: Date
    ) {
        guard let telemetry else { return }
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        let ctx: [String: Any] = [
            "scope": scope,
            "screenCount": screenCount,
            "successCount": summary.successCount,
            "failureCount": summary.failureCount,
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

    func cancelPrefetch() {
        inFlightPrefetch?.cancel()
        inFlightPrefetch = nil
    }

    /// `.numeric` so "1.10" > "1.2". Pre-release tags unsupported.
    private static func dslVersion(_ minRequired: String, isAtMost clientMax: String) -> Bool {
        let result = minRequired.compare(clientMax, options: .numeric)
        return result != .orderedDescending
    }

    struct PrefetchSummary: Sendable {
        var successCount: Int = 0
        var failureCount: Int = 0
        var cancelled: Bool = false
    }

    private static func runPrefetch(
        dataSource: RenderingDataSource,
        screens: [App8Cloud.PrefetchTarget],
        includingAssets: Bool,
        log: Diagnostics
    ) async -> PrefetchSummary {
        var summary = PrefetchSummary()
        do {
            let appStarted = Date()
            _ = try await dataSource.getApp()
            log.info("Prefetch: getApp \(Int(Date().timeIntervalSince(appStarted) * 1000))ms")

            let stylesStarted = Date()
            _ = try await dataSource.getStyles()
            log.info("Prefetch: getStyles \(Int(Date().timeIntervalSince(stylesStarted) * 1000))ms")

            let componentsStarted = Date()
            _ = try await dataSource.getComponents()
            log.info("Prefetch: getComponents \(Int(Date().timeIntervalSince(componentsStarted) * 1000))ms")

            // Localizations are fetched once per app launch and the engine
            // selects which locale to render against client-side via
            // TranslationStore + instance.setLocale(...). Warming here means
            // the first screen render doesn't pay an extra round-trip for
            // localized text resolution.
            let localizationsStarted = Date()
            _ = try await dataSource.getTranslations()
            log.info("Prefetch: getTranslations \(Int(Date().timeIntervalSince(localizationsStarted) * 1000))ms")
        } catch {
            log.warning("Prefetch: app-level warm failed: \(error)")
        }

        if includingAssets {
            let fontsStarted = Date()
            await dataSource.prepareFontsIfNeeded()
            log.info("Prefetch: prepareFonts \(Int(Date().timeIntervalSince(fontsStarted) * 1000))ms")
        }

        // Per-screen warm with bounded parallelism (4).
        guard !screens.isEmpty else { return summary }
        // Per-task outcome: .success, .failure, or .cancelled (excluded from counts).
        enum Outcome { case success, failure, cancelled }
        await withTaskGroup(of: Outcome.self) { group in
            let bound = 4
            var iterator = screens.makeIterator()

            func enqueueNext() {
                guard let target = iterator.next() else { return }
                group.addTask {
                    if Task.isCancelled { return .cancelled }
                    let screenStart = Date()
                    let dslStart = Date()
                    do {
                        try await dataSource.prefetchScreen(
                            id: target.id, version: target.version
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
                    log.info("[Prefetch] screen '\(target.id)' done — DSL \(dslMs)ms, assets \(assetsMs)ms, total \(totalMs)ms")
                    return .success
                }
            }

            for _ in 0..<min(bound, screens.count) { enqueueNext() }
            for await outcome in group {
                switch outcome {
                case .success: summary.successCount += 1
                case .failure: summary.failureCount += 1
                case .cancelled: summary.cancelled = true
                }
                if Task.isCancelled { break }
                enqueueNext()
            }
        }
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
