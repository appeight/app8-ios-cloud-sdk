import Foundation
import os

/// Byte-budget LRU cache; IO errors → misses (best-effort).
final class AssetCache: @unchecked Sendable {

    private let blobsDir: URL
    private let byteBudget: Int64
    private let indexFile: URL
    private let log: Diagnostics

    private struct State: Sendable {
        var lruOrder: [String] = []
        var sizes: [String: Int64] = [:]
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: .init())

    init(
        blobsDir: URL,
        byteBudget: Int64,
        indexFile: URL,
        diagnostics: Diagnostics
    ) {
        self.blobsDir = blobsDir
        self.byteBudget = byteBudget
        self.indexFile = indexFile
        self.log = diagnostics
        loadIndex()
    }

    // MARK: - Public

    func read(key: String) -> Data? {
        let url = blobsDir.appendingPathComponent(sanitizedPathComponent(key))
        guard let data = try? Data(contentsOf: url) else { return nil }
        let size = Int64(data.count)
        state.withLock { s in
            // Seed the size for an orphan blob the index didn't know about —
            // otherwise eviction under-counts the budget and never evicts it.
            if s.sizes[key] == nil {
                s.sizes[key] = size
            }
            Self.markAccess(in: &s, key: key)
        }
        return data
    }

    @discardableResult
    func write(key: String, data: Data) -> Bool {
        let url = blobsDir.appendingPathComponent(sanitizedPathComponent(key))
        let size = Int64(data.count)
        if size > byteBudget {
            log.warning("AssetCache: blob \(key) (\(size) bytes) > budget \(self.byteBudget); skipping write.")
            return false
        }

        // Decide which keys need to be evicted under the lock; do the actual
        // file removals + new write outside the lock to avoid holding it
        // across IO.
        let evictKeys: [String] = state.withLock { s in
            Self.computeEvictions(in: &s, byteBudget: byteBudget, incoming: size, newKey: key)
        }
        for victim in evictKeys {
            let victimURL = blobsDir.appendingPathComponent(sanitizedPathComponent(victim))
            try? FileManager.default.removeItem(at: victimURL)
            log.debug("AssetCache: evicted \(victim) to make room.")
        }
        guard atomicWrite(data, to: url) else { return false }

        let snapshot: State = state.withLock { s in
            s.sizes[key] = size
            Self.markAccess(in: &s, key: key)
            return s
        }
        persistIndex(snapshot: snapshot)
        return true
    }

    /// Drop all state + index + blobs (best-effort; IO errors → missing).
    func reset() {
        state.withLock { s in
            s.lruOrder.removeAll()
            s.sizes.removeAll()
        }
        try? FileManager.default.removeItem(at: indexFile)
        // Remove every blob file. Re-create the directory so subsequent
        // writes succeed (callers don't expect to set up the dir again).
        try? FileManager.default.removeItem(at: blobsDir)
        try? FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
    }

    // MARK: - Private

    private static func markAccess(in s: inout State, key: String) {
        if let idx = s.lruOrder.firstIndex(of: key) {
            s.lruOrder.remove(at: idx)
        }
        s.lruOrder.append(key)
    }

    /// Compute evictions; caller does IO outside lock to avoid holding it.
    private static func computeEvictions(
        in s: inout State,
        byteBudget: Int64,
        incoming: Int64,
        newKey: String
    ) -> [String] {
        var totalBytes = s.sizes.values.reduce(0, +)
        if let existing = s.sizes[newKey] { totalBytes -= existing }
        var evict: [String] = []
        while totalBytes + incoming > byteBudget,
              let victim = s.lruOrder.first,
              victim != newKey
        {
            s.lruOrder.removeFirst()
            if let bytes = s.sizes.removeValue(forKey: victim) {
                totalBytes -= bytes
            }
            evict.append(victim)
        }
        return evict
    }

    /// Index format: line-delimited "size\tkey" entries in LRU order
    /// (oldest first). Compact and easy to write atomically.
    private func loadIndex() {
        guard let raw = try? String(contentsOf: indexFile, encoding: .utf8) else { return }
        state.withLock { s in
            for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2,
                      let size = Int64(parts[0])
                else { continue }
                let key = String(parts[1])
                s.sizes[key] = size
                s.lruOrder.append(key)
            }
        }
    }

    /// Persist a snapshot of the index. Caller computes the snapshot under
    /// the lock and passes it in so we don't hold the lock across IO.
    private func persistIndex(snapshot: State) {
        var buffer = ""
        buffer.reserveCapacity(snapshot.lruOrder.count * 32)
        for key in snapshot.lruOrder {
            let size = snapshot.sizes[key] ?? 0
            buffer.append("\(size)\t\(key)\n")
        }
        guard let data = buffer.data(using: .utf8) else { return }
        atomicWrite(data, to: indexFile)
    }

}
