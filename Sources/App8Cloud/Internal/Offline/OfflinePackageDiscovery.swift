import Foundation

public extension App8Cloud {

    /// Default on-disk location for runtime-delivered `.a8pack` bundles:
    /// `Application Support/App8Cloud/packages/{appId}/`. Place a downloaded
    /// bundle here (or pass its URL directly to ``Instance/importOfflineBundle(at:)``)
    /// and ``Instance/importBundledPackages()`` will pick it up.
    static func defaultOfflinePackageDirectory(appId: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("App8Cloud", isDirectory: true)
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent(appId, isDirectory: true)
    }

    /// Every `.a8pack` from the two default locations: a `Bundle.main`
    /// `App8OfflinePackages/` folder reference (ship-with-app) and the per-app
    /// runtime directory above.
    internal static func discoverOfflinePackages(appId: String) -> [URL] {
        var found: [URL] = []
        if let bundled = Bundle.main.urls(
            forResourcesWithExtension: "a8pack", subdirectory: "App8OfflinePackages"
        ) {
            found.append(contentsOf: bundled)
        }
        let dir = defaultOfflinePackageDirectory(appId: appId)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) {
            found.append(contentsOf: entries.filter { $0.pathExtension == "a8pack" })
        }
        return found
    }
}
