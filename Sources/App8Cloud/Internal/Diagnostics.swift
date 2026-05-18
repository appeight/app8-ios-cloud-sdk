import Foundation
import os

/// os.Logger (subsystem: dev.app8.cloud); independent of engine logger.
///
/// `debug`/`info`/`warning`/`error` are all gated on `enabled` — a partner
/// who leaves diagnostics off writes nothing to the device unified log.
/// Interpolated values keep the default `.private` redaction, so even with
/// logging on, dynamic data (screen ids, asset names, host bundle id) is
/// shown only when a debugger is attached and redacted in sysdiagnose.
struct Diagnostics: Sendable {

    let enabled: Bool
    let logger: Logger

    init(enabled: Bool, category: String = "App8Cloud") {
        self.enabled = enabled
        self.logger = Logger(subsystem: "dev.app8.cloud", category: category)
    }

    func debug(_ message: @autoclosure @escaping () -> String) {
        guard enabled else { return }
        logger.debug("\(message())")
    }

    func info(_ message: @autoclosure @escaping () -> String) {
        guard enabled else { return }
        logger.info("\(message())")
    }

    func warning(_ message: @autoclosure @escaping () -> String) {
        guard enabled else { return }
        logger.warning("\(message())")
    }

    func error(_ message: @autoclosure @escaping () -> String) {
        guard enabled else { return }
        logger.error("\(message())")
    }

    /// Always emitted, even when diagnostics are disabled. Reserved for
    /// one-time SDK misconfiguration warnings raised at init time. Must
    /// never carry user or host data — only static setup guidance — since
    /// it is `.public` and lands in the unified log unconditionally.
    func configurationWarning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    static let disabled = Diagnostics(enabled: false)
}
