# App8Cloud

App8Cloud is the iOS SDK for the [App8](https://app8.dev) platform. It wraps
the [App8Engine](https://github.com/appeight/app8-ios-sdk) rendering engine
(its repository is named `app8-ios-sdk`) and adds everything needed to deliver
dynamic UI from the App8 API:

- A built-in `App8DataSource` that fetches DSL over `/sdk/v1/`.
- Token-based auth (`app8_live_…` / `app8_test_…`).
- An on-disk cache scoped per `(appId, screenId, version)`.
- Native fallback closures for resilience when a render fails.
- Host observability — subscribe to DSL `.emit` action events, observe
  analytics events (auto-fired and author-declared), and override the
  active translation locale.
- Render telemetry callbacks.

If you need full control over how DSL is fetched (custom API, offline-only),
use App8Engine directly with your own `App8DataSource`.

> **Status — pre-1.0.** The API may change between `0.x` releases; breaking
> changes bump the minor version. SemVer guarantees begin at `1.0`.

## Requirements

- **iOS 18+** — the minimum is shared with the App8Engine rendering core, and
  the SDK is written for Swift 6 strict concurrency (`@MainActor`-isolated
  throughout).
- **Swift 6.1+**

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/appeight/app8-ios-cloud-sdk.git", from: "0.2.2"),
```

Then add `App8Cloud` to your target's dependencies.

## Quick start

Create one instance and keep a strong reference to it — it owns the cache and
the rendering engine, so hold it on your app or scene delegate (not a local
variable). All `App8Cloud` APIs are main-actor isolated.

```swift
import App8Cloud

guard let apiURL = URL(string: "https://your-api.example.com/sdk/v1") else { return }

let cloud = App8Cloud.instance(
    token: "app8_live_abc123xyz",   // your App8 SDK token
    appId: "com.partner.flagship",  // your App8 app identifier
    environment: .custom(apiURL)
)

// Optional: identity attributes for analytics dashboards.
cloud.setAttributes([
    "userId": MyAuth.currentUserId ?? "",
    "plan":   MyAuth.currentPlan ?? "free",
])
```

`screen(...)` is `async` and never throws — it renders your fallback view
controller on failure. Call it from a `Task`:

```swift
// UIKit
Task {
    let vc = await cloud.screen(id: "home", version: nil, parameters: [:]) { error in
        NativeHomeViewController(error: error)
    }
    present(vc, animated: true)
}
```

A throwing variant — `try await cloud.screen(id:version:parameters:)` — is also
available if you'd rather handle errors yourself.

SwiftUI handles the async load for you — pass a `placeholder` and a `fallback`:

```swift
App8CloudScreenView(
    instance: cloud,
    screenId: "home",
    placeholder: { ProgressView() },
    fallback: { error in NativeHomeView(error: error) }
)
```

If the device is offline on first launch with nothing cached, the render fails
and your fallback is shown; once a screen is cached it renders without network.

## Preloading

The first `screen(...)` call makes several sequential network round-trips
(manifest, styles, components, screen). Warm the cache at launch so the first
navigation is instant:

```swift
Task.detached(priority: .background) {
    await cloud.prefetchAll()   // discovers and warms every screen + assets
}
```

`prefetchAll()` fetches the app manifest, styles, components, every reachable
screen, and the asset manifest. To warm only specific screens instead:

```swift
await cloud.prefetch(screens: [.init(id: "home"), .init(id: "settings")])
```

Preloading is idempotent (cached entries short-circuit), best-effort
(per-screen failures don't abort the batch), and cancellable via
`cloud.cancelPrefetch()`.

## Authoring screens

App8Cloud is the *client* half — it fetches and renders screens, it does not
create them. A "screen" is a DSL document (JSON) served by the API over
`/sdk/v1/`. Authoring tooling is outside the scope of this package.

## Native interop

DSL screens signal the host app rather than calling native code directly: a
control fires a URL and your app handles it, deep-link style. The `App8SDKDemo`
sample shows a host catching DSL-fired `openURL` events and pushing a native
screen in response.

## Events & analytics

`App8Cloud.Instance` exposes the engine's two in-process buses directly so
your host can react to what users do inside DSL screens and route analytics
to your own tracker (Mixpanel, Amplitude, Segment, …).

### Action events (DSL `.emit`)

DSL authors can fire named events from any component via the `.emit` action
(e.g. `connect.tapped`, `user.selected`). Subscribe by name, by screen,
or to everything:

```swift
let sub = cloud.subscribe(to: "connect.tapped") { event in
    MyAnalytics.track("connect_tapped", properties: event.payload)
}
// Hold `sub` for as long as you want events; let it deallocate to unsubscribe.
```

Combine and `AsyncStream` variants are available as `cloud.events` and
`cloud.eventStream`. To register a single handler delegate-style, use
`cloud.setEventHandler(_:)` (the handler is held weakly).

### Analytics events

The engine auto-fires `app8_*` lifecycle events — `app8_screen_appeared`,
`app8_screen_dismissed`, `app8_component_tapped`, `app8_navigation_pushed`,
`app8_url_opened`. The cloud SDK adds `app8_render_failed` and
`app8_render_fallback` to the same bus. Author-declared analytics events
(set via an `analytics` JSON binding in the DSL) flow on the same bus.

The canonical pattern is one handler that proxies every event to your real
tracker:

```swift
final class App8ToMixpanel: App8AnalyticsHandler {
    func app8DidTrack(_ event: App8AnalyticsEvent) {
        Mixpanel.mainInstance().track(
            event: event.name,
            properties: event.properties
        )
    }
}
cloud.setAnalyticsHandler(App8ToMixpanel())  // held weakly
```

`cloud.observeAnalytics(_:)`, `cloud.analytics` (Combine), and
`cloud.analyticsStream` (`AsyncStream`) are also available.

Tune which auto-events fire by mutating `cloud.analyticsConfig` —
`autoScreenEvents`, `autoComponentTaps`, `autoNavigationEvents`,
`autoUrlEvents` (all default `true`). The cloud SDK's render-lifecycle
emissions are gated by `autoScreenEvents`.

> **Privacy note.** Both buses are entirely in-process. Nothing on these
> buses is transmitted to App8's servers — that path is the separate,
> opt-out remote telemetry (`telemetry: .disabled`).

### Locale override

The engine uses the device locale for `{"$i18n": …}` lookups and
locale-aware formatters by default. Override it:

```swift
cloud.setLocale("fr-FR")     // force French
print(cloud.currentLocale)    // "fr-FR"
cloud.setLocale(nil)          // revert to device default
```

## Privacy & App Store

- **Telemetry** — the SDK sends anonymous render/usage telemetry to the API
  by default. Pass `telemetry: .disabled` to `App8Cloud.instance(...)` to turn
  it off. The SDK mints no device identifier.
- **Identity** — attributes you pass to `setAttributes(_:)` are sent to the
  API for analytics; only what you set is transmitted.
- **Privacy manifest** — the package ships `PrivacyInfo.xcprivacy`.
- **App Store review** — dynamic UI is permitted under App Review
  Guideline 4.7. Don't ship new permissions or core functionality via DSL.
- **Token** — `app8_live_…` is a *publishable* client token, not a secret; it
  is embedded in your app binary. Security comes from server-side scoping and
  rate-limiting, not token secrecy.

## Sample apps

The App8 iOS repository includes two runnable partner-style hosts —
`App8CloudDemo` (minimal) and `App8SDKDemo` (embeds a cloud screen as a child
view controller) — useful as end-to-end integration references.

## Support

Report bugs and ask integration questions via GitHub Issues on this repository.

## License

Apache 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
