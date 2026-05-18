import Foundation

/// `type` is the discriminator: `sdk_init`, `render_fallback`, or `custom`.
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
