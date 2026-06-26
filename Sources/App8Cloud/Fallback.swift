import Foundation
import UIKit

public extension App8Cloud {

    /// Builds the native view controller to show when a screen render fails.
    typealias ScreenFallback = @MainActor (App8Cloud.Error) -> UIViewController

    /// Builds the native view controller to show when an app launch fails.
    typealias AppFallback = @MainActor (App8Cloud.Error) -> UIViewController

    /// Builds the native view controller to show when a flow render fails.
    typealias FlowFallback = @MainActor (App8Cloud.Error) -> UIViewController

    /// Delivered to `onFallbackInvoked` whenever a fallback closure is used.
    struct FallbackEvent: Sendable {
        public let error: App8Cloud.Error
        /// `nil` for `startApp(fallback:)` fallbacks.
        public let screenId: String?
        public let source: Source

        public enum Source: Sendable {
            case screen
            case app
            case flow
        }

        public init(error: App8Cloud.Error, screenId: String?, source: Source) {
            self.error = error
            self.screenId = screenId
            self.source = source
        }
    }
}
