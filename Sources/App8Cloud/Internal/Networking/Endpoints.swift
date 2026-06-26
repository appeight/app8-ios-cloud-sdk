import Foundation

/// /sdk/v1 endpoints (GET except .telemetry).
enum Endpoint {
    case manifest(appId: String)
    case screen(appId: String, screenId: String, version: String?)
    case styles(appId: String)
    case components(appId: String)
    case assetsManifest(appId: String)
    case listScreens(appId: String)
    case telemetry(appId: String)
    /// Full all-locales bundle the engine loads into `TranslationStore`.
    case localizations(appId: String)
    // Published flows (gated multi-screen bundles).
    case listFlows(appId: String)
    case flow(appId: String, flowKey: String, version: String?)
    /// Flow-scoped member screen — NOT the same as `.screen`. These bytes are
    /// only reachable through the flow channel.
    case flowScreen(appId: String, flowKey: String, screenKey: String, version: String?)
    /// Flow-pinned styles / components (the flow's design-system version set).
    case flowStyles(appId: String, flowKey: String, version: String?)
    case flowComponents(appId: String, flowKey: String, version: String?)

    var path: String {
        switch self {
        case .manifest(let appId):
            return "/apps/\(appId)/manifest"
        case .screen(let appId, let screenId, _):
            return "/apps/\(appId)/screens/\(screenId)"
        case .styles(let appId):
            return "/apps/\(appId)/styles"
        case .components(let appId):
            return "/apps/\(appId)/components"
        case .assetsManifest(let appId):
            return "/apps/\(appId)/assets/manifest"
        case .listScreens(let appId):
            return "/apps/\(appId)/screens"
        case .telemetry(let appId):
            return "/apps/\(appId)/telemetry"
        case .localizations(let appId):
            return "/apps/\(appId)/localizations"
        case .listFlows(let appId):
            return "/apps/\(appId)/flows"
        case .flow(let appId, let flowKey, _):
            return "/apps/\(appId)/flows/\(flowKey)"
        case .flowScreen(let appId, let flowKey, let screenKey, _):
            return "/apps/\(appId)/flows/\(flowKey)/screens/\(screenKey)"
        case .flowStyles(let appId, let flowKey, _):
            return "/apps/\(appId)/flows/\(flowKey)/styles"
        case .flowComponents(let appId, let flowKey, _):
            return "/apps/\(appId)/flows/\(flowKey)/components"
        }
    }

    var method: String {
        switch self {
        case .telemetry: return "POST"
        default: return "GET"
        }
    }

    var queryItems: [URLQueryItem] {
        switch self {
        case .screen(_, _, let version?):
            return [URLQueryItem(name: "version", value: version)]
        case .flow(_, _, let version?):
            return [URLQueryItem(name: "version", value: version)]
        case .flowScreen(_, _, _, let version?):
            return [URLQueryItem(name: "version", value: version)]
        case .flowStyles(_, _, let version?):
            return [URLQueryItem(name: "version", value: version)]
        case .flowComponents(_, _, let version?):
            return [URLQueryItem(name: "version", value: version)]
        default:
            return []
        }
    }

    var coalesceKey: String {
        switch self {
        case .manifest(let appId):
            return "manifest:\(appId)"
        case .screen(let appId, let screenId, let version):
            return "screen:\(appId):\(screenId):\(version ?? "_latest")"
        case .styles(let appId):
            return "styles:\(appId)"
        case .components(let appId):
            return "components:\(appId)"
        case .assetsManifest(let appId):
            return "assets:\(appId)"
        case .listScreens(let appId):
            return "list-screens:\(appId)"
        case .telemetry(let appId):
            return "telemetry:\(appId)"
        case .localizations(let appId):
            return "localizations:\(appId)"
        case .listFlows(let appId):
            return "list-flows:\(appId)"
        case .flow(let appId, let flowKey, let version):
            return "flow:\(appId):\(flowKey):\(version ?? "_latest")"
        case .flowScreen(let appId, let flowKey, let screenKey, let version):
            return "flow-screen:\(appId):\(flowKey):\(screenKey):\(version ?? "_latest")"
        case .flowStyles(let appId, let flowKey, let version):
            return "flow-styles:\(appId):\(flowKey):\(version ?? "_latest")"
        case .flowComponents(let appId, let flowKey, let version):
            return "flow-components:\(appId):\(flowKey):\(version ?? "_latest")"
        }
    }

    func resolve(against base: URL) -> URL {
        let withPath = base.appendingPathComponent(path)
        guard var components = URLComponents(url: withPath, resolvingAgainstBaseURL: false) else {
            return withPath
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url ?? withPath
    }
}
