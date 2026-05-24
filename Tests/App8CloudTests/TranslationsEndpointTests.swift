//
//  TranslationsEndpointTests.swift
//  App8CloudTests
//

import XCTest
@testable import App8Cloud

final class TranslationsEndpointTests: XCTestCase {

    // MARK: - Endpoint shape

    func test_translationsEndpointPathMatchesBackendRoute() {
        let endpoint = Endpoint.translations(appId: "ABC123")
        XCTAssertEqual(endpoint.path, "/apps/ABC123/translations")
    }

    func test_translationsEndpointIsGet() {
        let endpoint = Endpoint.translations(appId: "ABC123")
        XCTAssertEqual(endpoint.method, "GET")
    }

    func test_translationsEndpointHasNoQueryItems() {
        // Locale selection is client-side; the server always returns the
        // full all-locales bundle. No ?locale= or Accept-Language fragmentation.
        let endpoint = Endpoint.translations(appId: "ABC123")
        XCTAssertTrue(endpoint.queryItems.isEmpty)
    }

    func test_translationsCoalesceKeyIsAppScoped() {
        // The in-flight coalescer dedupes concurrent fetches by this key —
        // scope must include appId so a second instance for a different
        // app doesn't piggyback on the first instance's fetch.
        let a = Endpoint.translations(appId: "app-1")
        let b = Endpoint.translations(appId: "app-2")
        XCTAssertNotEqual(a.coalesceKey, b.coalesceKey)
        XCTAssertEqual(a.coalesceKey, "translations:app-1")
    }

    func test_resolveBuildsAbsoluteURL() {
        let base = URL(string: "https://app8.example.com/sdk/v1")!
        let url = Endpoint.translations(appId: "ABC123").resolve(against: base)
        XCTAssertEqual(url.absoluteString, "https://app8.example.com/sdk/v1/apps/ABC123/translations")
    }

    // MARK: - Headers (Accept-Language removal)

    func test_standardHeadersOmitsAcceptLanguage() {
        // Phase 1 design dropped Accept-Language from the wire entirely —
        // confirm no header smuggling slips back in. Regression guard.
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
        // Sanity: the locale-related cleanup didn't break other headers.
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
