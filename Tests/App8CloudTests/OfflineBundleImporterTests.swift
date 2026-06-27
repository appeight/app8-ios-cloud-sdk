//
//  OfflineBundleImporterTests.swift
//  App8CloudTests
//
//  Verifies that importing a `.a8pack` directory seeds the disk cache so the
//  existing cache-first read path renders offline. See Docs/OFFLINE_BUNDLE_FORMAT.md.
//

import XCTest
@testable import App8Cloud

@MainActor
final class OfflineBundleImporterTests: XCTestCase {

    private var tempRoot: URL!
    private var bundleRoot: URL!

    override func setUp() {
        super.setUp()
        let id = UUID().uuidString
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("App8CloudOfflineCache-\(id)")
        bundleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("App8CloudOfflineBundle-\(id)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        try? FileManager.default.removeItem(at: bundleRoot)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeCaches() -> (DiskCache, AssetCache, FontRegistry) {
        let layout = CacheLayout(cacheRoot: tempRoot, appId: "app-1")
        let disk = DiskCache(layout: layout, versionsToKeep: 100, diagnostics: .disabled)
        let assets = AssetCache(blobsDir: layout.assetBlobsDir,
                                byteBudget: 50 * 1024 * 1024,
                                indexFile: layout.lruIndexFile,
                                diagnostics: .disabled)
        return (disk, assets, FontRegistry(diagnostics: .disabled))
    }

    /// Write a `.a8pack` directory and return its URL. `assets` is a list of
    /// `(descriptor, fileBytes)`; the descriptor's `sha256` is filled in here.
    private func writeBundle(
        type: String,
        appId: String = "app-1",
        key: String,
        version: String?,
        dslVersion: String?,
        payload: [String: Any],
        assets: [(descriptor: [String: Any], bytes: Data)] = []
    ) throws -> URL {
        let dir = bundleRoot.appendingPathComponent("\(key).a8pack", isDirectory: true)
        let assetsDir = dir.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        var assetDescriptors: [[String: Any]] = []
        for entry in assets {
            var desc = entry.descriptor
            let bytes = entry.bytes
            let path = desc["path"] as! String
            let fileURL = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try bytes.write(to: fileURL)
            desc["sha256"] = ContentHash.sha256Hex(bytes)
            assetDescriptors.append(desc)
        }

        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        var manifest: [String: Any] = [
            "type": type,
            "name": key,
            "bundleFormat": 1,
            "appId": appId,
            "key": key,
            "content": payloadData.base64EncodedString(),
            "assets": assetDescriptors,
        ]
        if let version { manifest["version"] = version }
        if let dslVersion { manifest["dslVersion"] = dslVersion }

        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        try manifestData.write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    private func importing(_ url: URL, into caches: (DiskCache, AssetCache, FontRegistry),
                           maxDsl: String = "1.0") throws -> App8Cloud.OfflineImportSummary {
        try OfflineBundleImporter.importBundle(
            directory: url,
            instanceAppId: "app-1",
            maxSupportedDslVersion: maxDsl,
            diskCache: caches.0,
            assetCache: caches.1,
            fontRegistry: caches.2,
            diagnostics: .disabled
        )
    }

    // MARK: - Screen bundle

    func testImportScreenBundleSeedsDiskCache() throws {
        let caches = makeCaches()
        let payload: [String: Any] = [
            "app": ["id": "app-1", "title": "Demo"],
            "styles": [["id": "s1"]],
            "components": [["id": "card"]],
            "screens": [
                "home": ["version": "v3", "data": ["id": "home", "type": "view"]],
            ],
            "localizations": ["defaultLocale": "en", "locales": ["en": ["hi": "Hi"]]],
            "datasources": ["datamocks/products": ["items": []]],
        ]
        let logo = Data("PNGDATA".utf8)
        let url = try writeBundle(
            type: "app8.offline.screen", key: "home", version: "v3", dslVersion: "1.0",
            payload: payload,
            assets: [(["id": "a1", "name": "logo", "filename": "logo.png",
                       "kind": "image", "mimeType": "image/png", "path": "assets/logo.png"], logo)]
        )

        let summary = try importing(url, into: caches)
        XCTAssertEqual(summary.type, "app8.offline.screen")
        XCTAssertEqual(summary.screensImported, 1)
        XCTAssertEqual(summary.assetsImported, 1)

        let (disk, assetCache, _) = caches
        XCTAssertTrue(disk.hasUsableAppCache())
        XCTAssertNotNil(disk.readManifest())
        XCTAssertEqual(disk.readStyles().count, 1)
        XCTAssertNotNil(disk.readComponent(componentId: "card"))
        // Both the pinned version and `_latest` must be seeded.
        XCTAssertNotNil(disk.readScreen(screenId: "home", version: "v3"))
        XCTAssertNotNil(disk.readScreen(screenId: "home", version: nil))
        XCTAssertEqual(disk.readScreenMeta(screenId: "home")?.servedVersion, "v3")
        XCTAssertNotNil(disk.readLocalizations())
        XCTAssertNotNil(disk.readDatasource(category: "datamocks", name: "products"))

        // Asset resolvable by id, filename, basename, and name.
        XCTAssertEqual(assetCache.read(key: "a1"), logo)
        XCTAssertEqual(assetCache.read(key: "logo.png"), logo)
        XCTAssertEqual(assetCache.read(key: "logo"), logo)
    }

    // MARK: - Flow bundle

    func testImportFlowBundleSeedsFlowChannel() throws {
        let caches = makeCaches()
        let payload: [String: Any] = [
            "flow": [
                "manifest": ["servedVersion": "v2", "startScreen": "intro",
                             "screens": [["screenKey": "intro"]]],
                "styles": [["id": "s1"]],
                "components": [["id": "card"]],
                "screens": ["intro": ["id": "intro", "type": "view"]],
            ],
        ]
        let url = try writeBundle(
            type: "app8.offline.flow", key: "onboarding", version: "v2", dslVersion: "1.0",
            payload: payload
        )

        let summary = try importing(url, into: caches)
        XCTAssertEqual(summary.type, "app8.offline.flow")
        XCTAssertEqual(summary.screensImported, 1)

        let disk = caches.0
        // Seeded under both the explicit version and `_latest`.
        XCTAssertNotNil(disk.readFlowManifest(flowKey: "onboarding", version: "v2"))
        XCTAssertNotNil(disk.readFlowManifest(flowKey: "onboarding", version: nil))
        XCTAssertEqual(disk.readFlowStyles(flowKey: "onboarding", version: "v2")?.count, 1)
        XCTAssertEqual(disk.readFlowComponents(flowKey: "onboarding", version: nil)?.count, 1)
        XCTAssertNotNil(disk.readFlowScreen(flowKey: "onboarding", version: "v2", screenKey: "intro"))
        XCTAssertNotNil(disk.readFlowScreen(flowKey: "onboarding", version: nil, screenKey: "intro"))
    }

    // MARK: - Validation

    func testChecksumMismatchThrows() throws {
        let caches = makeCaches()
        let url = try writeBundle(
            type: "app8.offline.screen", key: "home", version: "v1", dslVersion: "1.0",
            payload: ["screens": ["home": ["data": ["id": "home", "type": "view"]]]],
            assets: [(["id": "a1", "filename": "logo.png", "kind": "image", "path": "assets/logo.png"],
                      Data("ORIGINAL".utf8))]
        )
        try Data("TAMPERED".utf8).write(to: url.appendingPathComponent("assets/logo.png"))

        XCTAssertThrowsError(try importing(url, into: caches)) { error in
            guard case App8Cloud.Error.offlineBundleInvalid = error else {
                return XCTFail("expected offlineBundleInvalid, got \(error)")
            }
        }
    }

    func testAppIdMismatchThrows() throws {
        let caches = makeCaches()
        let url = try writeBundle(
            type: "app8.offline.screen", appId: "other-app", key: "home", version: "v1",
            dslVersion: "1.0",
            payload: ["screens": ["home": ["data": ["id": "home", "type": "view"]]]]
        )
        XCTAssertThrowsError(try importing(url, into: caches)) { error in
            guard case App8Cloud.Error.offlineBundleInvalid = error else {
                return XCTFail("expected offlineBundleInvalid, got \(error)")
            }
        }
    }

    func testDslVersionTooNewThrows() throws {
        let caches = makeCaches()
        let url = try writeBundle(
            type: "app8.offline.screen", key: "home", version: "v1", dslVersion: "2.0",
            payload: ["screens": ["home": ["data": ["id": "home", "type": "view"]]]]
        )
        XCTAssertThrowsError(try importing(url, into: caches, maxDsl: "1.0")) { error in
            guard case App8Cloud.Error.dslVersionUnsupported = error else {
                return XCTFail("expected dslVersionUnsupported, got \(error)")
            }
        }
    }

    func testDslVersionCompare() {
        XCTAssertTrue(dslVersionIsSupported("1.0", max: "1.0"))
        XCTAssertTrue(dslVersionIsSupported("1.0", max: "1.0.0"))
        XCTAssertTrue(dslVersionIsSupported("1.0", max: "1.2"))
        XCTAssertFalse(dslVersionIsSupported("1.3", max: "1.2"))
        XCTAssertFalse(dslVersionIsSupported("2.0", max: "1.9"))
    }
}
