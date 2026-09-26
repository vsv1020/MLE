import Foundation
import SwiftData
import Observation
import OSLog

/// The app's single source of truth for who is signed in.
///
/// Sits above ``AuthBackend`` and owns the parts that are the same regardless of
/// provider: session persistence in the Keychain, restoring at launch, guest fallback,
/// and publishing state to the UI.
///
/// The rule that shapes it: **auth never gates studying.** ``current`` is non-nil from
/// the first launch onward, because a guest session is created if there is nothing else.
/// There is no state in which the app shows a sign-in wall.
@MainActor
@Observable
public final class AuthService {
    /// The active session. Never `nil` after ``restore()`` — guest is a real session.
    public private(set) var current: Session?
    /// `true` while a sign-in, sign-up or restore is in flight.
    public private(set) var isBusy = false
    /// Last failure, for the form to display. Cleared on the next attempt.
    public private(set) var lastError: AuthError?

    /// Recovery code from the most recent sign-up. Held only until the UI has shown it,
    /// then cleared by ``acknowledgeRecoveryCode()`` — it must not linger in memory or be
    /// re-showable, or it stops being a one-time secret.
    public private(set) var pendingRecoveryCode: String?

    private let context: ModelContext
    private let keychain: KeychainStore
    private let localBackend: LocalAuthBackend
    private let remoteBackend: RemoteAuthBackend?
    private let appleCoordinator: AppleSignInCoordinator
    private let googleCoordinator: GoogleSignInCoordinator
    private let logger = Logger(subsystem: "com.vocabloop.app", category: "auth")

    /// - Parameter appleCoordinator: Pass a stub in tests. Defaults to `nil` rather than to
    ///   `AppleSignInCoordinator()`, because a default argument is evaluated in a *nonisolated*
    ///   context and that type is `@MainActor` — the direct default did not compile.
    public init(
        context: ModelContext,
        keychain: KeychainStore = KeychainStore(),
        remoteBackend: RemoteAuthBackend? = nil,
        appleCoordinator: AppleSignInCoordinator? = nil
    ) {
        self.context = context
        self.keychain = keychain
        self.localBackend = LocalAuthBackend(context: context)
        self.remoteBackend = remoteBackend
        self.appleCoordinator = appleCoordinator ?? AppleSignInCoordinator()
        self.googleCoordinator = GoogleSignInCoordinator()
    }

    /// The backend to use: the remote one when a server is configured, otherwise local.
    ///
    /// Resolved per call rather than at init, so a build that gains a server does not
    /// need a different composition root.
    private var backend: any AuthBackend {
        if let remoteBackend, remoteBackend.isAvailable { return remoteBackend }
        return localBackend
    }

    public var isSignedIn: Bool { current?.isGuest == false }
    public var isGuest: Bool { current?.isGuest ?? true }

    /// `true` when the active provider has a password that can be changed.
    public var canChangePassword: Bool {
        current?.provider.supportsPasswordChange ?? false
    }

    // MARK: - Launch

    /// Restore the stored session, or fall back to guest.
    ///
    /// Called once at launch, before the first frame. Every failure path ends in a usable
    /// guest session rather than an error screen — a keychain hiccup or an expired token
    /// must not stop someone from reviewing.
    public func restore() async {
        isBusy = true
        defer { isBusy = false }

        do {
            if let stored = try keychain.load() {
                let refreshed = try await backend.restore(stored)
                try? keychain.save(refreshed)
                current = refreshed
                return
            }
        } catch let error as AuthError {
            logger.info("Session restore failed, continuing as guest: \(error.localizedDescription, privacy: .public)")
            try? keychain.delete()
        } catch {
            logger.info("Session restore failed, continuing as guest.")
            try? keychain.delete()
        }

        current = await ensureGuestSession()
    }

    /// Guarantee an active account exists and return its session.
    private func ensureGuestSession() async -> Session {
        do {
            let account = try context.activeAccount()
            let session = Session(
                userID: account.userID,
                provider: account.provider,
                email: account.email,
                displayName: account.displayName
            )
            // A restored non-guest account (signed in on this device before, keychain
            // cleared) keeps its identity so its data is still reachable.
            return session
        } catch {
            logger.error("Could not create an account row: \(error.localizedDescription, privacy: .public)")
            // Last resort: an in-memory guest so the UI still has an identity to render.
            return .guest(userID: UUID().uuidString)
        }
    }

    // MARK: - Sign up / in

    public func signUp(email: String, password: String, confirmPassword: String, displayName: String) async -> Bool {
        guard password == confirmPassword else {
            lastError = .passwordsDoNotMatch
            return false
        }
        return await perform {
            let result = try await self.backend.signUp(
                email: email, password: password, displayName: displayName
            )
            try self.keychain.save(result.session)
            self.current = result.session
            self.pendingRecoveryCode = result.recoveryCode
        }
    }

    public func signIn(email: String, password: String) async -> Bool {
        await perform {
            let session = try await self.backend.signIn(email: email, password: password)
            try self.keychain.save(session)
            self.current = session
        }
    }

    /// Present the Apple sheet ourselves, then sign in.
    ///
    /// Used where there is no `SignInWithAppleButton` to hang the flow off — currently the
    /// "link an Apple account" row on the Account screen.
    public func signInWithApple() async -> Bool {
        await perform {
            let credential = try await self.appleCoordinator.requestCredential()
            let session = try await self.backend.signIn(apple: credential)
            try self.keychain.save(session)
            self.current = session
        }
    }

    /// Sign in with a credential the SwiftUI `SignInWithAppleButton` already obtained.
    ///
    /// Apple's HIG requires their button, and that button owns its own presentation, so this
    /// entry point exists rather than faking a tap on it. Both paths converge on the same
    /// ``AppleCredential`` mapping.
    public func signIn(appleCredential: AppleCredential) async -> Bool {
        await perform {
            let session = try await self.backend.signIn(apple: appleCredential)
            try self.keychain.save(session)
            self.current = session
        }
    }

    /// Google's sign-in page, then sign in. Keeps guest progress exactly as Apple does.
    public func signInWithGoogle() async -> Bool {
        await perform {
            let credential = try await self.googleCoordinator.requestCredential()
            let session = try await self.backend.signIn(google: credential)
            try self.keychain.save(session)
            self.current = session
        }
    }

    /// Record an Apple authorisation failure so the UI can react without duplicating the
    /// error mapping.
    public func reportAppleSignInFailure(_ error: AuthError) {
        lastError = error.isSilent ? nil : error
    }

    /// Continue without an account. Presented with equal weight to signing in, because
    /// it is a supported way to use the app rather than a way to postpone signing up.
    public func continueAsGuest() async {
        current = await ensureGuestSession()
        try? keychain.delete()
    }

    // MARK: - Password reset

    public func beginPasswordReset(email: String) async -> PasswordResetChallenge? {
        guard CredentialValidator.isValidEmail(email) else {
            lastError = .invalidEmail
            return nil
        }
        var challenge: PasswordResetChallenge?
        _ = await perform {
            challenge = try await self.backend.beginPasswordReset(email: email)
        }
        return challenge
    }

    public func completePasswordReset(
        email: String, proof: String, newPassword: String, confirmPassword: String
    ) async -> Bool {
        guard newPassword == confirmPassword else {
            lastError = .passwordsDoNotMatch
            return false
        }
        return await perform {
            try await self.backend.completePasswordReset(
                email: email, proof: proof, newPassword: newPassword
            )
        }
    }

    // MARK: - Account management

    public func changePassword(current currentPassword: String, new newPassword: String, confirm: String) async -> Bool {
        guard newPassword == confirm else {
            lastError = .passwordsDoNotMatch
            return false
        }
        guard let session = self.current else {
            lastError = .notSignedIn
            return false
        }
        return await perform {
            try await self.backend.changePassword(
                session: session, currentPassword: currentPassword, newPassword: newPassword
            )
        }
    }

    public func updateProfile(displayName: String?, email: String?) async -> Bool {
        guard let session = current else {
            lastError = .notSignedIn
            return false
        }
        return await perform {
            let updated = try await self.backend.updateProfile(
                session: session, displayName: displayName, email: email
            )
            try self.keychain.save(updated)
            self.current = updated
        }
    }

    /// Issue a replacement recovery code. Local accounts only — a remote account recovers
    /// by email and has no code.
    public func regenerateRecoveryCode() async -> String? {
        guard let session = current, session.provider == .local else {
            lastError = .providerDoesNotSupportPasswords
            return nil
        }
        var code: String?
        _ = await perform {
            code = try await self.localBackend.regenerateRecoveryCode(session: session)
        }
        return code
    }

    public func signOut() async {
        guard let session = current else { return }
        _ = await perform {
            try await self.backend.signOut(session: session)
            try? self.keychain.delete()
            self.current = await self.ensureGuestSession()
        }
    }

    /// Delete the account and all of its study data.
    ///
    /// Required in-app by App Store guideline 5.1.1(v). Leaves a fresh guest behind so
    /// the app stays usable rather than dropping into a dead state.
    public func deleteAccount() async -> Bool {
        guard let session = current else {
            lastError = .notSignedIn
            return false
        }
        return await perform {
            try await self.backend.deleteAccount(session: session)
            try? self.keychain.delete()
            self.current = await self.ensureGuestSession()
        }
    }

    // MARK: - UI plumbing

    public func acknowledgeRecoveryCode() {
        pendingRecoveryCode = nil
    }

    public func clearError() {
        lastError = nil
    }

    /// Run an operation with uniform busy-state and error handling.
    ///
    /// Every entry point goes through this so that no path can forget to reset `isBusy`
    /// (leaving the UI stuck behind a spinner) or leave a stale `lastError` on screen.
    private func perform(_ operation: () async throws -> Void) async -> Bool {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await operation()
            return true
        } catch let error as AuthError {
            // Cancellation is not a failure worth reporting; the user did it on purpose.
            lastError = error.isSilent ? nil : error
            return false
        } catch let error as PasswordHasher.HashError {
            lastError = .storage(error.localizedDescription)
            return false
        } catch {
            lastError = .storage(error.localizedDescription)
            return false
        }
    }
}
