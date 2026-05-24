import Foundation
import os

/// Holds an optional locale override set via `instance.setLocale(...)`.
/// Mirrors `AttributeBag` — the same `OSAllocatedUnfairLock`-backed pattern,
/// since the override is read from arbitrary contexts (header builder, render
/// callbacks) and written from the main thread by the public API.
///
/// When `override` is nil the SDK reports the device's first preferred
/// language; the engine then layers its own fallback (device → app default).
final class LocaleBag: @unchecked Sendable {

    private struct State: Sendable {
        var override: String?
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: .init())
    private let log: Diagnostics

    init(diagnostics: Diagnostics) {
        self.log = diagnostics
    }

    /// Pass nil to revert to the device default.
    func setOverride(_ locale: String?) {
        state.withLock { $0.override = locale.flatMap(Self.canonicalise) }
    }

    /// Best-effort canonical locale: override → device default → "en".
    /// Used as the public `currentLocale` value and (Phase 2+) for any
    /// downstream cache-key namespacing.
    func currentLocale() -> String {
        if let o = state.withLock({ $0.override }) { return o }
        if let device = Locale.preferredLanguages.first, let canonical = Self.canonicalise(device) {
            return canonical
        }
        return "en"
    }

    /// The override value, if one was set. Distinct from `currentLocale()` —
    /// callers that need to distinguish "explicitly set" vs "device default"
    /// look here.
    var overrideSnapshot: String? {
        state.withLock { $0.override }
    }

    /// Mirrors the backend's `lib/locale-negotiate.ts` normaliser so both
    /// sides use identical keys. Accepts `<lang>` or `<lang>-<REGION>` where
    /// language is 2-3 letters and region is 2 letters OR 3 digits.
    ///
    ///   `fr`        → `fr`
    ///   `fr-CA`     → `fr-CA`
    ///   `fr_ca`     → `fr-CA`
    ///   `FR-Ca`     → `fr-CA`
    ///   `419` (UN region only) → `nil`
    ///   `english`   → `nil` (4+ char lang rejected)
    ///   `fr-A`      → `nil` (1-char region rejected)
    ///
    /// Anything past the first two subtags (script, variants) is dropped
    /// silently — v1 only supports lang-region.
    private static func canonicalise(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let normalised = trimmed.replacingOccurrences(of: "_", with: "-")
        let parts = normalised.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let langRaw = parts.first else { return nil }
        let lang = langRaw.lowercased()
        guard (2...3).contains(lang.count), lang.allSatisfy({ $0.isLetter }) else { return nil }
        guard parts.count >= 2 else { return lang }
        // Region is whatever follows the first dash. Take only up to the next
        // dash so `fr-CA-x-private` cleanly normalises to `fr-CA`.
        let regionRaw = parts[1].split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let isTwoLetter = regionRaw.count == 2 && regionRaw.allSatisfy({ $0.isLetter })
        let isThreeDigit = regionRaw.count == 3 && regionRaw.allSatisfy({ $0.isNumber })
        guard isTwoLetter || isThreeDigit else { return nil }
        return "\(lang)-\(regionRaw.uppercased())"
    }
}
