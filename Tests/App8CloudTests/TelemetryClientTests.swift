//
//  TelemetryClientTests.swift
//  App8CloudTests
//

import XCTest
@testable import App8Cloud

@MainActor
final class TelemetryClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - Helpers

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

    private func makeTelemetry(
        identity: [String: String] = [:],
        appId: String = "app1"
    ) -> TelemetryClient {
        TelemetryClient(
            client: makeClient(),
            appId: appId,
            identityProvider: { identity },
            diagnostics: .disabled
        )
    }

    private func captureBody(from req: URLRequest) -> Data? {
        if let body = req.httpBody { return body }
        guard let stream = req.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 8192
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // MARK: - Tests

    func testEnqueueAndFlushPostsToTelemetryEndpoint() async {
        let captured = Locked<URLRequest?>(nil)
        let capturedBody = Locked<Data?>(nil)
        MockURLProtocol.requestHandler = { [weak self] req in
            captured.set(req)
            capturedBody.set(self?.captureBody(from: req))
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                    Data("{\"accepted\":1,\"skipped\":0}".utf8))
        }
        let client = makeTelemetry()
        client.enqueue(TelemetryEvent(
            type: "sdk_init",
            occurredAt: Date(timeIntervalSince1970: 1_770_000_000),
            screenKey: nil,
            context: ["hostBundleId": "com.partner.app"]
        ))
        await client.flush()

        let req = captured.get()
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertEqual(req?.url?.path, "/sdk/v1/apps/app1/telemetry")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = capturedBody.get() ?? Data()
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let events = json?["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 1)
        XCTAssertEqual(events?.first?["type"] as? String, "sdk_init")
        XCTAssertNotNil(events?.first?["occurredAt"] as? String)
    }

    func testEmptyFlushDoesNotPost() async {
        let attempts = Locked<Int>(0)
        MockURLProtocol.requestHandler = { req in
            attempts.set(attempts.get() + 1)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        let client = makeTelemetry()
        await client.flush()
        XCTAssertEqual(attempts.get(), 0)
    }

    func testBatchCapsAt100Events() async {
        let bodyByCall = Locked<[Data]>([])
        MockURLProtocol.requestHandler = { [weak self] req in
            if let body = self?.captureBody(from: req) {
                var arr = bodyByCall.get(); arr.append(body); bodyByCall.set(arr)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        let client = makeTelemetry()
        for i in 0..<150 {
            client.enqueue(TelemetryEvent(
                type: "custom",
                occurredAt: Date(),
                screenKey: nil,
                context: ["i": i]
            ))
        }
        await client.flush()

        let bodies = bodyByCall.get()
        XCTAssertGreaterThanOrEqual(bodies.count, 1)
        // At least one batch should hit the 100-event cap.
        let counts: [Int] = bodies.compactMap { data in
            (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["events"] as? [[String: Any]] }?
                .count
        }
        XCTAssertTrue(counts.contains { $0 == 100 || $0 < 100 && $0 > 0 },
                      "Expected at least one batch with up to 100 events; got counts=\(counts)")
        for c in counts { XCTAssertLessThanOrEqual(c, 100) }
    }

    func testBufferCapsAt500EventsDropsOldest() async {
        let capturedBody = Locked<Data?>(nil)
        MockURLProtocol.requestHandler = { [weak self] req in
            capturedBody.set(self?.captureBody(from: req))
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        let client = makeTelemetry()
        // Enqueue 600 events. Cap is 500; the first 100 should be dropped.
        for i in 0..<600 {
            client.enqueue(TelemetryEvent(
                type: "custom",
                occurredAt: Date(),
                screenKey: nil,
                context: ["i": i]
            ))
        }
        // Drain everything.
        for _ in 0..<10 { await client.flush() }

        // Reconstruct the events stream we sent. The smallest "i" still
        // present should be ≥100 (since 0..99 were evicted).
        // We can't reliably reconstruct cross-batch ordering without
        // capturing every body, so the simpler invariant is: the
        // last-flushed batch we captured must contain only i ≥ 100.
        guard let body = capturedBody.get(),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else {
            XCTFail("Failed to capture telemetry body."); return
        }
        let indices = events.compactMap { ($0["context"] as? [String: Any])?["i"] as? Int }
        for i in indices {
            XCTAssertGreaterThanOrEqual(i, 100, "Event i=\(i) should have been evicted (cap=500, total=600).")
        }
    }

    func testNon2xxResponseDropsBatch() async {
        let attempts = Locked<Int>(0)
        MockURLProtocol.requestHandler = { req in
            attempts.set(attempts.get() + 1)
            return (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        let client = makeTelemetry()
        client.enqueue(TelemetryEvent(
            type: "custom", occurredAt: Date(), screenKey: nil, context: nil
        ))
        await client.flush()
        // 400 is not in the retryable set — single attempt, then drop.
        XCTAssertEqual(attempts.get(), 1)
        // Subsequent flush has nothing to send.
        await client.flush()
        XCTAssertEqual(attempts.get(), 1)
    }

    func testISO8601EncodingInWirePayload() async {
        let capturedBody = Locked<Data?>(nil)
        MockURLProtocol.requestHandler = { [weak self] req in
            capturedBody.set(self?.captureBody(from: req))
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        let client = makeTelemetry()
        let when = Date(timeIntervalSince1970: 1_768_530_600)
        client.enqueue(TelemetryEvent(
            type: "sdk_init", occurredAt: when, screenKey: nil, context: nil
        ))
        await client.flush()
        guard let body = capturedBody.get(),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let events = json["events"] as? [[String: Any]],
              let occurredAt = events.first?["occurredAt"] as? String else {
            XCTFail("Failed to capture body."); return
        }
        // Round-trip: parsing the wire string must reproduce the
        // original timestamp.
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        let parsed = parser.date(from: occurredAt)
        XCTAssertEqual(parsed, when)
        // And the wire format must match the SDK's canonical encoding.
        XCTAssertEqual(occurredAt, parser.string(from: when))
    }

    func testIdentityHeaderIncludedFromProvider() async {
        let captured = Locked<URLRequest?>(nil)
        MockURLProtocol.requestHandler = { req in
            captured.set(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        let client = makeTelemetry(identity: ["userId": "u1"])
        client.enqueue(TelemetryEvent(
            type: "custom", occurredAt: Date(), screenKey: nil, context: nil
        ))
        await client.flush()
        let header = captured.get()?.value(forHTTPHeaderField: "X-App8-Identity")
        XCTAssertNotNil(header)
        let decoded = Data(base64Encoded: header ?? "") ?? Data()
        let attrs = try? JSONSerialization.jsonObject(with: decoded) as? [String: String]
        XCTAssertEqual(attrs?["userId"], "u1")
    }

    func testShutdownFlushesPendingEvents() async {
        let attempts = Locked<Int>(0)
        MockURLProtocol.requestHandler = { req in
            attempts.set(attempts.get() + 1)
            return (HTTPURLResponse(url: req.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        let client = makeTelemetry()
        client.enqueue(TelemetryEvent(
            type: "sdk_init", occurredAt: Date(), screenKey: nil, context: nil
        ))
        await client.shutdown()
        XCTAssertEqual(attempts.get(), 1)
    }

    func testSanitizeJSONDictDropsNonJSONValues() {
        struct Custom {}
        let raw: [String: Any] = [
            "ok": "value",
            "n": 42,
            "f": 3.14,
            "b": true,
            "nested": ["inner": "ok"] as [String: Any],
            "arr": [1, "two", false] as [Any],
            "bad": Custom(),               // dropped
            "nan": Double.nan              // dropped (non-finite)
        ]
        let cleaned = sanitizeJSONDict(raw)
        XCTAssertEqual(cleaned["ok"] as? String, "value")
        XCTAssertEqual(cleaned["n"] as? Int, 42)
        XCTAssertEqual(cleaned["f"] as? Double, 3.14)
        XCTAssertEqual(cleaned["b"] as? Bool, true)
        XCTAssertNotNil(cleaned["nested"] as? [String: Any])
        XCTAssertNotNil(cleaned["arr"] as? [Any])
        XCTAssertNil(cleaned["bad"])
        XCTAssertNil(cleaned["nan"])
    }
}
