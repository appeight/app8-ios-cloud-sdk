import Foundation
import os

/// FileManager-backed; IO errors → nil/false (best-effort).
final class DiskCache: Sendable {

    let layout: CacheLayout
    private let log: Diagnostics
    /// Cached version files to retain per screen (besides `_latest`). `0`
    /// disables pruning.
    private let versionsToKeep: Int

    /// Guards read-modify-write on `meta.json` — `touchMeta` and
    /// `updateAppResourceMeta` would otherwise lose entries when interleaved.
    private let metaLock = OSAllocatedUnfairLock()

    init(layout: CacheLayout, versionsToKeep: Int, diagnostics: Diagnostics) {
        self.layout = layout
        self.versionsToKeep = max(0, versionsToKeep)
        self.log = diagnostics
        // Wipe a stale-schema cache so disk-first readers don't decode
        // bytes shaped for an older `schemaVersion`.
        if let existing = MetaStore.readApp(at: layout.metaFile),
           existing.schemaVersion != CacheLayout.schemaVersion
        {
            diagnostics.warning("DiskCache: on-disk schema '\(existing.schemaVersion)' != current '\(CacheLayout.schemaVersion)' — wiping app cache.")
            try? FileManager.default.removeItem(at: layout.rootForApp)
        }
        ensureDirectories()
    }

    // MARK: - Existence

    func hasUsableAppCache() -> Bool {
        guard let meta = MetaStore.readApp(at: layout.metaFile) else { return false }
        return meta.schemaVersion == CacheLayout.schemaVersion
    }

    // MARK: - Meta reads

    func readAppMeta() -> CacheMeta? {
        MetaStore.readApp(at: layout.metaFile)
    }

    func readScreenMeta(screenId: String) -> ScreenMeta? {
        MetaStore.readScreen(at: layout.screenMetaFile(screenId: screenId))
    }

    func readAppResourceMeta(key: String) -> ResourceMeta? {
        readAppMeta()?.appResources?[key]
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

    func readAllComponents() -> [Data] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: layout.componentsDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
    }

    func readDatasource(category: String, name: String) -> Data? {
        try? Data(contentsOf: layout.datasourceFile(category: category, name: name))
    }

    func readLocalizations() -> Data? {
        try? Data(contentsOf: layout.localizationsFile)
    }

    func readAssetsManifest() -> Data? {
        try? Data(contentsOf: layout.assetsManifestFile)
    }

    func readScreensCatalog() -> Data? {
        try? Data(contentsOf: layout.screensCatalogFile)
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
    func writeLocalizations(_ data: Data) -> Bool {
        atomicWrite(data, to: layout.localizationsFile)
    }

    @discardableResult
    func writeAssetsManifest(_ data: Data) -> Bool {
        atomicWrite(data, to: layout.assetsManifestFile)
    }

    @discardableResult
    func writeScreensCatalog(_ data: Data) -> Bool {
        atomicWrite(data, to: layout.screensCatalogFile)
    }

    func clearScreensCatalog() {
        try? FileManager.default.removeItem(at: layout.screensCatalogFile)
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
        metaLock.withLock {
            let existing = MetaStore.readApp(at: layout.metaFile)
            let meta = CacheMeta(
                sdkVersion: SDKVersion.current,
                appResources: existing?.appResources,
                fetchedAt: Date(),
                dslVersion: dslVersion ?? existing?.dslVersion
            )
            return MetaStore.writeApp(meta, to: layout.metaFile)
        }
    }

    @discardableResult
    func writeScreenMeta(_ meta: ScreenMeta, screenId: String) -> Bool {
        MetaStore.writeScreen(meta, to: layout.screenMetaFile(screenId: screenId))
    }

    @discardableResult
    func updateAppResourceMeta(key: String, meta: ResourceMeta) -> Bool {
        metaLock.withLock {
            let existing = MetaStore.readApp(at: layout.metaFile)
            var resources = existing?.appResources ?? [:]
            resources[key] = meta
            let updated = CacheMeta(
                schemaVersion: CacheLayout.schemaVersion,
                sdkVersion: SDKVersion.current,
                appResources: resources,
                fetchedAt: Date(),
                dslVersion: existing?.dslVersion
            )
            return MetaStore.writeApp(updated, to: layout.metaFile)
        }
    }

    // MARK: - Flow channel reads/writes

    func readFlowManifest(flowKey: String, version: String?) -> Data? {
        try? Data(contentsOf: layout.flowManifestFile(flowKey: flowKey, version: version))
    }

    @discardableResult
    func writeFlowManifest(_ data: Data, flowKey: String, version: String?) -> Bool {
        atomicWrite(data, to: layout.flowManifestFile(flowKey: flowKey, version: version))
    }

    func readFlowScreen(flowKey: String, version: String?, screenKey: String) -> Data? {
        try? Data(contentsOf: layout.flowScreenFile(flowKey: flowKey, version: version, screenKey: screenKey))
    }

    @discardableResult
    func writeFlowScreen(_ data: Data, flowKey: String, version: String?, screenKey: String) -> Bool {
        atomicWrite(data, to: layout.flowScreenFile(flowKey: flowKey, version: version, screenKey: screenKey))
    }

    func readFlowStyles(flowKey: String, version: String?) -> [Data]? {
        guard let blob = try? Data(contentsOf: layout.flowStylesFile(flowKey: flowKey, version: version)) else {
            return nil
        }
        return decodeArrayOfBlobs(blob)
    }

    @discardableResult
    func writeFlowStyles(_ blobs: [Data], flowKey: String, version: String?) -> Bool {
        atomicWrite(encodeArrayOfBlobs(blobs), to: layout.flowStylesFile(flowKey: flowKey, version: version))
    }

    func readFlowComponents(flowKey: String, version: String?) -> [Data]? {
        guard let blob = try? Data(contentsOf: layout.flowComponentsFile(flowKey: flowKey, version: version)) else {
            return nil
        }
        return decodeArrayOfBlobs(blob)
    }

    @discardableResult
    func writeFlowComponents(_ blobs: [Data], flowKey: String, version: String?) -> Bool {
        atomicWrite(encodeArrayOfBlobs(blobs), to: layout.flowComponentsFile(flowKey: flowKey, version: version))
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
        let metaName = CacheLayout.screenMetaFilename
        let versioned = entries.filter {
            $0.pathExtension == "json"
                && $0.lastPathComponent != latestName
                && $0.lastPathComponent != metaName
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
