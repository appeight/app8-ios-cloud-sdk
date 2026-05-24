import XCTest
@testable import App8Cloud

final class LocalizationsEndpointTests: XCTestCase {

    // MARK: - Endpoint shape

    func test_localizationsEndpointPathMatchesBackendRoute() {
        let endpoint = Endpoint.localizations(appId: "ABC123")
        XCTAssertEqual(endpoint.path, "/apps/ABC123/localizations")
    }

    func test_localizationsEndpointIsGet() {
        let endpoint = Endpoint.localizations(appId: "ABC123")
        XCTAssertEqual(endpoint.method, "GET")
    }

    func test_localizationsEndpointHasNoQueryItems() {
        let endpoint = Endpoint.localizations(appId: "ABC123")
        XCTAssertTrue(endpoint.queryItems.isEmpty)
    }

    func test_localizationsCoalesceKeyIsAppScoped() {
        // appId scope prevents a second instance piggybacking on the first instance's fetch.
        let a = Endpoint.localizations(appId: "app-1")
        let b = Endpoint.localizations(appId: "app-2")
        XCTAssertNotEqual(a.coalesceKey, b.coalesceKey)
        XCTAssertEqual(a.coalesceKey, "localizations:app-1")
    }

    func test_resolveBuildsAbsoluteURL() {
        let base = URL(string: "https://app8.example.com/sdk/v1")!
        let url = Endpoint.localizations(appId: "ABC123").resolve(against: base)
        XCTAssertEqual(url.absoluteString, "https://app8.example.com/sdk/v1/apps/ABC123/localizations")
    }

    // MARK: - Headers (Accept-Language removal regression guard)

    func test_standardHeadersOmitsAcceptLanguage() {
        let builder = HeaderBuilder(
            token: "test-token",
            sdkVersion: "0.3.0",
            maxSupportedDslVersion: "1.0"
        )
        let headers = builder.standardHeaders()
        XCTAssertNil(headers["Accept-Language"])
        XCTAssertNil(headers["accept-language"])
    }

    func test_standardHeadersStillIncludesAuthAndSDKVersion() {
        let builder = HeaderBuilder(
            token: "test-token",
            sdkVersion: "0.3.0",
            maxSupportedDslVersion: "1.0"
        )
        let headers = builder.standardHeaders()
        XCTAssertEqual(headers["Authorization"], "Bearer test-token")
        XCTAssertEqual(headers["X-App8-SDK-Version"], "0.3.0")
        XCTAssertEqual(headers["X-App8-DSL-Max"], "1.0")
    }
}
