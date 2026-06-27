import Foundation
import App8Engine

public extension App8Cloud {

    enum Error: Swift.Error, Sendable, LocalizedError, CustomStringConvertible {

        case authInvalid

        case appNotFound(appId: String)
        case screenNotFound(screenId: String)
        case screenVersionNotFound(screenId: String, version: String)

        case noNetwork(underlying: URLError)
        case timeout
        /// `retryable=true` means the SDK already retried internally.
        case serverError(status: Int, retryable: Bool)

        case decodeFailed(context: String, underlying: Swift.Error)

        case dslVersionUnsupported(found: String, max: String)

        /// `networkPolicy == .offlineOnly` and the resource wasn't in the cache,
        /// so the SDK refused to reach the network. `context` names the resource.
        case offlineResourceMissing(context: String)

        /// An offline `.a8pack` bundle couldn't be imported — malformed manifest,
        /// unsupported `bundleFormat`, app-id mismatch, or a failed asset checksum.
        case offlineBundleInvalid(reason: String)

        case engine(App8.Error)

        // MARK: -

        public var errorDescription: String? {
            switch self {
            case .authInvalid:
                return "App8Cloud: token rejected (401/403). Check the token and the environment."
            case .appNotFound(let id):
                return "App8Cloud: app '\(id)' not found."
            case .screenNotFound(let id):
                return "App8Cloud: screen '\(id)' not found."
            case .screenVersionNotFound(let id, let version):
                return "App8Cloud: screen '\(id)' has no version '\(version)'."
            case .noNetwork(let underlying):
                return "App8Cloud: no network (\(underlying.code))."
            case .timeout:
                return "App8Cloud: request timed out."
            case .serverError(let status, let retryable):
                return "App8Cloud: server error \(status) (retryable=\(retryable))."
            case .decodeFailed(let context, let underlying):
                return "App8Cloud: decode failed in \(context): \(underlying)."
            case .dslVersionUnsupported(let found, let max):
                return "App8Cloud: DSL version \(found) > max supported \(max). Upgrade the SDK."
            case .offlineResourceMissing(let context):
                return "App8Cloud: offline-only and '\(context)' is not in the cache. " +
                    "Import an offline bundle or warm the cache while online."
            case .offlineBundleInvalid(let reason):
                return "App8Cloud: offline bundle invalid: \(reason)."
            case .engine(let inner):
                return "App8Cloud: engine error: \(inner.errorDescription ?? "\(inner)")."
            }
        }

        public var description: String { errorDescription ?? "App8Cloud: error" }
    }
}
