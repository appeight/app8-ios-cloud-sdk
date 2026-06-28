import Foundation

/// The App8Cloud SDK version.
///
/// Sent to the backend in the `X-App8-SDK-Version` header and recorded in
/// disk-cache metadata. SwiftPM does not expose the package/git-tag version
/// to compiled code, so this constant is the single source of truth — it
/// must be bumped to match the published git tag on every release.
enum SDKVersion {
    static let current = "0.3.2"
}
