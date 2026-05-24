//
//  EventAnalyticsPassthroughTests.swift
//  App8CloudTests
//
//  Covers the host-facing event + analytics + locale passthrough that the
//  cloud SDK exposes on `App8Cloud.Instance`:
//   - `eventBus` / `analyticsBus` are the same instances the engine uses
//   - `analyticsConfig` get/set forwards to the engine
//   - `setLocale` / `currentLocale` forward to the engine
//   - `subscribe(_:)` / `observeAnalytics(_:)` receive events dispatched to
//     the underlying engine buses
//   - `setEventHandler(_:)` / `setAnalyticsHandler(_:)` plumb delegates to the
//     engine buses
//   - `app8_render_failed` fires on the analytics bus when the throwing
//     render path throws, gated by `analyticsConfig.autoScreenEvents`
//   - `app8_render_fallback` fires on the analytics bus when the fallback
//     path is taken, gated by the same flag
//

import XCTest
import UIKit
@testable import App8Cloud
@_spi(Advanced) import App8Cloud
import App8Engine

@MainActor
final class EventAnalyticsPassthroughTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /// Same `makeInstance()` shape used by `A8CInstanceFallbackTests` — builds
    /// an `A8CInstance` with an injected `URLSession` so `MockURLProtocol`
    /// intercepts every request.
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

    // MARK: - Bus identity

    func testEventBusIsSameInstanceAsEngine() {
        let cloud = makeInstance()
        XCTAssertTrue(cloud.eventBus === cloud.engine.eventBus,
                      "Cloud must expose the engine's eventBus, not a separate one")
    }

    func testAnalyticsBusIsSameInstanceAsEngine() {
        let cloud = makeInstance()
        XCTAssertTrue(cloud.analyticsBus === cloud.engine.analyticsBus,
                      "Cloud must expose the engine's analyticsBus, not a separate one")
    }

    // MARK: - analyticsConfig

    func testAnalyticsConfigReadsFromEngine() {
        let cloud = makeInstance()
        cloud.engine.analyticsConfig.autoScreenEvents = false
        XCTAssertFalse(cloud.analyticsConfig.autoScreenEvents)
    }

    func testAnalyticsConfigWriteForwardsToEngine() {
        let cloud = makeInstance()
        var cfg = cloud.analyticsConfig
        cfg.autoComponentTaps = false
        cloud.analyticsConfig = cfg
        XCTAssertFalse(cloud.engine.analyticsConfig.autoComponentTaps,
                       "Setting analyticsConfig on cloud must mutate the engine's config")
    }

    // MARK: - Locale

    func testSetLocaleForwardsToEngine() {
        let cloud = makeInstance()
        cloud.setLocale("fr-FR")
        XCTAssertEqual(cloud.engine.currentLocale, "fr-FR")
        XCTAssertEqual(cloud.currentLocale, "fr-FR")
    }

    func testSetLocaleNilRevertsToDeviceDefault() {
        let cloud = makeInstance()
        cloud.setLocale("ja-JP")
        XCTAssertEqual(cloud.currentLocale, "ja-JP")
        cloud.setLocale(nil)
        // After nil, the engine reverts to a device-derived locale — we can't
        // assert the exact value (it depends on the simulator), but it must
        // no longer be the override we set.
        XCTAssertNotEqual(cloud.currentLocale, "ja-JP")
    }

    // MARK: - Subscriptions

    func testSubscribeReceivesEventsDispatchedToEngineBus() {
        let cloud = makeInstance()
        let received = Locked<[String]>([])

        let sub = cloud.subscribe { event in
            received.set(received.get() + [event.name])
        }
        defer { sub.cancel() }

        cloud.engine.eventBus.dispatch(App8Event(
            name: "host_subscribed",
            screenId: "home",
            componentId: nil,
            componentType: nil,
            payload: [:]
        ))
        XCTAssertEqual(received.get(), ["host_subscribed"])
    }

    func testSubscribeToNameFiltersByEventName() {
        let cloud = makeInstance()
        let received = Locked<[String]>([])

        let sub = cloud.subscribe(to: "tracked") { event in
            received.set(received.get() + [event.name])
        }
        defer { sub.cancel() }

        cloud.engine.eventBus.dispatch(App8Event(
            name: "tracked",
            screenId: "home",
            componentId: nil,
            componentType: nil,
            payload: [:]
        ))
        cloud.engine.eventBus.dispatch(App8Event(
            name: "ignored",
            screenId: "home",
            componentId: nil,
            componentType: nil,
            payload: [:]
        ))
        XCTAssertEqual(received.get(), ["tracked"])
    }

    func testObserveAnalyticsReceivesAnalyticsEvents() {
        let cloud = makeInstance()
        let received = Locked<[String]>([])

        let sub = cloud.observeAnalytics { event in
            received.set(received.get() + [event.name])
        }
        defer { sub.cancel() }

        cloud.engine.analyticsBus.dispatch(App8AnalyticsEvent(
            name: "app8_screen_appeared",
            screenId: "home",
            componentId: nil,
            componentType: nil,
            properties: [:]
        ))
        XCTAssertEqual(received.get(), ["app8_screen_appeared"])
    }

    // MARK: - Delegate handlers

    func testSetEventHandlerSetsEngineDelegate() {
        let cloud = makeInstance()
        let handler = RecordingEventHandler()
        cloud.setEventHandler(handler)
        XCTAssertTrue(cloud.engine.eventBus.delegate === handler)

        cloud.setEventHandler(nil)
        XCTAssertNil(cloud.engine.eventBus.delegate)
    }

    func testSetAnalyticsHandlerSetsEngineDelegate() {
        let cloud = makeInstance()
        let handler = RecordingAnalyticsHandler()
        cloud.setAnalyticsHandler(handler)
        XCTAssertTrue(cloud.engine.analyticsBus.delegate === handler)

        cloud.setAnalyticsHandler(nil)
        XCTAssertNil(cloud.engine.analyticsBus.delegate)
    }

    // MARK: - app8_render_failed bus emission

    func testRenderFailedFiresOnAnalyticsBus() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        let cloud = makeInstance()
        let received = Locked<[App8AnalyticsEvent]>([])
        let sub = cloud.observeAnalytics { received.set(received.get() + [$0]) }
        defer { sub.cancel() }

        do {
            _ = try await cloud.screen(id: "home", version: "v1", parameters: [:])
            XCTFail("Expected throw")
        } catch {
            // expected
        }

        let failed = received.get().first { $0.name == "app8_render_failed" }
        XCTAssertNotNil(failed, "app8_render_failed should land on analyticsBus")
        XCTAssertEqual(failed?.screenId, "home")
        XCTAssertEqual(failed?.properties["kind"] as? String, "screen")
        XCTAssertEqual(failed?.properties["requestedVersion"] as? String, "v1")
        XCTAssertEqual(failed?.properties["status"] as? Int, 500)
    }

    func testRenderFailedSuppressedWhenAutoScreenEventsDisabled() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        let cloud = makeInstance()
        cloud.engine.analyticsConfig.autoScreenEvents = false
        let received = Locked<[App8AnalyticsEvent]>([])
        let sub = cloud.observeAnalytics { received.set(received.get() + [$0]) }
        defer { sub.cancel() }

        _ = try? await cloud.screen(id: "home", version: nil, parameters: [:])

        let failed = received.get().first { $0.name == "app8_render_failed" }
        XCTAssertNil(failed,
                     "app8_render_failed must respect engine.analyticsConfig.autoScreenEvents")
    }

    // MARK: - app8_render_fallback bus emission

    func testRenderFallbackFiresOnAnalyticsBus() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        let cloud = makeInstance()
        let received = Locked<[App8AnalyticsEvent]>([])
        let sub = cloud.observeAnalytics { received.set(received.get() + [$0]) }
        defer { sub.cancel() }

        _ = await cloud.screen(id: "home", version: nil, parameters: [:]) { _ in
            UIViewController()
        }

        let fallback = received.get().first { $0.name == "app8_render_fallback" }
        XCTAssertNotNil(fallback, "app8_render_fallback should land on analyticsBus")
        XCTAssertEqual(fallback?.screenId, "home")
        XCTAssertEqual(fallback?.properties["kind"] as? String, "screen")
        XCTAssertEqual(fallback?.properties["status"] as? Int, 500)
    }

    func testRenderFallbackSuppressedWhenAutoScreenEventsDisabled() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        let cloud = makeInstance()
        cloud.engine.analyticsConfig.autoScreenEvents = false
        let received = Locked<[App8AnalyticsEvent]>([])
        let sub = cloud.observeAnalytics { received.set(received.get() + [$0]) }
        defer { sub.cancel() }

        _ = await cloud.screen(id: "home", version: nil, parameters: [:]) { _ in
            UIViewController()
        }

        let fallback = received.get().first { $0.name == "app8_render_fallback" }
        XCTAssertNil(fallback,
                     "app8_render_fallback must respect engine.analyticsConfig.autoScreenEvents")
    }
}

// MARK: - Test handlers

@MainActor
private final class RecordingEventHandler: App8EventHandler {
    func app8DidEmit(_ event: App8Event) {}
}

@MainActor
private final class RecordingAnalyticsHandler: App8AnalyticsHandler {
    func app8DidTrack(_ event: App8AnalyticsEvent) {}
}
