import Foundation

/// `type` is the discriminator. Valid values:
/// - `sdk_init` — fires once per Instance init.
/// - `screen_render` — fires on every successful screen or app render.
/// - `screen_presented` — fires once the host has laid out the returned VC at
///   a non-zero size. Carries the container dimensions and device idiom so we
///   can see what surface partners are actually integrating us into. Won't
///   fire if the VC is rendered but never installed in a window.
/// - `screen_render_failed` — fires on every render failure (throwing or fallback path).
/// - `render_fallback` — fires when the partner's fallback closure is actually invoked.
/// - `screen_availability_shortcircuit` — fires when `screen(id:)` returns
///   `.screenNotFound` or `.dslVersionUnsupported` without a network round
///   trip because the local screen catalog ruled the call out. Always
///   accompanied by a `screen_render_failed` for the same call, but carries
///   distinct catalog-freshness context (`catalogAge_ms`, `catalogSource`,
///   `catalogScreenCount`) so the backend can measure how often the catalog
///   spares partners a blank screen.
/// - `prefetch_completed` — fires when a `prefetch(...)` / `prefetchAll(...)` batch finishes.
/// - `asset_fetch_failed` — fires when an asset blob fetch fails after retries.
/// - `attributes_set` — fires when `setAttributes(...)` is called.
/// - `attributes_cleared` — fires when `clearAttributes()` is called.
/// - `custom` — fires from the public `track(name:context:)` API.
///
/// Note: the fallback-closure variants emit BOTH `screen_render_failed` and
/// `render_fallback` for one failure. Dedupe by
/// `(screenKey, reason, occurredAt-bucket)` or count one event type.
struct TelemetryEvent: @unchecked Sendable {
    let type: String
    let occurredAt: Date
    let screenKey: String?
    let context: [String: Any]?

    func toWireDict(formatter: ISO8601DateFormatter) -> [String: Any] {
        var d: [String: Any] = [
            "type": type,
            "occurredAt": formatter.string(from: occurredAt)
        ]
        if let screenKey { d["screenKey"] = screenKey }
        if let context, !context.isEmpty { d["context"] = context }
        return d
    }
}

/// Stable string tag for an `App8Cloud.Error`. Shared between `render_fallback`,
/// `screen_render_failed`, and `asset_fetch_failed` so the backend can group
/// by reason across event types.
func telemetryReasonString(_ error: App8Cloud.Error) -> String {
    switch error {
    case .authInvalid:                 return "auth_invalid"
    case .appNotFound:                 return "app_not_found"
    case .screenNotFound:               return "screen_not_found"
    case .screenVersionNotFound:        return "screen_version_not_found"
    case .noNetwork:                   return "network_unavailable"
    case .timeout:                     return "timeout"
    case .serverError:                 return "server_error"
    case .decodeFailed:                return "decode_failed"
    case .dslVersionUnsupported:        return "dsl_version_unsupported"
    case .offlineResourceMissing:       return "offline_resource_missing"
    case .offlineBundleInvalid:         return "offline_bundle_invalid"
    case .engine:                      return "engine_error"
    }
}

/// Strip non-JSON-encodable values (closures, custom classes, NaN, etc.) recursively.
func sanitizeJSONDict(_ input: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (k, v) in input {
        if let safe = sanitizeJSONValue(v) {
            out[k] = safe
        }
    }
    return out
}

private func sanitizeJSONValue(_ value: Any) -> Any? {
    if value is NSNull { return NSNull() }
    if let s = value as? String { return s }
    if let b = value as? Bool, type(of: value) == Bool.self { return b }
    if let n = value as? NSNumber {
        // NSNumber boxes Bool/Int/Double — disambiguate via objCType.
        let t = String(cString: n.objCType)
        if t == "c" || t == "B" { return n.boolValue }
        if t == "f" || t == "d" {
            let dbl = n.doubleValue
            return dbl.isFinite ? dbl : nil
        }
        return n.intValue
    }
    if let arr = value as? [Any] {
        return arr.compactMap(sanitizeJSONValue)
    }
    if let dict = value as? [String: Any] {
        return sanitizeJSONDict(dict)
    }
    return nil
}
