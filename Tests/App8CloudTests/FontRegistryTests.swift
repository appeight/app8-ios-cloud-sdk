//
//  FontRegistryTests.swift
//  App8CloudTests
//

import XCTest
@testable import App8Cloud

final class FontRegistryTests: XCTestCase {

    // MARK: - isFont classification

    func testIsFontByMimeType() {
        XCTAssertTrue(FontRegistry.isFont(filename: "x", mimeType: "font/ttf"))
        XCTAssertTrue(FontRegistry.isFont(filename: "x", mimeType: "font/otf"))
        XCTAssertTrue(FontRegistry.isFont(filename: "x", mimeType: "font/sfnt"))
        XCTAssertTrue(FontRegistry.isFont(filename: "x", mimeType: "application/font-sfnt"))
        XCTAssertTrue(FontRegistry.isFont(filename: "x", mimeType: "application/x-font-ttf"))
        XCTAssertTrue(FontRegistry.isFont(filename: "x", mimeType: "application/x-font-otf"))
    }

    func testIsFontByExtensionWhenMimeMissing() {
        XCTAssertTrue(FontRegistry.isFont(filename: "Inter.ttf", mimeType: nil))
        XCTAssertTrue(FontRegistry.isFont(filename: "Inter.otf", mimeType: nil))
        XCTAssertTrue(FontRegistry.isFont(filename: "Inter.ttc", mimeType: nil))
        XCTAssertTrue(FontRegistry.isFont(filename: "Inter.TTF", mimeType: nil))
        // Common case: backend uploaded as octet-stream
        XCTAssertTrue(FontRegistry.isFont(filename: "Inter.ttf", mimeType: "application/octet-stream"))
    }

    func testIsNotFont() {
        XCTAssertFalse(FontRegistry.isFont(filename: "logo.png", mimeType: "image/png"))
        XCTAssertFalse(FontRegistry.isFont(filename: "doc.pdf", mimeType: "application/pdf"))
        XCTAssertFalse(FontRegistry.isFont(filename: "script.js", mimeType: "application/javascript"))
        // WOFF/WOFF2 are out of scope (CoreText doesn't handle them natively)
        XCTAssertFalse(FontRegistry.isFont(filename: "Inter.woff", mimeType: "font/woff"))
        XCTAssertFalse(FontRegistry.isFont(filename: "Inter.woff2", mimeType: "font/woff2"))
    }

    // MARK: - register() with bad input

    func testRegisterFailsGracefullyOnGarbageBytes() {
        let registry = FontRegistry(diagnostics: .disabled)
        let bogus = Data(repeating: 0xFF, count: 64)
        let result = registry.register(data: bogus, assetId: "asset-1", filename: "fake.ttf")
        XCTAssertNil(result)
        XCTAssertTrue(registry.registeredPostScriptNames.isEmpty)
        // Failed registrations roll back the dedupe entry — so a retry
        // with valid bytes can still succeed.
        XCTAssertFalse(registry.isAssetRegistered(id: "asset-1"))
    }

    func testRegisterFailsGracefullyOnEmptyBytes() {
        let registry = FontRegistry(diagnostics: .disabled)
        let result = registry.register(data: Data(), assetId: "asset-2", filename: "empty.ttf")
        XCTAssertNil(result)
        XCTAssertFalse(registry.isAssetRegistered(id: "asset-2"))
    }

    // Note: end-to-end registration with a real .ttf is exercised
    // implicitly via your local backend test — bundling a font in the
    // test target adds tens of KB and a license attribution burden for
    // marginal coverage value (CoreText's CGFont path is well-trodden).
}
