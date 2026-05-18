//
//  A8CInstanceFallbackTests.swift
//  App8CloudTests
//
//  Covers the fallback feature in v0.3 surface:
//   - Fallback closure invoked on errors
//   - Throwing variant unchanged
//   - onFallbackInvoked notification fires after closure
//   - Success path skips fallback
//

import XCTest
import UIKit
@testable import App8Cloud

@MainActor
final class A8CInstanceFallbackTests: XCTestCase {

    private var tempCacheRoot: URL!

    override func setUp() {
        super.setUp()
        tempCacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("App8CloudFallbackTests-\(UUID().uuidString)")
        MockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempCacheRoot)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /// Build an `A8CInstance` directly (bypassing the public factory) so we
    /// can inject a `URLSession` whose `protocolClasses` includes
    /// `MockURLProtocol`. `URLProtocol.registerClass()` doesn't reach the
    /// SDK's internally-constructed ephemeral session, so direct injection
    /// is the only way.
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

    private static let validManifestResponse = #"""
    {
      "configuration": { "id": "test-app", "title": "Test", "initialScreenId": "home" }
    }
    """#

    private static let validScreenResponse = #"""
    {
      "servedVersion": "v3",
      "data": { "id": "home", "type": "view" }
    }
    """#

    // MARK: - Tests

    func testScreenFallbackInvokedOnAuthError() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        let cloud = makeInstance()
        let receivedError = Locked<App8Cloud.Error?>(nil)
        let sentinelVC = UIViewController()

        let vc = await cloud.screen(id: "home", version: nil, parameters: [:]) { error in
            receivedError.set(error)
            return sentinelVC
        }

        XCTAssertTrue(vc === sentinelVC, "Fallback closure's VC should be returned")
        if case .authInvalid = receivedError.get() {
            // pass
        } else {
            XCTFail("Expected .authInvalid; got \(String(describing: receivedError.get()))")
        }
    }

    func testOnFallbackInvokedFiresAfterClosure() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        let cloud = makeInstance()
        let order = Locked<[String]>([])

        cloud.onFallbackInvoked = { event in
            order.set(order.get() + ["callback"])
            XCTAssertEqual(event.screenId, "home")
            XCTAssertEqual(event.source, .screen)
            if case .authInvalid = event.error {
                // pass
            } else {
                XCTFail("Wrong error in callback")
            }
        }

        _ = await cloud.screen(id: "home", version: nil, parameters: [:]) { _ in
            order.set(order.get() + ["closure"])
            return UIViewController()
        }

        XCTAssertEqual(order.get(), ["closure", "callback"],
                       "Fallback closure must run before onFallbackInvoked")
    }

    func testThrowingVariantStillThrowsOn401() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        let cloud = makeInstance()
        do {
            _ = try await cloud.screen(id: "home", version: nil, parameters: [:])
            XCTFail("Expected throw")
        } catch let App8Cloud.Error.authInvalid {
            // pass
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testStartAppFallbackPath() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        let cloud = makeInstance()
        let received = Locked<App8Cloud.Error?>(nil)
        let sentinel = UIViewController()
        var callbackEvent: App8Cloud.FallbackEvent?
        cloud.onFallbackInvoked = { event in callbackEvent = event }

        let vc = await cloud.startApp(version: nil) { error in
            received.set(error)
            return sentinel
        }

        XCTAssertTrue(vc === sentinel)
        if case .authInvalid = received.get() {} else {
            XCTFail("Expected .authInvalid")
        }
        XCTAssertEqual(callbackEvent?.source, .app)
        XCTAssertNil(callbackEvent?.screenId, "startApp fallbacks have nil screenId")
    }

    func testFallbackOnDecodeError() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("not valid json {{{".utf8))
        }

        let cloud = makeInstance()
        let received = Locked<App8Cloud.Error?>(nil)

        _ = await cloud.screen(id: "home", version: nil, parameters: [:]) { error in
            received.set(error)
            return UIViewController()
        }

        XCTAssertNotNil(received.get())
        switch received.get() {
        case .decodeFailed, .engine:
            break
        default:
            XCTFail("Expected decode-class error; got \(String(describing: received.get()))")
        }
    }
}
