//
//  HTTPClientTests.swift
//  App8CloudTests
//

import XCTest
@testable import App8Cloud

final class HTTPClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeClient(timeout: TimeInterval = 5) -> HTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let headers = HeaderBuilder(
            token: "app8_test_abc1234567",
            sdkVersion: "0.3.0",
            maxSupportedDslVersion: "1.0"
        )
        return HTTPClient(
            baseURL: URL(string: "https://test.app8.dev/sdk/v1")!,
            headers: headers,
            timeout: timeout,
            diagnostics: .disabled,
            sessionOverride: session
        )
    }

    func testGetInjectsBearerHeader() async throws {
        let captured = Locked<URLRequest?>(nil)
        MockURLProtocol.requestHandler = { req in
            captured.set(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8))
        }

        let client = makeClient()
        _ = try await client.get(.manifest(appId: "app1"))

        let req = captured.get()
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer app8_test_abc1234567")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "X-App8-SDK-Version"), "0.3.0")
        XCTAssertEqual(req?.url?.path, "/sdk/v1/apps/app1/manifest")
        XCTAssertEqual(req?.httpMethod, "GET")
    }

    func testGetWithVersionAddsQuery() async throws {
        let captured = Locked<URLRequest?>(nil)
        MockURLProtocol.requestHandler = { req in
            captured.set(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8))
        }

        let client = makeClient()
        _ = try await client.get(.screen(appId: "app1", screenId: "home", version: "v3"))

        let req = captured.get()
        XCTAssertEqual(req?.url?.path, "/sdk/v1/apps/app1/screens/home")
        XCTAssertEqual(req?.url?.query, "version=v3")
    }

    func testIdentityHeaderEncodedAsBase64() async throws {
        let captured = Locked<URLRequest?>(nil)
        MockURLProtocol.requestHandler = { req in
            captured.set(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8))
        }

        let client = makeClient()
        _ = try await client.get(
            .manifest(appId: "app1"),
            identity: ["userId": "u1", "plan": "pro"]
        )

        let req = captured.get()
        let header = req?.value(forHTTPHeaderField: "X-App8-Identity")
        XCTAssertNotNil(header)
        // Decode base64 and assert it's valid JSON with our keys.
        let decoded = Data(base64Encoded: header ?? "") ?? Data()
        let json = try JSONSerialization.jsonObject(with: decoded) as? [String: String]
        XCTAssertEqual(json?["userId"], "u1")
        XCTAssertEqual(json?["plan"], "pro")
    }

    func test401MapsToAuthInvalid() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data())
        }
        let client = makeClient()
        do {
            _ = try await client.get(.manifest(appId: "app1"))
            XCTFail("Expected throw.")
        } catch let App8Cloud.Error.authInvalid {
            // pass
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func test404OnScreenWithVersionMapsToScreenVersionNotFound() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             Data())
        }
        let client = makeClient()
        do {
            _ = try await client.get(.screen(appId: "app1", screenId: "home", version: "v99"))
            XCTFail("Expected throw.")
        } catch let App8Cloud.Error.screenVersionNotFound(id, version) {
            XCTAssertEqual(id, "home")
            XCTAssertEqual(version, "v99")
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func test404OnScreenWithoutVersionMapsToScreenNotFound() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             Data())
        }
        let client = makeClient()
        do {
            _ = try await client.get(.screen(appId: "app1", screenId: "ghost", version: nil))
            XCTFail("Expected throw.")
        } catch let App8Cloud.Error.screenNotFound(id) {
            XCTAssertEqual(id, "ghost")
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func test503TriggersRetryThenSucceeds() async throws {
        let attempts = Locked<Int>(0)
        MockURLProtocol.requestHandler = { req in
            let n = attempts.get() + 1
            attempts.set(n)
            if n < 3 {
                return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                        Data())
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8))
        }
        let client = makeClient()
        let result = try await client.get(.manifest(appId: "app1"))
        XCTAssertEqual(attempts.get(), 3)
        XCTAssertEqual(result.data, Data("{}".utf8))
    }

    func test412ParsesRequiredAndClientMaxFromBody() async {
        let body = """
        {"error":"Bundle requires DSL 1.2","code":"dsl_version_mismatch","required":"1.2","client_max":"1.0"}
        """.data(using: .utf8)!
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 412, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = makeClient()
        do {
            _ = try await client.get(.screen(appId: "app1", screenId: "checkout", version: nil))
            XCTFail("Expected throw.")
        } catch let App8Cloud.Error.dslVersionUnsupported(found, max) {
            XCTAssertEqual(found, "1.2")
            XCTAssertEqual(max, "1.0")
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func test412FallsBackToPlaceholdersWhenBodyMissing() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 412, httpVersion: nil, headerFields: nil)!,
             Data())
        }
        let client = makeClient()
        do {
            _ = try await client.get(.manifest(appId: "app1"))
            XCTFail("Expected throw.")
        } catch let App8Cloud.Error.dslVersionUnsupported(found, max) {
            XCTAssertEqual(found, "?")
            XCTAssertEqual(max, "?")
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func testPostTelemetrySendsJSONBody() async throws {
        let captured = Locked<URLRequest?>(nil)
        let capturedBody = Locked<Data?>(nil)
        MockURLProtocol.requestHandler = { req in
            captured.set(req)
            // URLProtocol doesn't surface httpBody directly; pull from
            // httpBodyStream when present.
            if let stream = req.httpBodyStream {
                stream.open()
                var data = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                stream.close()
                capturedBody.set(data)
            } else if let body = req.httpBody {
                capturedBody.set(body)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                    Data("{\"accepted\":1,\"skipped\":0}".utf8))
        }
        let client = makeClient()
        let payload = Data("{\"events\":[{\"type\":\"sdk_init\"}]}".utf8)
        _ = try await client.post(.telemetry(appId: "app1"), body: payload)

        let req = captured.get()
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertEqual(req?.url?.path, "/sdk/v1/apps/app1/telemetry")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(capturedBody.get(), payload)
    }

    func testPostTelemetry400Throws() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
             Data("{\"error\":\"batch_too_large\",\"code\":\"batch_too_large\"}".utf8))
        }
        let client = makeClient()
        do {
            _ = try await client.post(.telemetry(appId: "app1"), body: Data("{}".utf8))
            XCTFail("Expected throw.")
        } catch let App8Cloud.Error.serverError(status, retryable) {
            XCTAssertEqual(status, 400)
            XCTAssertFalse(retryable)
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func testRawAssetURLDoesNotIncludeBearer() async throws {
        let captured = Locked<URLRequest?>(nil)
        MockURLProtocol.requestHandler = { req in
            captured.set(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data([0xFF]))
        }
        let client = makeClient()
        _ = try await client.getRawURL(URL(string: "https://cdn.example.com/blob?token=xyz")!)
        let req = captured.get()
        XCTAssertNil(req?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(req?.value(forHTTPHeaderField: "X-App8-Identity"))
    }
}

// MARK: - URLProtocol fixture

final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) static var requestHandler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { /* no-op */ }
}

// MARK: - Lock helper

final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ initial: T) { self.value = initial }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: T) { lock.lock(); defer { lock.unlock() }; value = newValue }
}
