//
//  InFlightCoalescerTests.swift
//  App8CloudTests
//

import XCTest
@testable import App8Cloud

@MainActor
final class InFlightCoalescerTests: XCTestCase {

    func testConcurrentCallsCoalesceToOneTask() async throws {
        let coalescer = InFlightCoalescer()
        let counter = Counter()
        let payload = Data([0xAA])

        // Fire 50 concurrent callers for the same key. The work closure
        // should execute exactly once.
        //
        // The work intentionally sleeps 100ms — long enough to guarantee
        // all 50 callers finish their `coalescer.run(...)` lookup BEFORE
        // the work completes and removes itself from the dedupe map.
        // (`Task.yield()` was too fast: the work finished + cleaned up
        // before some callers reached the lookup, so they spawned fresh
        // tasks.) Production network calls take much longer than 100ms,
        // so the dedupe always works in real life.
        //
        // Explicit captures in `addTask` so Swift 6's region-based
        // isolation checker can reason about the transferred values.
        let results = await withTaskGroup(of: Data.self) { group in
            for _ in 0..<50 {
                group.addTask { [coalescer, counter, payload] in
                    let data = try? await coalescer.run(key: "k1") {
                        await counter.bumpAndYield()
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        return payload
                    }
                    return data ?? Data()
                }
            }
            var collected: [Data] = []
            for await r in group { collected.append(r) }
            return collected
        }

        XCTAssertEqual(results.count, 50)
        XCTAssertTrue(results.allSatisfy { $0 == payload })
        let count = await counter.value
        XCTAssertEqual(count, 1, "Coalescer should have invoked work exactly once.")
    }

    func testDifferentKeysDoNotCoalesce() async throws {
        let coalescer = InFlightCoalescer()
        let counter = Counter()

        async let a: Data = coalescer.run(key: "a") {
            await counter.bumpAndYield()
            return Data()
        }
        async let b: Data = coalescer.run(key: "b") {
            await counter.bumpAndYield()
            return Data()
        }
        _ = try await (a, b)

        let count = await counter.value
        XCTAssertEqual(count, 2)
    }

    func testCallsAfterCompletionAreFreshFetches() async throws {
        let coalescer = InFlightCoalescer()
        let counter = Counter()

        _ = try await coalescer.run(key: "k") {
            await counter.bumpAndYield()
            return Data()
        }
        _ = try await coalescer.run(key: "k") {
            await counter.bumpAndYield()
            return Data()
        }
        let count = await counter.value
        XCTAssertEqual(count, 2)
    }
}

private actor Counter {
    private(set) var value = 0
    func bumpAndYield() async {
        value += 1
        // Yield once so concurrent callers actually queue up before we
        // resolve, exercising the coalescer's dedupe path.
        await Task.yield()
    }
}
