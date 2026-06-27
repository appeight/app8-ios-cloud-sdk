import Foundation

struct HTTPResult: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

struct ResponseTooLargeError: Swift.Error, Sendable {
    let byteCount: Int
}

/// Caching is owned by `DiskCache`, not URLCache, hence `ephemeral` session.
final class HTTPClient: @unchecked Sendable {

    private let session: URLSession
    private let baseURL: URL
    private let headers: HeaderBuilder
    private let log: Diagnostics

    /// When true (`networkPolicy == .offlineOnly`) every request short-circuits
    /// to `offlineResourceMissing` before touching the network. Because all SDK
    /// reads are cache-first, cache hits return before reaching here — only a
    /// genuine miss surfaces the offline error.
    private let offlineOnly: Bool

    /// Post-download cap on one response body so a misbehaving backend can't
    /// make the SDK decode/cache an unbounded blob.
    private let maxResponseBytes = 32 * 1024 * 1024

    init(
        baseURL: URL,
        headers: HeaderBuilder,
        timeout: TimeInterval,
        diagnostics: Diagnostics,
        offlineOnly: Bool = false,
        sessionOverride: URLSession? = nil
    ) {
        self.offlineOnly = offlineOnly
        if let override = sessionOverride {
            self.session = override
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            // Whole-transfer budget (incl. retries): 4× the per-request
            // timeout, floored at 120s.
            config.timeoutIntervalForResource = max(timeout * 4, 120)
            config.waitsForConnectivity = true
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
        self.baseURL = baseURL
        self.headers = headers
        self.log = diagnostics
    }

    // MARK: - Public

    func get(
        _ endpoint: Endpoint,
        identity: [String: String]? = nil
    ) async throws -> HTTPResult {
        try guardOffline(endpoint.coalesceKey)
        return try await sendWithRetry { [self] in
            let url = endpoint.resolve(against: baseURL)
            var req = URLRequest(url: url)
            req.httpMethod = endpoint.method
            headers.apply(to: &req, identityAttributes: identity)
            log.debug("HTTP \(req.httpMethod ?? "?") \(url.absoluteString)")
            return try await send(req, endpoint: endpoint)
        }
    }

    /// 4xx is not retried (unrecoverable). 5xx/transient retries with backoff.
    func post(
        _ endpoint: Endpoint,
        body: Data,
        identity: [String: String]? = nil
    ) async throws -> HTTPResult {
        try guardOffline(endpoint.coalesceKey)
        return try await sendWithRetry { [self] in
            let url = endpoint.resolve(against: baseURL)
            var req = URLRequest(url: url)
            req.httpMethod = endpoint.method
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            headers.apply(to: &req, identityAttributes: identity)
            log.debug("HTTP \(req.httpMethod ?? "?") \(url.absoluteString) bytes=\(body.count)")
            return try await send(req, endpoint: endpoint)
        }
    }

    /// Does NOT include the SDK token — presigned URLs carry their own auth.
    func getRawURL(_ url: URL) async throws -> HTTPResult {
        try guardOffline("asset:\(url.host ?? "")\(url.path)")
        return try await sendWithRetry { [self] in
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue(headers.standardHeaders()["User-Agent"], forHTTPHeaderField: "User-Agent")
            log.debug("HTTP GET \(url.host ?? "<no host>")\(url.path)")
            return try await sendBare(req)
        }
    }

    // MARK: - Internals

    /// In offline-only mode, refuse the network before any request work.
    private func guardOffline(_ context: String) throws {
        if offlineOnly {
            log.debug("HTTP suppressed (offlineOnly): \(context)")
            throw App8Cloud.Error.offlineResourceMissing(context: context)
        }
    }

    private func send(_ request: URLRequest, endpoint: Endpoint) async throws -> HTTPResult {
        let (data, urlResponse) = try await session.data(for: request)
        guard let http = urlResponse as? HTTPURLResponse else {
            throw App8Cloud.Error.serverError(status: -1, retryable: false)
        }
        if (200...299).contains(http.statusCode) {
            try enforceSizeLimit(data, endpoint: endpoint.coalesceKey)
            return HTTPResult(data: data, response: http)
        }
        throw map(status: http.statusCode, endpoint: endpoint, body: data)
    }

    private func sendBare(_ request: URLRequest) async throws -> HTTPResult {
        let (data, urlResponse) = try await session.data(for: request)
        guard let http = urlResponse as? HTTPURLResponse else {
            throw App8Cloud.Error.serverError(status: -1, retryable: false)
        }
        if (200...299).contains(http.statusCode) {
            try enforceSizeLimit(data, endpoint: "asset")
            return HTTPResult(data: data, response: http)
        }
        throw genericMap(status: http.statusCode)
    }

    private func enforceSizeLimit(_ data: Data, endpoint: String) throws {
        let limit = maxResponseBytes
        guard data.count > limit else { return }
        log.warning("HTTP response for \(endpoint) is \(data.count) bytes, " +
                    "over the \(limit)-byte limit — rejecting.")
        throw App8Cloud.Error.decodeFailed(
            context: "response too large (\(data.count) bytes) for \(endpoint)",
            underlying: ResponseTooLargeError(byteCount: data.count)
        )
    }

    private func sendWithRetry(
        _ work: @Sendable () async throws -> HTTPResult
    ) async throws -> HTTPResult {
        // Exponential backoff (~3×) between retries: 0.4s, 1.2s, 3.6s.
        // Array length also caps the retry count at 3.
        let delays: [UInt64] = [400_000_000, 1_200_000_000, 3_600_000_000]
        var attempt = 0
        while true {
            do {
                try Task.checkCancellation()
                return try await work()
            } catch {
                let shouldRetry = isTransient(error) && attempt < delays.count
                if !shouldRetry {
                    throw mapURLError(error)
                }
                let jitter = UInt64.random(in: 0...100_000_000)
                try? await Task.sleep(nanoseconds: delays[attempt] &+ jitter)
                attempt += 1
            }
        }
    }

    private func isTransient(_ error: Swift.Error) -> Bool {
        if let cloud = error as? App8Cloud.Error {
            switch cloud {
            case .serverError(let status, _):
                return status == 408 || status == 429 || status == 502 || status == 503 || status == 504
            case .timeout, .noNetwork:
                return true
            default:
                return false
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost, .timedOut, .cannotConnectToHost,
                 .dnsLookupFailed, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }
        return false
    }

    // MARK: - Error mapping

    /// Carried by every non-2xx response. 412 also has top-level `required`/`client_max`.
    private struct BackendErrorBody: Decodable {
        let error: String?
        let code: String?
        let required: String?
        let client_max: String?
        let details: [String: String]?
    }

    private func map(status: Int, endpoint: Endpoint, body: Data) -> App8Cloud.Error {
        let parsed = try? JSONDecoder().decode(BackendErrorBody.self, from: body)
        if let parsed {
            log.warning(
                "HTTP \(status) endpoint=\(endpoint.coalesceKey) " +
                "code=\(parsed.code ?? "?") " +
                "details=\(parsed.details?.description ?? "[]")"
            )
        }
        switch (status, endpoint) {
        case (401, _), (403, _):
            return .authInvalid
        case (404, .manifest(let appId)):
            return .appNotFound(appId: appId)
        case (404, .screen(_, let screenId, nil)):
            return .screenNotFound(screenId: screenId)
        case (404, .screen(_, let screenId, let version?)):
            return .screenVersionNotFound(screenId: screenId, version: version)
        case (404, _):
            return .serverError(status: 404, retryable: false)
        case (412, .screen), (412, .manifest):
            return .dslVersionUnsupported(
                found: parsed?.required ?? "?",
                max: parsed?.client_max ?? "?"
            )
        case let (s, _) where s == 408 || s == 429 || (502...504).contains(s):
            return .serverError(status: s, retryable: true)
        case let (s, _) where (500...599).contains(s):
            return .serverError(status: s, retryable: false)
        default:
            return .serverError(status: status, retryable: false)
        }
    }

    private func genericMap(status: Int) -> App8Cloud.Error {
        switch status {
        case 401, 403: return .authInvalid
        case 408, 429, 502, 503, 504: return .serverError(status: status, retryable: true)
        case 500...599: return .serverError(status: status, retryable: false)
        default: return .serverError(status: status, retryable: false)
        }
    }

    private func mapURLError(_ error: Swift.Error) -> Swift.Error {
        if error is App8Cloud.Error { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return App8Cloud.Error.timeout
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .dnsLookupFailed:
                return App8Cloud.Error.noNetwork(underlying: urlError)
            default:
                return App8Cloud.Error.noNetwork(underlying: urlError)
            }
        }
        return error
    }
}
