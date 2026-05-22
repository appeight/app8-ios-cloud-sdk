import Foundation
import UIKit
import os
import App8Engine

@MainActor
protocol RenderingBridge: AnyObject {
    var identityAttributes: [String: String] { get }

    func pinnedVersion(forScreen screenId: String) -> String?

    func recordServed(version: String?, fromCache: Bool, forScreen screenId: String)
}

final class RenderingDataSource: App8DataSource, @unchecked Sendable {

    let appId: String

    private let client: HTTPClient
    private let log: Diagnostics
    private let coalescer = InFlightCoalescer()

    /// In-memory cache mirrors disk cache for hot paths.
    private struct State: Sendable {
        var manifest: Data?
        var styles: [Data] = []
        /// Explicit "we've fetched styles" flag. Can't use
        /// `!styles.isEmpty` — apps with zero styles would re-fetch
        /// every render.
        var stylesLoaded = false
        var components: [Data] = []
        var componentsByDslId: [String: Data] = [:]
        /// Same rationale as `stylesLoaded`.
        var componentsLoaded = false
        var screensByCacheKey: [String: Data] = [:]
        var datasources: [String: Data] = [:]
        var allScreenIds: [String] = []
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: .init())

    private let cache: DiskCache?
    private let assetCache: AssetCache?
    private let fontRegistry: FontRegistry
    @MainActor private weak var telemetry: TelemetryClient?

    private struct AssetState: Sendable {
        var manifest: AssetManifestEntries?
        var fontsPrepared: Bool = false
        /// In-flight task driving the current font-prep run. Concurrent
        /// callers `await` this task instead of doing duplicate work.
        var inFlightFontPrep: Task<Void, Never>?
    }
    private let assetState = OSAllocatedUnfairLock<AssetState>(initialState: .init())

    @MainActor private weak var _bridge: RenderingBridge?

    /// Weak to avoid a retain cycle — the engine strong-holds this data
    /// source. Bound after `A8CInstance` constructs the engine.
    @MainActor private weak var engine: App8.Instance?

    init(
        appId: String,
        client: HTTPClient,
        cache: DiskCache?,
        assetCache: AssetCache?,
        fontRegistry: FontRegistry,
        diagnostics: Diagnostics
    ) {
        self.appId = appId
        self.client = client
        self.cache = cache
        self.assetCache = assetCache
        self.fontRegistry = fontRegistry
        self.log = diagnostics
    }

    @MainActor
    func bind(bridge: RenderingBridge) {
        _bridge = bridge
    }

    @MainActor
    func bind(engine: App8.Instance) {
        self.engine = engine
    }

    /// Weak — `A8CInstance` strong-holds `telemetry` for the SDK's lifetime.
    @MainActor
    func bind(telemetry: TelemetryClient?) {
        self.telemetry = telemetry
    }

    // MARK: - Cache reset

    func resetInMemoryState(scope: App8Cloud.CacheScope) {
        switch scope {
        case .all:
            state.withLock { s in
                s.manifest = nil
                s.styles = []
                s.stylesLoaded = false
                s.components = []
                s.componentsByDslId = [:]
                s.componentsLoaded = false
                s.screensByCacheKey = [:]
                s.datasources = [:]
                s.allScreenIds = []
            }
            assetState.withLock { s in
                s.manifest = nil
                s.fontsPrepared = false
                s.inFlightFontPrep?.cancel()
                s.inFlightFontPrep = nil
            }
        case .screen(let id):
            let prefix = "\(id)@"
            state.withLock { s in
                s.screensByCacheKey = s.screensByCacheKey.filter { !$0.key.hasPrefix(prefix) }
                s.allScreenIds.removeAll { $0 == id }
            }
        case .assetsOnly:
            // No-op: only the blob cache is wiped (via AssetCache.reset());
            // the in-memory manifest's URLs stay valid.
            break
        }
    }

    @MainActor
    private func currentBridge() -> RenderingBridge? { _bridge }

    // MARK: - App8DataSource

    func getApp() async throws -> Data {
        try await loadManifestIfNeeded()
        guard let blob = state.withLock({ $0.manifest }) else {
            throw App8Cloud.Error.decodeFailed(context: "getApp", underlying: NoBlobError())
        }
        return blob
    }

    func getStyles() async throws -> [Data] {
        try await loadStylesIfNeeded()
        return state.withLock { $0.styles }
    }

    func getComponents() async throws -> [Data] {
        try await loadComponentsIfNeeded()
        return state.withLock { $0.components }
    }

    func getScreen(screenId: String) async throws -> Data {
        let pinnedVersion = await readPinnedVersion(screenId: screenId)
        let key = cacheKey(screenId: screenId, version: pinnedVersion)

        if let hit = state.withLock({ $0.screensByCacheKey[key] }) {
            await reportServed(version: pinnedVersion, fromCache: true, screenId: screenId)
            return hit
        }
        if let blob = cache?.readScreen(screenId: screenId, version: pinnedVersion) {
            state.withLock { $0.screensByCacheKey[key] = blob }
            await reportServed(version: pinnedVersion, fromCache: true, screenId: screenId)
            return blob
        }
        return try await fetchScreen(screenId: screenId, version: pinnedVersion)
    }

    func getComponent(componentId: String) async throws -> Data {
        try await loadComponentsIfNeeded()
        if let hit = state.withLock({ $0.componentsByDslId[componentId] }) {
            return hit
        }
        if let blob = cache?.readComponent(componentId: componentId) {
            return blob
        }
        throw App8Cloud.Error.decodeFailed(
            context: "getComponent(\(componentId))",
            underlying: NoBlobError()
        )
    }

    func getDatasource(screenId: String, datasourceId: String) async throws -> Data {
        if let hit = state.withLock({ $0.datasources[datasourceId] }) {
            return hit
        }
        let parts = datasourceId.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2,
           let blob = cache?.readDatasource(category: parts[0], name: parts[1])
        {
            return blob
        }
        throw App8Cloud.Error.decodeFailed(
            context: "getDatasource(\(datasourceId))",
            underlying: NoBlobError()
        )
    }

    func getAsset(assetId: String?, assetName: String?) async throws -> Data? {
        let key = (assetId ?? assetName) ?? ""
        guard !key.isEmpty else { return nil }

        if let blob = assetCache?.read(key: key) {
            log.debug("[Asset] hit key='\(key)' (id=\(assetId ?? "nil") name=\(assetName ?? "nil"))")
            return blob
        }
        log.info("[Asset] MISS key='\(key)' (id=\(assetId ?? "nil") name=\(assetName ?? "nil")) — fetching")
        let started = Date()
        let manifest = try await ensureAssetManifest()
        guard let entry = manifest.resolve(id: assetId, name: assetName),
              let url = URL(string: entry.downloadUrl)
        else {
            log.warning("[Asset] not in manifest: id=\(assetId ?? "nil") name=\(assetName ?? "nil")")
            return nil
        }
        guard url.scheme?.lowercased() == "https" else {
            log.warning("[Asset] rejecting non-HTTPS download URL for key='\(key)'.")
            return nil
        }
        let entryId = entry.id
        let client = self.client
        let data: Data
        do {
            data = try await coalescer.run(key: "asset:\(entryId)") {
                let result = try await client.getRawURL(url)
                return result.data
            }
        } catch {
            await emitAssetFetchFailed(assetId: entryId, error: error)
            throw error
        }
        assetCache?.write(key: key, data: data)
        if entryId != key {
            assetCache?.write(key: entryId, data: data)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log.info("[Asset] fetched key='\(key)' (\(data.count) bytes) in \(ms)ms")
        return data
    }

    func getAllScreenIds() async throws -> [String]? {
        let ids = state.withLock { $0.allScreenIds }
        if !ids.isEmpty { return ids }
        let disk = cache?.enumerateScreenIds() ?? []
        return disk.isEmpty ? nil : disk
    }

    // Streaming unsupported — engine falls back to request/response fetches.
    func streamScreen(screenId: String) -> AsyncStream<Data>? { nil }
    func streamDatasource(screenId: String, datasourceId: String, componentPath: String?) -> AsyncStream<Data>? { nil }
    func streamStyles() -> AsyncStream<Data>? { nil }

    // MARK: - Prefetch (no engine render — just cache warming)

    func prefetchScreen(id: String, version: String?) async throws {
        let key = cacheKey(screenId: id, version: version)
        if state.withLock({ $0.screensByCacheKey[key] }) != nil {
            return
        }
        if let blob = cache?.readScreen(screenId: id, version: version) {
            state.withLock { $0.screensByCacheKey[key] = blob }
            return
        }
        _ = try await fetchScreen(screenId: id, version: version)
    }

    /// Prefetch images + fonts the screen references, skipping ones already cached/registered.
    @MainActor
    func prefetchScreenImages(id: String, version: String?) async {
        guard let engine = self.engine else {
            log.debug("prefetchScreenImages: engine not bound; skipping.")
            return
        }
        let refs: App8.AssetReferenceSet
        do {
            refs = try await engine.collectAssetReferences(screenId: id)
        } catch {
            log.warning("prefetchScreenImages: collectAssetReferences failed for \(id): \(error)")
            return
        }
        log.info("[Prefetch] screen='\(id)' refs: images=\(refs.images.count) fonts=\(refs.fonts.count)")
        // Two image-prefetch paths:
        //   1. Manifest-resolvable (id/name) — goes through `getAsset`, lands in
        //      our disk-backed AssetCache; engine looks it up at render time.
        //   2. Raw HTTPS URLs without id/name — warmed via URLSession.shared so
        //      the response lands in URLCache.shared, which the engine's
        //      ImageLoader URLSession (default config) consults transparently.
        var manifestImagesToFetch: [App8.AssetReference] = []
        var rawUrlsToFetch: [String] = []
        var seenUrls = Set<String>()
        for ref in refs.images {
            let id = (ref.id?.isEmpty == false) ? ref.id : nil
            let name = (ref.name?.isEmpty == false) ? ref.name : nil
            if id != nil || name != nil {
                let key = (id ?? name) ?? ""
                if assetCache?.read(key: key) == nil {
                    manifestImagesToFetch.append(ref)
                }
                continue
            }
            // URL-only ref. Defer the HTTPS check to `prefetchRawURL` so http
            // URLs surface a warning there.
            if let url = ref.url, !url.isEmpty, seenUrls.insert(url).inserted {
                rawUrlsToFetch.append(url)
            }
        }
        let fontsToFetch: [App8.FontReference] = refs.fonts.filter { ref in
            UIFont(name: ref.postScriptName, size: 1) == nil
        }
        // Log so render-time misses can be correlated to skipped prefetch entries.
        if !manifestImagesToFetch.isEmpty {
            let keys = manifestImagesToFetch.map { ($0.id ?? $0.name) ?? "?" }
            log.info("[Prefetch] screen='\(id)' will fetch \(manifestImagesToFetch.count) image(s): \(keys)")
        }
        if !rawUrlsToFetch.isEmpty {
            log.info("[Prefetch] screen='\(id)' will warm \(rawUrlsToFetch.count) raw URL(s): \(rawUrlsToFetch)")
        }
        if !fontsToFetch.isEmpty {
            let names = fontsToFetch.map(\.postScriptName)
            log.info("[Prefetch] screen='\(id)' will register \(fontsToFetch.count) font(s): \(names)")
        }

        if manifestImagesToFetch.isEmpty && rawUrlsToFetch.isEmpty && fontsToFetch.isEmpty {
            log.info("[Prefetch] screen='\(id)' — nothing to fetch (\(refs.images.count) images, \(refs.fonts.count) fonts already warm).")
            return
        }

        let started = Date()
        await withTaskGroup(of: Void.self) { group in
            let bound = 4
            // Interleave images, raw URLs, and fonts behind a single bounded
            // pool — they share the network and CPU budget anyway.
            var imageIter = manifestImagesToFetch.makeIterator()
            var urlIter = rawUrlsToFetch.makeIterator()
            var fontIter = fontsToFetch.makeIterator()
            let log = self.log

            func enqueueNext() {
                if let imgRef = imageIter.next() {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            _ = try await self.getAsset(assetId: imgRef.id, assetName: imgRef.name)
                        } catch {
                            log.warning("prefetchScreenImages: getAsset failed for id=\(imgRef.id ?? "nil") name=\(imgRef.name ?? "nil"): \(error)")
                        }
                    }
                } else if let urlString = urlIter.next() {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.prefetchRawURL(urlString)
                    }
                } else if let fontRef = fontIter.next() {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.downloadAndRegisterFont(fontRef)
                    }
                }
            }
            let totalWork = manifestImagesToFetch.count + rawUrlsToFetch.count + fontsToFetch.count
            let initial = min(bound, totalWork)
            for _ in 0..<initial { enqueueNext() }
            for await _ in group { enqueueNext() }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let skippedImages = refs.images.count - manifestImagesToFetch.count - rawUrlsToFetch.count
        log.info("prefetchScreenImages: screen=\(id) — warmed \(manifestImagesToFetch.count) manifest image(s) + \(rawUrlsToFetch.count) raw URL(s) + \(fontsToFetch.count) font(s) in \(ms)ms (skipped \(skippedImages) cached images, \(refs.fonts.count - fontsToFetch.count) registered fonts).")
    }

    /// Warm `URLCache.shared` so the engine's `ImageLoader` (built from
    /// `URLSessionConfiguration.default`) serves the render-time fetch from
    /// cache. Depends on the origin sending usable `Cache-Control` /
    /// `Expires` — common CDNs do. Coalesced so concurrent prefetches for
    /// the same URL share one in-flight request.
    private func prefetchRawURL(_ urlString: String) async {
        guard let url = URL(string: urlString) else {
            log.warning("[Prefetch] raw-URL skipped — invalid URL: '\(urlString)'")
            return
        }
        guard url.scheme?.lowercased() == "https" else {
            log.warning("[Prefetch] raw-URL skipped — non-HTTPS: '\(urlString)'")
            return
        }
        let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy)
        do {
            _ = try await coalescer.run(key: "rawurl:\(urlString)") {
                let (data, _) = try await URLSession.shared.data(for: request)
                return data
            }
        } catch {
            log.warning("[Prefetch] raw-URL fetch failed: \(urlString) — \(error)")
        }
    }

    /// Register fonts before render (prevents fallback). Idempotent.
    @MainActor
    func ensureScreenFontsRegistered(id: String) async {
        guard let engine = self.engine else {
            log.debug("ensureScreenFontsRegistered: engine not bound; skipping.")
            return
        }
        let refs: App8.AssetReferenceSet
        do {
            refs = try await engine.collectAssetReferences(screenId: id)
        } catch {
            log.warning("ensureScreenFontsRegistered: collectAssetReferences failed for \(id): \(error)")
            return
        }
        let fontsToFetch = refs.fonts.filter { UIFont(name: $0.postScriptName, size: 1) == nil }
        if fontsToFetch.isEmpty { return }

        let started = Date()
        await withTaskGroup(of: Void.self) { group in
            let bound = 4
            var iter = fontsToFetch.makeIterator()
            func enqueueNext() {
                guard let fontRef = iter.next() else { return }
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.downloadAndRegisterFont(fontRef)
                }
            }
            for _ in 0..<min(bound, fontsToFetch.count) { enqueueNext() }
            for await _ in group { enqueueNext() }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log.info("ensureScreenFontsRegistered: screen=\(id) — registered \(fontsToFetch.count) font(s) in \(ms)ms.")
    }

    /// Engine asset hint preferred; falls back to PostScript-name → filename match.
    private func downloadAndRegisterFont(_ ref: App8.FontReference) async {
        let assetId: String?
        let assetName: String?
        if let hint = ref.asset {
            assetId = hint.id
            assetName = hint.name
        } else {
            guard let manifest = try? await ensureAssetManifest() else { return }
            let psName = ref.postScriptName
            let hit = manifest.byFilename.first { (filename, _) in
                let base = (filename as NSString).deletingPathExtension
                return base == psName
            }
            assetId = hit?.value.id
            assetName = hit?.key
        }
        // Engine's `UIFont(name:)` doesn't auto-pick up an `AssetCache` write — register explicitly.
        do {
            guard let data = try await getAsset(assetId: assetId, assetName: assetName) else {
                log.warning("downloadAndRegisterFont: asset not found for \(ref.postScriptName).")
                return
            }
            let registerId = assetId ?? assetName ?? ref.postScriptName
            fontRegistry.register(data: data, assetId: registerId, filename: assetName ?? ref.postScriptName)
        } catch {
            log.warning("downloadAndRegisterFont: getAsset failed for \(ref.postScriptName): \(error)")
        }
    }

    // MARK: - Internals

    @MainActor
    private func readIdentity() -> [String: String] {
        currentBridge()?.identityAttributes ?? [:]
    }

    @MainActor
    private func readPinnedVersion(screenId: String) -> String? {
        currentBridge()?.pinnedVersion(forScreen: screenId)
    }

    @MainActor
    private func reportServed(version: String?, fromCache: Bool, screenId: String) {
        currentBridge()?.recordServed(version: version, fromCache: fromCache, forScreen: screenId)
    }

    @MainActor
    private func emitAssetFetchFailed(assetId: String, error: Swift.Error) {
        // Cancellation isn't a failure; don't inflate failure counts with it.
        if error is CancellationError { return }
        guard let telemetry else { return }
        var ctx: [String: Any] = ["assetId": assetId]
        // `HTTPClient.sendWithRetry` maps URLError → App8Cloud.Error, so the
        // `unknown` branch should be unreachable in practice.
        if let cloudError = error as? App8Cloud.Error {
            ctx["reason"] = telemetryReasonString(cloudError)
            if case let .serverError(status, _) = cloudError {
                ctx["status"] = status
            }
        } else {
            ctx["reason"] = "unknown"
        }
        telemetry.enqueue(.init(
            type: "asset_fetch_failed",
            occurredAt: Date(),
            screenKey: nil,
            context: ctx
        ))
    }

    private func cacheKey(screenId: String, version: String?) -> String {
        "\(screenId)@\(version ?? CacheLayout.latestVersionSentinel)"
    }

    private func fetchScreen(screenId: String, version: String?) async throws -> Data {
        let identity = await readIdentity()
        let endpoint = Endpoint.screen(appId: appId, screenId: screenId, version: version)
        let client = self.client
        let raw = try await coalescer.run(key: endpoint.coalesceKey) {
            let result = try await client.get(endpoint, identity: identity)
            return result.data
        }
        let response: ScreenRenderResponse
        do {
            response = try JSONDecoder().decode(ScreenRenderResponse.self, from: raw)
        } catch {
            throw App8Cloud.Error.decodeFailed(context: "ScreenRenderResponse", underlying: error)
        }
        applyScreenResponse(response, screenId: screenId, requestedVersion: version)
        await reportServed(version: response.servedVersion, fromCache: false, screenId: screenId)
        return response.data
    }

    private func applyScreenResponse(
        _ response: ScreenRenderResponse,
        screenId: String,
        requestedVersion: String?
    ) {
        let body = response.data
        let key = cacheKey(screenId: screenId, version: requestedVersion)

        let snapshot = state.withLock { s in
            (s.styles, s.components, s.componentsByDslId)
        }
        var nextStyles = snapshot.0
        var nextComponents = snapshot.1
        var nextComponentsByDslId = snapshot.2
        if let styles = response.styles {
            nextStyles = mergeBlobs(nextStyles, with: styles)
        }
        if let components = response.components {
            for blob in components {
                if let id = extractDslId(from: blob) {
                    nextComponentsByDslId[id] = blob
                }
            }
            nextComponents = mergeBlobs(nextComponents, with: components)
        }

        let finalStyles = nextStyles
        let finalComponents = nextComponents
        let finalComponentsByDslId = nextComponentsByDslId

        state.withLock { s in
            s.screensByCacheKey[key] = body
            if !s.allScreenIds.contains(screenId) {
                s.allScreenIds.append(screenId)
            }
            s.styles = finalStyles
            s.components = finalComponents
            s.componentsByDslId = finalComponentsByDslId
            // Mark loaders satisfied so the app-level fetches don't later
            // clobber the merged set (those endpoints REPLACE, not merge).
            // Assumes inline styles/components are the complete set —
            // revisit if backend ever ships per-screen subsets.
            if response.styles != nil {
                s.stylesLoaded = true
            }
            if response.components != nil {
                s.componentsLoaded = true
            }
            if let dss = response.datasources {
                for (path, blob) in dss { s.datasources[path] = blob }
            }
        }
        cache?.writeScreen(screenId: screenId, version: requestedVersion, data: body)
        // Persist under served-version too — future explicit pin hits cache.
        if let served = response.servedVersion, served != (requestedVersion ?? "") {
            cache?.writeScreen(screenId: screenId, version: served, data: body)
        }
    }

    private func loadManifestIfNeeded() async throws {
        let alreadyLoaded = state.withLock { $0.manifest != nil }
        if !alreadyLoaded {
            if let cache, cache.hasUsableAppCache(),
               let manifest = cache.readManifest()
            {
                state.withLock { $0.manifest = manifest }
            } else {
                let identity = await readIdentity()
                let endpoint = Endpoint.manifest(appId: appId)
                let client = self.client
                let raw = try await coalescer.run(key: endpoint.coalesceKey) {
                    let result = try await client.get(endpoint, identity: identity)
                    return result.data
                }
                let response: AppManifestResponse
                do {
                    response = try JSONDecoder().decode(AppManifestResponse.self, from: raw)
                } catch {
                    throw App8Cloud.Error.decodeFailed(context: "AppManifestResponse", underlying: error)
                }
                state.withLock { $0.manifest = response.configuration }
                cache?.writeManifest(response.configuration)
                cache?.touchMeta()
            }
        }
        await prepareFontsIfNeeded()
    }

    /// Idempotent, coalesces concurrent callers on the same Task.
    func prepareFontsIfNeeded() async {
        if assetState.withLock({ $0.fontsPrepared }) { return }

        // Hand out the Task under the lock; `await` OUTSIDE — would deadlock the unfair lock.
        let task: Task<Void, Never> = assetState.withLock { s in
            if let inFlight = s.inFlightFontPrep { return inFlight }
            let newTask: Task<Void, Never> = Task { [weak self] in
                guard let self else { return }
                await self.actuallyPrepareFonts()
            }
            s.inFlightFontPrep = newTask
            return newTask
        }
        await task.value
    }

    private func actuallyPrepareFonts() async {
        defer {
            assetState.withLock {
                $0.fontsPrepared = true
                $0.inFlightFontPrep = nil
            }
        }
        let manifestStarted = Date()
        do {
            _ = try await ensureAssetManifest()
        } catch {
            log.warning("prepareFontsIfNeeded: asset manifest fetch failed (\(error)) — skipping font registration.")
            return
        }
        let manifestMs = Int(Date().timeIntervalSince(manifestStarted) * 1000)
        log.info("prepareFontsIfNeeded: asset manifest cached in \(manifestMs)ms — per-screen font registration is now driven by the engine's collectAssetReferences API.")
        // Per-screen prefetch via `prefetchScreenImages` is the only path that
        // downloads + registers fonts now — don't eagerly walk the manifest.
    }

    private func loadStylesIfNeeded() async throws {
        // Engine hits styles before manifest, so prepare fonts here too.
        await prepareFontsIfNeeded()

        if state.withLock({ $0.stylesLoaded }) { return }
        // File presence (even empty array) means we've fetched before.
        if let cache, cache.readStylesBlob() != nil {
            let disk = cache.readStyles()
            state.withLock {
                $0.styles = disk
                $0.stylesLoaded = true
            }
            return
        }
        let identity = await readIdentity()
        let endpoint = Endpoint.styles(appId: appId)
        let client = self.client
        let raw = try await coalescer.run(key: endpoint.coalesceKey) {
            let result = try await client.get(endpoint, identity: identity)
            return result.data
        }
        let styles: StyleArrayResponse
        do {
            styles = try JSONDecoder().decode(StyleArrayResponse.self, from: raw)
        } catch {
            throw App8Cloud.Error.decodeFailed(context: "StyleArrayResponse", underlying: error)
        }
        state.withLock {
            $0.styles = styles.items
            $0.stylesLoaded = true
        }
        cache?.writeStyles(styles.items)
    }

    private func loadComponentsIfNeeded() async throws {
        if state.withLock({ $0.componentsLoaded }) { return }
        let identity = await readIdentity()
        let endpoint = Endpoint.components(appId: appId)
        let client = self.client
        let raw = try await coalescer.run(key: endpoint.coalesceKey) {
            let result = try await client.get(endpoint, identity: identity)
            return result.data
        }
        let components: ComponentArrayResponse
        do {
            components = try JSONDecoder().decode(ComponentArrayResponse.self, from: raw)
        } catch {
            throw App8Cloud.Error.decodeFailed(context: "ComponentArrayResponse", underlying: error)
        }
        let byDslId: [String: Data] = components.items.reduce(into: [:]) { acc, blob in
            if let id = extractDslId(from: blob) {
                acc[id] = blob
            }
        }
        state.withLock { s in
            s.components = components.items
            s.componentsByDslId = byDslId
            s.componentsLoaded = true
        }
        cache?.writeComponents(components.items, idResolver: extractDslId)
    }

    private func extractDslId(from blob: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: blob) as? [String: Any] else {
            return nil
        }
        return json["id"] as? String
    }

    private func mergeBlobs(_ existing: [Data], with new: [Data]) -> [Data] {
        var seen = Set(existing.map { $0 })
        var result = existing
        for blob in new where !seen.contains(blob) {
            result.append(blob)
            seen.insert(blob)
        }
        return result
    }

    // MARK: - Asset manifest

    private struct AssetManifestEntries: Sendable {
        let byId: [String: AssetEntry]
        let byFilename: [String: AssetEntry]
        let expiresAt: Date

        func resolve(id: String?, name: String?) -> AssetEntry? {
            if let id, let hit = byId[id] { return hit }
            if let name, let hit = byFilename[name] { return hit }
            return nil
        }

        var isExpired: Bool { Date() >= expiresAt }
    }

    private struct AssetEntry: Sendable {
        let id: String
        let filename: String
        let mimeType: String?
        let downloadUrl: String
    }

    private func ensureAssetManifest() async throws -> AssetManifestEntries {
        if let manifest = assetState.withLock({ $0.manifest }), !manifest.isExpired {
            return manifest
        }
        if let prior = assetState.withLock({ $0.manifest }) {
            log.info("ensureAssetManifest: re-fetching — prior manifest expired at \(prior.expiresAt).")
        } else {
            log.info("ensureAssetManifest: first fetch.")
        }
        let identity = await readIdentity()
        let endpoint = Endpoint.assetsManifest(appId: appId)
        let client = self.client
        let raw = try await coalescer.run(key: endpoint.coalesceKey) {
            let result = try await client.get(endpoint, identity: identity)
            return result.data
        }
        let decoded: AssetsResponse
        do {
            decoded = try JSONDecoder().decode(AssetsResponse.self, from: raw)
        } catch {
            throw App8Cloud.Error.decodeFailed(context: "AssetsResponse", underlying: error)
        }
        // Floor at 60s — misconfigured backends sending 0 would refetch on every lookup.
        let effectiveExpiresIn = max(decoded.expiresIn, 60)
        if effectiveExpiresIn != decoded.expiresIn {
            log.warning("ensureAssetManifest: backend expiresIn=\(decoded.expiresIn)s is too low; flooring to \(effectiveExpiresIn)s for in-memory cache.")
        }
        log.info("ensureAssetManifest: backend returned \(decoded.assets.count) asset(s), expiresIn=\(decoded.expiresIn)s (using \(effectiveExpiresIn)s).")
        var byId: [String: AssetEntry] = [:]
        var byFilename: [String: AssetEntry] = [:]
        for asset in decoded.assets {
            let entry = AssetEntry(
                id: asset.id,
                filename: asset.filename,
                mimeType: asset.mimeType,
                downloadUrl: asset.downloadUrl
            )
            byId[asset.id] = entry
            byFilename[asset.filename] = entry
        }
        let manifest = AssetManifestEntries(
            byId: byId,
            byFilename: byFilename,
            expiresAt: Date().addingTimeInterval(TimeInterval(effectiveExpiresIn))
        )
        assetState.withLock { $0.manifest = manifest }
        return manifest
    }

    // MARK: - Published-screen discovery

    struct PublishedScreen: Sendable, Hashable {
        let screenKey: String
        let version: String
        let minDslVersion: String
    }

    /// nil = backend pre-dates the endpoint (404). Throws on transport/auth/decode failures.
    func fetchPublishedScreens() async throws -> [PublishedScreen]? {
        let identity = await readIdentity()
        let endpoint = Endpoint.listScreens(appId: appId)
        let client = self.client
        let raw: Data
        do {
            raw = try await coalescer.run(key: endpoint.coalesceKey) {
                let result = try await client.get(endpoint, identity: identity)
                return result.data
            }
        } catch App8Cloud.Error.serverError(let status, _) where status == 404 {
            log.info("[Prefetch] backend has no /apps/{id}/screens endpoint (404) — falling back to flow BFS only.")
            return nil
        }
        let decoded: ListScreensResponse
        do {
            decoded = try JSONDecoder().decode(ListScreensResponse.self, from: raw)
        } catch {
            throw App8Cloud.Error.decodeFailed(context: "ListScreensResponse", underlying: error)
        }
        return decoded.screens.map {
            PublishedScreen(
                screenKey: $0.screenKey,
                version: $0.version,
                minDslVersion: $0.minDslVersion
            )
        }
    }

    private struct ListScreensResponse: Decodable {
        let screens: [ScreenItem]

        struct ScreenItem: Decodable {
            let screenKey: String
            let version: String
            let minDslVersion: String
        }
    }

    private struct AssetsResponse: Decodable {
        let assets: [AssetItem]
        let expiresIn: Int

        struct AssetItem: Decodable {
            let id: String
            let filename: String
            let mimeType: String?
            let downloadUrl: String
        }
    }
}

private struct StyleArrayResponse: Decodable {
    let items: [Data]
    enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeRawJSONArrayIfPresent(forKey: .items) ?? []
    }
}

private struct ComponentArrayResponse: Decodable {
    let items: [Data]
    enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeRawJSONArrayIfPresent(forKey: .items) ?? []
    }
}

private struct NoBlobError: Swift.Error {}
