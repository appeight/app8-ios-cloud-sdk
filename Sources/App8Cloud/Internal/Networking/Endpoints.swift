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
    case translations(appId: String)

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
        case .translations(let appId):
            return "/apps/\(appId)/translations"
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
        case .translations(let appId):
            return "translations:\(appId)"
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
