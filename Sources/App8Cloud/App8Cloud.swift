import Foundation
import App8Engine

/// Namespace for the App8Cloud SDK — server-driven UI delivery and
/// rendering on top of the App8Engine. Start with ``instance(token:appId:environment:diskCache:telemetry:maxSupportedDslVersion:)``.
public enum App8Cloud {

    /// Creates an SDK instance for one App8 app.
    ///
    /// - Parameters:
    ///   - token: Publishable SDK token (`app8_live_…` / `app8_test_…`).
    ///   - appId: The App8 app identifier to render screens from.
    ///   - environment: Backend `/sdk/v1` base URL, via `.custom(URL)`.
    ///   - diskCache: On-disk cache policy; defaults to enabled.
    ///   - telemetry: Render/usage telemetry policy; defaults to enabled.
    ///   - diagnosticLoggingEnabled: Emit SDK diagnostic logs to the unified
    ///     log (subsystem `dev.app8.cloud`). Off by default; turn on during
    ///     integration / debugging.
    ///   - maxSupportedDslVersion: Highest DSL version this build can render.
    @MainActor
    public static func instance(
        token: String,
        appId: String,
        environment: Environment,
        diskCache: DiskCachePolicy = .default,
        telemetry: TelemetryPolicy = .enabled,
        diagnosticLoggingEnabled: Bool = false,
        maxSupportedDslVersion: String = "1.0"
    ) -> Instance {
        A8CInstance(
            token: token,
            appId: appId,
            environment: environment,
            diskCachePolicy: diskCache,
            telemetryPolicy: telemetry,
            diagnosticLoggingEnabled: diagnosticLoggingEnabled,
            maxSupportedDslVersion: maxSupportedDslVersion
        )
    }
}
