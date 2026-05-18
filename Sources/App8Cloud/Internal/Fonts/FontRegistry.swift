import Foundation
import CoreText
import CoreGraphics
import UIKit
import os

/// Process-wide registry (idempotent per asset id).
final class FontRegistry: @unchecked Sendable {

    private let log: Diagnostics
    private let state = OSAllocatedUnfairLock<State>(initialState: .init())

    private struct State: Sendable {
        var registeredAssetIds: Set<String> = []
        /// PostScript names already registered this process — skips
        /// duplicate registrations when one font ships under multiple
        /// filenames/asset ids (CoreText rejects re-registration with 305).
        var registeredPostScriptNameSet: Set<String> = []
        var registeredPostScriptNames: [String] = []
    }

    init(diagnostics: Diagnostics) {
        self.log = diagnostics
    }

    var registeredPostScriptNames: [String] {
        state.withLock { $0.registeredPostScriptNames }
    }

    func isAssetRegistered(id: String) -> Bool {
        state.withLock { $0.registeredAssetIds.contains(id) }
    }

    /// Re-registering same assetId is a no-op (CoreText error 305 otherwise).
    @discardableResult
    func register(data: Data, assetId: String, filename: String) -> String? {
        let alreadyRegistered = state.withLock { s -> Bool in
            if s.registeredAssetIds.contains(assetId) { return true }
            s.registeredAssetIds.insert(assetId)
            return false
        }
        if alreadyRegistered { return nil }

        guard let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider) else {
            state.withLock { _ = $0.registeredAssetIds.remove(assetId) }
            log.warning("FontRegistry: could not construct CGFont for \(filename) (asset \(assetId)).")
            return nil
        }

        // Dedupe by PostScript name before calling CoreText: the same font
        // can arrive under multiple asset ids, or already be in the system
        // table (host `UIAppFonts`, another loader, a prior launch). CoreText
        // rejects re-registration with error 305 and logs a noisy line.
        let psName = (cgFont.postScriptName as String?) ?? ""
        if !psName.isEmpty {
            let alreadyKnown = state.withLock { $0.registeredPostScriptNameSet.contains(psName) }
            if alreadyKnown {
                log.debug("FontRegistry: '\(psName)' already registered; skipping \(filename).")
                return psName
            }
            if UIFont(name: psName, size: 1) != nil {
                // System already has this font (host bundle, UIAppFonts,
                // or a prior cloud-SDK process). Mark as registered so
                // we don't retry from another asset id.
                state.withLock { s in
                    if s.registeredPostScriptNameSet.insert(psName).inserted {
                        s.registeredPostScriptNames.append(psName)
                    }
                }
                log.debug("FontRegistry: '\(psName)' available system-wide; skipping CoreText register for \(filename).")
                return psName
            }
        }

        // CTFontManagerRegisterGraphicsFont — deprecated on iOS 18 but the
        // simplest in-memory API; replacements need a file URL or async handler.
        var error: Unmanaged<CFError>?
        let ok = withUnsafeDeprecation {
            CTFontManagerRegisterGraphicsFont(cgFont, &error)
        }
        if !ok {
            let cfError = error?.takeRetainedValue()
            let code = cfError.map { CFErrorGetCode($0) } ?? 0
            // Error 305 = kCTFontManagerErrorAlreadyRegistered. Benign:
            // some other code path (or another asset id with the same
            // PostScript name) already registered this font. Treat as
            // success — record the name + assetId so we don't try again.
            if code == 305 {
                if !psName.isEmpty {
                    state.withLock { s in
                        if s.registeredPostScriptNameSet.insert(psName).inserted {
                            s.registeredPostScriptNames.append(psName)
                        }
                    }
                    log.debug("FontRegistry: '\(psName)' was already registered (CoreText 305); marking \(filename) as done.")
                }
                return psName.isEmpty ? nil : psName
            }
            state.withLock { _ = $0.registeredAssetIds.remove(assetId) }
            let msg = cfError?.localizedDescription ?? "unknown"
            log.warning("FontRegistry: registration failed for \(filename): \(msg)")
            return nil
        }
        let nameForRecord = psName.isEmpty ? "(unknown)" : psName
        state.withLock { s in
            if s.registeredPostScriptNameSet.insert(nameForRecord).inserted {
                s.registeredPostScriptNames.append(nameForRecord)
            }
        }
        log.info("FontRegistry: registered '\(nameForRecord)' from \(filename).")
        return psName.isEmpty ? nil : psName
    }

    /// Wrap the deprecated CoreText call so the deprecation warning is
    /// confined to one place. Compiles cleanly in -Wno-deprecated-declarations
    /// regions; the cost is purely cosmetic.
    @inline(__always)
    private func withUnsafeDeprecation<T>(_ body: () -> T) -> T {
        body()
    }

    /// CoreText supports ttf/otf/ttc; WOFF requires decoder (unsupported).
    static func isFont(filename: String, mimeType: String?) -> Bool {
        let lowerMime = mimeType?.lowercased() ?? ""
        let ext = (filename as NSString).pathExtension.lowercased()

        // Exclude WOFF / WOFF2 explicitly — CoreText can't decode them.
        if ext == "woff" || ext == "woff2" { return false }
        if lowerMime == "font/woff" || lowerMime == "font/woff2" { return false }

        if lowerMime.hasPrefix("font/") { return true }
        if lowerMime == "application/font-sfnt" { return true }
        if lowerMime == "application/x-font-ttf" || lowerMime == "application/x-font-otf" { return true }
        return ["ttf", "otf", "ttc"].contains(ext)
    }
}
