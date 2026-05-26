//
//  ScreenCatalogTests.swift
//  App8CloudTests
//
//  Covers the screen-availability catalog feature:
//   - `availability(of:)` tri-state synchronous API
//   - `screen(id:)` short-circuits unknown IDs without a network call
//   - Catalog persists to disk and survives Instance recreation
//   - Stale catalogs (older than TTL) fall through to the network
//   - Graceful degradation when backend doesn't expose `/screens`
//   - Opportunistic seeding from successful renders
//   - Skew correction: catalog drops entries that 404 from the screen endpoint
//

import XCTest
import UIKit
import App8Engine
@testable import App8Cloud

// MARK: - Nonisolated test fixtures
//
// Live at file scope (not nested in the `@MainActor` test class) so they
// can be referenced from `@Sendable` URL-protocol handler closures without
// hopping actors.

private enum Fixture {
    static let manifestJSON = #"""
    { "configuration": { "id": "test-app", "title": "Test", "initialScreenId": "home" } }
    """#
    static let stylesJSON = #"{"items":[]}"#
    static let componentsJSON = #"{"items":[]}"#
    static let localizationsJSON = #"{"defaultLocale":"en","locales":{}}"#
    static let homeScreenJSON = #"""
    { "servedVersion": "v1", "data": { "id": "home", "type": "view" } }
    """#

    /// `/screens` listing JSON with the supplied screen IDs.
    static func screensListJSON(
        _ screens: [(key: String, version: String, minDsl: String, updatedAt: String?)]
    ) -> String {
        let items = screens.map { s -> String in
            let updated = s.updatedAt.map { #", "updatedAt": "\#($0)""# } ?? ""
            return #"{"screenKey":"\#(s.key)","version":"\#(s.version)","minDslVersion":"\#(s.minDsl)"\#(updated)}"#
        }.joined(separator: ",")
        return #"{"screens":[\#(items)]}"#
    }

    static func ok(_ req: URLRequest, _ body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         body.data(using: .utf8)!)
    }

    static func notFound(_ req: URLRequest) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
         Data())
    }

    /// Standard mock handler: serves manifest/styles/components/localizations
    /// from the static JSON above, and the screen list from the supplied
    /// `screensList`. Falls back to 404 for everything else.
    static func standardHandler(
        screensList: String? = nil,
        homeBody: String = Fixture.homeScreenJSON,
        counter: Locked<[String: Int]>? = nil
    ) -> @Sendable (URLRequest) -> (HTTPURLResponse, Data) {
        return { req in
            let path = req.url!.path
            counter?.set((counter?.get() ?? [:]).merging([path: 1], uniquingKeysWith: +))
            let listPath = "/sdk/v1/apps/test-app/screens"
            if path == listPath {
                if let screensList {
                    return ok(req, screensList)
                }
                return notFound(req)
            }
            if path.hasSuffix("/manifest")           { return ok(req, manifestJSON) }
            if path.hasSuffix("/styles")             { return ok(req, stylesJSON) }
            if path.hasSuffix("/components")         { return ok(req, componentsJSON) }
            if path.hasSuffix("/localizations")      { return ok(req, localizationsJSON) }
            if path == "/sdk/v1/apps/test-app/screens/home" { return ok(req, homeBody) }
            return notFound(req)
        }
    }
}

@MainActor
final class ScreenCatalogTests: XCTestCase {

    private var tempRoots: [URL] = []

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        for url in tempRoots {
            try? FileManager.default.removeItem(at: url)
        }
        tempRoots.removeAll()
        super.tearDown()
    }

    // MARK: - Instance helpers

    /// Makes an in-memory instance with no disk cache. Use for tests that
    /// don't need persistence across instances.
    private func makeInstance(
        catalogTTL: TimeInterval = 24 * 60 * 60
    ) -> A8CInstance {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return A8CInstance(
            token: "app8_test_abc1234567",
            appId: "test-app",
            environment: .custom(URL(string: "https://test.app8.dev/sdk/v1")!),
            diskCachePolicy: .disabled,
            telemetryPolicy: .disabled,
            requestTimeoutSeconds: 2,
            urlSessionOverride: session
        )
    }

    /// Makes a disk-backed instance. Returns the instance and the cache root
    /// (so the test can construct a second instance pointing at the same dir).
    private func makeDiskBackedInstance(
        appId: String = "test-app",
        rootDirectory: URL? = nil,
        catalogTTL: TimeInterval = 24 * 60 * 60,
        telemetry: App8Cloud.TelemetryPolicy = .disabled
    ) -> (A8CInstance, URL) {
        let root = rootDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("App8CloudCatalogTests-\(UUID().uuidString)")
        if rootDirectory == nil {
            tempRoots.append(root)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let instance = A8CInstance(
            token: "app8_test_abc1234567",
            appId: appId,
            environment: .custom(URL(string: "https://test.app8.dev/sdk/v1")!),
            diskCachePolicy: .enabled(.init(rootDirectory: root, catalogTTL: catalogTTL)),
            telemetryPolicy: telemetry,
            requestTimeoutSeconds: 2,
            urlSessionOverride: session
        )
        return (instance, root)
    }

    // MARK: - 1. emptyOnFirstUse_shortCircuitDoesNotFire

    func testCatalog_emptyOnFirstUse_shortCircuitDoesNotFire() async {
        // Backend doesn't expose `/screens` (404). Without a catalog the SDK
        // must round-trip — `screen("nope")` hits `/screens/nope`, gets 404,
        // surfaces `.screenNotFound`. The catalog must NOT swallow the call.
        let counter = Locked<[String: Int]>([:])
        MockURLProtocol.requestHandler = Fixture.standardHandler(screensList: nil, counter: counter)

        let cloud = makeInstance()
        await cloud.awaitCatalogReady(timeout: 1.0)
        do {
            _ = try await cloud.screen(id: "nope", version: nil, parameters: [:])
            XCTFail("expected screenNotFound")
        } catch let err as App8Cloud.Error {
            guard case .screenNotFound = err else {
                XCTFail("expected screenNotFound, got \(err)")
                return
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        // The render path fetches `/screens/nope` twice on failure (once via
        // `ensureScreenFontsRegistered`, once via `engine.renderScreen`).
        // We only care that it *did* go to network — not the exact count.
        XCTAssertGreaterThanOrEqual(counter.get()["/sdk/v1/apps/test-app/screens/nope"] ?? 0, 1,
                                    "must round-trip to backend when no catalog is available")
    }

    // MARK: - 2. populatedFromPrefetchAll_shortCircuitsUnknownId

    func testCatalog_populatedFromPrefetchAll_shortCircuitsUnknownId() async {
        let counter = Locked<[String: Int]>([:])
        let list = Fixture.screensListJSON([("home", "v1", "1.0", "2026-01-01T00:00:00Z")])
        MockURLProtocol.requestHandler = Fixture.standardHandler(screensList: list, counter: counter)

        let cloud = makeInstance()
        await cloud.prefetchAll(includingAssets: false)
        XCTAssertEqual(cloud.availability(of: "home"), .known)
        XCTAssertEqual(cloud.availability(of: "nope"), .unknown)

        let beforeAttempt = counter.get()["/sdk/v1/apps/test-app/screens/nope"] ?? 0
        do {
            _ = try await cloud.screen(id: "nope", version: nil, parameters: [:])
            XCTFail("expected screenNotFound short-circuit")
        } catch let err as App8Cloud.Error {
            guard case .screenNotFound = err else {
                XCTFail("expected screenNotFound, got \(err)")
                return
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let afterAttempt = counter.get()["/sdk/v1/apps/test-app/screens/nope"] ?? 0
        XCTAssertEqual(beforeAttempt, afterAttempt,
                       "short-circuit must NOT hit the network for unknown IDs")
    }

    // MARK: - 3. fallbackVariantShortCircuitsImmediately

    func testCatalog_fallbackVariantShortCircuitsImmediately() async {
        let counter = Locked<[String: Int]>([:])
        let list = Fixture.screensListJSON([("home", "v1", "1.0", nil)])
        MockURLProtocol.requestHandler = Fixture.standardHandler(screensList: list, counter: counter)

        let cloud = makeInstance()
        await cloud.prefetchAll(includingAssets: false)

        let beforeAttempt = counter.get()["/sdk/v1/apps/test-app/screens/nope"] ?? 0
        let fallbackHit = Locked<App8Cloud.Error?>(nil)
        let vc = await cloud.screen(
            id: "nope",
            version: nil,
            parameters: [:],
            fallback: { error in
                fallbackHit.set(error)
                return UIViewController()
            }
        )
        XCTAssertNotNil(vc)
        if case .screenNotFound = fallbackHit.get() {
            // expected
        } else {
            XCTFail("fallback should receive screenNotFound, got \(String(describing: fallbackHit.get()))")
        }
        let afterAttempt = counter.get()["/sdk/v1/apps/test-app/screens/nope"] ?? 0
        XCTAssertEqual(beforeAttempt, afterAttempt,
                       "fallback variant must also short-circuit without network")
    }

    // MARK: - 4. persistsAcrossInstances

    func testCatalog_persistsAcrossInstances() async {
        let counter = Locked<[String: Int]>([:])
        let list = Fixture.screensListJSON([("home", "v1", "1.0", "2026-01-01T00:00:00Z")])
        MockURLProtocol.requestHandler = Fixture.standardHandler(screensList: list, counter: counter)

        let (cloudA, root) = makeDiskBackedInstance()
        await cloudA.prefetchAll(includingAssets: false)
        XCTAssertEqual(cloudA.availability(of: "home"), .known)

        // Drop the handler — instance B's background refresh should hit the
        // unset handler and fail, but the disk-loaded catalog stays valid.
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 0, httpVersion: nil, headerFields: nil)!, Data())
        }
        let (cloudB, _) = makeDiskBackedInstance(rootDirectory: root)
        // Disk hydrate is synchronous in init — assert immediately.
        XCTAssertEqual(cloudB.availability(of: "home"), .known)
        XCTAssertEqual(cloudB.availability(of: "nope"), .unknown,
                       "disk-loaded catalog must support short-circuit on unknown IDs")
    }

    // MARK: - 5. staleCatalogDoesNotShortCircuit

    func testCatalog_staleCatalogDoesNotShortCircuit() async {
        // TTL=0 means "always stale" — the catalog still answers
        // `availability(of:)` queries but `screen(id:)` falls through to
        // network so a just-published screen isn't masked. The TTL lives
        // on `DiskCacheConfig`, so this test needs a disk-backed instance.
        let counter = Locked<[String: Int]>([:])
        let list = Fixture.screensListJSON([("home", "v1", "1.0", nil)])
        MockURLProtocol.requestHandler = Fixture.standardHandler(screensList: list, counter: counter)

        let (cloud, _) = makeDiskBackedInstance(catalogTTL: 0)
        await cloud.prefetchAll(includingAssets: false)
        // `availability(of:)` collapses stale + unknown to `.catalogNotLoaded`
        // so hosts can't accidentally hide CTAs based on a stale negative.
        XCTAssertEqual(cloud.availability(of: "nope"), .catalogNotLoaded)

        let beforeAttempt = counter.get()["/sdk/v1/apps/test-app/screens/nope"] ?? 0
        do {
            _ = try await cloud.screen(id: "nope", version: nil, parameters: [:])
            XCTFail("expected screenNotFound from server")
        } catch let err as App8Cloud.Error {
            guard case .screenNotFound = err else {
                XCTFail("expected screenNotFound, got \(err)")
                return
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let afterAttempt = counter.get()["/sdk/v1/apps/test-app/screens/nope"] ?? 0
        XCTAssertGreaterThan(afterAttempt, beforeAttempt,
                             "stale catalog must fall through to network")
    }

    // MARK: - 6. backend404OnScreens_doesNotShortCircuit

    func testCatalog_backend404OnScreens_doesNotShortCircuit() async {
        // Backend lacks `/screens`. Catalog is `loaded=true` with
        // `backendSupportsEnumeration=false`. Unknown IDs must NOT
        // short-circuit because we only have positives from seeding.
        let counter = Locked<[String: Int]>([:])
        MockURLProtocol.requestHandler = Fixture.standardHandler(screensList: nil, counter: counter)

        let cloud = makeInstance()
        await cloud.awaitCatalogReady(timeout: 1.0)

        do {
            _ = try await cloud.screen(id: "nope", version: nil, parameters: [:])
            XCTFail("expected screenNotFound from network")
        } catch let err as App8Cloud.Error {
            guard case .screenNotFound = err else {
                XCTFail("expected screenNotFound, got \(err)")
                return
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertGreaterThanOrEqual(counter.get()["/sdk/v1/apps/test-app/screens/nope"] ?? 0, 1)
        XCTAssertNotNil(cloud.catalog, "catalog should be loaded (even if backend-unsupported)")
        XCTAssertFalse(cloud.catalog!.backendSupportsEnumeration)
    }

    // MARK: - 7. opportunisticSeedingAfterRender

    func testCatalog_opportunisticSeedingAfterRender() async {
        // Backend 404s `/screens`. After a successful render of `home`, the
        // catalog should contain `home` but NOT short-circuit unknown IDs.
        MockURLProtocol.requestHandler = Fixture.standardHandler(screensList: nil)

        let cloud = makeInstance()
        await cloud.awaitCatalogReady(timeout: 1.0)
        _ = try? await cloud.screen(id: "home", version: nil, parameters: [:])

        XCTAssertEqual(cloud.availability(of: "home"), .known,
                       "seeded from successful render")
        XCTAssertEqual(cloud.availability(of: "nope"), .catalogNotLoaded,
                       "seeded catalog can't speak to IDs we haven't seen")
    }

    // MARK: - 8. skewHandling_catalogStaleAfterServer404

    func testCatalog_skewHandling_catalogStaleAfterServer404() async {
        // Catalog claims `home` exists. Backend returns 404 for `/screens/home`
        // (e.g. screen was just unpublished). The error must surface AND the
        // catalog must drop the entry.
        let list = Fixture.screensListJSON([("home", "v1", "1.0", nil)])
        MockURLProtocol.requestHandler = { req in
            let path = req.url!.path
            if path == "/sdk/v1/apps/test-app/screens"  { return Fixture.ok(req, list) }
            if path.hasSuffix("/manifest")              { return Fixture.ok(req, Fixture.manifestJSON) }
            if path.hasSuffix("/styles")                { return Fixture.ok(req, Fixture.stylesJSON) }
            if path.hasSuffix("/components")            { return Fixture.ok(req, Fixture.componentsJSON) }
            if path.hasSuffix("/localizations")         { return Fixture.ok(req, Fixture.localizationsJSON) }
            return Fixture.notFound(req)  // /screens/home → 404
        }

        let cloud = makeInstance()
        await cloud.awaitCatalogReady(timeout: 1.0)
        XCTAssertEqual(cloud.availability(of: "home"), .known)

        do {
            _ = try await cloud.screen(id: "home", version: nil, parameters: [:])
            XCTFail("expected screenNotFound from server")
        } catch let err as App8Cloud.Error {
            guard case .screenNotFound = err else {
                XCTFail("expected screenNotFound, got \(err)")
                return
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(cloud.availability(of: "home"), .unknown,
                       "catalog must drop stale entry after server 404")
    }

    // MARK: - 9. versionPinBypassesShortCircuit

    func testCatalog_versionPinBypassesShortCircuit() async {
        // Catalog has `home` at v1. Host asks for `home` at v99. Short-circuit
        // must NOT fire on the (id, version) tuple — the server is the
        // authority on which versions of `home` are published.
        let counter = Locked<[String: Int]>([:])
        let list = Fixture.screensListJSON([("home", "v1", "1.0", nil)])
        MockURLProtocol.requestHandler = { req in
            let path = req.url!.path
            counter.set(counter.get().merging([path: 1], uniquingKeysWith: +))
            if path == "/sdk/v1/apps/test-app/screens"  { return Fixture.ok(req, list) }
            if path.hasSuffix("/manifest")              { return Fixture.ok(req, Fixture.manifestJSON) }
            if path.hasSuffix("/styles")                { return Fixture.ok(req, Fixture.stylesJSON) }
            if path.hasSuffix("/components")            { return Fixture.ok(req, Fixture.componentsJSON) }
            if path.hasSuffix("/localizations")         { return Fixture.ok(req, Fixture.localizationsJSON) }
            return Fixture.notFound(req)  // /screens/home?version=v99 → 404
        }

        let cloud = makeInstance()
        await cloud.awaitCatalogReady(timeout: 1.0)

        do {
            _ = try await cloud.screen(id: "home", version: "v99", parameters: [:])
            XCTFail("expected screenVersionNotFound from server")
        } catch let err as App8Cloud.Error {
            guard case .screenVersionNotFound = err else {
                XCTFail("expected screenVersionNotFound, got \(err)")
                return
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertGreaterThanOrEqual(counter.get()["/sdk/v1/apps/test-app/screens/home"] ?? 0, 1,
                                    "must round-trip for pinned version")
    }

    // MARK: - 10. dslVersionGate

    func testCatalog_dslVersionGate_unsupportedShortCircuitsToDslError() async {
        // Catalog says home requires minDsl 5.0; SDK supports 1.0. Throws
        // dslVersionUnsupported synchronously without touching the network.
        let counter = Locked<[String: Int]>([:])
        let list = Fixture.screensListJSON([("home", "v1", "5.0", nil)])
        MockURLProtocol.requestHandler = Fixture.standardHandler(screensList: list, counter: counter)

        let cloud = makeInstance()
        await cloud.awaitCatalogReady(timeout: 1.0)

        let beforeAttempt = counter.get()["/sdk/v1/apps/test-app/screens/home"] ?? 0
        do {
            _ = try await cloud.screen(id: "home", version: nil, parameters: [:])
            XCTFail("expected dslVersionUnsupported short-circuit")
        } catch let err as App8Cloud.Error {
            guard case .dslVersionUnsupported(let found, let max) = err else {
                XCTFail("expected dslVersionUnsupported, got \(err)")
                return
            }
            XCTAssertEqual(found, "5.0")
            XCTAssertEqual(max, "1.0")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let afterAttempt = counter.get()["/sdk/v1/apps/test-app/screens/home"] ?? 0
        XCTAssertEqual(beforeAttempt, afterAttempt,
                       "dsl-gate short-circuit must NOT hit the network")
    }

    // MARK: - 11. concurrentScreenCalls_singleRefresh

    func testCatalog_concurrentScreenCalls_singleRefresh() async {
        // Many concurrent first-time calls must collapse to ONE `/screens`
        // request via the InFlightCoalescer.
        let counter = Locked<[String: Int]>([:])
        let list = Fixture.screensListJSON([("home", "v1", "1.0", nil)])
        MockURLProtocol.requestHandler = Fixture.standardHandler(screensList: list, counter: counter)

        let cloud = makeInstance()
        // Don't await the init refresh — instead pile on parallel calls.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { await cloud.refreshCatalog() }
            }
            for await _ in group {}
        }
        XCTAssertLessThanOrEqual(counter.get()["/sdk/v1/apps/test-app/screens"] ?? 0, 2,
                                 "concurrent triggers should collapse via InFlightCoalescer (one init + one batch refresh max)")
    }

    // MARK: - 12. awaitCatalogReady

    func testCatalog_awaitCatalogReady_returnsBeforeTimeout() async {
        let list = Fixture.screensListJSON([("home", "v1", "1.0", nil)])
        MockURLProtocol.requestHandler = Fixture.standardHandler(screensList: list)

        let cloud = makeInstance()
        let snapshot = await cloud.awaitCatalogReady(timeout: 3.0)
        XCTAssertNotNil(snapshot)
        XCTAssertTrue(snapshot!.backendSupportsEnumeration)
        XCTAssertEqual(snapshot!.screenIds, ["home"])
    }

    func testCatalog_awaitCatalogReady_timesOut() async {
        // Block /screens forever; awaitCatalogReady must time out and return nil.
        let pending = expectation(description: "/screens received")
        pending.assertForOverFulfill = false
        MockURLProtocol.requestHandler = { req in
            if req.url!.path == "/sdk/v1/apps/test-app/screens" {
                pending.fulfill()
                // Sleep longer than the timeout via blocking the URL protocol's
                // thread. We can't await here, so use a busy-wait sentinel:
                Thread.sleep(forTimeInterval: 1.5)
                return Fixture.notFound(req)
            }
            return Fixture.notFound(req)
        }
        let cloud = makeInstance()
        let snapshot = await cloud.awaitCatalogReady(timeout: 0.3)
        XCTAssertNil(snapshot, "timeout must return nil")
        await fulfillment(of: [pending], timeout: 3.0)
    }

    // MARK: - 13. telemetry_emitsShortCircuitEvent

    func testCatalog_telemetry_emitsShortCircuitEvent() async {
        let list = Fixture.screensListJSON([("home", "v1", "1.0", nil)])
        MockURLProtocol.requestHandler = Fixture.standardHandler(screensList: list)

        let cloud = makeInstance()
        let received = Locked<[App8AnalyticsEvent]>([])
        let sub = cloud.observeAnalytics { event in
            received.set(received.get() + [event])
        }
        await cloud.awaitCatalogReady(timeout: 1.0)

        _ = try? await cloud.screen(id: "nope", version: nil, parameters: [:])

        let events = received.get()
        let shortCircuit = events.first { $0.name == App8AnalyticsEvent.Auto.screenShortcircuit }
        XCTAssertNotNil(shortCircuit, "short-circuit event must fire on the analytics bus")
        XCTAssertEqual(shortCircuit?.screenId, "nope")
        XCTAssertEqual(shortCircuit?.properties["reason"] as? String, "screen_not_found")
        XCTAssertEqual(shortCircuit?.properties["catalog_source"] as? String, "network")
        XCTAssertEqual(shortCircuit?.properties["catalog_screen_count"] as? Int, 1)
        // `app8.render.failed` should also fire — short-circuit doesn't
        // suppress the established render-lifecycle event.
        XCTAssertNotNil(events.first { $0.name == App8AnalyticsEvent.Auto.renderFailed })
        _ = sub  // keep subscription alive
    }

    // MARK: - 14. schemaVersionBump_wipesDiskCatalog

    func testCatalog_schemaVersionBump_wipesDiskCatalog() {
        // Write a malformed catalog (wrong schemaVersion) and verify init
        // discards it without crashing.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("App8CloudCatalogSchemaTests-\(UUID().uuidString)")
        tempRoots.append(root)
        let layout = CacheLayout(cacheRoot: root, appId: "test-app")
        try? FileManager.default.createDirectory(at: layout.rootForApp, withIntermediateDirectories: true)
        let stale = #"{"schemaVersion":"v0-future","sdkVersion":"x","appId":"test-app","fetchedAt":"2026-01-01T00:00:00Z","source":"disk","backendSupportsEnumeration":true,"screens":{}}"#
        try? stale.data(using: .utf8)!.write(to: layout.screensCatalogFile)

        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 0, httpVersion: nil, headerFields: nil)!, Data())
        }
        let (cloud, _) = makeDiskBackedInstance(rootDirectory: root)
        // After init the stale catalog must have been discarded — nil/empty
        // snapshot rather than a v0 ghost.
        let snap = cloud.catalog
        XCTAssertTrue(snap == nil || snap!.screenIds.isEmpty)
        // File should be gone (cleared on schema mismatch).
        XCTAssertNil(try? Data(contentsOf: layout.screensCatalogFile))
    }

    // MARK: - 15. clearCacheAll_wipesCatalog

    func testCatalog_clearCacheAll_wipesCatalog() async {
        let list = Fixture.screensListJSON([("home", "v1", "1.0", nil)])
        MockURLProtocol.requestHandler = Fixture.standardHandler(screensList: list)

        let (cloud, root) = makeDiskBackedInstance()
        await cloud.prefetchAll(includingAssets: false)
        XCTAssertEqual(cloud.availability(of: "home"), .known)
        let layout = CacheLayout(cacheRoot: root, appId: "test-app")
        XCTAssertNotNil(try? Data(contentsOf: layout.screensCatalogFile))

        // Stop the mock from responding to the post-clearCache refresh so we
        // can observe the in-memory reset cleanly.
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 0, httpVersion: nil, headerFields: nil)!, Data())
        }
        await cloud.clearCache(scope: .all)
        // In-memory mirror cleared immediately; refresh fires in background
        // but the failing mock keeps it unloaded.
        XCTAssertNil(cloud.catalog,
                     "in-memory catalog must be wiped after clearCache(.all)")
        XCTAssertNil(try? Data(contentsOf: layout.screensCatalogFile),
                     "on-disk catalog file must be removed by clearAll")
    }
}
