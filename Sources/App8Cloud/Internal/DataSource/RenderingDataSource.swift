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
        var localizations: Data?
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

    /// In-memory cache of flow-scoped member screen bytes, keyed by
    /// `flowKey/screenKey@version`. Kept separate from `state.screensByCacheKey`
    /// so flow screens never leak into the public single-screen channel.
    private let flowScreenState = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])

    @MainActor private weak var _bridge: RenderingBridge?

    /// Weak to avoid a retain cycle — the engine strong-holds this data
    /// source. Bound after `A8CInstance` constructs the engine.
    @MainActor private weak var engine: App8.Instance?

    /// Bound by `A8CInstance` after construction. The store is thread-safe
    /// (internal `OSAllocatedUnfairLock`) and outlives this data source —
    /// safe to hold strongly. Used by `fetchPublishedScreens` (network
    /// refresh sink) and `applyScreenResponse` (opportunistic seeding).
    private let catalogRef = OSAllocatedUnfairLock<ScreenCatalogStore?>(initialState: nil)

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

    func bind(catalog: ScreenCatalogStore) {
        catalogRef.withLock { $0 = catalog }
    }

    private func currentCatalog() -> ScreenCatalogStore? {
        catalogRef.withLock { $0 }
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
                s.localizations = nil
            }
            assetState.withLock { s in
                s.manifest = nil
                s.fontsPrepared = false
                s.inFlightFontPrep?.cancel()
                s.inFlightFontPrep = nil
            }
            flowScreenState.withLock { $0 = [:] }
        case .screen(let id):
            let prefix = "\(id)@"
            state.withLock { s in
                s.screensByCacheKey = s.screensByCacheKey.filter { !$0.key.hasPrefix(prefix) }
                s.allScreenIds.removeAll { $0 == id }
            }
            // Flow members are keyed `flowKey/screenKey@version`; drop any whose
            // screenKey matches so a flow re-render refetches this screen too.
            flowScreenState.withLock {
                $0 = $0.filter { !$0.key.contains("/\(id)@") }
            }
        case .assetsOnly:
            // No-op: only the blob cache is wiped (via AssetCache.reset());
            // the in-memory manifest's URLs stay valid.
            break
        }
    }

    /// Drop the in-memory flow-screen cache. Called on flow teardown — the
    /// session is over, so member bytes kept for back-navigation are no longer
    /// needed. Bounds growth to a single active flow session.
    func clearFlowScreenCache() {
        flowScreenState.withLock { $0 = [:] }
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

    /// App-level `transitions` registry from the app manifest, as raw JSON
    /// object blobs. Fallback for the flow channel: until a published flow
    /// carries its own pinned transitions, the flow's synthetic manifest borrows
    /// the app-level set so named transitions keep resolving. Returns `[]` when
    /// the manifest has no transitions or can't be parsed.
    func appManifestTransitions() async -> [Data] {
        guard let blob = try? await getApp(),
              let obj = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let arr = obj["transitions"] as? [[String: Any]]
        else { return [] }
        return arr.compactMap { try? JSONSerialization.data(withJSONObject: $0, options: []) }
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
        log.debug("[Asset] MISS key='\(key)' (id=\(assetId ?? "nil") name=\(assetName ?? "nil")) — fetching")
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
        log.debug("[Asset] fetched key='\(key)' (\(data.count) bytes) in \(ms)ms")
        return data
    }

    func getAllScreenIds() async throws -> [String]? {
        // Catalog is the authoritative listing when the backend has shipped
        // `/apps/{id}/screens` — covers the case where the engine asks for
        // enumeration before any render has run (e.g. diagnostics, BFS).
        if let catalogSnapshot = currentCatalog()?.publicSnapshot(),
           catalogSnapshot.backendSupportsEnumeration,
           !catalogSnapshot.screenIds.isEmpty
        {
            return catalogSnapshot.screenIds
        }
        let ids = state.withLock { $0.allScreenIds }
        if !ids.isEmpty { return ids }
        let disk = cache?.enumerateScreenIds() ?? []
        return disk.isEmpty ? nil : disk
    }

    // Streaming unsupported — engine falls back to request/response fetches.
    func streamScreen(screenId: String) -> AsyncStream<Data>? { nil }
    func streamDatasource(screenId: String, datasourceId: String, componentPath: String?) -> AsyncStream<Data>? { nil }
    func streamStyles() -> AsyncStream<Data>? { nil }

    // MARK: - Flow channel (gated multi-screen bundles)

    /// Fetch a published flow's lazy manifest (entry screen + member list).
    func getFlowManifest(flowKey: String, version: String?) async throws -> FlowManifestResponse {
        // Network-first (keeps online flows fresh), with a disk fallback so a
        // seeded/imported bundle renders offline. `.offlineOnly` makes the
        // network call throw instantly, dropping straight to disk.
        let identity = await readIdentity()
        let endpoint = Endpoint.flow(appId: appId, flowKey: flowKey, version: version)
        let client = self.client
        do {
            let raw = try await coalescer.run(key: endpoint.coalesceKey) {
                let result = try await client.get(endpoint, identity: identity)
                return result.data
            }
            let decoded: FlowManifestResponse
            do {
                decoded = try JSONDecoder().decode(FlowManifestResponse.self, from: raw)
            } catch {
                throw App8Cloud.Error.decodeFailed(context: "FlowManifestResponse", underlying: error)
            }
            cache?.writeFlowManifest(raw, flowKey: flowKey, version: version)
            return decoded
        } catch {
            if let disk = cache?.readFlowManifest(flowKey: flowKey, version: version),
               let decoded = try? JSONDecoder().decode(FlowManifestResponse.self, from: disk)
            {
                log.debug("getFlowManifest('\(flowKey)'): served from disk after network error: \(error)")
                return decoded
            }
            throw error
        }
    }

    /// Fetch a flow-scoped member screen's DSL bytes. These are reachable ONLY
    /// through the flow channel — never via `getScreen`. Cached in-memory keyed
    /// by `flowKey/screenKey@version` so back-navigation doesn't refetch.
    func getFlowScreenData(flowKey: String, screenKey: String, version: String?) async throws -> Data {
        let key = "\(flowKey)/\(screenKey)@\(version ?? "_latest")"
        if let hit = flowScreenState.withLock({ $0[key] }) { return hit }

        let identity = await readIdentity()
        let endpoint = Endpoint.flowScreen(appId: appId, flowKey: flowKey, screenKey: screenKey, version: version)
        let client = self.client
        do {
            let raw = try await coalescer.run(key: endpoint.coalesceKey) {
                let result = try await client.get(endpoint, identity: identity)
                return result.data
            }
            let response: ScreenRenderResponse
            do {
                response = try JSONDecoder().decode(ScreenRenderResponse.self, from: raw)
            } catch {
                throw App8Cloud.Error.decodeFailed(context: "FlowScreenRenderResponse", underlying: error)
            }
            flowScreenState.withLock { $0[key] = response.data }
            cache?.writeFlowScreen(response.data, flowKey: flowKey, version: version, screenKey: screenKey)
            return response.data
        } catch {
            if let disk = cache?.readFlowScreen(flowKey: flowKey, version: version, screenKey: screenKey) {
                flowScreenState.withLock { $0[key] = disk }
                log.debug("getFlowScreenData('\(flowKey)/\(screenKey)'): served from disk after network error: \(error)")
                return disk
            }
            throw error
        }
    }

    /// Fetch the flow's pinned styles (backend falls back to app-level latest
    /// when the flow pinned none). Not disk-cached: the flow engine loads these
    /// once at init, and the version pin already makes the bytes stable.
    func getFlowStyles(flowKey: String, version: String?) async throws -> [Data] {
        let identity = await readIdentity()
        let endpoint = Endpoint.flowStyles(appId: appId, flowKey: flowKey, version: version)
        let client = self.client
        do {
            let raw = try await coalescer.run(key: endpoint.coalesceKey) {
                let result = try await client.get(endpoint, identity: identity)
                return result.data
            }
            let items: [Data]
            do {
                items = try JSONDecoder().decode(StyleArrayResponse.self, from: raw).items
            } catch {
                throw App8Cloud.Error.decodeFailed(context: "FlowStyleArrayResponse", underlying: error)
            }
            cache?.writeFlowStyles(items, flowKey: flowKey, version: version)
            return items
        } catch {
            if let disk = cache?.readFlowStyles(flowKey: flowKey, version: version) {
                log.debug("getFlowStyles('\(flowKey)'): served from disk after network error: \(error)")
                return disk
            }
            throw error
        }
    }

    /// Fetch the flow's pinned components (or app-level latest when none pinned).
    func getFlowComponents(flowKey: String, version: String?) async throws -> [Data] {
        let identity = await readIdentity()
        let endpoint = Endpoint.flowComponents(appId: appId, flowKey: flowKey, version: version)
        let client = self.client
        do {
            let raw = try await coalescer.run(key: endpoint.coalesceKey) {
                let result = try await client.get(endpoint, identity: identity)
                return result.data
            }
            let items: [Data]
            do {
                items = try JSONDecoder().decode(ComponentArrayResponse.self, from: raw).items
            } catch {
                throw App8Cloud.Error.decodeFailed(context: "FlowComponentArrayResponse", underlying: error)
            }
            cache?.writeFlowComponents(items, flowKey: flowKey, version: version)
            return items
        } catch {
            if let disk = cache?.readFlowComponents(flowKey: flowKey, version: version) {
                log.debug("getFlowComponents('\(flowKey)'): served from disk after network error: \(error)")
                return disk
            }
            throw error
        }
    }

    /// Register fonts for a screen using a host-supplied engine (e.g. a flow
    /// engine) rather than the bound app-level engine. Mirrors
    /// `ensureScreenFontsRegistered(id:)` but lets the flow path preload fonts
    /// for screens decoded by its own engine.
    @MainActor
    func ensureScreenFontsRegistered(id: String, using engine: App8.Instance) async {
        let refs: App8.AssetReferenceSet
        do {
            refs = try await engine.collectAssetReferences(screenId: id)
        } catch {
            log.warning("ensureScreenFontsRegistered(using:): collectAssetReferences failed for \(id): \(error)")
            return
        }
        let fontsToFetch = refs.fonts.filter { UIFont(name: $0.postScriptName, size: 1) == nil }
        if fontsToFetch.isEmpty { return }
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
    }

    /// Warm a screen's named image assets (poster, backgrounds, icons) into the
    /// asset cache using a host-supplied engine — so the entry screen paints
    /// complete instead of blank→pop (the "blink"). The flow's assets are
    /// `remoteAsset`-by-name (no direct URL), so `prefetchImages` can't warm
    /// them — they must go through `getAsset`. Skips `video/*` assets: they're
    /// large and stream behind their (now pre-warmed) poster, so blocking on
    /// them would just slow first paint. Mirrors `ensureScreenFontsRegistered`.
    @MainActor
    func ensureScreenImagesWarmed(id: String, using engine: App8.Instance) async {
        let refs: App8.AssetReferenceSet
        do {
            refs = try await engine.collectAssetReferences(screenId: id)
        } catch {
            log.warning("ensureScreenImagesWarmed(using:): collectAssetReferences failed for \(id): \(error)")
            return
        }
        guard !refs.images.isEmpty else { return }
        let manifest = try? await ensureAssetManifest()
        let toWarm = refs.images.filter { ref in
            guard let manifest, let entry = manifest.resolve(id: ref.id, name: ref.name) else {
                return true // unknown mime — warm it rather than risk a blink
            }
            return !(entry.mimeType?.hasPrefix("video/") ?? false)
        }
        guard !toWarm.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            let bound = 4
            var iter = toWarm.makeIterator()
            func enqueueNext() {
                guard let ref = iter.next() else { return }
                group.addTask { [weak self] in
                    _ = try? await self?.getAsset(assetId: ref.id, assetName: ref.name)
                }
            }
            for _ in 0..<min(bound, toWarm.count) { enqueueNext() }
            for await _ in group { enqueueNext() }
        }
    }

    /// Full all-locales payload for `TranslationStore`.
    func getTranslations() async throws -> Data {
        if let cached = state.withLock({ $0.localizations }) {
            return cached
        }
        if let cache, cache.hasUsableAppCache(),
           let disk = cache.readLocalizations()
        {
            state.withLock { $0.localizations = disk }
            return disk
        }
        let identity = await readIdentity()
        let endpoint = Endpoint.localizations(appId: appId)
        let client = self.client
        let raw = try await coalescer.run(key: endpoint.coalesceKey) {
            let result = try await client.get(endpoint, identity: identity)
            return result.data
        }
        state.withLock { $0.localizations = raw }
        if let cache {
            cache.writeLocalizations(raw)
            // Seed meta so the next prefetch can hash-compare instead of
            // re-fetching this as .noPriorCache.
            let existingUpdatedAt = cache.readAppResourceMeta(key: "localizations")?.updatedAt
            cache.updateAppResourceMeta(key: "localizations", meta: ResourceMeta(
                updatedAt: existingUpdatedAt,
                contentHash: ContentHash.sha256Hex(raw),
                fetchedAt: Date()
            ))
        }
        return raw
    }

    // MARK: - Prefetch (no engine render — just cache warming)

    enum PrefetchOutcome: Sendable, Equatable, CustomStringConvertible {
        case cachedFresh
        case unchanged
        case refreshed(reason: InvalidationReason)

        var description: String {
            switch self {
            case .cachedFresh:           return "cached"
            case .unchanged:             return "unchanged"
            case .refreshed(let reason): return "refreshed(\(reason.rawValue))"
            }
        }
    }

    enum InvalidationReason: String, Sendable {
        case versionChanged    = "version_changed"
        case updatedAtChanged  = "updated_at_changed"
        case contentChanged    = "content_changed"
        case noPriorCache      = "no_prior_cache"
    }

    func prefetchScreen(
        id: String,
        version: String?,
        expected: ScreenFreshness? = nil
    ) async throws -> PrefetchOutcome {
        let key = cacheKey(screenId: id, version: version)
        let stored = cache?.readScreenMeta(screenId: id)
        let storedBlob = cache?.readScreen(screenId: id, version: version)

        if let expected, let stored, let storedBlob,
           freshnessMatches(stored: stored, expected: expected)
        {
            state.withLock { $0.screensByCacheKey[key] = storedBlob }
            return .cachedFresh
        }

        // No-signal fallback: trust the cache when the backend doesn't
        // ship updatedAt, mirroring pre-feature warm-once semantics.
        if expected?.updatedAt == nil,
           let storedBlob,
           (expected?.version == nil || stored?.servedVersion == expected?.version)
        {
            state.withLock { $0.screensByCacheKey[key] = storedBlob }
            return .cachedFresh
        }

        // Wipe BEFORE fetching so a fetch failure leaves the screen uncached.
        let preCheckReason: InvalidationReason? = {
            if let expected, let stored {
                return mismatchReason(stored: stored, expected: expected)
            }
            if stored == nil { return .noPriorCache }
            return nil
        }()
        if let reason = preCheckReason, reason != .noPriorCache {
            cache?.clearScreen(id: id)
            state.withLock {
                $0.screensByCacheKey = $0.screensByCacheKey.filter { !$0.key.hasPrefix("\(id)@") }
            }
        }

        let response = try await fetchScreenResponse(screenId: id, version: version)
        let newHash = ContentHash.sha256Hex(response.data)
        // Skip the write only when the blob exists AND its hash matches.
        let canTrustStoredBlob = (preCheckReason == nil) && (storedBlob != nil)
        let priorHash = canTrustStoredBlob ? stored?.contentHash : nil
        let bytesChanged = (priorHash != newHash)

        applyScreenResponse(
            response,
            screenId: id,
            requestedVersion: version,
            expected: expected,
            existingMeta: stored,
            contentHash: newHash,
            skipDiskWrite: !bytesChanged
        )
        await reportServed(version: response.servedVersion, fromCache: false, screenId: id)

        if !bytesChanged {
            return .unchanged
        }
        return .refreshed(reason: preCheckReason ?? .contentChanged)
    }

    /// Matches only when `updatedAt` is present on both sides — without it
    /// we can't rule out an in-place change without fetching.
    private func freshnessMatches(stored: ScreenMeta, expected: ScreenFreshness) -> Bool {
        guard let expectedUpdated = expected.updatedAt,
              let storedUpdated = stored.updatedAt,
              expectedUpdated == storedUpdated
        else {
            return false
        }
        if let expectedVersion = expected.version,
           expectedVersion != stored.servedVersion
        {
            return false
        }
        return true
    }

    private func hydrateComponentsFromDiskIfCold(precomputed: [Data]? = nil) {
        guard state.withLock({ !$0.componentsLoaded }) else { return }
        let blobs = precomputed ?? cache?.readAllComponents() ?? []
        guard !blobs.isEmpty else { return }
        let byDslId: [String: Data] = blobs.reduce(into: [:]) { acc, blob in
            if let id = extractDslId(from: blob) { acc[id] = blob }
        }
        state.withLock { s in
            s.components = blobs
            s.componentsByDslId = byDslId
            s.componentsLoaded = true
        }
    }

    private func mismatchReason(stored: ScreenMeta, expected: ScreenFreshness) -> InvalidationReason? {
        if let expectedVersion = expected.version,
           let storedVersion = stored.servedVersion,
           expectedVersion != storedVersion
        {
            return .versionChanged
        }
        if let expectedUpdated = expected.updatedAt,
           let storedUpdated = stored.updatedAt,
           expectedUpdated != storedUpdated
        {
            return .updatedAtChanged
        }
        return nil
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
        log.debug("[Prefetch] screen='\(id)' refs: images=\(refs.images.count) fonts=\(refs.fonts.count)")
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
            }
            // Also warm an explicit URL whenever present — including alongside
            // an id/name. Many templates carry both: a literal `id` plus a
            // per-instance `url` resolved from a `{{var}}`. The render-time
            // path prefers the URL when given, so the manifest fetch by itself
            // can land in the disk cache but still miss the actual image bytes.
            if let url = ref.url, !url.isEmpty, seenUrls.insert(url).inserted {
                rawUrlsToFetch.append(url)
            }
        }
        let fontsToFetch: [App8.FontReference] = refs.fonts.filter { ref in
            UIFont(name: ref.postScriptName, size: 1) == nil
        }
        // Debug-level so render-time misses can be correlated to skipped prefetch entries.
        if !manifestImagesToFetch.isEmpty {
            let keys = manifestImagesToFetch.map { ($0.id ?? $0.name) ?? "?" }
            log.debug("[Prefetch] screen='\(id)' will fetch \(manifestImagesToFetch.count) image(s): \(keys)")
        }
        if !rawUrlsToFetch.isEmpty {
            log.debug("[Prefetch] screen='\(id)' will warm \(rawUrlsToFetch.count) raw URL(s): \(rawUrlsToFetch)")
        }
        if !fontsToFetch.isEmpty {
            let names = fontsToFetch.map(\.postScriptName)
            log.debug("[Prefetch] screen='\(id)' will register \(fontsToFetch.count) font(s): \(names)")
        }

        if manifestImagesToFetch.isEmpty && rawUrlsToFetch.isEmpty && fontsToFetch.isEmpty {
            log.debug("[Prefetch] screen='\(id)' — nothing to fetch (\(refs.images.count) images, \(refs.fonts.count) fonts already warm).")
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
        log.debug("prefetchScreenImages: screen=\(id) — warmed \(manifestImagesToFetch.count) image(s) + \(rawUrlsToFetch.count) raw URL(s) + \(fontsToFetch.count) font(s) in \(ms)ms.")
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
        log.debug("ensureScreenFontsRegistered: screen=\(id) — registered \(fontsToFetch.count) font(s) in \(ms)ms.")
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

    /// Render-time fetch on cache miss.
    private func fetchScreen(screenId: String, version: String?) async throws -> Data {
        let priorMeta = cache?.readScreenMeta(screenId: screenId)
        let response = try await fetchScreenResponse(screenId: screenId, version: version)
        let hash = ContentHash.sha256Hex(response.data)
        applyScreenResponse(
            response,
            screenId: screenId,
            requestedVersion: version,
            expected: nil,
            existingMeta: priorMeta,
            contentHash: hash,
            skipDiskWrite: false
        )
        await reportServed(version: response.servedVersion, fromCache: false, screenId: screenId)
        return response.data
    }

    private func fetchScreenResponse(screenId: String, version: String?) async throws -> ScreenRenderResponse {
        let identity = await readIdentity()
        let endpoint = Endpoint.screen(appId: appId, screenId: screenId, version: version)
        let client = self.client
        let raw = try await coalescer.run(key: endpoint.coalesceKey) {
            let result = try await client.get(endpoint, identity: identity)
            return result.data
        }
        do {
            return try JSONDecoder().decode(ScreenRenderResponse.self, from: raw)
        } catch {
            throw App8Cloud.Error.decodeFailed(context: "ScreenRenderResponse", underlying: error)
        }
    }

    private func applyScreenResponse(
        _ response: ScreenRenderResponse,
        screenId: String,
        requestedVersion: String?,
        expected: ScreenFreshness?,
        existingMeta: ScreenMeta? = nil,
        contentHash: String,
        skipDiskWrite: Bool
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

        currentCatalog()?.mergeSeen(id: screenId)
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
        if !skipDiskWrite {
            cache?.writeScreen(screenId: screenId, version: requestedVersion, data: body)
        }
        // Served-version alias for future explicit-pin reads. Rewritten if
        // pruning removed it on a prior session, even on skipDiskWrite.
        if let served = response.servedVersion,
           served != (requestedVersion ?? ""),
           cache?.readScreen(screenId: screenId, version: served) == nil
        {
            cache?.writeScreen(screenId: screenId, version: served, data: body)
        }
        // Render-time `fetchScreen` passes `expected: nil`; preserving the
        // prior `updatedAt` keeps the next prefetch's cheap-precheck working.
        let resolvedUpdatedAt = expected?.updatedAt ?? existingMeta?.updatedAt
        let meta = ScreenMeta(
            servedVersion: response.servedVersion,
            requestedVersion: requestedVersion,
            updatedAt: resolvedUpdatedAt,
            contentHash: contentHash
        )
        cache?.writeScreenMeta(meta, screenId: screenId)
    }

    // MARK: - Prefetch freshness checks for app-level resources

    /// Prefetch-only. Render-time path still uses `loadManifestIfNeeded`.
    func refreshManifestIfChanged(expectedUpdatedAt: String?) async throws -> PrefetchOutcome {
        let stored = cache?.readAppResourceMeta(key: "manifest")
        if let expectedUpdatedAt,
           let stored,
           stored.updatedAt == expectedUpdatedAt,
           cache?.readManifest() != nil
        {
            hydrateManifestFromDiskIfCold()
            return .cachedFresh
        }
        // No-signal fallback: trust the cache, capped by the max-age TTL
        // so silent backend updates surface within a day.
        if expectedUpdatedAt == nil,
           cache?.readManifest() != nil,
           isWithinNoSignalMaxAge(stored?.fetchedAt)
        {
            hydrateManifestFromDiskIfCold()
            return .cachedFresh
        }

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
        let newHash = ContentHash.sha256Hex(response.configuration)
        let priorHash = stored?.contentHash
        let bytesChanged = (priorHash != newHash)

        if bytesChanged {
            state.withLock { $0.manifest = response.configuration }
            cache?.writeManifest(response.configuration)
        } else {
            state.withLock { s in
                if s.manifest == nil { s.manifest = response.configuration }
            }
        }
        cache?.updateAppResourceMeta(key: "manifest", meta: ResourceMeta(
            updatedAt: expectedUpdatedAt ?? stored?.updatedAt,
            contentHash: newHash,
            fetchedAt: Date()
        ))

        if !bytesChanged { return .unchanged }
        return .refreshed(reason: priorHash == nil ? .noPriorCache : .contentChanged)
    }

    /// Cap on the no-signal cache-trust window — daily re-check catches
    /// silent backend updates against pre-feature backends.
    private static let noSignalMaxAge: TimeInterval = 24 * 60 * 60

    /// `nil` ⇒ legacy meta without `fetchedAt`; one-shot pass while it gets rewritten.
    private func isWithinNoSignalMaxAge(_ fetchedAt: Date?) -> Bool {
        guard let fetchedAt else { return true }
        return Date().timeIntervalSince(fetchedAt) < Self.noSignalMaxAge
    }

    private func hydrateManifestFromDiskIfCold() {
        guard let cache, let blob = cache.readManifest() else { return }
        state.withLock { s in
            if s.manifest == nil { s.manifest = blob }
        }
    }

    func refreshStylesIfChanged(expectedUpdatedAt: String?) async throws -> PrefetchOutcome {
        let stored = cache?.readAppResourceMeta(key: "styles")
        if let expectedUpdatedAt,
           let stored,
           stored.updatedAt == expectedUpdatedAt,
           cache?.readStylesBlob() != nil
        {
            hydrateStylesFromDiskIfCold()
            return .cachedFresh
        }
        if expectedUpdatedAt == nil,
           cache?.readStylesBlob() != nil,
           isWithinNoSignalMaxAge(stored?.fetchedAt)
        {
            hydrateStylesFromDiskIfCold()
            return .cachedFresh
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
        let newHash = ContentHash.sha256Hex(raw)
        let priorHash = stored?.contentHash
        let bytesChanged = (priorHash != newHash)

        if bytesChanged {
            state.withLock { s in
                s.styles = styles.items
                s.stylesLoaded = true
            }
            cache?.writeStyles(styles.items)
        } else {
            state.withLock { s in
                if !s.stylesLoaded {
                    s.styles = styles.items
                    s.stylesLoaded = true
                }
            }
        }
        cache?.updateAppResourceMeta(key: "styles", meta: ResourceMeta(
            updatedAt: expectedUpdatedAt ?? stored?.updatedAt,
            contentHash: newHash,
            fetchedAt: Date()
        ))

        if !bytesChanged { return .unchanged }
        return .refreshed(reason: priorHash == nil ? .noPriorCache : .contentChanged)
    }

    private func hydrateStylesFromDiskIfCold() {
        guard let cache, cache.readStylesBlob() != nil else { return }
        state.withLock { s in
            guard !s.stylesLoaded else { return }
            s.styles = cache.readStyles()
            s.stylesLoaded = true
        }
    }

    func refreshComponentsIfChanged(expectedUpdatedAt: String?) async throws -> PrefetchOutcome {
        let stored = cache?.readAppResourceMeta(key: "components")
        if let expectedUpdatedAt,
           let stored,
           stored.updatedAt == expectedUpdatedAt,
           let blobs = cache?.readAllComponents(), !blobs.isEmpty
        {
            hydrateComponentsFromDiskIfCold(precomputed: blobs)
            return .cachedFresh
        }
        if expectedUpdatedAt == nil,
           let blobs = cache?.readAllComponents(), !blobs.isEmpty,
           isWithinNoSignalMaxAge(stored?.fetchedAt)
        {
            hydrateComponentsFromDiskIfCold(precomputed: blobs)
            return .cachedFresh
        }

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
        let newHash = ContentHash.sha256Hex(raw)
        let priorHash = stored?.contentHash
        let bytesChanged = (priorHash != newHash)

        let byDslId: [String: Data] = components.items.reduce(into: [:]) { acc, blob in
            if let id = extractDslId(from: blob) {
                acc[id] = blob
            }
        }
        if bytesChanged {
            state.withLock { s in
                s.components = components.items
                s.componentsByDslId = byDslId
                s.componentsLoaded = true
            }
            cache?.writeComponents(components.items, idResolver: extractDslId)
        } else {
            state.withLock { s in
                if !s.componentsLoaded {
                    s.components = components.items
                    s.componentsByDslId = byDslId
                    s.componentsLoaded = true
                }
            }
        }
        cache?.updateAppResourceMeta(key: "components", meta: ResourceMeta(
            updatedAt: expectedUpdatedAt ?? stored?.updatedAt,
            contentHash: newHash,
            fetchedAt: Date()
        ))

        if !bytesChanged { return .unchanged }
        return .refreshed(reason: priorHash == nil ? .noPriorCache : .contentChanged)
    }

    func refreshLocalizationsIfChanged(expectedUpdatedAt: String?) async throws -> PrefetchOutcome {
        let stored = cache?.readAppResourceMeta(key: "localizations")
        if let expectedUpdatedAt,
           let stored,
           stored.updatedAt == expectedUpdatedAt,
           cache?.readLocalizations() != nil
        {
            hydrateLocalizationsFromDiskIfCold()
            return .cachedFresh
        }
        if expectedUpdatedAt == nil,
           cache?.readLocalizations() != nil,
           isWithinNoSignalMaxAge(stored?.fetchedAt)
        {
            hydrateLocalizationsFromDiskIfCold()
            return .cachedFresh
        }

        let identity = await readIdentity()
        let endpoint = Endpoint.localizations(appId: appId)
        let client = self.client
        let raw = try await coalescer.run(key: endpoint.coalesceKey) {
            let result = try await client.get(endpoint, identity: identity)
            return result.data
        }
        let newHash = ContentHash.sha256Hex(raw)
        let priorHash = stored?.contentHash
        let bytesChanged = (priorHash != newHash)

        if bytesChanged {
            state.withLock { $0.localizations = raw }
            cache?.writeLocalizations(raw)
        } else {
            state.withLock { s in
                if s.localizations == nil { s.localizations = raw }
            }
        }
        cache?.updateAppResourceMeta(key: "localizations", meta: ResourceMeta(
            updatedAt: expectedUpdatedAt ?? stored?.updatedAt,
            contentHash: newHash,
            fetchedAt: Date()
        ))

        if !bytesChanged { return .unchanged }
        return .refreshed(reason: priorHash == nil ? .noPriorCache : .contentChanged)
    }

    private func hydrateLocalizationsFromDiskIfCold() {
        guard let cache, let disk = cache.readLocalizations() else { return }
        state.withLock { s in
            if s.localizations == nil { s.localizations = disk }
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
        log.debug("prepareFontsIfNeeded: asset manifest cached in \(manifestMs)ms.")
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
        // Disk-first — engine BFS would otherwise trigger /components on every cold start.
        if let cache, cache.hasUsableAppCache() {
            let disk = cache.readAllComponents()
            if !disk.isEmpty {
                let byDslId: [String: Data] = disk.reduce(into: [:]) { acc, blob in
                    if let id = extractDslId(from: blob) { acc[id] = blob }
                }
                state.withLock { s in
                    s.components = disk
                    s.componentsByDslId = byDslId
                    s.componentsLoaded = true
                }
                return
            }
        }
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
        /// Filename without extension → entry. DSL `remoteAsset` references use a
        /// bare name (e.g. "IconMeteors"), while the manifest stores the full
        /// filename ("IconMeteors.png"), so an exact-filename match alone misses.
        let byBasename: [String: AssetEntry]
        let expiresAt: Date

        func resolve(id: String?, name: String?) -> AssetEntry? {
            if let id, let hit = byId[id] { return hit }
            if let name {
                // Exact filename first (when the DSL includes the extension),
                // then the extensionless basename used by `remoteAsset` refs.
                if let hit = byFilename[name] { return hit }
                if let hit = byBasename[name] { return hit }
            }
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
        // Disk hydrate — saves a /assets/manifest round trip on warm starts.
        if assetState.withLock({ $0.manifest == nil }),
           let cache,
           cache.hasUsableAppCache(),
           let diskBytes = cache.readAssetsManifest(),
           let persisted = try? jsonDecoder.decode(PersistedAssetsManifest.self, from: diskBytes)
        {
            let now = Date()
            let expiresAt = persisted.fetchedAt.addingTimeInterval(TimeInterval(persisted.expiresIn))
            // `fetchedAt <= now` guards against wall-clock rollback.
            if expiresAt > now, persisted.fetchedAt <= now {
                let entries = Self.entriesFromAssetItems(
                    persisted.assets.map { ($0.id, $0.filename, $0.mimeType, $0.downloadUrl) },
                    expiresAt: expiresAt
                )
                assetState.withLock { $0.manifest = entries }
                log.debug("ensureAssetManifest: hydrated from disk (\(persisted.assets.count) asset(s), expires \(expiresAt)).")
                return entries
            } else {
                log.debug("ensureAssetManifest: disk copy expired at \(expiresAt); re-fetching.")
            }
        }
        if let prior = assetState.withLock({ $0.manifest }) {
            log.debug("ensureAssetManifest: re-fetching — prior manifest expired at \(prior.expiresAt).")
        } else {
            log.debug("ensureAssetManifest: first fetch.")
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
        log.debug("ensureAssetManifest: backend returned \(decoded.assets.count) asset(s), expiresIn=\(decoded.expiresIn)s (using \(effectiveExpiresIn)s).")
        let now = Date()
        let manifest = Self.entriesFromAssetItems(
            decoded.assets.map { ($0.id, $0.filename, $0.mimeType, $0.downloadUrl) },
            expiresAt: now.addingTimeInterval(TimeInterval(effectiveExpiresIn))
        )
        assetState.withLock { $0.manifest = manifest }
        // Persist for next launch. Store the effective (floored) expiresIn
        // so a future read reflects the same policy this session enforced.
        let persisted = PersistedAssetsManifest(
            schemaVersion: CacheLayout.schemaVersion,
            fetchedAt: now,
            expiresIn: effectiveExpiresIn,
            assets: decoded.assets.map {
                PersistedAssetsManifest.AssetItem(
                    id: $0.id, filename: $0.filename,
                    mimeType: $0.mimeType, downloadUrl: $0.downloadUrl
                )
            }
        )
        if let data = try? jsonEncoder.encode(persisted) {
            cache?.writeAssetsManifest(data)
        }
        return manifest
    }

    private static func entriesFromAssetItems(
        _ items: [(id: String, filename: String, mimeType: String?, downloadUrl: String)],
        expiresAt: Date
    ) -> AssetManifestEntries {
        var byId: [String: AssetEntry] = [:]
        var byFilename: [String: AssetEntry] = [:]
        var byBasename: [String: AssetEntry] = [:]
        for item in items {
            let entry = AssetEntry(
                id: item.id,
                filename: item.filename,
                mimeType: item.mimeType,
                downloadUrl: item.downloadUrl
            )
            byId[item.id] = entry
            byFilename[item.filename] = entry
            // First-wins on basename collisions (e.g. icon.png vs icon.jpg) — a
            // bare-name DSL ref is ambiguous there anyway; exact-filename still wins.
            let basename = (item.filename as NSString).deletingPathExtension
            if !basename.isEmpty, byBasename[basename] == nil {
                byBasename[basename] = entry
            }
        }
        return AssetManifestEntries(byId: byId, byFilename: byFilename, byBasename: byBasename, expiresAt: expiresAt)
    }

    private struct PersistedAssetsManifest: Codable, Sendable {
        let schemaVersion: String
        let fetchedAt: Date
        let expiresIn: Int
        let assets: [AssetItem]

        struct AssetItem: Codable, Sendable {
            let id: String
            let filename: String
            let mimeType: String?
            let downloadUrl: String
        }
    }

    private var jsonEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private var jsonDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Published-screen discovery

    struct PublishedScreen: Sendable, Hashable {
        let screenKey: String
        let version: String
        let minDslVersion: String
        let updatedAt: String?
    }

    /// Per-resource `updatedAt` from the `/screens` list. Nil fields mean
    /// the backend didn't ship that timestamp — fall back to hash-compare.
    struct AppResourcesSnapshot: Sendable, Equatable {
        let manifest: String?
        let styles: String?
        let components: String?
        let localizations: String?
    }

    struct PublishedSnapshot: Sendable {
        let screens: [PublishedScreen]
        let resources: AppResourcesSnapshot?
    }

    /// nil = backend pre-dates the endpoint (404). Throws on transport/auth/decode failures.
    func fetchPublishedScreens() async throws -> PublishedSnapshot? {
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
            log.debug("[Prefetch] backend has no /apps/{id}/screens endpoint (404) — falling back to flow BFS only.")
            currentCatalog()?.markBackendUnsupported()
            return nil
        }
        let decoded: ListScreensResponse
        do {
            decoded = try JSONDecoder().decode(ListScreensResponse.self, from: raw)
        } catch {
            throw App8Cloud.Error.decodeFailed(context: "ListScreensResponse", underlying: error)
        }
        let screens = decoded.screens.map {
            PublishedScreen(
                screenKey: $0.screenKey,
                version: $0.version,
                minDslVersion: $0.minDslVersion,
                updatedAt: $0.updatedAt
            )
        }
        let resources = decoded.resources.map {
            AppResourcesSnapshot(
                manifest: $0.manifest?.updatedAt,
                styles: $0.styles?.updatedAt,
                components: $0.components?.updatedAt,
                localizations: $0.localizations?.updatedAt
            )
        }
        currentCatalog()?.replace(from: ScreenCatalogStore.NetworkSnapshot(
            screens: screens.map {
                ScreenCatalogStore.NetworkSnapshot.Screen(
                    screenKey: $0.screenKey,
                    version: $0.version,
                    minDslVersion: $0.minDslVersion,
                    updatedAt: $0.updatedAt
                )
            }
        ))
        return PublishedSnapshot(screens: screens, resources: resources)
    }

    private struct ListScreensResponse: Decodable {
        let screens: [ScreenItem]
        let resources: ResourcesBlock?

        struct ScreenItem: Decodable {
            let screenKey: String
            let version: String
            let minDslVersion: String
            let updatedAt: String?
        }

        struct ResourcesBlock: Decodable {
            let manifest: Freshness?
            let styles: Freshness?
            let components: Freshness?
            let localizations: Freshness?
        }

        struct Freshness: Decodable {
            let updatedAt: String
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
