import Foundation
import os

/// In-memory + on-disk store of the published screen catalog
/// (`GET /apps/{id}/screens` response).
///
/// The cloud SDK consults this on every `screen(id:)` call to short-circuit
/// unknown screen IDs without a network round-trip. Backed by a single
/// `screens_catalog.json` file under the disk cache root and a
/// lock-protected in-memory mirror.
///
/// Not isolated to `@MainActor`: the engine calls
/// `RenderingDataSource.applyScreenResponse` from arbitrary actors, so the
/// store has to be reachable off the main thread. State is protected by
/// `OSAllocatedUnfairLock`, matching the pattern used by `RenderingDataSource`.
final class ScreenCatalogStore: @unchecked Sendable {

    /// Source of the current snapshot — surfaced to telemetry and to the
    /// public `backendSupportsEnumeration` flag.
    enum Source: String, Codable, Sendable {
        /// Came from `/apps/{id}/screens`.
        case network
        /// Loaded from disk on init.
        case disk
        /// Empty/partial catalog populated only from successful renders.
        /// Used when the backend doesn't expose the listing endpoint.
        case seededFromRender
    }

    /// Per-screen metadata. `version`/`minDslVersion` are nil for entries
    /// added via `mergeSeen` (we know the ID exists because we rendered it,
    /// but we never re-pull its catalog metadata that way). Network-sourced
    /// entries always carry both.
    struct Entry: Codable, Sendable, Equatable {
        let version: String?
        let minDslVersion: String?
        let updatedAt: String?
    }

    /// Persisted shape.
    private struct PersistedSnapshot: Codable {
        let schemaVersion: String
        let sdkVersion: String
        let appId: String
        let fetchedAt: Date
        let source: Source
        let backendSupportsEnumeration: Bool
        let screens: [String: Entry]
    }

    private struct State {
        var screens: [String: Entry] = [:]
        var fetchedAt: Date?
        var source: Source = .seededFromRender
        var backendSupportsEnumeration: Bool = false
        var loaded: Bool = false
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: .init())

    private let appId: String
    private let diskCache: DiskCache?
    private let ttl: TimeInterval
    private let log: Diagnostics

    init(
        appId: String,
        diskCache: DiskCache?,
        catalogTTL: TimeInterval,
        diagnostics: Diagnostics
    ) {
        self.appId = appId
        self.diskCache = diskCache
        self.ttl = max(0, catalogTTL)
        self.log = diagnostics
    }

    // MARK: - Loading

    /// Synchronously hydrate from disk if a valid snapshot is present.
    /// Cheap (single small JSON read); safe to call from `A8CInstance.init`.
    func loadFromDisk() {
        guard let diskCache, let data = diskCache.readScreensCatalog() else {
            return
        }
        guard let decoded = try? Self.decoder.decode(PersistedSnapshot.self, from: data) else {
            log.warning("ScreenCatalogStore: failed to decode \(CacheLayout.schemaVersion) catalog — ignoring.")
            return
        }
        guard decoded.schemaVersion == CacheLayout.schemaVersion else {
            log.info("ScreenCatalogStore: disk catalog schema '\(decoded.schemaVersion)' != current '\(CacheLayout.schemaVersion)' — discarding.")
            diskCache.clearScreensCatalog()
            return
        }
        guard decoded.appId == appId else {
            log.warning("ScreenCatalogStore: disk catalog appId '\(decoded.appId)' != current '\(self.appId)' — discarding.")
            diskCache.clearScreensCatalog()
            return
        }
        state.withLock { s in
            s.screens = decoded.screens
            s.fetchedAt = decoded.fetchedAt
            // Tag the in-memory copy as `.disk` so telemetry can distinguish
            // a freshly-served catalog from a previously-persisted one.
            s.source = .disk
            s.backendSupportsEnumeration = decoded.backendSupportsEnumeration
            s.loaded = true
        }
        log.debug("ScreenCatalogStore: hydrated \(decoded.screens.count) screen(s) from disk (fetchedAt=\(decoded.fetchedAt), backendSupportsEnumeration=\(decoded.backendSupportsEnumeration)).")
    }

    // MARK: - Mutation

    /// Replace the catalog with a network-fetched snapshot. Persists to disk.
    func replace(from snapshot: NetworkSnapshot) {
        let now = Date()
        let dict: [String: Entry] = snapshot.screens.reduce(into: [:]) { acc, s in
            acc[s.screenKey] = Entry(
                version: s.version,
                minDslVersion: s.minDslVersion,
                updatedAt: s.updatedAt
            )
        }
        let count = dict.count
        state.withLock { s in
            s.screens = dict
            s.fetchedAt = now
            s.source = .network
            s.backendSupportsEnumeration = true
            s.loaded = true
        }
        persist(source: .network, backendSupportsEnumeration: true, fetchedAt: now)
        log.info("ScreenCatalogStore: refreshed from network — \(count) screen(s).")
    }

    /// Record that the backend does NOT support the listing endpoint (404).
    /// Keeps any previously-seeded entries in place but marks the catalog
    /// as "loaded but enumeration-unsupported" so `availability(of:)`
    /// returns `.catalogNotLoaded` for IDs the host hasn't rendered yet
    /// (we have no authoritative negative set in this mode).
    func markBackendUnsupported() {
        let now = Date()
        state.withLock { s in
            s.fetchedAt = now
            s.source = .seededFromRender
            s.backendSupportsEnumeration = false
            s.loaded = true
        }
        persist(source: .seededFromRender, backendSupportsEnumeration: false, fetchedAt: now)
        log.info("ScreenCatalogStore: backend has no /screens endpoint — running in seed-from-render mode.")
    }

    /// Opportunistically add an ID after a successful render. Idempotent.
    /// Persists only when the catalog changes.
    func mergeSeen(id: String) {
        let changed: Bool = state.withLock { s in
            guard s.screens[id] == nil else { return false }
            s.screens[id] = Entry(version: nil, minDslVersion: nil, updatedAt: nil)
            // We don't bump fetchedAt here — that timestamp is the catalog's
            // freshness clock, not the seeding moment. Keeping it as-is
            // preserves the TTL semantics for the network-sourced portion.
            if s.fetchedAt == nil {
                s.fetchedAt = Date()
                s.source = .seededFromRender
                s.loaded = true
            }
            return true
        }
        guard changed else { return }
        let snapshot = state.withLock { s -> (Source, Bool, Date)? in
            guard let fetchedAt = s.fetchedAt else { return nil }
            return (s.source, s.backendSupportsEnumeration, fetchedAt)
        }
        if let snapshot {
            persist(
                source: snapshot.0,
                backendSupportsEnumeration: snapshot.1,
                fetchedAt: snapshot.2
            )
        }
    }

    /// Remove an entry after the screen endpoint returned 404 despite the
    /// catalog claiming the screen existed. Persists immediately so the
    /// stale entry doesn't survive process restart.
    func markStaleIfBackendSays404(id: String) {
        let changed: Bool = state.withLock { s in
            guard s.screens.removeValue(forKey: id) != nil else { return false }
            return true
        }
        guard changed else { return }
        let snap = state.withLock { s -> (Source, Bool, Date)? in
            guard let fetchedAt = s.fetchedAt else { return nil }
            return (s.source, s.backendSupportsEnumeration, fetchedAt)
        }
        if let snap {
            persist(
                source: snap.0,
                backendSupportsEnumeration: snap.1,
                fetchedAt: snap.2
            )
        }
        log.info("ScreenCatalogStore: dropped stale entry '\(id)' after backend 404.")
    }

    /// Drop the in-memory catalog state. Called by `clearCache(.all)` after
    /// the disk file has already been wiped via `DiskCache.clearAll()`.
    /// Does not touch the disk (no-op on disk side — the directory is gone).
    func resetForCacheClear() {
        state.withLock { s in
            s.screens = [:]
            s.fetchedAt = nil
            s.source = .seededFromRender
            s.backendSupportsEnumeration = false
            s.loaded = false
        }
    }

    // MARK: - Reads

    /// Public snapshot, or nil if the catalog has never been loaded.
    func publicSnapshot() -> App8Cloud.ScreenCatalog? {
        state.withLock { s in
            guard s.loaded, let fetchedAt = s.fetchedAt else { return nil }
            return App8Cloud.ScreenCatalog(
                screenIds: s.screens.keys.sorted(),
                fetchedAt: fetchedAt,
                backendSupportsEnumeration: s.backendSupportsEnumeration
            )
        }
    }

    /// Tri-state check used by `screen(id:)` and `availability(of:)`.
    ///
    /// `now` is taken once at the call site to keep the lock window tight.
    func availability(of id: String, now: Date = Date()) -> Decision {
        state.withLock { s in
            guard s.loaded, let fetchedAt = s.fetchedAt else {
                return .catalogNotLoaded
            }
            let entry = s.screens[id]
            let isFresh = ttl > 0 && now.timeIntervalSince(fetchedAt) <= ttl
            // Without a network-sourced catalog (`backendSupportsEnumeration`
            // false), absence is uninformative — we only have positives from
            // opportunistic seeding. Surface `.catalogNotLoaded` for unknown
            // IDs so `screen(id:)` falls through to the network instead of
            // short-circuiting on a partial catalog.
            if entry == nil {
                if s.backendSupportsEnumeration && isFresh {
                    return .unknownFresh
                } else if s.backendSupportsEnumeration {
                    return .unknownStale
                } else {
                    return .catalogNotLoaded
                }
            }
            // Asymmetric on purpose: TTL gates NEGATIVES (unknownFresh vs.
            // unknownStale) but NOT positives. A stale `.known` may be wrong
            // (screen just unpublished), and the render path corrects that
            // via `markStaleIfBackendSays404` after a 404 round-trip. A
            // stale `.unknown`, by contrast, is uncorrectable from host UI —
            // a hidden CTA is invisible. We prefer the false-positive
            // failure mode (CTA shows → tap → host fallback) over the
            // false-negative one (CTA hidden → user never sees the feature).
            return .known(entry: entry!, fetchedAt: fetchedAt, source: s.source)
        }
    }

    enum Decision: Sendable {
        case known(entry: Entry, fetchedAt: Date, source: Source)
        case unknownFresh
        case unknownStale
        case catalogNotLoaded
    }

    /// True if the catalog has been loaded at least once (from any source).
    var isLoaded: Bool {
        state.withLock { $0.loaded }
    }

    /// Catalog age in seconds since the most recent network/disk refresh.
    /// Nil if the catalog has never been loaded.
    func ageSeconds(now: Date = Date()) -> Int? {
        state.withLock { s in
            guard let fetchedAt = s.fetchedAt else { return nil }
            return Int(now.timeIntervalSince(fetchedAt) * 1000)
        }
    }

    /// Source of the current in-memory catalog. Used by telemetry.
    func currentSource() -> Source {
        state.withLock { $0.source }
    }

    /// Number of screen IDs currently in the catalog.
    func screenCount() -> Int {
        state.withLock { $0.screens.count }
    }

    // MARK: - Persistence helpers

    private func persist(
        source: Source,
        backendSupportsEnumeration: Bool,
        fetchedAt: Date
    ) {
        guard let diskCache else { return }
        let screens = state.withLock { $0.screens }
        let payload = PersistedSnapshot(
            schemaVersion: CacheLayout.schemaVersion,
            sdkVersion: SDKVersion.current,
            appId: appId,
            fetchedAt: fetchedAt,
            source: source,
            backendSupportsEnumeration: backendSupportsEnumeration,
            screens: screens
        )
        guard let data = try? Self.encoder.encode(payload) else {
            log.warning("ScreenCatalogStore: failed to encode catalog snapshot — skipping persist.")
            return
        }
        diskCache.writeScreensCatalog(data)
    }

    // MARK: - Codable adapters

    /// Lightweight, dependency-free shape that mirrors the network response
    /// the data source decodes from `/apps/{id}/screens`. Letting the store
    /// own this type keeps it independent of `RenderingDataSource` internals.
    struct NetworkSnapshot: Sendable {
        struct Screen: Sendable {
            let screenKey: String
            let version: String
            let minDslVersion: String
            let updatedAt: String?
        }
        let screens: [Screen]
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
