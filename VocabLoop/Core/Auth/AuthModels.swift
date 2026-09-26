import Foundation

/// An authenticated (or guest) session.
///
/// The only thing the UI ever sees. Whichever ``AuthBackend`` produced it — local,
/// remote, or Apple — the shape is identical, which is what keeps the views from
/// growing per-provider branches.
public struct Session: Codable, Hashable, Sendable {
    public var userID: String
    public var provider: AuthProvider
    public var email: String?
    public var displayName: String
    /// Bearer token for the remote API. `nil` for local and guest sessions.
    public var accessToken: String?
    public var refreshToken: String?
    public var expiresAt: Date?
    public var createdAt: Date

    public init(
        userID: String,
        provider: AuthProvider,
        email: String? = nil,
        displayName: String,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.userID = userID
        self.provider = provider
        self.email = email
        self.displayName = displayName
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }

    public var isGuest: Bool { provider == .guest }

    /// `true` when a remote session's token has expired and needs refreshing.
    /// Local and guest sessions never expire — there is nothing to expire against.
    public func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    public static func guest(userID: String) -> Session {
        Session(userID: userID, provider: .guest, displayName: "Guest")
    }
}

/// Credential taken from Sign in with Apple, normalised so ``AuthBackend`` does not
/// depend on `AuthenticationServices`.
public struct AppleCredential: Hashable, Sendable {
    /// Apple's stable, opaque per-team user identifier. The only field we can rely on.
    public var userIdentifier: String
    /// Present on first authorisation only, and possibly a private relay address.
    public var email: String?
    /// Present on first authorisation only.
    public var fullName: String?
    /// JWT for server-side verification. Unused by the local backend.
    public var identityToken: Data?

    public init(
        userIdentifier: String,
        email: String? = nil,
        fullName: String? = nil,
        identityToken: Data? = nil
    ) {
        self.userIdentifier = userIdentifier
        self.email = email
        self.fullName = fullName
        self.identityToken = identityToken
    }
}

/// Credential from Google sign-in, already verified by ``GoogleSignInCoordinator``.
public struct GoogleCredential: Hashable, Sendable {
    /// The ID token's `sub`: stable for the life of the Google account.
    public var userIdentifier: String
    /// Only set when Google reports the address as verified.
    public var email: String?
    public var fullName: String?
    /// Raw ID token, for a server to verify independently. Unused by the local backend.
    public var idToken: String

    public init(userIdentifier: String, email: String? = nil, fullName: String? = nil, idToken: String) {
        self.userIdentifier = userIdentifier
        self.email = email
        self.fullName = fullName
        self.idToken = idToken
    }
}

/// Errors surfaced to the user.
///
/// Messages are deliberately vague about *which* credential was wrong.
/// ``invalidCredentials`` covers both "no such account" and "wrong password", because
/// distinguishing them turns the sign-in form into an account-enumeration oracle. It is
/// also why sign-up reports ``emailAlreadyRegistered`` only after the password has
/// passed validation.
public enum AuthError: LocalizedError, Equatable {
    case invalidEmail
    case weakPassword(reason: String)
    case passwordsDoNotMatch
    case emailAlreadyRegistered
    case invalidCredentials
    case notSignedIn
    case sessionExpired
    case recoveryCodeInvalid
    case recoveryCodeAlreadyUsed
    case appleSignInFailed(String)
    case appleSignInUnavailable
    case appleSignInCancelled
    case googleSignInFailed(String)
    case googleSignInCancelled
    case providerDoesNotSupportPasswords
    case network(String)
    case server(status: Int, message: String?)
    case keychain(status: Int32)
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEmail:
            "That does not look like an email address."
        case .weakPassword(let reason):
            reason
        case .passwordsDoNotMatch:
            "The two passwords do not match."
        case .emailAlreadyRegistered:
            "An account already exists for that email. Try signing in instead."
        case .invalidCredentials:
            "That email and password do not match an account."
        case .notSignedIn:
            "You need to be signed in to do that."
        case .sessionExpired:
            "Your session has expired. Please sign in again."
        case .recoveryCodeInvalid:
            "That recovery code is not correct."
        case .recoveryCodeAlreadyUsed:
            "That recovery code has already been used. Each code works once."
        case .appleSignInFailed(let detail):
            "Sign in with Apple did not complete: \(detail)"
        case .appleSignInUnavailable:
            "Sign in with Apple is not enabled for this build. "
            + "Add the Sign in with Apple capability in Xcode, or use email instead."
        case .appleSignInCancelled, .googleSignInCancelled:
            // Not surfaced — the user knows they cancelled.
            nil
        case .googleSignInFailed(let detail):
            "Sign in with Google did not complete: \(detail)"
        case .providerDoesNotSupportPasswords:
            "This account signs in with Apple or Google, so it has no password to change."
        case .network(let detail):
            "Could not reach the server: \(detail)"
        case .server(let status, let message):
            message ?? "The server returned an error (\(status))."
        case .keychain(let status):
            "Could not access the keychain (code \(status))."
        case .storage(let detail):
            "Could not save your account: \(detail)"
        }
    }

    /// `true` for errors that are not worth showing an alert for.
    public var isSilent: Bool { self == .appleSignInCancelled || self == .googleSignInCancelled }
}

/// Email and password validation.
///
/// Password rules follow NIST SP 800-63B rather than the usual composition theatre:
/// length is what matters, a generous maximum must be allowed, and the useful check is
/// against known-common passwords — not against whether the user remembered to add a
/// punctuation mark.
public enum CredentialValidator {
    public static let minimumPasswordLength = 8
    /// NIST requires at least 64 to be accepted. The cap exists only to bound the
    /// PBKDF2 input.
    public static let maximumPasswordLength = 128

    /// Deliberately permissive. Over-strict email regexes reject valid addresses, and
    /// the only real test of an address is whether mail arrives.
    public static func isValidEmail(_ email: String) -> Bool {
        let trimmed = email.normalizedEmail
        guard trimmed.count >= 5, trimmed.count <= 254 else { return false }
        guard !trimmed.contains(" ") else { return false }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let (local, domain) = (parts[0], parts[1])
        guard !local.isEmpty, !domain.isEmpty else { return false }
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        guard !domain.contains("..") else { return false }
        return true
    }

    /// A short list of the passwords that appear at the top of every breach corpus.
    ///
    /// Not a substitute for a real blocklist — a shipping app should check against a
    /// large corpus, ideally via a k-anonymity range query. This catches the worst
    /// offenders offline, which is the constraint we are actually under.
    static let blockedPasswords: Set<String> = [
        "password", "12345678", "123456789", "1234567890", "qwerty123", "password1",
        "password123", "iloveyou", "abc12345", "letmein1", "welcome1", "admin123",
        "qwertyuiop", "1q2w3e4r", "sunshine", "princess", "football", "baseball",
        "trustno1", "superman", "starwars", "whatever", "vocabloop",
    ]

    public static func validatePassword(_ password: String) -> AuthError? {
        if password.count < minimumPasswordLength {
            return .weakPassword(
                reason: "Use at least \(minimumPasswordLength) characters. Length matters more than symbols."
            )
        }
        if password.count > maximumPasswordLength {
            return .weakPassword(reason: "That password is longer than \(maximumPasswordLength) characters.")
        }
        // Whitespace-only passwords pass a length check but are almost certainly a
        // paste accident.
        if password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .weakPassword(reason: "Your password cannot be only spaces.")
        }
        if blockedPasswords.contains(password.lowercased()) {
            return .weakPassword(reason: "That password appears in lists of common passwords. Choose another.")
        }
        return nil
    }

    /// Rough strength indicator for the sign-up form's meter, `0…1`.
    ///
    /// Length-dominant on purpose, so the meter rewards what actually helps rather than
    /// teaching users to append "!1".
    public static func passwordStrength(_ password: String) -> Double {
        guard !password.isEmpty else { return 0 }
        var score = min(Double(password.count) / 16.0, 0.75)
        var classes = 0
        if password.rangeOfCharacter(from: .lowercaseLetters) != nil { classes += 1 }
        if password.rangeOfCharacter(from: .uppercaseLetters) != nil { classes += 1 }
        if password.rangeOfCharacter(from: .decimalDigits) != nil { classes += 1 }
        if password.rangeOfCharacter(from: .punctuationCharacters.union(.symbols)) != nil { classes += 1 }
        score += Double(classes) * 0.0625
        if blockedPasswords.contains(password.lowercased()) { return 0.05 }
        return min(score, 1)
    }
}
