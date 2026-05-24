import Foundation

struct HeaderBuilder: Sendable {

    let token: String
    let sdkVersion: String
    let maxSupportedDslVersion: String

    func standardHeaders() -> [String: String] {
        var h: [String: String] = [
            "Authorization": "Bearer \(token)",
            "X-App8-SDK-Version": sdkVersion,
            "X-App8-DSL-Max": maxSupportedDslVersion,
            "User-Agent": userAgent(),
            "Accept": "application/json",
        ]
        // No Accept-Language: locale selection is client-side via TranslationStore.
        if let bundleId = Bundle.main.bundleIdentifier {
            h["X-App8-Host-Bundle-Id"] = bundleId
        }
        if let hostVersion = hostAppVersion() {
            h["X-App8-Host-Version"] = hostVersion
        }
        return h
    }

    func apply(
        to request: inout URLRequest,
        identityAttributes: [String: String]? = nil
    ) {
        for (k, v) in standardHeaders() {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if let identityAttributes, !identityAttributes.isEmpty,
           let header = encodeIdentityHeader(identityAttributes) {
            request.setValue(header, forHTTPHeaderField: "X-App8-Identity")
        }
    }

    private func encodeIdentityHeader(_ attributes: [String: String]) -> String? {
        guard let json = try? JSONSerialization.data(withJSONObject: attributes, options: [.sortedKeys])
        else { return nil }
        return json.base64EncodedString()
    }

    var hostBundleId: String? { Bundle.main.bundleIdentifier }
    var hostAppVersionString: String? { hostAppVersion() }

    // MARK: - Helpers

    private func userAgent() -> String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let device = deviceModel()
        let locale = Locale.current.identifier
        return "App8Cloud/\(sdkVersion) (\(osVersion); \(device); \(locale))"
    }

    private func deviceModel() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        return machine.isEmpty ? "iOS" : machine
    }

    private func hostAppVersion() -> String? {
        guard let info = Bundle.main.infoDictionary else { return nil }
        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?): return "\(s)+\(b)"
        case let (s?, nil): return s
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }
}
