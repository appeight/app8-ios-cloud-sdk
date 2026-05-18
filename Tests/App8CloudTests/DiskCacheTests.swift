//
//  DiskCacheTests.swift
//  App8CloudTests
//

import XCTest
@testable import App8Cloud

@MainActor
final class DiskCacheTests: XCTestCase {

    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("App8CloudDiskCacheTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func makeCache(versionsToKeep: Int = 100) -> DiskCache {
        let layout = CacheLayout(cacheRoot: tempRoot, appId: "test-app")
        return DiskCache(layout: layout, versionsToKeep: versionsToKeep, diagnostics: .disabled)
    }

    func testWriteAndReadAppLevel() {
        let cache = makeCache()
        // Note: writeStyles uses encodeArrayOfBlobs which assumes each
        // entry is itself valid JSON (the production caller always feeds
        // pre-encoded DSL JSON), so test fixtures must be JSON-shaped.
        let styleA = Data(#"{"id":"a"}"#.utf8)
        let styleB = Data(#"{"id":"b"}"#.utf8)

        XCTAssertTrue(cache.writeManifest(Data("MANIFEST".utf8)))
        XCTAssertTrue(cache.writeStyles([styleA, styleB]))
        XCTAssertTrue(cache.writeComponent(componentId: "card", data: Data("CARD".utf8)))
        XCTAssertTrue(cache.writeDatasource(category: "datamocks", name: "products",
                                            data: Data("DS".utf8)))
        cache.touchMeta()

        XCTAssertTrue(cache.hasUsableAppCache())
        XCTAssertEqual(cache.readManifest(), Data("MANIFEST".utf8))
        XCTAssertEqual(cache.readStyles().count, 2)
        XCTAssertEqual(cache.readComponent(componentId: "card"), Data("CARD".utf8))
        XCTAssertEqual(cache.readDatasource(category: "datamocks", name: "products"), Data("DS".utf8))
    }

    func testWriteAndReadScreenWithVersion() {
        let cache = makeCache()
        // Latest (unpinned)
        XCTAssertTrue(cache.writeScreen(screenId: "home", version: nil, data: Data("LATEST".utf8)))
        // Pinned versions
        XCTAssertTrue(cache.writeScreen(screenId: "home", version: "v3", data: Data("V3".utf8)))
        XCTAssertTrue(cache.writeScreen(screenId: "home", version: "v4", data: Data("V4".utf8)))

        XCTAssertEqual(cache.readScreen(screenId: "home", version: nil), Data("LATEST".utf8))
        XCTAssertEqual(cache.readScreen(screenId: "home", version: "v3"), Data("V3".utf8))
        XCTAssertEqual(cache.readScreen(screenId: "home", version: "v4"), Data("V4".utf8))
        XCTAssertNil(cache.readScreen(screenId: "home", version: "v99"),
                     "Missing pinned version returns nil")
    }

    func testEnumerateScreenIds() {
        let cache = makeCache()
        cache.writeScreen(screenId: "home", version: nil, data: Data("X".utf8))
        cache.writeScreen(screenId: "settings", version: "v2", data: Data("Y".utf8))
        cache.writeScreen(screenId: "profile", version: nil, data: Data("Z".utf8))

        XCTAssertEqual(Set(cache.enumerateScreenIds()), Set(["home", "settings", "profile"]))
    }

    func testClearScreen() {
        let cache = makeCache()
        cache.writeScreen(screenId: "home", version: nil, data: Data("X".utf8))
        cache.writeScreen(screenId: "home", version: "v3", data: Data("Y".utf8))
        cache.writeScreen(screenId: "settings", version: nil, data: Data("Z".utf8))

        cache.clearScreen(id: "home")
        XCTAssertNil(cache.readScreen(screenId: "home", version: nil))
        XCTAssertNil(cache.readScreen(screenId: "home", version: "v3"))
        XCTAssertEqual(cache.readScreen(screenId: "settings", version: nil), Data("Z".utf8))
    }

    func testClearAll() {
        let cache = makeCache()
        cache.writeManifest(Data("M".utf8))
        cache.writeScreen(screenId: "home", version: nil, data: Data("S".utf8))
        cache.touchMeta()

        cache.clearAll()
        XCTAssertNil(cache.readManifest())
        XCTAssertNil(cache.readScreen(screenId: "home", version: nil))
        XCTAssertFalse(cache.hasUsableAppCache())
    }

    func testVersionPruningKeepsRecentAndLatest() {
        let cache = makeCache(versionsToKeep: 2)
        cache.writeScreen(screenId: "home", version: nil, data: Data("LATEST".utf8))
        for v in ["v1", "v2", "v3", "v4"] {
            cache.writeScreen(screenId: "home", version: v, data: Data(v.utf8))
            // Distinct modification times so prune ordering is deterministic.
            Thread.sleep(forTimeInterval: 0.01)
        }
        // `_latest` always survives pruning.
        XCTAssertEqual(cache.readScreen(screenId: "home", version: nil), Data("LATEST".utf8))
        // Only the 2 most-recently-written versioned files remain.
        XCTAssertEqual(cache.readScreen(screenId: "home", version: "v4"), Data("v4".utf8))
        XCTAssertEqual(cache.readScreen(screenId: "home", version: "v3"), Data("v3".utf8))
        XCTAssertNil(cache.readScreen(screenId: "home", version: "v2"), "v2 should be pruned")
        XCTAssertNil(cache.readScreen(screenId: "home", version: "v1"), "v1 should be pruned")
    }

    func testSchemaMismatchInvalidatesCache() {
        let cache = makeCache()
        cache.writeManifest(Data("X".utf8))
        cache.touchMeta()

        let badMeta = #"""
        {"schemaVersion":"v999","sdkVersion":"0.0.0","fetchedAt":"2026-01-01T00:00:00Z"}
        """#.data(using: .utf8)!
        try? badMeta.write(to: cache.layout.metaFile)

        XCTAssertFalse(cache.hasUsableAppCache())
    }
}
