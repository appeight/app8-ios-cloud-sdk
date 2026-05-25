import Foundation

/// Disk cache layout keyed by `(appId, screenId, version)`.
/// ```
/// {root}/v1/{appId}/
///   manifest.json
///   styles.json
///   components/{componentDslId}.json
///   screens/{screenId}/{_latest|version}.json
///   datasources/{category}/{name}.json
///   assets/manifest.json
///   assets/blobs/{assetIdOrFilename}
///   meta.json
///   lru/index.bin
/// ```
/// Schema bump leaves old version dirs on disk — `clearCache(.all)` to remove.
struct CacheLayout: Sendable {
    let cacheRoot: URL
    let appId: String

    static let schemaVersion = "v1"

    static let latestVersionSentinel = "_latest"

    var rootForApp: URL {
        cacheRoot
            .appendingPathComponent(Self.schemaVersion, isDirectory: true)
            .appendingPathComponent(appId, isDirectory: true)
    }

    var manifestFile: URL {
        rootForApp.appendingPathComponent("manifest.json", isDirectory: false)
    }

    var stylesFile: URL {
        rootForApp.appendingPathComponent("styles.json", isDirectory: false)
    }

    var componentsDir: URL {
        rootForApp.appendingPathComponent("components", isDirectory: true)
    }

    func componentFile(componentId: String) -> URL {
        componentsDir.appendingPathComponent("\(sanitizedPathComponent(componentId)).json", isDirectory: false)
    }

    var screensDir: URL {
        rootForApp.appendingPathComponent("screens", isDirectory: true)
    }

    func screenDir(screenId: String) -> URL {
        screensDir.appendingPathComponent(sanitizedPathComponent(screenId), isDirectory: true)
    }

    func screenFile(screenId: String, version: String?) -> URL {
        let v = version ?? Self.latestVersionSentinel
        return screenDir(screenId: screenId)
            .appendingPathComponent("\(sanitizedPathComponent(v)).json", isDirectory: false)
    }

    /// Sibling of the DSL files; version pruning skips it.
    static let screenMetaFilename = "_meta.json"

    func screenMetaFile(screenId: String) -> URL {
        screenDir(screenId: screenId)
            .appendingPathComponent(Self.screenMetaFilename, isDirectory: false)
    }

    var datasourcesDir: URL {
        rootForApp.appendingPathComponent("datasources", isDirectory: true)
    }

    func datasourceFile(category: String, name: String) -> URL {
        datasourcesDir
            .appendingPathComponent(sanitizedPathComponent(category), isDirectory: true)
            .appendingPathComponent("\(sanitizedPathComponent(name)).json", isDirectory: false)
    }

    var metaFile: URL {
        rootForApp.appendingPathComponent("meta.json", isDirectory: false)
    }

    var assetsDir: URL {
        rootForApp.appendingPathComponent("assets", isDirectory: true)
    }

    var assetsManifestFile: URL {
        assetsDir.appendingPathComponent("manifest.json", isDirectory: false)
    }

    var assetBlobsDir: URL {
        assetsDir.appendingPathComponent("blobs", isDirectory: true)
    }

    var localizationsFile: URL {
        rootForApp.appendingPathComponent("localizations.json", isDirectory: false)
    }

    var lruDir: URL {
        rootForApp.appendingPathComponent("lru", isDirectory: true)
    }

    var lruIndexFile: URL {
        lruDir.appendingPathComponent("index.bin", isDirectory: false)
    }
}

func defaultCacheRoot() -> URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    return caches.appendingPathComponent("App8Cloud", isDirectory: true)
}

/// Map an arbitrary string to a single safe filesystem path component.
/// Strips path separators and shell-hostile characters, and never returns
/// `.`, `..`, or an empty string — so a crafted screen/component/asset id
/// cannot traverse out of the cache root.
func sanitizedPathComponent(_ raw: String) -> String {
    var out = ""
    out.reserveCapacity(raw.count)
    for scalar in raw.unicodeScalars {
        switch scalar {
        case "/", "\\", "\0", "\n", "\r", "\t", ":", "?", "*", "<", ">", "|", "\"":
            out.append("_")
        default:
            out.append(Character(scalar))
        }
    }
    if out.isEmpty || out == "." || out == ".." {
        return "_"
    }
    return out
}
