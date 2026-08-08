import Foundation
import SwiftData

/// Fully offline authentication against the on-device store.
///
/// This is the default backend, and it is a real one rather than a stub: accounts are
/// created, passwords are hashed with PBKDF2, and recovery works — all with the radio
/// off. That is the point. An app whose sign-in screen needs a network is an app that
/// cannot be studied on a plane.
///
/// It does not pretend to be a server. There is no cross-device identity here; that
/// arrives with ``RemoteAuthBackend``, and the two share this protocol so switching is a
/// composition-root change rather than a rewrite.
@MainActor
public final class LocalAuthBackend: AuthBackend {
    private let context: ModelContext

    /// Always true — there is nothing to be unavailable.
    public var isAvailable: Bool { true }

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Sign up

    public func signUp(email: String, password: String, displayName: String) async throws -> SignUpResult {
        let normalisedEmail = email.normalizedEmail
        guard CredentialValidator.isValidEmail(normalisedEmail) else { throw AuthError.invalidEmail }
        // Validate the password *before* checking whether the email is taken, so a
        // caller cannot probe for registered addresses using a throwaway password.
        if let problem = CredentialValidator.validatePassword(password) { throw problem }
        guard try findAccount(withEmail: normalisedEmail) == nil else { throw AuthError.emailAlreadyRegistered }

        let salt = try PasswordHasher.makeSalt()
        let hash = try PasswordHasher.hash(password: password, salt: salt)
        let recoveryCode = try RecoveryCode.generate()
        let recoverySalt = try PasswordHasher.makeSalt()
        let recoveryHash = try PasswordHasher.hash(
            password: RecoveryCode.normalise(recoveryCode), salt: recoverySalt
        )

        let now = Date()
        // Adopt the guest account rather than creating a new one, so everything the user
        // studied before signing up simply becomes theirs. No migration, no data copy,
        // and nothing to get wrong.
        let account: UserAccount
        if let guest = try adoptableGuest() {
            account = guest
        } else {
            account = UserAccount(displayName: displayName, provider: .local, now: now)
            context.insert(account)
        }

        account.email = normalisedEmail
        account.displayName = displayName.isEmpty ? String(normalisedEmail.prefix(while: { $0 != "@" })) : displayName
        account.provider = .local
        account.passwordHash = hash
        account.passwordSalt = salt
        account.passwordIterations = PasswordHasher.iterations
        account.recoveryCodeHash = recoveryHash
        account.recoveryCodeSalt = recoverySalt
        account.recoveryCodeUsedAt = nil
        account.isActive = true
        account.lastSignedInAt = now
        account.touch(now)

        try deactivateOthers(except: account)
        try saveOrThrow()

        return SignUpResult(session: makeSession(for: account), recoveryCode: recoveryCode)
    }

    // MARK: - Sign in

    public func signIn(email: String, password: String) async throws -> Session {
        let normalisedEmail = email.normalizedEmail
        guard let account = try findAccount(withEmail: normalisedEmail),
              let hash = account.passwordHash,
              let salt = account.passwordSalt
        else {
            // Spend comparable time on a missing account so response time does not reveal
            // whether the address is registered.
            _ = try? PasswordHasher.hash(password: password, salt: try PasswordHasher.makeSalt())
            throw AuthError.invalidCredentials
        }

        guard PasswordHasher.verify(
            password: password, hash: hash, salt: salt,
            iterations: account.passwordIterations
        ) else {
            throw AuthError.invalidCredentials
        }

        // Transparently upgrade the work factor when the stored one is behind. The user
        // has just supplied the plaintext, so this is the only moment it is possible.
        if account.passwordIterations < PasswordHasher.iterations {
            let newSalt = try PasswordHasher.makeSalt()
            account.passwordSalt = newSalt
            account.passwordHash = try PasswordHasher.hash(password: password, salt: newSalt)
            account.passwordIterations = PasswordHasher.iterations
        }

        let now = Date()
        account.isActive = true
        account.lastSignedInAt = now
        account.touch(now)
        try deactivateOthers(except: account)
        try saveOrThrow()

        return makeSession(for: account)
    }

    public func signIn(apple credential: AppleCredential) async throws -> Session {
        let now = Date()
        let identifier = credential.userIdentifier

        // Match on Apple's opaque identifier, never on email: the email may be a private
        // relay address, may be withheld entirely, and is only provided on the first
        // authorisation.
        var descriptor = FetchDescriptor<UserAccount>(
            predicate: #Predicate { $0.appleUserIdentifier == identifier }
        )
        descriptor.fetchLimit = 1

        let account: UserAccount
        if let existing = try context.fetch(descriptor).first {
            account = existing
        } else if let guest = try adoptableGuest() {
            account = guest
        } else {
            let fresh = UserAccount(displayName: credential.fullName ?? "Me", provider: .apple, now: now)
            context.insert(fresh)
            account = fresh
        }

        account.provider = .apple
        account.appleUserIdentifier = identifier
        // Only overwrite name and email when Apple actually gave them to us — on repeat
        // sign-ins both are nil, and blanking a name the user has since edited is a bug.
        if let email = credential.email, !email.isEmpty { account.email = email.normalizedEmail }
        if let name = credential.fullName, !name.isEmpty, account.displayName.isEmpty || account.displayName == "Guest" {
            account.displayName = name
        }
        if account.displayName.isEmpty { account.displayName = "Me" }
        account.isActive = true
        account.lastSignedInAt = now
        account.touch(now)

        try deactivateOthers(except: account)
        try saveOrThrow()
        return makeSession(for: account)
    }

    // MARK: - Password reset

    public func beginPasswordReset(email: String) async throws -> PasswordResetChallenge {
        // Always report the same challenge, whether or not the address exists. Saying
        // "no such account" here would turn this form into an account-enumeration oracle.
        .recoveryCode
    }

    public func completePasswordReset(email: String, proof: String, newPassword: String) async throws {
        if let problem = CredentialValidator.validatePassword(newPassword) { throw problem }

        guard let account = try findAccount(withEmail: email.normalizedEmail),
              let recoveryHash = account.recoveryCodeHash,
              let recoverySalt = account.recoveryCodeSalt
        else {
            throw AuthError.recoveryCodeInvalid
        }
        guard account.recoveryCodeUsedAt == nil else { throw AuthError.recoveryCodeAlreadyUsed }

        guard PasswordHasher.verify(
            password: RecoveryCode.normalise(proof),
            hash: recoveryHash, salt: recoverySalt,
            iterations: PasswordHasher.iterations
        ) else {
            throw AuthError.recoveryCodeInvalid
        }

        let salt = try PasswordHasher.makeSalt()
        account.passwordSalt = salt
        account.passwordHash = try PasswordHasher.hash(password: newPassword, salt: salt)
        account.passwordIterations = PasswordHasher.iterations
        // Spent codes cannot be replayed. The user gets a fresh one so they are not left
        // without a recovery path.
        account.recoveryCodeUsedAt = Date()
        account.touch()
        try saveOrThrow()
    }

    /// Issue a replacement recovery code, invalidating the old one.
    public func regenerateRecoveryCode(session: Session) async throws -> String {
        let account = try requireAccount(for: session)
        guard account.provider.supportsPasswordChange else {
            throw AuthError.providerDoesNotSupportPasswords
        }
        let code = try RecoveryCode.generate()
        let salt = try PasswordHasher.makeSalt()
        account.recoveryCodeSalt = salt
        account.recoveryCodeHash = try PasswordHasher.hash(
            password: RecoveryCode.normalise(code), salt: salt
        )
        account.recoveryCodeUsedAt = nil
        account.touch()
        try saveOrThrow()
        return code
    }

    // MARK: - Account management

    public func changePassword(session: Session, currentPassword: String, newPassword: String) async throws {
        let account = try requireAccount(for: session)
        guard account.provider.supportsPasswordChange else {
            throw AuthError.providerDoesNotSupportPasswords
        }
        guard let hash = account.passwordHash, let salt = account.passwordSalt,
              PasswordHasher.verify(
                  password: currentPassword, hash: hash, salt: salt,
                  iterations: account.passwordIterations
              )
        else {
            throw AuthError.invalidCredentials
        }
        if let problem = CredentialValidator.validatePassword(newPassword) { throw problem }

        let newSalt = try PasswordHasher.makeSalt()
        account.passwordSalt = newSalt
        account.passwordHash = try PasswordHasher.hash(password: newPassword, salt: newSalt)
        account.passwordIterations = PasswordHasher.iterations
        account.touch()
        try saveOrThrow()
    }

    public func updateProfile(session: Session, displayName: String?, email: String?) async throws -> Session {
        let account = try requireAccount(for: session)
        if let displayName {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { account.displayName = trimmed }
        }
        if let email {
            let normalised = email.normalizedEmail
            guard CredentialValidator.isValidEmail(normalised) else { throw AuthError.invalidEmail }
            if normalised != account.email {
                guard try findAccount(withEmail: normalised) == nil else {
                    throw AuthError.emailAlreadyRegistered
                }
                account.email = normalised
            }
        }
        account.touch()
        try saveOrThrow()
        return makeSession(for: account)
    }

    /// Delete the account and everything the user studied.
    ///
    /// Deliberately thorough: cards, review history, day rollups and daily batches all
    /// go. "Delete my account" that leaves the review log behind is not deletion. The
    /// dictionary itself stays — it is bundled content, not user data.
    public func deleteAccount(session: Session) async throws {
        let account = try requireAccount(for: session)
        let userID = account.userID

        try context.delete(model: ReviewLog.self)
        try context.delete(model: Card.self)
        try context.delete(model: StudyDay.self, where: #Predicate { $0.userID == userID })
        try context.delete(model: DailyBatch.self, where: #Predicate { $0.userID == userID })
        try context.delete(model: SyncOutboxItem.self)

        // User-authored words are user data and go with the account; bundled entries stay.
        try context.delete(model: Entry.self, where: #Predicate { $0.isUserCreated })
        try context.delete(model: Deck.self, where: #Predicate { !$0.isBuiltIn })

        context.delete(account)
        try saveOrThrow()

        // Leave a fresh guest behind so the app remains usable rather than dropping the
        // user into an unrecoverable state.
        let guest = UserAccount.makeGuest()
        context.insert(guest)
        try saveOrThrow()
    }

    public func restore(_ session: Session) async throws -> Session {
        let account = try requireAccount(for: session)
        return makeSession(for: account)
    }

    public func signOut(session: Session) async throws {
        // Signing out of a local account does not delete it; the row stays so signing
        // back in restores everything. A guest is left active so the app stays usable.
        guard let account = try findAccount(withUserID: session.userID) else { return }
        account.isActive = false
        account.touch()

        let guest: UserAccount
        if let existing = try adoptableGuest() {
            guest = existing
        } else {
            guest = UserAccount.makeGuest()
            context.insert(guest)
        }
        guest.isActive = true
        guest.touch()
        try deactivateOthers(except: guest)
        try saveOrThrow()
    }

    // MARK: - Helpers

    private func makeSession(for account: UserAccount) -> Session {
        Session(
            userID: account.userID,
            provider: account.provider,
            email: account.email,
            displayName: account.displayName,
            createdAt: account.lastSignedInAt ?? Date()
        )
    }

    private func findAccount(withEmail email: String) throws -> UserAccount? {
        var descriptor = FetchDescriptor<UserAccount>(predicate: #Predicate { $0.email == email })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func findAccount(withUserID userID: String) throws -> UserAccount? {
        var descriptor = FetchDescriptor<UserAccount>(predicate: #Predicate { $0.userID == userID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func requireAccount(for session: Session) throws -> UserAccount {
        guard let account = try findAccount(withUserID: session.userID) else {
            throw AuthError.notSignedIn
        }
        return account
    }

    /// The active guest account, if there is one — the row whose data a new sign-up
    /// should adopt.
    private func adoptableGuest() throws -> UserAccount? {
        let guestRaw = AuthProvider.guest.rawValue
        var descriptor = FetchDescriptor<UserAccount>(
            predicate: #Predicate { $0.providerRaw == guestRaw && $0.isActive }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Exactly one account is active at a time, which is what lets every query scope by a
    /// single `userID` without ambiguity.
    private func deactivateOthers(except account: UserAccount) throws {
        let keep = account.userID
        let others = try context.fetch(
            FetchDescriptor<UserAccount>(predicate: #Predicate { $0.userID != keep && $0.isActive })
        )
        for other in others {
            other.isActive = false
        }
    }

    private func saveOrThrow() throws {
        do {
            try context.save()
        } catch {
            throw AuthError.storage(error.localizedDescription)
        }
    }
}
