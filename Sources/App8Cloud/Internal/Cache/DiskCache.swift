import Foundation

/// FileManager-backed; IO errors → nil/false (best-effort).
final class DiskCache: Sendable {

    let layout: CacheLayout
    private let log: Diagnostics
    /// Cached version files to retain per screen (besides `_latest`). `0`
    /// disables pruning.
    private let versionsToKeep: Int

    init(layout: CacheLayout, versionsToKeep: Int, diagnostics: Diagnostics) {
        self.layout = layout
        self.versionsToKeep = max(0, versionsToKeep)
        self.log = diagnostics
        ensureDirectories()
    }

    // MARK: - Existence

    func hasUsableAppCache() -> Bool {
        guard let meta = MetaStore.read(at: layout.metaFile) else { return false }
        return meta.schemaVersion == CacheLayout.schemaVersion
    }

    // MARK: - Reads

    func readManifest() -> Data? { try? Data(contentsOf: layout.manifestFile) }
    func readStylesBlob() -> Data? { try? Data(contentsOf: layout.stylesFile) }

    func readScreen(screenId: String, version: String?) -> Data? {
        try? Data(contentsOf: layout.screenFile(screenId: screenId, version: version))
    }

    func readComponent(componentId: String) -> Data? {
        try? Data(contentsOf: layout.componentFile(componentId: componentId))
    }

    func readDatasource(category: String, name: String) -> Data? {
        try? Data(contentsOf: layout.datasourceFile(category: category, name: name))
    }

    func readStyles() -> [Data] {
        guard let blob = readStylesBlob() else { return [] }
        return decodeArrayOfBlobs(blob)
    }

    func enumerateScreenIds() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: layout.screensDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
    }

    // MARK: - Writes

    @discardableResult
    func writeManifest(_ data: Data) -> Bool {
        atomicWrite(data, to: layout.manifestFile)
    }

    @discardableResult
    func writeStyles(_ blobs: [Data]) -> Bool {
        atomicWrite(encodeArrayOfBlobs(blobs), to: layout.stylesFile)
    }

    @discardableResult
    func writeScreen(screenId: String, version: String?, data: Data) -> Bool {
        let ok = atomicWrite(data, to: layout.screenFile(screenId: screenId, version: version))
        pruneScreenVersions(screenId: screenId)
        return ok
    }

    @discardableResult
    func writeComponent(componentId: String, data: Data) -> Bool {
        atomicWrite(data, to: layout.componentFile(componentId: componentId))
    }

    @discardableResult
    func writeDatasource(category: String, name: String, data: Data) -> Bool {
        atomicWrite(data, to: layout.datasourceFile(category: category, name: name))
    }

    @discardableResult
    func writeComponents(_ blobs: [Data], idResolver: (Data) -> String?) -> Bool {
        var allOk = true
        for blob in blobs {
            guard let id = idResolver(blob) else { continue }
            allOk = atomicWrite(blob, to: layout.componentFile(componentId: id)) && allOk
        }
        return allOk
    }

    @discardableResult
    func touchMeta(dslVersion: String? = nil) -> Bool {
        let meta = CacheMeta(sdkVersion: SDKVersion.current, dslVersion: dslVersion)
        return MetaStore.write(meta, to: layout.metaFile)
    }

    // MARK: - Clear

    func clearAll() {
        try? FileManager.default.removeItem(at: layout.rootForApp)
        ensureDirectories()
    }

    func clearScreen(id: String) {
        try? FileManager.default.removeItem(at: layout.screenDir(screenId: id))
    }

    // MARK: - Private

    /// Keep `_latest` plus the `versionsToKeep` most-recently-written
    /// version files per screen; delete the rest. Best-effort.
    private func pruneScreenVersions(screenId: String) {
        guard versionsToKeep > 0 else { return }
        let dir = layout.screenDir(screenId: screenId)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let latestName = "\(CacheLayout.latestVersionSentinel).json"
        let versioned = entries.filter {
            $0.pathExtension == "json" && $0.lastPathComponent != latestName
        }
        guard versioned.count > versionsToKeep else { return }

        let modDate: (URL) -> Date = { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
        }
        let sorted = versioned.sorted { modDate($0) > modDate($1) }
        for victim in sorted.dropFirst(versionsToKeep) {
            try? fm.removeItem(at: victim)
            log.debug("DiskCache: pruned old screen version \(victim.lastPathComponent) for '\(screenId)'.")
        }
    }

    private func ensureDirectories() {
        let fm = FileManager.default
        for dir in [
            layout.rootForApp,
            layout.componentsDir,
            layout.screensDir,
            layout.datasourcesDir,
            layout.assetsDir,
            layout.assetBlobsDir,
            layout.lruDir,
        ] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func encodeArrayOfBlobs(_ blobs: [Data]) -> Data {
        var out = Data()
        out.append(0x5B) // [
        for (i, blob) in blobs.enumerated() {
            if i > 0 { out.append(0x2C) } // ,
            out.append(blob)
        }
        out.append(0x5D) // ]
        return out
    }

    private func decodeArrayOfBlobs(_ data: Data) -> [Data] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        return json.compactMap {
            try? JSONSerialization.data(withJSONObject: $0, options: [])
        }
    }
}
