import Foundation

/// Imports a `.a8pack` directory into the App8Cloud disk cache, so the existing
/// cache-first read path renders it offline and refreshes it when online.
/// See `Docs/OFFLINE_BUNDLE_FORMAT.md`.
@MainActor
enum OfflineBundleImporter {

    static func importBundle(
        directory: URL,
        instanceAppId: String,
        maxSupportedDslVersion: String,
        diskCache: DiskCache?,
        assetCache: AssetCache?,
        fontRegistry: FontRegistry,
        diagnostics log: Diagnostics
    ) throws -> App8Cloud.OfflineImportSummary {

        guard let diskCache else {
            throw App8Cloud.Error.offlineBundleInvalid(
                reason: "disk cache is disabled; enable DiskCachePolicy to import bundles")
        }

        let manifest = try OfflineManifest.load(fromDirectory: directory)

        guard manifest.bundleFormat <= OfflineManifest.supportedBundleFormat else {
            throw App8Cloud.Error.offlineBundleInvalid(
                reason: "bundleFormat \(manifest.bundleFormat) is newer than supported \(OfflineManifest.supportedBundleFormat)")
        }
        guard manifest.appId == instanceAppId else {
            throw App8Cloud.Error.offlineBundleInvalid(
                reason: "bundle appId '\(manifest.appId)' != instance appId '\(instanceAppId)'")
        }
        if let dsl = manifest.dslVersion, !dslVersionIsSupported(dsl, max: maxSupportedDslVersion) {
            throw App8Cloud.Error.dslVersionUnsupported(found: dsl, max: maxSupportedDslVersion)
        }

        let payload = try manifest.decodePayload()
        let version = manifest.version

        // App-wide pieces (both bundle types).
        if let loc = payload["localizations"], let data = jsonData(loc) {
            diskCache.writeLocalizations(data)
            diskCache.updateAppResourceMeta(key: "localizations",
                                            meta: resourceMeta(payload, "localizations", body: data))
        }
        if let ds = payload["datasources"] as? [String: Any] {
            for (compoundKey, value) in ds {
                guard let data = jsonData(value) else { continue }
                let parts = compoundKey.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2 else {
                    log.warning("offline import: datasource key '\(compoundKey)' is not 'category/name' — skipping")
                    continue
                }
                diskCache.writeDatasource(category: parts[0], name: parts[1], data: data)
            }
        }

        let screensImported: Int
        switch manifest.type {
        case "app8.offline.screen":
            screensImported = importScreenBundle(payload, version: version, diskCache: diskCache)
        case "app8.offline.flow":
            screensImported = importFlowBundle(payload, flowKey: manifest.key, version: version,
                                               diskCache: diskCache, log: log)
        default:
            throw App8Cloud.Error.offlineBundleInvalid(reason: "unknown bundle type '\(manifest.type)'")
        }

        // Seal app meta so `hasUsableAppCache()` is true and disk-first reads engage.
        diskCache.touchMeta(dslVersion: manifest.dslVersion)

        let (assets, fonts) = try importAssets(manifest.assets, directory: directory,
                                               assetCache: assetCache, fontRegistry: fontRegistry, log: log)

        log.debug("offline import: \(manifest.type) key='\(manifest.key)' version=\(version ?? "latest") " +
                  "screens=\(screensImported) assets=\(assets) fonts=\(fonts)")
        return .init(type: manifest.type, key: manifest.key, version: version,
                     screensImported: screensImported, assetsImported: assets, fontsRegistered: fonts)
    }

    // MARK: - Screen bundle

    private static func importScreenBundle(_ payload: [String: Any], version: String?, diskCache: DiskCache) -> Int {
        if let app = payload["app"], let data = jsonData(app) {
            diskCache.writeManifest(data)
            diskCache.updateAppResourceMeta(key: "manifest", meta: resourceMeta(payload, "manifest", body: data))
        }
        // Write styles.json even when empty so `loadStylesIfNeeded` reads disk
        // instead of falling through to the network.
        let styles = blobArray(payload["styles"])
        diskCache.writeStyles(styles)
        diskCache.updateAppResourceMeta(key: "styles",
                                        meta: resourceMeta(payload, "styles", body: jsonData(payload["styles"]) ?? emptyArray))

        diskCache.writeComponents(blobArray(payload["components"]), idResolver: componentId)

        var count = 0
        if let screens = payload["screens"] as? [String: Any] {
            for (screenKey, value) in screens {
                guard let entry = value as? [String: Any],
                      let dsl = entry["data"], let data = jsonData(dsl) else { continue }
                let v = entry["version"] as? String ?? version
                // Both the explicit version and `_latest`, so `screen(id:)`
                // (latest) and `screen(id:version:)` both resolve offline.
                diskCache.writeScreen(screenId: screenKey, version: v, data: data)
                diskCache.writeScreen(screenId: screenKey, version: nil, data: data)
                diskCache.writeScreenMeta(
                    ScreenMeta(servedVersion: v, requestedVersion: v,
                               updatedAt: entry["updatedAt"] as? String,
                               contentHash: ContentHash.sha256Hex(data)),
                    screenId: screenKey)
                count += 1
            }
        }
        return count
    }

    // MARK: - Flow bundle

    private static func importFlowBundle(_ payload: [String: Any], flowKey: String, version: String?,
                                         diskCache: DiskCache, log: Diagnostics) -> Int {
        guard let flow = payload["flow"] as? [String: Any] else {
            log.warning("offline import: flow bundle is missing its 'flow' payload")
            return 0
        }
        if let m = flow["manifest"], let data = jsonData(m) {
            diskCache.writeFlowManifest(data, flowKey: flowKey, version: version)
            diskCache.writeFlowManifest(data, flowKey: flowKey, version: nil)
        }
        let styles = blobArray(flow["styles"])
        diskCache.writeFlowStyles(styles, flowKey: flowKey, version: version)
        diskCache.writeFlowStyles(styles, flowKey: flowKey, version: nil)

        let components = blobArray(flow["components"])
        diskCache.writeFlowComponents(components, flowKey: flowKey, version: version)
        diskCache.writeFlowComponents(components, flowKey: flowKey, version: nil)

        var count = 0
        if let screens = flow["screens"] as? [String: Any] {
            for (screenKey, value) in screens {
                guard let data = jsonData(value) else { continue }
                diskCache.writeFlowScreen(data, flowKey: flowKey, version: version, screenKey: screenKey)
                diskCache.writeFlowScreen(data, flowKey: flowKey, version: nil, screenKey: screenKey)
                count += 1
            }
        }
        return count
    }

    // MARK: - Assets + fonts

    private static func importAssets(_ descriptors: [OfflineAssetDescriptor], directory: URL,
                                     assetCache: AssetCache?, fontRegistry: FontRegistry,
                                     log: Diagnostics) throws -> (assets: Int, fonts: Int) {
        var assetCount = 0
        var fontCount = 0
        let root = directory.standardizedFileURL

        for d in descriptors {
            // Path safety: relative, no traversal, stays under the bundle root.
            if d.path.hasPrefix("/") || d.path.split(separator: "/").contains("..") {
                throw App8Cloud.Error.offlineBundleInvalid(reason: "unsafe asset path '\(d.path)'")
            }
            let fileURL = directory.appendingPathComponent(d.path).standardizedFileURL
            guard fileURL.path.hasPrefix(root.path) else {
                throw App8Cloud.Error.offlineBundleInvalid(reason: "asset path escapes bundle: '\(d.path)'")
            }
            guard let bytes = try? Data(contentsOf: fileURL) else {
                throw App8Cloud.Error.offlineBundleInvalid(reason: "missing asset file '\(d.path)'")
            }
            if let expected = d.sha256, !expected.isEmpty {
                let actual = ContentHash.sha256Hex(bytes)
                guard actual == expected.lowercased() else {
                    throw App8Cloud.Error.offlineBundleInvalid(
                        reason: "checksum mismatch for '\(d.path)' (expected \(expected), got \(actual))")
                }
            }

            // Seed under every key the engine might resolve by: assetId, filename,
            // basename, and descriptor name. `getAsset` uses `assetId ?? assetName`.
            var keys = Set<String>()
            for k in [d.id, d.filename, d.name].compactMap({ $0 }) where !k.isEmpty { keys.insert(k) }
            if let filename = d.filename {
                let base = (filename as NSString).deletingPathExtension
                if !base.isEmpty { keys.insert(base) }
            }
            if let assetCache {
                for key in keys { assetCache.write(key: key, data: bytes) }
            } else {
                log.warning("offline import: asset cache disabled — image '\(d.path)' will miss at render time")
            }
            assetCount += 1

            let isFont = (d.kind == "font") || FontRegistry.isFont(filename: d.filename ?? "", mimeType: d.mimeType)
            if isFont {
                let assetId = d.id ?? d.filename ?? d.path
                if fontRegistry.register(data: bytes, assetId: assetId, filename: d.filename ?? d.path) != nil {
                    fontCount += 1
                }
            }
        }
        return (assetCount, fontCount)
    }

    // MARK: - JSON helpers

    private static let emptyArray = Data("[]".utf8)

    /// Re-serialize a parsed JSON value (object/array) back to bytes.
    private static func jsonData(_ value: Any?) -> Data? {
        guard let value, JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [])
    }

    /// An array-of-objects payload → `[Data]` of each element's bytes.
    private static func blobArray(_ value: Any?) -> [Data] {
        guard let arr = value as? [Any] else { return [] }
        return arr.compactMap { jsonData($0) }
    }

    private static func componentId(_ blob: Data) -> String? {
        let json = (try? JSONSerialization.jsonObject(with: blob)) as? [String: Any]
        return json?["id"] as? String
    }

    private static func resourceMeta(_ payload: [String: Any], _ key: String, body: Data) -> ResourceMeta {
        let rm = (payload["resourceMeta"] as? [String: Any])?[key] as? [String: Any]
        return ResourceMeta(
            updatedAt: rm?["updatedAt"] as? String,
            contentHash: (rm?["contentHash"] as? String) ?? ContentHash.sha256Hex(body),
            fetchedAt: Date()
        )
    }
}
