import Foundation
import os

let reservedKeyPrefix: Character = "$"

final class AttributeBag: @unchecked Sendable {

    private struct State: Sendable {
        var values: [String: String] = [:]
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: .init())
    private let log: Diagnostics

    init(diagnostics: Diagnostics) {
        self.log = diagnostics
    }

    /// Reserved keys (`$…`) are dropped — the `$` namespace stays reserved
    /// for any future SDK-managed attributes.
    @discardableResult
    func setAttributes(_ attributes: [String: String]) -> [String] {
        var rejected: [String] = []
        let filtered = attributes.filter { key, _ in
            if key.first == reservedKeyPrefix {
                rejected.append(key)
                return false
            }
            return true
        }
        if !rejected.isEmpty {
            let joined = rejected.sorted().joined(separator: ", ")
            log.warning("AttributeBag: rejected reserved keys: \(joined)")
        }
        state.withLock { s in
            for (k, v) in filtered { s.values[k] = v }
        }
        return rejected
    }

    func clearAttributes() {
        state.withLock { $0.values.removeAll(keepingCapacity: true) }
    }

    var snapshot: [String: String] {
        state.withLock { $0.values }
    }
}
