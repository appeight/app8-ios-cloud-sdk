import Foundation

/// `GET /sdk/v1/apps/{id}/screens/{id}?version=…`.
struct ScreenRenderResponse: Decodable {
    /// May differ from what the partner requested (e.g. nil → latest published).
    let servedVersion: String?
    let data: Data
    let styles: [Data]?
    let components: [Data]?
    let datasources: [String: Data]?

    enum CodingKeys: String, CodingKey {
        case servedVersion, data, styles, components, datasources
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        servedVersion = try container.decodeIfPresent(String.self, forKey: .servedVersion)
        data = try container.decodeRawJSON(forKey: .data)
        styles = try container.decodeRawJSONArrayIfPresent(forKey: .styles)
        components = try container.decodeRawJSONArrayIfPresent(forKey: .components)
        if container.contains(.datasources), try !container.decodeNil(forKey: .datasources) {
            let nested = try container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .datasources)
            var out: [String: Data] = [:]
            for key in nested.allKeys {
                out[key.stringValue] = try nested.decodeRawJSON(forKey: key)
            }
            datasources = out
        } else {
            datasources = nil
        }
    }
}

/// `GET /sdk/v1/apps/{id}/manifest`.
struct AppManifestResponse: Decodable {
    let configuration: Data

    enum CodingKeys: String, CodingKey {
        case configuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try container.decodeRawJSON(forKey: .configuration)
    }
}

/// `GET /sdk/v1/apps/{id}/flows/{flowKey}?version=…` — the lazy flow manifest.
/// Member screen bytes are fetched separately from
/// `/flows/{flowKey}/screens/{screenKey}`.
struct FlowManifestResponse: Decodable {
    let servedVersion: String?
    let startScreen: String
    let minDslVersion: String?
    let screens: [ScreenRef]
    /// App-level transition registry pinned with the flow. Raw JSON objects,
    /// injected into the synthetic flow manifest so screens that reference a
    /// named transition by id resolve it. `nil`/empty until the backend ships
    /// the flow's own pinned set — the SDK then falls back to the app-level
    /// registry (see `FlowScopedDataSource.getApp`).
    let transitions: [Data]?

    struct ScreenRef: Decodable {
        let screenKey: String
        let updatedAt: String?
    }

    enum CodingKeys: String, CodingKey {
        case servedVersion, startScreen, minDslVersion, screens, transitions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        servedVersion = try c.decodeIfPresent(String.self, forKey: .servedVersion)
        startScreen = try c.decode(String.self, forKey: .startScreen)
        minDslVersion = try c.decodeIfPresent(String.self, forKey: .minDslVersion)
        screens = try c.decode([ScreenRef].self, forKey: .screens)
        transitions = try c.decodeRawJSONArrayIfPresent(forKey: .transitions)
    }
}

// MARK: - Optional raw-JSON helpers

extension KeyedDecodingContainer {
    func decodeRawJSONArrayIfPresent(forKey key: Key) throws -> [Data]? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        let nested = try superDecoder(forKey: key)
        var unkeyed = try nested.unkeyedContainer()
        var out: [Data] = []
        while !unkeyed.isAtEnd {
            let value = try unkeyed.decode(RawJSON.self)
            out.append(try JSONSerialization.data(withJSONObject: value.value, options: []))
        }
        return out
    }
}
