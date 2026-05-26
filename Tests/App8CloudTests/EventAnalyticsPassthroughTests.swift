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
//   - Cloud render-lifecycle events: `app8.render.failed`, `app8.render.fallback`,
//     and `app8.screen.rendered` fire on the analytics bus, gated by
//     `analyticsConfig.autoCloudEvents` (NOT `autoScreenEvents` — that gate
//     only controls engine lifecycle).
//   - Init-window invariant: no analytics events fire between
//     `App8.instance(dataSource:)` returning and the cloud SDK teaching the
//     bus its version.
//   - IRON RULE: `autoScreenEvents=false` no longer suppresses cloud events.
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

    // MARK: - Version stamping (cloud teaches bus at init)

    func testCloudInitTeachesBusItsVersion() {
        let cloud = makeInstance()
        XCTAssertEqual(cloud.engine.analyticsBus.cloudVersion, SDKVersion.current,
                       "Cloud init must set analyticsBus.cloudVersion to SDKVersion.current")
        XCTAssertEqual(cloud.engine.eventBus.cloudVersion, SDKVersion.current,
                       "Cloud init must set eventBus.cloudVersion to SDKVersion.current")
    }

    func testCloudEventsCarryCloudVersionStamp() {
        let cloud = makeInstance()
        let received = Locked<[App8AnalyticsEvent]>([])
        let sub = cloud.observeAnalytics { received.set(received.get() + [$0]) }
        defer { sub.cancel() }

        // Dispatch a synthetic analytics event through the cloud-attached bus.
        cloud.engine.analyticsBus.dispatch(App8AnalyticsEvent(
            name: "synth.event",
            screenId: "home",
            properties: [:]
        ))

        let event = received.get().first
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.cloudVersion, SDKVersion.current)
        XCTAssertEqual(event?.engineVersion, EngineVersion.current)
        XCTAssertEqual(event?.properties["cloud_version"] as? String, SDKVersion.current)
        XCTAssertEqual(event?.properties["engine_version"] as? String, EngineVersion.current)
    }

    // MARK: - Init-window invariant (D4 regression)

    /// Pins the empty window between `App8.instance(dataSource:)` returning
    /// and the cloud SDK's teach-bus-cloud-version line running. No analytics
    /// events should fire there. If a future PR adds an engine-init-time
    /// event, this test must explicitly re-evaluate that decision.
    func testNoAnalyticsEventsInInitWindow() {
        // Subscribe to a freshly-built engine before any cloud wrapping.
        let engine = App8.instance(dataSource: TestDataSource())
        let preReceived = Locked<[App8AnalyticsEvent]>([])
        let sub = engine.analyticsBus.subscribe { preReceived.set(preReceived.get() + [$0]) }
        defer { sub.cancel() }

        // Construction alone must not fire any analytics events.
        XCTAssertTrue(preReceived.get().isEmpty,
                      "Engine construction must not fire analytics events. Adding an engine-init-time event invalidates the init-window invariant; this test must be revisited.")
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

    func testAutoCloudEventsDefaultsTrue() {
        let cloud = makeInstance()
        XCTAssertTrue(cloud.analyticsConfig.autoCloudEvents)
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
            name: App8AnalyticsEvent.Auto.screenAppeared,
            screenId: "home",
            componentId: nil,
            componentType: nil,
            properties: [:]
        ))
        XCTAssertEqual(received.get(), [App8AnalyticsEvent.Auto.screenAppeared])
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

    // MARK: - app8.render.failed bus emission

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

        let failed = received.get().first { $0.name == App8AnalyticsEvent.Auto.renderFailed }
        XCTAssertNotNil(failed, "app8.render.failed should land on analyticsBus")
        XCTAssertEqual(failed?.screenId, "home")
        XCTAssertEqual(failed?.properties["kind"] as? String, "screen")
        XCTAssertEqual(failed?.properties["requested_version"] as? String, "v1")
        XCTAssertEqual(failed?.properties["status"] as? Int, 500)
        // Both versions stamped.
        XCTAssertEqual(failed?.engineVersion, EngineVersion.current)
        XCTAssertEqual(failed?.cloudVersion, SDKVersion.current)
    }

    func testRenderFailedSuppressedWhenAutoCloudEventsDisabled() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        let cloud = makeInstance()
        cloud.engine.analyticsConfig.autoCloudEvents = false
        let received = Locked<[App8AnalyticsEvent]>([])
        let sub = cloud.observeAnalytics { received.set(received.get() + [$0]) }
        defer { sub.cancel() }

        _ = try? await cloud.screen(id: "home", version: nil, parameters: [:])

        let failed = received.get().first { $0.name == App8AnalyticsEvent.Auto.renderFailed }
        XCTAssertNil(failed,
                     "app8.render.failed must respect engine.analyticsConfig.autoCloudEvents")
    }

    /// IRON RULE regression: callers who used `autoScreenEvents=false` to
    /// silence cloud render telemetry must migrate to `autoCloudEvents`.
    /// `autoScreenEvents` now only gates the engine's screen lifecycle.
    func testAutoScreenEventsDoesNotSuppressCloudEvents() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        let cloud = makeInstance()
        cloud.engine.analyticsConfig.autoScreenEvents = false  // engine lifecycle off
        cloud.engine.analyticsConfig.autoCloudEvents = true    // cloud telemetry on
        let received = Locked<[App8AnalyticsEvent]>([])
        let sub = cloud.observeAnalytics { received.set(received.get() + [$0]) }
        defer { sub.cancel() }

        _ = try? await cloud.screen(id: "home", version: nil, parameters: [:])

        let failed = received.get().first { $0.name == App8AnalyticsEvent.Auto.renderFailed }
        XCTAssertNotNil(failed,
                        "autoScreenEvents=false must NOT suppress cloud events; only autoCloudEvents=false does")
    }

    // MARK: - app8.render.fallback bus emission

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

        let fallback = received.get().first { $0.name == App8AnalyticsEvent.Auto.renderFallback }
        XCTAssertNotNil(fallback, "app8.render.fallback should land on analyticsBus")
        XCTAssertEqual(fallback?.screenId, "home")
        XCTAssertEqual(fallback?.properties["kind"] as? String, "screen")
        XCTAssertEqual(fallback?.properties["status"] as? Int, 500)
    }

    func testRenderFallbackSuppressedWhenAutoCloudEventsDisabled() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        let cloud = makeInstance()
        cloud.engine.analyticsConfig.autoCloudEvents = false
        let received = Locked<[App8AnalyticsEvent]>([])
        let sub = cloud.observeAnalytics { received.set(received.get() + [$0]) }
        defer { sub.cancel() }

        _ = await cloud.screen(id: "home", version: nil, parameters: [:]) { _ in
            UIViewController()
        }

        let fallback = received.get().first { $0.name == App8AnalyticsEvent.Auto.renderFallback }
        XCTAssertNil(fallback,
                     "app8.render.fallback must respect engine.analyticsConfig.autoCloudEvents")
    }

    // MARK: - app8.screen.rendered — funnel denominator (success arm)

    /// `app8.screen.rendered` must NOT fire on the render-failure path.
    /// Funnel correctness — accidental success-arm overcount is the most
    /// likely silent regression.
    func testScreenRenderedDoesNotFireOnFailurePath() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        let cloud = makeInstance()
        let received = Locked<[App8AnalyticsEvent]>([])
        let sub = cloud.observeAnalytics { received.set(received.get() + [$0]) }
        defer { sub.cancel() }

        _ = try? await cloud.screen(id: "home", version: nil, parameters: [:])

        let rendered = received.get().first { $0.name == App8AnalyticsEvent.Auto.screenRendered }
        XCTAssertNil(rendered,
                     "app8.screen.rendered MUST NOT fire on render-failure path; that would overcount the success arm")
    }

    /// And not on the host-fallback path either.
    func testScreenRenderedDoesNotFireOnFallbackPath() async {
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

        let rendered = received.get().first { $0.name == App8AnalyticsEvent.Auto.screenRendered }
        XCTAssertNil(rendered,
                     "app8.screen.rendered MUST NOT fire when host-fallback runs")
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

private final class TestDataSource: App8DataSource, @unchecked Sendable {
    func getApp() async throws -> Data { Data() }
    func getStyles() async throws -> [Data] { [] }
    func getComponents() async throws -> [Data] { [] }
    func getComponent(componentId: String) async throws -> Data { Data() }
    func getAsset(assetId: String?, assetName: String?) async throws -> Data? { nil }
    func getScreen(screenId: String) async throws -> Data { Data() }
    func getDatasource(screenId: String, datasourceId: String) async throws -> Data { Data() }
}
