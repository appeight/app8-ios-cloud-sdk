//
//  DatasourceReloadTests.swift
//  App8CloudTests
//
//  The DSL `reloadDatasource` action asks the data source for fresh bytes:
//  `getDatasource` keeps serving the cached render-response copy, while
//  `reloadDatasource` refetches the screen that carries the datasource.
//

import XCTest
@testable import App8Cloud

@MainActor
final class DatasourceReloadTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeDataSource() -> RenderingDataSource {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = HTTPClient(
            baseURL: URL(string: "https://test.app8.dev/sdk/v1")!,
            headers: HeaderBuilder(token: "app8_test_abc1234567", sdkVersion: "0.6.0", maxSupportedDslVersion: "1.0"),
            timeout: 2,
            diagnostics: .disabled,
            sessionOverride: URLSession(configuration: config)
        )
        return RenderingDataSource(
            appId: "test-app",
            client: client,
            cache: nil,
            assetCache: nil,
            fontRegistry: FontRegistry(diagnostics: .disabled),
            diagnostics: .disabled
        )
    }

    /// Serves `/screens/home` with a datasource whose id grows per request.
    private func serveHome(_ counter: Locked<Int>, status: @escaping @Sendable () -> Int = { 200 }) {
        MockURLProtocol.requestHandler = { req in
            let code = status()
            guard code == 200, req.url!.path.hasSuffix("/screens/home") else {
                return (HTTPURLResponse(url: req.url!, statusCode: code == 200 ? 404 : code, httpVersion: nil, headerFields: nil)!, Data())
            }
            counter.set(counter.get() + 1)
            let n = counter.get()
            let body = #"""
            { "servedVersion": "1", "data": { "id": "home", "type": "screen", "content": {} },
              "datasources": { "datasources/items": { "data": [ { "id": "v\#(n)" } ] } } }
            """#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    private func itemId(_ data: Data) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((object?["data"] as? [[String: Any]])?.first)?["id"] as? String
    }

    func testReloadFetchesFreshBytesWhileGetServesTheCache() async throws {
        let counter = Locked<Int>(0)
        serveHome(counter)
        let ds = makeDataSource()
        _ = try await ds.getScreen(screenId: "home")

        let cached = try await ds.getDatasource(screenId: "home", datasourceId: "datasources/items")
        XCTAssertEqual(try itemId(cached), "v1")
        XCTAssertEqual(counter.get(), 1, "getDatasource serves the render response's copy")

        let fresh = try await ds.reloadDatasource(screenId: "home", datasourceId: "datasources/items")
        XCTAssertEqual(try itemId(fresh), "v2")
        XCTAssertEqual(counter.get(), 2)

        let after = try await ds.getDatasource(screenId: "home", datasourceId: "datasources/items")
        XCTAssertEqual(try itemId(after), "v2", "the reload refreshes the cache too")
    }

    func testAppScopeReloadUsesTheScreenThatCarriedTheDatasource() async throws {
        let counter = Locked<Int>(0)
        serveHome(counter)
        let ds = makeDataSource()
        _ = try await ds.getScreen(screenId: "home")

        // App variables reload with an empty screenId.
        let fresh = try await ds.reloadDatasource(screenId: "", datasourceId: "datasources/items")
        XCTAssertEqual(try itemId(fresh), "v2")
    }

    func testReloadFailsInsteadOfServingStaleData() async throws {
        let counter = Locked<Int>(0)
        let failing = Locked<Bool>(false)
        serveHome(counter, status: { failing.get() ? 500 : 200 })
        let ds = makeDataSource()
        _ = try await ds.getScreen(screenId: "home")

        failing.set(true)
        do {
            _ = try await ds.reloadDatasource(screenId: "home", datasourceId: "datasources/items")
            XCTFail("a failed fetch must throw so the action's onError runs")
        } catch {}

        do {
            _ = try await ds.reloadDatasource(screenId: "", datasourceId: "datasources/unknown")
            XCTFail("no screen carries this datasource")
        } catch {}
    }
}
