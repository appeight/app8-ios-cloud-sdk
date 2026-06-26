import Foundation
import App8Engine

/// An `App8DataSource` that scopes the engine to a single published flow.
///
/// - `getApp()` synthesizes a one-flow manifest (`navigation.startFlow` =
///   `flowKey`) from the fetched flow manifest, so the engine's flow machinery
///   runs unchanged.
/// - `getScreen(_:)` routes to the flow-scoped endpoint
///   (`/flows/{flowKey}/screens/{screenKey}`) via the parent's
///   `getFlowScreenData`, keeping a published flow's member screens off the
///   public single-screen channel.
/// - Everything else (styles, components, assets, translations) delegates to
///   the app-level `RenderingDataSource`. Flow-level deps auto-pin the app's
///   latest versions at publish time, so the app-level resources are the
///   correct set for v1.
final class FlowScopedDataSource: App8DataSource, @unchecked Sendable {

    private let parent: RenderingDataSource
    private let flowKey: String
    private let version: String?
    private let startScreen: String
    private let screenKeys: [String]
    /// The flow's own pinned transition registry (raw JSON objects), when the
    /// backend ships it. Empty → fall back to the app-level registry.
    private let flowTransitions: [Data]

    init(
        parent: RenderingDataSource,
        flowKey: String,
        version: String?,
        manifest: FlowManifestResponse
    ) {
        self.parent = parent
        self.flowKey = flowKey
        self.version = version
        self.startScreen = manifest.startScreen
        self.screenKeys = manifest.screens.map(\.screenKey)
        self.flowTransitions = manifest.transitions ?? []
    }

    func getApp() async throws -> Data {
        var manifest: [String: Any] = [
            "title": flowKey,
            "defaultUserInterfaceStyle": "light",
            "navigation": [
                "startFlow": flowKey,
                "flows": [
                    ["id": flowKey, "startScreen": startScreen]
                ],
            ],
        ]
        // Inject the transition registry so screens that reference a named
        // transition by id (e.g. a push/fade) animate instead of falling back to
        // UIKit's plain slide. Prefer the flow's own pinned set; until the
        // backend ships it, borrow the app-level registry.
        let transitions = await resolveTransitions()
        if !transitions.isEmpty {
            manifest["transitions"] = transitions
        }
        return try JSONSerialization.data(withJSONObject: manifest, options: [])
    }

    /// Pinned flow transitions when present, else the app-level registry.
    private func resolveTransitions() async -> [[String: Any]] {
        let source = flowTransitions.isEmpty ? await parent.appManifestTransitions() : flowTransitions
        return source.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func getScreen(screenId: String) async throws -> Data {
        try await parent.getFlowScreenData(flowKey: flowKey, screenKey: screenId, version: version)
    }

    func getAllScreenIds() async throws -> [String]? {
        screenKeys.isEmpty ? nil : screenKeys
    }

    // MARK: - Flow-pinned design system

    /// The flow's pinned style versions (backend falls back to app-level latest
    /// when the flow pinned none). The engine snapshots these once at init.
    func getStyles() async throws -> [Data] {
        try await parent.getFlowStyles(flowKey: flowKey, version: version)
    }

    func getComponents() async throws -> [Data] {
        try await parent.getFlowComponents(flowKey: flowKey, version: version)
    }

    // MARK: - App-level passthrough

    func getComponent(componentId: String) async throws -> Data {
        try await parent.getComponent(componentId: componentId)
    }
    func getAsset(assetId: String?, assetName: String?) async throws -> Data? {
        try await parent.getAsset(assetId: assetId, assetName: assetName)
    }
    func getDatasource(screenId: String, datasourceId: String) async throws -> Data {
        // Datasources resolve through the member screen's inline payload at
        // render time; fall back to the app-level datasource cache otherwise.
        try await parent.getDatasource(screenId: screenId, datasourceId: datasourceId)
    }
    // Localizations stay app-level for v1: they're app-wide (all locales × keys)
    // and the public localization channel serves latest, so per-flow pinning is
    // deferred (would need a `published_flow_version_localizations` table +
    // endpoint). Delegates to the app-level translations.
    func getTranslations() async throws -> Data { try await parent.getTranslations() }

    // Streaming unsupported for flows in v1.
    func streamScreen(screenId: String) -> AsyncStream<Data>? { nil }
    func streamDatasource(screenId: String, datasourceId: String, componentPath: String?) -> AsyncStream<Data>? { nil }
    func streamStyles() -> AsyncStream<Data>? { nil }
}
