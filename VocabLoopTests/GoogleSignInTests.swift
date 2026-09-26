import XCTest
import SwiftData
@testable import VocabLoop

@MainActor
final class GoogleSignInTests: XCTestCase {
    private let clientID = "123-abc.apps.googleusercontent.com"

    // MARK: - OAuth request

    func testCallbackSchemeIsTheReversedClientID() {
        let request = GoogleOAuthRequest(clientID: clientID)
        XCTAssertEqual(request.callbackScheme, "com.googleusercontent.apps.123-abc")
        XCTAssertEqual(request.redirectURI, "com.googleusercontent.apps.123-abc:/oauth2redirect")
    }

    /// The worked example from RFC 7636, appendix B.
    func testCodeChallengeMatchesTheRFCVector() {
        let request = GoogleOAuthRequest(
            clientID: clientID, codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        )
        XCTAssertEqual(request.codeChallenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAuthorizationURLCarriesPKCEStateAndNonce() throws {
        let request = GoogleOAuthRequest(clientID: clientID, codeVerifier: "v", state: "s1", nonce: "n1")
        let items = try XCTUnwrap(URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("client_id"), clientID)
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("state"), "s1")
        XCTAssertEqual(value("nonce"), "n1")
        XCTAssertEqual(value("scope"), "openid email profile")
    }

    func testCallbackWithAnotherRequestsStateIsRefused() {
        let request = GoogleOAuthRequest(clientID: clientID, state: "mine")
        let forged = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?code=abc&state=theirs")!
        XCTAssertThrowsError(try request.authorizationCode(from: forged))

        let genuine = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?code=abc&state=mine")!
        XCTAssertEqual(try request.authorizationCode(from: genuine), "abc")
    }

    func testDeclinedConsentIsSilent() {
        let request = GoogleOAuthRequest(clientID: clientID, state: "mine")
        let denied = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?error=access_denied&state=mine")!
        XCTAssertThrowsError(try request.authorizationCode(from: denied)) { error in
            XCTAssertEqual(error as? AuthError, .googleSignInCancelled)
        }
    }

    // MARK: - ID token

    private func token(_ claims: [String: Any]) throws -> String {
        let header = Data(#"{"alg":"RS256"}"#.utf8).base64URLEncoded
        let payload = try JSONSerialization.data(withJSONObject: claims).base64URLEncoded
        return "\(header).\(payload).signature"
    }

    private func claims(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = [
            "iss": "https://accounts.google.com", "aud": clientID, "sub": "10987",
            "exp": Date().addingTimeInterval(600).timeIntervalSince1970, "nonce": "n1",
            "email": "person@gmail.com", "email_verified": true, "name": "Pat Person",
        ]
        base.merge(overrides) { $1 }
        return base
    }

    func testValidTokenYieldsACredential() throws {
        let credential = try GoogleIDToken.verify(try token(claims()), clientID: clientID, nonce: "n1")
        XCTAssertEqual(credential.userIdentifier, "10987")
        XCTAssertEqual(credential.email, "person@gmail.com")
        XCTAssertEqual(credential.fullName, "Pat Person")
    }

    func testTokenForAnotherAppIsRefused() throws {
        XCTAssertThrowsError(try GoogleIDToken.verify(
            try token(claims(["aud": "other.apps.googleusercontent.com"])), clientID: clientID, nonce: "n1"
        ))
    }

    func testTokenFromAnotherRequestIsRefused() throws {
        XCTAssertThrowsError(try GoogleIDToken.verify(try token(claims()), clientID: clientID, nonce: "n2"))
    }

    func testExpiredTokenIsRefused() throws {
        XCTAssertThrowsError(try GoogleIDToken.verify(
            try token(claims(["exp": Date().addingTimeInterval(-5).timeIntervalSince1970])),
            clientID: clientID, nonce: "n1"
        ))
    }

    /// An unverified address proves nothing, and the local backend links accounts by email.
    func testUnverifiedEmailIsDropped() throws {
        let credential = try GoogleIDToken.verify(
            try token(claims(["email_verified": false])), clientID: clientID, nonce: "n1"
        )
        XCTAssertNil(credential.email)
    }

    // MARK: - Local backend

    func testGoogleSignInKeepsGuestProgressAndMatchesOnSub() async throws {
        let context = try TestStore.makeContext()
        let guest = try context.activeAccount()
        let backend = LocalAuthBackend(context: context)

        let first = try await backend.signIn(google: GoogleCredential(
            userIdentifier: "10987", email: "person@gmail.com", fullName: "Pat Person", idToken: "t"
        ))
        XCTAssertEqual(first.userID, guest.userID, "signing in must keep what the guest studied")
        XCTAssertEqual(first.provider, .google)
        XCTAssertEqual(first.displayName, "Pat Person")

        // The address changed on Google's side: still the same account.
        let second = try await backend.signIn(google: GoogleCredential(
            userIdentifier: "10987", email: "renamed@gmail.com", idToken: "t"
        ))
        XCTAssertEqual(second.userID, first.userID)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserAccount>()), 1)
    }

    func testGoogleLinksToAnEmailAccountWithTheSameAddress() async throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let backend = LocalAuthBackend(context: context)
        let created = try await backend.signUp(
            email: "person@gmail.com", password: "a good long password", displayName: "Pat"
        )
        try await backend.signOut(session: created.session)

        let viaGoogle = try await backend.signIn(google: GoogleCredential(
            userIdentifier: "10987", email: "person@gmail.com", idToken: "t"
        ))
        XCTAssertEqual(viaGoogle.userID, created.session.userID, "one person, one account")

        // Linking must not take the password away.
        let viaPassword = try await backend.signIn(email: "person@gmail.com", password: "a good long password")
        XCTAssertEqual(viaPassword.userID, created.session.userID)
    }
}
