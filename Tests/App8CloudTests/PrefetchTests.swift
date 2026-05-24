//
//  PrefetchTests.swift
//  App8CloudTests
//
//  Covers v0.3.1 preload API.
//

import XCTest
import UIKit
@testable import App8Cloud

@MainActor
final class PrefetchTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /// Inject a `URLSession` with `MockURLProtocol` plumbed in — see
    /// `A8CInstanceFallbackTests` for the rationale.
    private func makeInstance() -> App8Cloud.Instance {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return A8CInstance(
            token: "app8_test_abc1234567",
            appId: "test-app",
            environment: .custom(URL(string: "https://test.app8.dev/sdk/v1")!),
            diskCachePolicy: .disabled,
            requestTimeoutSeconds: 2,
            urlSessionOverride: session
        )
    }

    private static let manifestResponse = #"""
    { "configuration": { "id": "test-app", "title": "Test", "initialScreenId": "home" } }
    """#

    /// Manifest with a navigation block declaring three flow entry-points.
    private static let manifestWithNavigation = #"""
    {
      "configuration": {
        "id": "test-app",
        "title": "Test",
        "navigation": {
          "startFlow": "main",
          "flows": [
            { "id": "main",       "startScreen": "home" },
            { "id": "onboarding", "startScreen": "welcome" },
            { "id": "settings",   "startScreen": "settings_root" }
          ]
        }
      }
    }
    """#
    private static let stylesResponse = #"{"items":[]}"#
    private static let componentsResponse = #"{"items":[]}"#
    private static let localizationsResponse = #"{"defaultLocale":"en","locales":{}}"#
    private static let screenResponse = #"""
    { "servedVersion": "v3", "data": { "id": "home", "type": "view" } }
    """#

    func testPrefetchWarmsAppLevelThenScreens() async {
        let counter = Locked<[String: Int]>([:])
        MockURLProtocol.requestHandler = { req in
            let path = req.url!.path
            counter.set(counter.get().merging([path: 1], uniquingKeysWith: +))
            let body: String
            if path.hasSuffix("/manifest")           { body = Self.manifestResponse }
            else if path.hasSuffix("/styles")        { body = Self.stylesResponse }
            else if path.hasSuffix("/components")    { body = Self.componentsResponse }
            else if path.hasSuffix("/localizations") { body = Self.localizationsResponse }
            else                                     { body = Self.screenResponse }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body.data(using: .utf8)!)
        }

        let cloud = makeInstance()
        await cloud.prefetch(
            screens: [
                .init(id: "home"),
                .init(id: "settings", version: "v2"),
            ],
            includingAssets: false
        )

        let counts = counter.get()
        XCTAssertEqual(counts["/sdk/v1/apps/test-app/manifest"], 1)
        XCTAssertEqual(counts["/sdk/v1/apps/test-app/styles"], 1)
        XCTAssertEqual(counts["/sdk/v1/apps/test-app/components"], 1)
        XCTAssertEqual(counts["/sdk/v1/apps/test-app/localizations"], 1,
            "prefetchAll must warm the localizations bundle so the first screen render doesn't pay an extra round-trip")
        XCTAssertEqual(counts["/sdk/v1/apps/test-app/screens/home"], 1)
        XCTAssertEqual(counts["/sdk/v1/apps/test-app/screens/settings"], 1)
    }

    func testPrefetchIsIdempotent() async {
        let counter = Locked<Int>(0)
        MockURLProtocol.requestHandler = { req in
            counter.set(counter.get() + 1)
            let path = req.url!.path
            let body: String
            if path.hasSuffix("/manifest")           { body = Self.manifestResponse }
            else if path.hasSuffix("/styles")        { body = Self.stylesResponse }
            else if path.hasSuffix("/components")    { body = Self.componentsResponse }
            else if path.hasSuffix("/localizations") { body = Self.localizationsResponse }
            else                                     { body = Self.screenResponse }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body.data(using: .utf8)!)
        }

        let cloud = makeInstance()
        await cloud.prefetch(screens: [.init(id: "home")], includingAssets: false)
        let after1 = counter.get()
        await cloud.prefetch(screens: [.init(id: "home")], includingAssets: false)
        let after2 = counter.get()

        XCTAssertEqual(after1, after2,
                       "Second prefetch with same targets must hit in-memory cache.")
    }

    func testPrefetchAllDiscoversFlowsFromManifest() async {
        let visited = Locked<Set<String>>([])
        MockURLProtocol.requestHandler = { req in
            let path = req.url!.path
            visited.set(visited.get().union([path]))
            let body: String
            if path.hasSuffix("/manifest")        { body = Self.manifestWithNavigation }
            else if path.hasSuffix("/styles")     { body = Self.stylesResponse }
            else if path.hasSuffix("/components") { body = Self.componentsResponse }
            else                                  { body = Self.screenResponse }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body.data(using: .utf8)!)
        }

        let cloud = makeInstance()
        await cloud.prefetch()      // parameterless convenience → prefetchAll(includingAssets: true)

        // All three flow entry-points should have been fetched.
        let paths = visited.get()
        XCTAssertTrue(paths.contains("/sdk/v1/apps/test-app/screens/home"),
                      "home (main flow) should be prefetched")
        XCTAssertTrue(paths.contains("/sdk/v1/apps/test-app/screens/welcome"),
                      "welcome (onboarding flow) should be prefetched")
        XCTAssertTrue(paths.contains("/sdk/v1/apps/test-app/screens/settings_root"),
                      "settings_root (settings flow) should be prefetched")
    }

    func testPrefetchAllNoNavigationBlockJustWarmsAppLevel() async {
        let visited = Locked<Set<String>>([])
        MockURLProtocol.requestHandler = { req in
            let path = req.url!.path
            visited.set(visited.get().union([path]))
            let body: String
            if path.hasSuffix("/manifest")        { body = Self.manifestResponse }    // no navigation
            else if path.hasSuffix("/styles")     { body = Self.stylesResponse }
            else if path.hasSuffix("/components") { body = Self.componentsResponse }
            else                                  { body = Self.screenResponse }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body.data(using: .utf8)!)
        }

        let cloud = makeInstance()
        await cloud.prefetch()

        let paths = visited.get()
        XCTAssertTrue(paths.contains("/sdk/v1/apps/test-app/manifest"))
        XCTAssertFalse(paths.contains { $0.contains("/screens/") },
                       "No flow entry-points discovered → no per-screen fetches")
    }

    func testPrefetchSurvivesPerScreenFailure() async {
        MockURLProtocol.requestHandler = { req in
            let path = req.url!.path
            // Return 200 for everything except /screens/broken — that 500s.
            if path.hasSuffix("/screens/broken") {
                return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        Data())
            }
            let body: String
            if path.hasSuffix("/manifest")           { body = Self.manifestResponse }
            else if path.hasSuffix("/styles")        { body = Self.stylesResponse }
            else if path.hasSuffix("/components")    { body = Self.componentsResponse }
            else if path.hasSuffix("/localizations") { body = Self.localizationsResponse }
            else                                     { body = Self.screenResponse }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body.data(using: .utf8)!)
        }

        let cloud = makeInstance()
        // Should NOT throw — partial failures swallow.
        await cloud.prefetch(
            screens: [.init(id: "home"), .init(id: "broken"), .init(id: "settings")],
            includingAssets: false
        )
        // No assertion needed beyond "didn't throw / didn't hang".
    }
}
