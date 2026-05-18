import Foundation
import UIKit

/// Best-effort fire-and-forget batching (failed flushes drop batch).
@MainActor
final class TelemetryClient {

    private let bufferCap = 500
    private let flushAtSize = 50
    private let batchLimit = 100
    private let flushInterval: TimeInterval = 10

    private let client: HTTPClient
    private let appId: String
    private let identityProvider: @MainActor () -> [String: String]
    private let log: Diagnostics

    private var buffer: [TelemetryEvent] = []
    private var flushTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    nonisolated(unsafe) private var backgroundObserver: NSObjectProtocol?

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(
        client: HTTPClient,
        appId: String,
        identityProvider: @escaping @MainActor () -> [String: String],
        diagnostics: Diagnostics
    ) {
        self.client = client
        self.appId = appId
        self.identityProvider = identityProvider
        self.log = diagnostics

        startTimer()
        registerBackgroundObserver()
    }

    deinit {
        // Only Task cancellation is safe from a nonisolated deinit under
        // Swift 6. The notification observer is removed in `shutdown()`;
        // if that never runs, its `[weak self]` closure just no-ops.
        timerTask?.cancel()
        flushTask?.cancel()
    }

    // MARK: - Public

    func enqueue(_ event: TelemetryEvent) {
        if buffer.count >= bufferCap {
            buffer.removeFirst(buffer.count - bufferCap + 1)
            let cap = self.bufferCap
            log.warning("Telemetry: buffer at cap (\(cap)); dropped oldest event.")
        }
        buffer.append(event)
        if buffer.count >= flushAtSize {
            triggerFlush()
        }
    }

    func flush() async {
        triggerFlush()
        await flushTask?.value
    }

    /// Call from `stopApp()` or instance teardown.
    func shutdown() async {
        timerTask?.cancel()
        timerTask = nil
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
            self.backgroundObserver = nil
        }
        await flush()
    }

    // MARK: - Internals

    private func triggerFlush() {
        if let existing = flushTask, !existing.isCancelled {
            return
        }
        let batch = drain(upTo: batchLimit)
        guard !batch.isEmpty else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.send(batch)
        }
        flushTask = task
    }

    private func drain(upTo limit: Int) -> [TelemetryEvent] {
        let count = min(buffer.count, limit)
        guard count > 0 else { return [] }
        let drained = Array(buffer.prefix(count))
        buffer.removeFirst(count)
        return drained
    }

    private func send(_ events: [TelemetryEvent]) async {
        let identity = identityProvider()
        let payload: [String: Any] = [
            "events": events.map { $0.toWireDict(formatter: isoFormatter) }
        ]
        let body: Data
        do {
            body = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
        } catch {
            log.warning("Telemetry: payload serialization failed (\(error)) — dropping \(events.count) events.")
            flushTask = nil
            return
        }
        do {
            _ = try await client.post(
                .telemetry(appId: appId),
                body: body,
                identity: identity.isEmpty ? nil : identity
            )
            log.debug("Telemetry: flushed \(events.count) events.")
        } catch {
            log.warning("Telemetry: flush failed (\(error)) — dropped \(events.count) events.")
        }
        flushTask = nil
        // If more events accumulated during the flush, the next size
        // trigger or the timer will pick them up — we deliberately
        // don't recurse here to avoid hot loops on a flapping backend.
    }

    private func startTimer() {
        let interval = flushInterval
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                let nanos = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                await self?.timerTick()
            }
        }
    }

    private func timerTick() async {
        guard !buffer.isEmpty else { return }
        triggerFlush()
    }

    private func registerBackgroundObserver() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Already on main, but closure isn't statically MainActor — hop via Task.
            Task { @MainActor [weak self] in
                self?.triggerFlush()
            }
        }
    }
}
