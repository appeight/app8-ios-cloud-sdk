import Foundation

public extension App8Cloud {

    /// Result of importing one `.a8pack` bundle into the disk cache.
    struct OfflineImportSummary: Sendable, Equatable {
        /// `app8.offline.flow` or `app8.offline.screen`.
        public let type: String
        /// The flow_key or screen_key the bundle carries.
        public let key: String
        /// Published version label (nil = latest).
        public let version: String?
        /// Number of screen DSL documents seeded (screen + flow members).
        public let screensImported: Int
        /// Number of asset binaries written to the asset cache.
        public let assetsImported: Int
        /// Number of fonts registered with CoreText.
        public let fontsRegistered: Int
    }
}

/// The `manifest.json` envelope. Assets are structured; the DSL payload rides in
/// `content` as base64 and is parsed separately (it mixes typed + opaque blobs).
struct OfflineManifest: Decodable {
    let type: String
    let name: String
    let version: String?
    let dslVersion: String?
    let bundleFormat: Int
    let appId: String
    let key: String
    let createdAt: String?
    let content: String
    let assets: [OfflineAssetDescriptor]
}

struct OfflineAssetDescriptor: Decodable {
    let id: String?
    let name: String?
    let filename: String?
    let kind: String?
    let mimeType: String?
    let sizeBytes: Int?
    let sha256: String?
    let postScriptName: String?
    let path: String
}

extension OfflineManifest {

    /// The highest container schema this SDK build understands.
    static let supportedBundleFormat = 1

    static func load(fromDirectory dir: URL) throws -> OfflineManifest {
        let manifestURL = dir.appendingPathComponent("manifest.json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw App8Cloud.Error.offlineBundleInvalid(reason: "missing manifest.json at \(dir.lastPathComponent)")
        }
        do {
            return try JSONDecoder().decode(OfflineManifest.self, from: data)
        } catch {
            throw App8Cloud.Error.offlineBundleInvalid(reason: "manifest.json decode failed: \(error)")
        }
    }

    func decodePayload() throws -> [String: Any] {
        guard let raw = Data(base64Encoded: content) else {
            throw App8Cloud.Error.offlineBundleInvalid(reason: "content is not valid base64")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            throw App8Cloud.Error.offlineBundleInvalid(reason: "content payload is not a JSON object")
        }
        return obj
    }
}

/// Compare dotted numeric versions ("1.0", "1.2.3"). Returns true when `lhs <= rhs`.
/// Non-numeric / missing components compare as 0, so "1.0" == "1.0.0".
func dslVersionIsSupported(_ found: String, max: String) -> Bool {
    func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
    let a = parts(found), b = parts(max)
    let n = Swift.max(a.count, b.count)
    for i in 0..<n {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x < y }
    }
    return true
}
