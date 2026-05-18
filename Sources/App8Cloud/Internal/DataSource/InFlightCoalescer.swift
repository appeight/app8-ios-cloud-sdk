import Foundation
import os

final class InFlightCoalescer: @unchecked Sendable {

    private let state = OSAllocatedUnfairLock<[String: Task<Data, Swift.Error>]>(initialState: [:])

    func run(
        key: String,
        work: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        let task = state.withLock { tasks -> Task<Data, Swift.Error> in
            if let existing = tasks[key] {
                return existing
            }
            let new = Task<Data, Swift.Error> { [weak self] in
                defer { self?.complete(key: key) }
                return try await work()
            }
            tasks[key] = new
            return new
        }
        return try await task.value
    }

    private func complete(key: String) {
        state.withLock { $0[key] = nil }
    }
}
