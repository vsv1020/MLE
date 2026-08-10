import Foundation

/// Result of creating an account.
///
/// Sign-up returns more than a session because the local backend also issues a one-time
/// recovery code that must be shown to the user exactly once. Modelling it as part of
/// the return value means it cannot be silently dropped.
public struct SignUpResult: Sendable {
    public var session: Session
    /// Shown once, then never retrievable. `nil` for backends that recover by email.
    public var recoveryCode: String?

    public init(session: Session, recoveryCode: String? = nil) {
        self.session = session
        self.recoveryCode = recoveryCode
    }
}

/// Everything an authentication provider must be able to do.
///
/// Two implementations ship: ``LocalAuthBackend`` (offline, on-device) and
/// ``RemoteAuthBackend`` (REST). The protocol exists so the UI never learns which one is
/// live — which is what makes "works offline" and "syncs when you have an account" the
/// same code path rather than two.
///
/// `@MainActor` because the local implementation writes through a SwiftData
/// `ModelContext` owned by the main actor. The remote implementation does its I/O in
/// detached `async` calls regardless, so nothing blocks the main thread.
@MainActor
public protocol AuthBackend {
    /// `false` when the backend needs a network and there is none, so the UI can explain
    /// itself instead of failing a request.
    var isAvailable: Bool { get }

    func signUp(email: String, password: String, displayName: String) async throws -> SignUpResult
    func signIn(email: String, password: String) async throws -> Session
    func signIn(apple credential: AppleCredential) async throws -> Session

    /// Begin recovery. The local backend verifies a recovery code offline; a remote one
    /// would send an email. Returns whether a code is required next.
    func beginPasswordReset(email: String) async throws -> PasswordResetChallenge

    func completePasswordReset(email: String, proof: String, newPassword: String) async throws

    func changePassword(session: Session, currentPassword: String, newPassword: String) async throws

    func updateProfile(session: Session, displayName: String?, email: String?) async throws -> Session

    /// Remove the account. Must be reachable from inside the app — App Store guideline
    /// 5.1.1(v) requires in-app deletion for any app that supports account creation.
    func deleteAccount(session: Session) async throws

    /// Re-validate a session restored from the Keychain at launch.
    func restore(_ session: Session) async throws -> Session

    func signOut(session: Session) async throws
}

/// What the user must supply to finish a password reset.
public enum PasswordResetChallenge: Hashable, Sendable {
    /// Enter the one-time recovery code issued at sign-up. Used offline.
    case recoveryCode
    /// A reset link was emailed. Used when a server exists.
    case emailedLink
}
