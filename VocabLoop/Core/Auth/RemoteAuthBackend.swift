import Foundation
import SwiftData

/// Authentication against a REST server.
///
/// Not wired up in the shipping build — ``APIConfiguration/offline`` leaves `baseURL`
/// nil, so ``isAvailable`` is false and ``AuthService`` uses ``LocalAuthBackend``
/// instead. It exists now, rather than later, because it is what proves the
/// ``AuthBackend`` boundary is real: if the protocol were shaped around the local
/// implementation's conveniences, writing this would have forced a change to it.
///
/// The wire contract below is the one a server would have to implement. Documenting it
/// in code, with concrete request and response types, is more useful than a README that
/// drifts.
@MainActor
public final class RemoteAuthBackend: AuthBackend {
    private let client: APIClient
    private let context: ModelContext
    private let isServerConfigured: Bool

    public init(client: APIClient, context: ModelContext, isServerConfigured: Bool) {
        self.client = client
        self.context = context
        self.isServerConfigured = isServerConfigured
    }

    public var isAvailable: Bool { isServerConfigured }

    // MARK: - Wire contract

    struct SignUpRequest: Encodable {
        var email: String
        var password: String
        var displayName: String
    }

    struct SignInRequest: Encodable {
        var email: String
        var password: String
    }

    struct AppleSignInRequest: Encodable {
        var identityToken: String
        var userIdentifier: String
        var email: String?
        var fullName: String?
    }

    struct GoogleSignInRequest: Encodable {
        var idToken: String
    }

    struct ResetRequest: Encodable {
        var email: String
    }

    struct CompleteResetRequest: Encodable {
        var email: String
        var token: String
        var newPassword: String
    }

    struct ChangePasswordRequest: Encodable {
        var currentPassword: String
        var newPassword: String
    }

    struct UpdateProfileRequest: Encodable {
        var displayName: String?
        var email: String?
    }

    /// `POST /auth/*` response.
    struct SessionResponse: Decodable {
        var userId: String
        var email: String?
        var displayName: String
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
    }

    private static let signUp = APIClient.Endpoint(path: "auth/sign-up", method: "POST", requiresAuth: false)
    private static let signIn = APIClient.Endpoint(path: "auth/sign-in", method: "POST", requiresAuth: false)
    private static let appleSignIn = APIClient.Endpoint(path: "auth/apple", method: "POST", requiresAuth: false)
    private static let googleSignIn = APIClient.Endpoint(path: "auth/google", method: "POST", requiresAuth: false)
    private static let resetRequest = APIClient.Endpoint(path: "auth/reset", method: "POST", requiresAuth: false)
    private static let resetComplete = APIClient.Endpoint(path: "auth/reset/complete", method: "POST", requiresAuth: false)
    private static let changePassword = APIClient.Endpoint(path: "auth/password", method: "PUT")
    private static let profile = APIClient.Endpoint(path: "auth/profile", method: "PATCH")
    private static let deleteAccount = APIClient.Endpoint(path: "auth/account", method: "DELETE")
    private static let refresh = APIClient.Endpoint(path: "auth/refresh", method: "POST")
    private static let signOutEndpoint = APIClient.Endpoint(path: "auth/sign-out", method: "POST")

    // MARK: - AuthBackend

    public func signUp(email: String, password: String, displayName: String) async throws -> SignUpResult {
        // Validate locally first. There is no reason to spend a round trip discovering
        // that a password is eight characters short.
        let normalisedEmail = email.normalizedEmail
        guard CredentialValidator.isValidEmail(normalisedEmail) else { throw AuthError.invalidEmail }
        if let problem = CredentialValidator.validatePassword(password) { throw problem }

        let response = try await client.send(
            Self.signUp,
            body: SignUpRequest(email: normalisedEmail, password: password, displayName: displayName),
            as: SessionResponse.self
        )
        let session = try await adopt(response, provider: .remote)
        // Recovery is by emailed link on a server, so there is no code to show.
        return SignUpResult(session: session, recoveryCode: nil)
    }

    public func signIn(email: String, password: String) async throws -> Session {
        let response = try await client.send(
            Self.signIn,
            body: SignInRequest(email: email.normalizedEmail, password: password),
            as: SessionResponse.self
        )
        return try await adopt(response, provider: .remote)
    }

    public func signIn(apple credential: AppleCredential) async throws -> Session {
        guard let token = credential.identityToken.map({ $0.base64EncodedString() }) else {
            throw AuthError.appleSignInFailed("Apple did not return an identity token.")
        }
        let response = try await client.send(
            Self.appleSignIn,
            body: AppleSignInRequest(
                identityToken: token,
                userIdentifier: credential.userIdentifier,
                email: credential.email,
                fullName: credential.fullName
            ),
            as: SessionResponse.self
        )
        let session = try await adopt(response, provider: .apple)
        if let account = try findAccount(withUserID: session.userID) {
            account.appleUserIdentifier = credential.userIdentifier
            try context.save()
        }
        return session
    }

    /// The server must verify the ID token itself (signature, `aud`, `iss`, `exp`) — the
    /// client-side checks only protect the on-device account.
    public func signIn(google credential: GoogleCredential) async throws -> Session {
        let response = try await client.send(
            Self.googleSignIn,
            body: GoogleSignInRequest(idToken: credential.idToken),
            as: SessionResponse.self
        )
        let session = try await adopt(response, provider: .google)
        if let account = try findAccount(withUserID: session.userID) {
            account.googleUserIdentifier = credential.userIdentifier
            try context.save()
        }
        return session
    }

    public func beginPasswordReset(email: String) async throws -> PasswordResetChallenge {
        try await client.send(Self.resetRequest, body: ResetRequest(email: email.normalizedEmail))
        return .emailedLink
    }

    public func completePasswordReset(email: String, proof: String, newPassword: String) async throws {
        if let problem = CredentialValidator.validatePassword(newPassword) { throw problem }
        try await client.send(
            Self.resetComplete,
            body: CompleteResetRequest(
                email: email.normalizedEmail, token: proof, newPassword: newPassword
            )
        )
    }

    public func changePassword(session: Session, currentPassword: String, newPassword: String) async throws {
        if let problem = CredentialValidator.validatePassword(newPassword) { throw problem }
        await client.setBearerToken(session.accessToken)
        try await client.send(
            Self.changePassword,
            body: ChangePasswordRequest(currentPassword: currentPassword, newPassword: newPassword)
        )
    }

    public func updateProfile(session: Session, displayName: String?, email: String?) async throws -> Session {
        await client.setBearerToken(session.accessToken)
        let response = try await client.send(
            Self.profile,
            body: UpdateProfileRequest(displayName: displayName, email: email?.normalizedEmail),
            as: SessionResponse.self
        )
        return try await adopt(response, provider: session.provider)
    }

    public func deleteAccount(session: Session) async throws {
        await client.setBearerToken(session.accessToken)
        try await client.send(Self.deleteAccount)
        // The server has confirmed. Local removal reuses the local backend so there is
        // exactly one implementation of "erase everything", and it cannot drift.
        try await LocalAuthBackend(context: context).deleteAccount(session: session)
    }

    public func restore(_ session: Session) async throws -> Session {
        guard !session.isExpired() else {
            guard session.refreshToken != nil else { throw AuthError.sessionExpired }
            await client.setBearerToken(session.refreshToken)
            let response = try await client.send(Self.refresh, as: SessionResponse.self)
            return try await adopt(response, provider: session.provider)
        }
        await client.setBearerToken(session.accessToken)
        return session
    }

    public func signOut(session: Session) async throws {
        await client.setBearerToken(session.accessToken)
        // A failed sign-out request must not trap the user in a signed-in state — the
        // local session is cleared by AuthService regardless.
        try? await client.send(Self.signOutEndpoint)
        await client.setBearerToken(nil)
        try await LocalAuthBackend(context: context).signOut(session: session)
    }

    // MARK: - Local mirror

    /// Mirror the server's identity into the local store.
    ///
    /// The local ``UserAccount`` row still has to exist even for a remote account,
    /// because every query in the app scopes by `userID`. As with the local backend, an
    /// active guest is adopted rather than replaced, so signing up does not discard what
    /// the user studied first.
    private func adopt(_ response: SessionResponse, provider: AuthProvider) async throws -> Session {
        let now = Date()
        let account: UserAccount
        // `findAccount` rather than `account`: a local constant named `account` shadows a
        // method of the same name for the whole scope, including the line that declares it,
        // so `try account(withRemoteID:)` reads as calling a `UserAccount` value.
        if let existing = try findAccount(withRemoteID: response.userId) {
            account = existing
        } else if let guest = try adoptableGuest() {
            account = guest
        } else {
            let fresh = UserAccount(displayName: response.displayName, provider: provider, now: now)
            context.insert(fresh)
            account = fresh
        }

        account.remoteID = response.userId
        account.email = response.email?.normalizedEmail
        if !response.displayName.isEmpty { account.displayName = response.displayName }
        account.provider = provider
        account.isActive = true
        account.lastSignedInAt = now
        account.touch(now)

        let keep = account.userID
        for other in try context.fetch(
            FetchDescriptor<UserAccount>(predicate: #Predicate { $0.userID != keep && $0.isActive })
        ) {
            other.isActive = false
        }
        try context.save()

        await client.setBearerToken(response.accessToken)
        return Session(
            userID: account.userID,
            provider: provider,
            email: account.email,
            displayName: account.displayName,
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: response.expiresAt,
            createdAt: now
        )
    }

    private func findAccount(withRemoteID remoteID: String) throws -> UserAccount? {
        var descriptor = FetchDescriptor<UserAccount>(predicate: #Predicate { $0.remoteID == remoteID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func findAccount(withUserID userID: String) throws -> UserAccount? {
        var descriptor = FetchDescriptor<UserAccount>(predicate: #Predicate { $0.userID == userID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func adoptableGuest() throws -> UserAccount? {
        let guestRaw = AuthProvider.guest.rawValue
        var descriptor = FetchDescriptor<UserAccount>(
            predicate: #Predicate { $0.providerRaw == guestRaw && $0.isActive }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
