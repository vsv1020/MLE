import Foundation
import OSLog

/// Where the optional backend lives.
///
/// `baseURL` is `nil` until a server exists, and that is the switch that keeps the app
/// fully offline: ``APIClient/isConfigured`` is false, ``RemoteAuthBackend`` reports
/// itself unavailable, and ``SyncEngine`` never leaves the outbox. Nothing else in the
/// app has to know.
public struct APIConfiguration: Sendable {
    /// `private(set)` so the HTTPS check in the initialiser cannot be bypassed by assigning
    /// to it afterwards.
    public private(set) var baseURL: URL?
    public var timeout: TimeInterval

    public init(baseURL: URL? = nil, timeout: TimeInterval = 20) {
        if Self.isTransportAcceptable(baseURL) {
            self.baseURL = baseURL
        } else {
            // Trap in development so the mistake is found immediately, but still refuse the URL
            // in release rather than shipping a build that talks plaintext.
            assertionFailure("VocabLoop's API base URL must be https, got \(baseURL?.scheme ?? "none")")
            self.baseURL = nil
        }
        self.timeout = timeout
    }

    /// Whether a base URL may be used.
    ///
    /// Checked here rather than relying on App Transport Security: ATS can be weakened by an
    /// Info.plist exception, and a bearer token must never leave the device in clear text
    /// because someone pointed the app at a local test server. `nil` is acceptable — it is the
    /// shipping configuration.
    ///
    /// Separated from the initialiser so it is testable; constructing a bad configuration would
    /// trip the assertion above and abort the test run.
    public static func isTransportAcceptable(_ url: URL?) -> Bool {
        guard let url else { return true }
        return url.scheme?.lowercased() == "https"
    }

    /// No server configured — the shipping default.
    public static let offline = APIConfiguration()
}

/// Minimal REST transport.
///
/// Hand-rolled rather than pulling in a networking library: the whole surface is five
/// endpoints, and a dependency here would have to be justified against an app that is
/// designed to work without a network at all.
public actor APIClient {
    public struct Endpoint: Sendable {
        public var path: String
        public var method: String
        public var requiresAuth: Bool

        public init(path: String, method: String = "GET", requiresAuth: Bool = true) {
            self.path = path
            self.method = method
            self.requiresAuth = requiresAuth
        }
    }

    private let configuration: APIConfiguration
    private let session: URLSession
    private let logger = Logger(subsystem: "com.vocabloop.app", category: "api")
    private var bearerToken: String?

    public init(configuration: APIConfiguration = .offline, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = configuration.timeout
            // Never serve a cached response for an API call: a stale review count is
            // worse than no review count.
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            // And never *write* one either. `requestCachePolicy` only stops reads; without
            // this, authenticated API responses would sit in an on-disk URLCache that no
            // sign-out clears.
            config.urlCache = nil
            // Cookies would be a second, invisible source of session state alongside the
            // Keychain. The API is bearer-token only.
            config.httpCookieAcceptPolicy = .never
            config.httpShouldSetCookies = false
            // Let the OS wait for connectivity rather than failing instantly — this is an
            // app that expects to be offline.
            config.waitsForConnectivity = true
            self.session = URLSession(configuration: config)
        }
    }

    public var isConfigured: Bool { configuration.baseURL != nil }

    public func setBearerToken(_ token: String?) {
        bearerToken = token
    }

    /// Send a request with a body and decode the response.
    ///
    /// Throws ``AuthError/network(_:)`` when there is no server configured, so callers
    /// get one consistent failure instead of having to check `isConfigured` first.
    public func send<Body: Encodable, Response: Decodable>(
        _ endpoint: Endpoint,
        body: Body,
        as responseType: Response.Type
    ) async throws -> Response {
        try decode(try await sendRaw(endpoint, body: body))
    }

    /// Send a request with no body and decode the response.
    public func send<Response: Decodable>(
        _ endpoint: Endpoint,
        as responseType: Response.Type
    ) async throws -> Response {
        try decode(try await sendRaw(endpoint, body: Empty?.none))
    }

    /// Send a request with a body, ignoring the response.
    public func send<Body: Encodable>(_ endpoint: Endpoint, body: Body) async throws {
        _ = try await sendRaw(endpoint, body: body)
    }

    /// Send a request with no body, ignoring the response.
    public func send(_ endpoint: Endpoint) async throws {
        _ = try await sendRaw(endpoint, body: Empty?.none)
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            // The request succeeded but the payload was not what we expect — a server
            // contract mismatch. Reported as a server error, because it is one.
            throw AuthError.server(status: 200, message: "Unexpected response from the server.")
        }
    }

    private func sendRaw<Body: Encodable>(_ endpoint: Endpoint, body: Body?) async throws -> Data {
        guard let baseURL = configuration.baseURL else {
            throw AuthError.network("No server is configured for this build.")
        }
        if endpoint.requiresAuth, bearerToken == nil {
            throw AuthError.notSignedIn
        }

        var request = URLRequest(url: baseURL.appending(path: endpoint.path))
        request.httpMethod = endpoint.method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken, endpoint.requiresAuth {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw AuthError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AuthError.network("Malformed response.")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw AuthError.sessionExpired
        default:
            // Surface the server's own message when it sends one — a generic "error 422"
            // is useless to both the user and to us.
            let message = (try? Self.decoder.decode(ErrorEnvelope.self, from: data))?.message
            logger.error("\(endpoint.method, privacy: .public) \(endpoint.path, privacy: .public) → \(http.statusCode)")
            throw AuthError.server(status: http.statusCode, message: message)
        }
    }

    /// Placeholder for calls with no request body.
    public struct Empty: Codable, Sendable {}

    private struct ErrorEnvelope: Decodable {
        var message: String?
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
