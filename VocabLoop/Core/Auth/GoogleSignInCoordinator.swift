import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

/// Where the Google OAuth client ID comes from.
///
/// Read from the `GIDClientID` Info.plist key, which the build fills from the
/// `GOOGLE_CLIENT_ID` build setting (see `Config/Info.plist`). A build without one hides the
/// Google button rather than showing one that fails — a dead button is a review rejection.
public enum GoogleSignInConfiguration {
    public static var clientID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unexpanded `$(GOOGLE_CLIENT_ID)` or an empty setting both mean "not configured".
        guard trimmed.hasSuffix(".apps.googleusercontent.com") else { return nil }
        return trimmed
    }

    public static var isConfigured: Bool { clientID != nil }
}

/// Google sign-in without the Google SDK.
///
/// The flow is the one Google documents for iOS clients: authorization code with PKCE, run in
/// an `ASWebAuthenticationSession`, redirected back through the reversed client ID scheme, then
/// exchanged for tokens at Google's token endpoint. An iOS client has no secret, so nothing
/// sensitive ships in the binary. Doing it directly keeps a large third-party dependency (and
/// its privacy manifest) out of an app that only needs the user's ID and email.
@MainActor
public final class GoogleSignInCoordinator: NSObject {
    private var session: ASWebAuthenticationSession?
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        super.init()
    }

    public func requestCredential() async throws -> GoogleCredential {
        guard let clientID = GoogleSignInConfiguration.clientID else {
            throw AuthError.googleSignInFailed("Google sign-in is not configured for this build.")
        }
        guard session == nil else {
            throw AuthError.googleSignInFailed("A sign-in request is already in progress.")
        }

        let request = GoogleOAuthRequest(clientID: clientID)
        defer { session = nil }
        let callback = try await authorize(request)
        let code = try request.authorizationCode(from: callback)
        let idToken = try await exchange(code: code, request: request)
        return try GoogleIDToken.verify(idToken, clientID: clientID, nonce: request.nonce)
    }

    private func authorize(_ request: GoogleOAuthRequest) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: request.authorizationURL,
                callbackURLScheme: request.callbackScheme
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.googleSignInCancelled)
                } else {
                    continuation.resume(throwing: AuthError.googleSignInFailed(
                        error?.localizedDescription ?? "No response from Google."
                    ))
                }
            }
            session.presentationContextProvider = self
            // Share Safari's Google cookie, so someone already signed in to Google only picks
            // an account instead of typing a password.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: AuthError.googleSignInFailed("Could not open the sign-in page."))
            }
        }
    }

    private func exchange(code: String, request: GoogleOAuthRequest) async throws -> String {
        var urlRequest = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = request.tokenRequestBody(code: code)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: urlRequest)
        } catch {
            throw AuthError.network(error.localizedDescription)
        }
        struct TokenResponse: Decodable {
            var id_token: String?
            var error: String?
            var error_description: String?
        }
        let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let token = decoded?.id_token else {
            throw AuthError.googleSignInFailed(
                decoded?.error_description ?? decoded?.error ?? "Google did not return an ID token."
            )
        }
        return token
    }
}

extension GoogleSignInCoordinator: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first { $0.activationState == .foregroundActive }?.keyWindow
            ?? scenes.first?.windows.first
        return window ?? ASPresentationAnchor()
    }
}

// MARK: - Request

/// One authorization attempt: the PKCE verifier, `state` and `nonce` that tie the redirect and
/// the ID token back to this request. Pure value logic, so it is testable without a browser.
struct GoogleOAuthRequest {
    let clientID: String
    let codeVerifier: String
    let state: String
    let nonce: String

    init(clientID: String, codeVerifier: String = Self.randomToken(), state: String = Self.randomToken(),
         nonce: String = Self.randomToken()) {
        self.clientID = clientID
        self.codeVerifier = codeVerifier
        self.state = state
        self.nonce = nonce
    }

    /// `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`.
    var callbackScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    var redirectURI: String { "\(callbackScheme):/oauth2redirect" }

    var codeChallenge: String {
        Data(SHA256.hash(data: Data(codeVerifier.utf8))).base64URLEncoded
    }

    var authorizationURL: URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return components.url!
    }

    func authorizationCode(from callback: URL) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            throw error == "access_denied" ? AuthError.googleSignInCancelled : AuthError.googleSignInFailed(error)
        }
        // A redirect carrying someone else's `state` is a forged or replayed response.
        guard value("state") == state else {
            throw AuthError.googleSignInFailed("The response did not match this sign-in request.")
        }
        guard let code = value("code"), !code.isEmpty else {
            throw AuthError.googleSignInFailed("Google did not return an authorization code.")
        }
        return code
    }

    func tokenRequestBody(code: String) -> Data {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
        ]
        // `URLComponents` leaves `+` alone, which a form body would read as a space.
        let query = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        return Data(query.utf8)
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

// MARK: - ID token

/// Checks on the ID token's claims.
///
/// The token arrives straight from Google's token endpoint over TLS in exchange for a code
/// only this request could redeem, which is what OpenID Connect accepts in place of a
/// signature check for a native client. The claims are still checked, so a token minted for
/// another app, another request or another time is refused.
enum GoogleIDToken {
    static let issuers: Set<String> = ["https://accounts.google.com", "accounts.google.com"]

    static func verify(_ token: String, clientID: String, nonce: String, now: Date = Date()) throws -> GoogleCredential {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = Data(base64URLEncoded: String(parts[1])) else {
            throw AuthError.googleSignInFailed("Malformed ID token.")
        }
        struct Claims: Decodable {
            var iss: String
            var aud: String
            var sub: String
            var exp: TimeInterval
            var nonce: String?
            var email: String?
            var email_verified: Bool?
            var name: String?
        }
        guard let claims = try? JSONDecoder().decode(Claims.self, from: payload) else {
            throw AuthError.googleSignInFailed("Malformed ID token.")
        }
        guard issuers.contains(claims.iss), claims.aud == clientID, claims.nonce == nonce else {
            throw AuthError.googleSignInFailed("The ID token was not issued for this sign-in.")
        }
        guard Date(timeIntervalSince1970: claims.exp) > now else {
            throw AuthError.googleSignInFailed("The ID token has expired.")
        }
        return GoogleCredential(
            userIdentifier: claims.sub,
            // An unverified address is not evidence of anything, so it is not passed on —
            // the local backend links accounts by email.
            email: claims.email_verified == true ? claims.email : nil,
            fullName: claims.name,
            idToken: token
        )
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
