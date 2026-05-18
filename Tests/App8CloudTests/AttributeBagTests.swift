//
//  AttributeBagTests.swift
//  App8CloudTests
//

import XCTest
@testable import App8Cloud

final class AttributeBagTests: XCTestCase {

    private func makeBag() -> AttributeBag {
        AttributeBag(diagnostics: .disabled)
    }

    func testInitialBagIsEmpty() {
        let bag = makeBag()
        XCTAssertTrue(bag.snapshot.isEmpty)
    }

    func testSetAttributesMerges() {
        let bag = makeBag()
        bag.setAttributes(["userId": "u1", "plan": "pro"])
        XCTAssertEqual(bag.snapshot["userId"], "u1")
        XCTAssertEqual(bag.snapshot["plan"], "pro")
        bag.setAttributes(["plan": "enterprise", "country": "US"])
        XCTAssertEqual(bag.snapshot["userId"], "u1", "userId should persist across calls")
        XCTAssertEqual(bag.snapshot["plan"], "enterprise", "later keys should override")
        XCTAssertEqual(bag.snapshot["country"], "US")
    }

    func testReservedKeyIsRejected() {
        let bag = makeBag()
        let rejected = bag.setAttributes([
            "userId": "u1",
            "$deviceId": "no",
            "$debug": "no",
        ])
        XCTAssertEqual(Set(rejected), Set(["$deviceId", "$debug"]))
        XCTAssertNil(bag.snapshot["$deviceId"], "reserved keys must not be stored")
        XCTAssertNil(bag.snapshot["$debug"])
        XCTAssertEqual(bag.snapshot["userId"], "u1", "non-reserved keys still merge")
    }

    func testClearAttributesRemovesAll() {
        let bag = makeBag()
        bag.setAttributes(["userId": "u1", "plan": "pro", "country": "US"])
        bag.clearAttributes()
        XCTAssertTrue(bag.snapshot.isEmpty)
    }
}
