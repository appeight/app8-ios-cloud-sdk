//
//  LocaleBagTests.swift
//  App8CloudTests
//

import XCTest
@testable import App8Cloud

final class LocaleBagTests: XCTestCase {

    private func makeBag() -> LocaleBag {
        LocaleBag(diagnostics: .disabled)
    }

    // MARK: - Override flow

    func test_initialOverrideIsNil() {
        let bag = makeBag()
        XCTAssertNil(bag.overrideSnapshot)
    }

    func test_setOverrideStoresCanonicalisedValue() {
        let bag = makeBag()
        bag.setOverride("fr-CA")
        XCTAssertEqual(bag.overrideSnapshot, "fr-CA")
        XCTAssertEqual(bag.currentLocale(), "fr-CA")
    }

    func test_setOverrideNilRevertsToDeviceDefault() {
        let bag = makeBag()
        bag.setOverride("zh-CN")
        bag.setOverride(nil)
        XCTAssertNil(bag.overrideSnapshot)
        // currentLocale should now reflect device default (not zh-CN). The
        // exact device locale varies across CI environments, so we assert
        // the negative rather than a specific value.
        XCTAssertNotEqual(bag.currentLocale(), "zh-CN")
    }

    // MARK: - Canonicalisation (must match backend lib/locale-negotiate.ts)

    func test_underscoreSeparatorBecomesDash() {
        let bag = makeBag()
        bag.setOverride("fr_CA")
        XCTAssertEqual(bag.overrideSnapshot, "fr-CA")
    }

    func test_mixedCaseNormalisesToLangLowerRegionUpper() {
        let bag = makeBag()
        bag.setOverride("FR-ca")
        XCTAssertEqual(bag.overrideSnapshot, "fr-CA")
    }

    func test_languageOnlyTagIsLowercased() {
        let bag = makeBag()
        bag.setOverride("EN")
        XCTAssertEqual(bag.overrideSnapshot, "en")
    }

    func test_emptyStringIsRejected() {
        // Empty input is treated as "no override". Prevents accidentally
        // wiping the device default with an unintended setLocale("").
        let bag = makeBag()
        bag.setOverride("")
        XCTAssertNil(bag.overrideSnapshot)
    }

    func test_garbageTagIsRejected() {
        // Inputs that aren't a recognisable BCP-47 prefix are dropped so
        // they don't end up as Accept-Language values or cache keys.
        let bag = makeBag()
        bag.setOverride("not-a-locale-tag-at-all-12345")
        XCTAssertNil(bag.overrideSnapshot)
    }
}
