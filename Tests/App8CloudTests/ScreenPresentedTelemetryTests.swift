//
//  ScreenPresentedTelemetryTests.swift
//  App8CloudTests
//

import XCTest
import UIKit
@testable import App8Cloud

@MainActor
final class ScreenPresentedTelemetryTests: XCTestCase {

    func testLayoutSentinelFiresOnceOnFirstNonZeroLayout() {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let calls = Locked<Int>(0)
        let captured = Locked<CGSize>(.zero)

        LayoutSentinelView.attach(to: parent) { size, _ in
            calls.set(calls.get() + 1)
            captured.set(size)
        }

        parent.setNeedsLayout()
        parent.layoutIfNeeded()

        XCTAssertEqual(calls.get(), 1)
        XCTAssertEqual(captured.get(), CGSize(width: 390, height: 844))
    }

    func testLayoutSentinelDoesNotRefireOnSubsequentLayouts() {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let calls = Locked<Int>(0)
        LayoutSentinelView.attach(to: parent) { _, _ in
            calls.set(calls.get() + 1)
        }

        parent.setNeedsLayout()
        parent.layoutIfNeeded()
        XCTAssertEqual(calls.get(), 1)

        parent.frame = CGRect(x: 0, y: 0, width: 500, height: 700)
        parent.setNeedsLayout()
        parent.layoutIfNeeded()

        XCTAssertEqual(calls.get(), 1, "Sentinel must fire exactly once even after resize")
    }

    func testLayoutSentinelDoesNotFireOnZeroSizedParent() {
        let parent = UIView(frame: .zero)
        let calls = Locked<Int>(0)
        LayoutSentinelView.attach(to: parent) { _, _ in
            calls.set(calls.get() + 1)
        }

        parent.setNeedsLayout()
        parent.layoutIfNeeded()

        XCTAssertEqual(calls.get(), 0)
    }

    func testLayoutSentinelRemovesItselfAfterFiring() {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let initialChildren = parent.subviews.count
        LayoutSentinelView.attach(to: parent) { _, _ in }
        XCTAssertEqual(parent.subviews.count, initialChildren + 1)

        parent.setNeedsLayout()
        parent.layoutIfNeeded()

        XCTAssertEqual(parent.subviews.count, initialChildren,
            "Sentinel should detach after reporting size — host hierarchy stays clean.")
    }

    func testSizeClassStringPinsWireValues() {
        XCTAssertEqual(sizeClassString(.compact), "compact")
        XCTAssertEqual(sizeClassString(.regular), "regular")
        XCTAssertEqual(sizeClassString(.unspecified), "unspecified")
    }

    func testDeviceIdiomStringPinsWireValues() {
        XCTAssertEqual(deviceIdiomString(.phone), "phone")
        XCTAssertEqual(deviceIdiomString(.pad), "pad")
        XCTAssertEqual(deviceIdiomString(.mac), "mac")
        XCTAssertEqual(deviceIdiomString(.tv), "tv")
        XCTAssertEqual(deviceIdiomString(.carPlay), "carPlay")
        XCTAssertEqual(deviceIdiomString(.vision), "vision")
        XCTAssertEqual(deviceIdiomString(.unspecified), "unspecified")
    }
}
