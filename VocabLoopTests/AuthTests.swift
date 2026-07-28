import XCTest
import SwiftData
@testable import VocabLoop

@MainActor
final class AuthTests: XCTestCase {

    // MARK: - Password hashing

    func testHashRoundTripVerifies() throws {
        let salt = try PasswordHasher.makeSalt()
        // A low iteration count keeps the suite fast; the production count is asserted separately.
        let hash = try PasswordHasher.hash(password: "correct horse battery", salt: salt, iterations: 1_000)

        XCTAssertTrue(PasswordHasher.verify(
            password: "correct horse battery", hash: hash, salt: salt, iterations: 1_000
        ))
        XCTAssertFalse(PasswordHasher.verify(
            password: "correct horse batter", hash: hash, salt: salt, iterations: 1_000
        ))
    }

    func testSameSaltAndPasswordProduceTheSameHash() throws {
        let salt = try PasswordHasher.makeSalt()
        let first = try PasswordHasher.hash(password: "hunter2hunter2", salt: salt, iterations: 1_000)
        let second = try PasswordHasher.hash(password: "hunter2hunter2", salt: salt, iterations: 1_000)
        XCTAssertEqual(first, second)
    }

    /// Per-user salts are what stop one rainbow table from cracking every account at once.
    func testDifferentSaltsProduceDifferentHashes() throws {
        let a = try PasswordHasher.hash(
            password: "same password", salt: try PasswordHasher.makeSalt(), iterations: 1_000
        )
        let b = try PasswordHasher.hash(
            password: "same password", salt: try PasswordHasher.makeSalt(), iterations: 1_000
        )
        XCTAssertNotEqual(a, b)
    }

    func testSaltIsRandomAndCorrectLength() throws {
        var seen = Set<Data>()
        for _ in 0..<50 {
            let salt = try PasswordHasher.makeSalt()
            XCTAssertEqual(salt.count, PasswordHasher.saltByteCount)
            XCTAssertTrue(seen.insert(salt).inserted, "salts must not repeat")
        }
    }

    /// A password typed on two keyboards can be the same characters but different bytes.
    /// NFC normalisation on both sides is what stops "wrong password" reports nobody can explain.
    func testUnicodeNormalisationMakesEquivalentPasswordsMatch() throws {
        let salt = try PasswordHasher.makeSalt()
        let precomposed = "café password"                     // é as one codepoint
        let decomposed = "cafe\u{0301} password"              // e + combining acute

        let hash = try PasswordHasher.hash(password: precomposed, salt: salt, iterations: 1_000)
        XCTAssertTrue(PasswordHasher.verify(
            password: decomposed, hash: hash, salt: salt, iterations: 1_000
        ))
    }

    func testConstantTimeComparisonAgreesWithEquality() {
        let a = Data([1, 2, 3, 4])
        XCTAssertTrue(PasswordHasher.constantTimeEquals(a, Data([1, 2, 3, 4])))
        XCTAssertFalse(PasswordHasher.constantTimeEquals(a, Data([1, 2, 3, 5])))
        XCTAssertFalse(PasswordHasher.constantTimeEquals(a, Data([1, 2, 3])))
        XCTAssertTrue(PasswordHasher.constantTimeEquals(Data(), Data()))
    }

    func testProductionIterationCountMeetsGuidance() {
        // OWASP's 2023 floor for PBKDF2-HMAC-SHA256.
        XCTAssertGreaterThanOrEqual(PasswordHasher.iterations, 600_000)
    }

    // MARK: - Recovery codes

    func testRecoveryCodeShapeAndEntropy() throws {
        var seen = Set<String>()
        for _ in 0..<50 {
            let code = try RecoveryCode.generate()
            XCTAssertEqual(code.count, 19, "4 groups of 4 plus 3 dashes")
            XCTAssertEqual(code.filter { $0 == "-" }.count, 3)
            XCTAssertTrue(seen.insert(code).inserted, "codes must not repeat")
        }
    }

    /// The alphabet excludes the characters people misread off paper, and `normalise` folds the
    /// substitutions they type instead.
    func testRecoveryCodeNormalisationFoldsCommonMistypes() {
        XCTAssertEqual(RecoveryCode.normalise("k7m2-9xpq"), "K7M29XPQ")
        XCTAssertEqual(RecoveryCode.normalise("O0-Il1"), "00111")
        XCTAssertEqual(RecoveryCode.normalise("U V"), "VV")
    }

    func testRecoveryCodeAlphabetExcludesAmbiguousCharacters() {
        let alphabet = Set(RecoveryCode.alphabet)
        for character in "ILOU" {
            XCTAssertFalse(alphabet.contains(character), "\(character) is easy to misread")
        }
    }

    // MARK: - Validation

    func testEmailValidation() {
        for valid in ["a@b.co", "someone@example.com", "First.Last+tag@sub.example.co.uk"] {
            XCTAssertTrue(CredentialValidator.isValidEmail(valid), valid)
        }
        for invalid in ["", "nope", "no@domain", "@example.com", "a@.com", "a@b..com", "a b@c.com", "two@at@example.com"] {
            XCTAssertFalse(CredentialValidator.isValidEmail(invalid), invalid)
        }
    }

    func testEmailComparisonIgnoresCaseAndWhitespace() {
        XCTAssertEqual("  Someone@Example.COM ".normalizedEmail, "someone@example.com")
    }

    /// NIST SP 800-63B: length is the rule, composition is not. A 64-character passphrase of
    /// lowercase words must be accepted.
    func testPasswordPolicyFollowsLengthNotComposition() {
        XCTAssertNil(CredentialValidator.validatePassword("correct horse battery staple"))
        XCTAssertNil(CredentialValidator.validatePassword("aaaaaaaa"), "no composition rules")
        XCTAssertNotNil(CredentialValidator.validatePassword("short"))
        XCTAssertNotNil(CredentialValidator.validatePassword("        "), "whitespace only")
        XCTAssertNotNil(CredentialValidator.validatePassword("password"), "common password")
        XCTAssertNotNil(CredentialValidator.validatePassword(
            String(repeating: "a", count: CredentialValidator.maximumPasswordLength + 1)
        ))
    }

    func testMaximumPasswordLengthMeetsGuidance() {
        // NIST requires at least 64 characters to be accepted.
        XCTAssertGreaterThanOrEqual(CredentialValidator.maximumPasswordLength, 64)
    }

    func testPasswordStrengthRewardsLengthAndPunishesCommonPasswords() {
        let short = CredentialValidator.passwordStrength("abcdefgh")
        let long = CredentialValidator.passwordStrength("abcdefghijklmnopqrst")
        XCTAssertGreaterThan(long, short, "length must dominate the meter")
        XCTAssertLessThan(CredentialValidator.passwordStrength("password"), 0.1)
        XCTAssertEqual(CredentialValidator.passwordStrength(""), 0)
    }

    // MARK: - Local backend

    func testSignUpAdoptsTheGuestAccountSoProgressIsKept() async throws {
        let context = try TestStore.makeContext()
        let guest = try context.activeAccount()
        let guestUserID = guest.userID
        XCTAssertTrue(guest.isGuest)

        // Something studied before signing up.
        let entry = try TestStore.makeEntry(in: context, headword: "abandon")
        try TestStore.makeCard(in: context, for: entry, due: referenceDate)

        let backend = LocalAuthBackend(context: context)
        let result = try await backend.signUp(
            email: "user@example.com", password: "a good long password", displayName: "Tester"
        )

        // Same row, relabelled — not a new account with the old data orphaned.
        XCTAssertEqual(result.session.userID, guestUserID)
        XCTAssertEqual(result.session.provider, .local)
        XCTAssertNotNil(result.recoveryCode)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Card>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserAccount>()), 1)
    }

    func testSignUpRejectsADuplicateEmail() async throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let backend = LocalAuthBackend(context: context)

        _ = try await backend.signUp(
            email: "user@example.com", password: "a good long password", displayName: "First"
        )
        do {
            _ = try await backend.signUp(
                email: "USER@example.com", password: "another good password", displayName: "Second"
            )
            XCTFail("expected a duplicate-email failure")
        } catch let error as AuthError {
            XCTAssertEqual(error, .emailAlreadyRegistered)
        }
    }

    /// Password validation runs *before* the duplicate check, so a caller cannot probe for
    /// registered addresses using a throwaway password.
    func testWeakPasswordIsRejectedBeforeEmailExistenceIsRevealed() async throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let backend = LocalAuthBackend(context: context)
        _ = try await backend.signUp(
            email: "taken@example.com", password: "a good long password", displayName: "First"
        )

        do {
            _ = try await backend.signUp(email: "taken@example.com", password: "short", displayName: "X")
            XCTFail("expected a weak-password failure")
        } catch let error as AuthError {
            guard case .weakPassword = error else {
                return XCTFail("expected weakPassword, got \(error)")
            }
        }
    }

    func testSignInSucceedsWithCorrectPasswordAndFailsOtherwise() async throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let backend = LocalAuthBackend(context: context)
        _ = try await backend.signUp(
            email: "user@example.com", password: "a good long password", displayName: "Tester"
        )

        let session = try await backend.signIn(email: "User@Example.com", password: "a good long password")
        XCTAssertEqual(session.email, "user@example.com")

        do {
            _ = try await backend.signIn(email: "user@example.com", password: "wrong password entirely")
            XCTFail("expected a credential failure")
        } catch let error as AuthError {
            XCTAssertEqual(error, .invalidCredentials)
        }
    }

    /// Sign-in must not reveal whether an address is registered — the same error for both cases.
    func testUnknownEmailAndWrongPasswordGiveTheSameError() async throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let backend = LocalAuthBackend(context: context)
        _ = try await backend.signUp(
            email: "known@example.com", password: "a good long password", displayName: "Tester"
        )

        var errors: [AuthError] = []
        for (email, password) in [
            ("known@example.com", "the wrong password"),
            ("unknown@example.com", "the wrong password"),
        ] {
            do {
                _ = try await backend.signIn(email: email, password: password)
                XCTFail("expected a failure for \(email)")
            } catch let error as AuthError {
                errors.append(error)
            }
        }
        XCTAssertEqual(errors, [.invalidCredentials, .invalidCredentials])
    }

    func testRecoveryCodeResetsThePasswordExactlyOnce() async throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let backend = LocalAuthBackend(context: context)
        let result = try await backend.signUp(
            email: "user@example.com", password: "the original password", displayName: "Tester"
        )
        let code = try XCTUnwrap(result.recoveryCode)

        try await backend.completePasswordReset(
            email: "user@example.com", proof: code, newPassword: "the replacement password"
        )
        _ = try await backend.signIn(email: "user@example.com", password: "the replacement password")

        // Spent codes must not be replayable.
        do {
            try await backend.completePasswordReset(
                email: "user@example.com", proof: code, newPassword: "a third password"
            )
            XCTFail("expected the code to be spent")
        } catch let error as AuthError {
            XCTAssertEqual(error, .recoveryCodeAlreadyUsed)
        }
    }

    func testWrongRecoveryCodeIsRejected() async throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let backend = LocalAuthBackend(context: context)
        _ = try await backend.signUp(
            email: "user@example.com", password: "the original password", displayName: "Tester"
        )

        do {
            try await backend.completePasswordReset(
                email: "user@example.com", proof: "AAAA-BBBB-CCCC-DDDD", newPassword: "a new password here"
            )
            XCTFail("expected a rejection")
        } catch let error as AuthError {
            XCTAssertEqual(error, .recoveryCodeInvalid)
        }
    }

    /// Recovery must not become an oracle either: an unknown address gives the same error as a
    /// wrong code.
    func testResetForUnknownEmailDoesNotRevealItsAbsence() async throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let backend = LocalAuthBackend(context: context)

        let challenge = try await backend.beginPasswordReset(email: "nobody@example.com")
        XCTAssertEqual(challenge, .recoveryCode, "the flow must advance regardless")

        do {
            try await backend.completePasswordReset(
                email: "nobody@example.com", proof: "AAAA-BBBB-CCCC-DDDD", newPassword: "a new password here"
            )
            XCTFail("expected a rejection")
        } catch let error as AuthError {
            XCTAssertEqual(error, .recoveryCodeInvalid)
        }
    }

    func testChangePasswordRequiresTheCurrentOne() async throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let backend = LocalAuthBackend(context: context)
        let result = try await backend.signUp(
            email: "user@example.com", password: "the original password", displayName: "Tester"
        )

        do {
            try await backend.changePassword(
                session: result.session, currentPassword: "not the password", newPassword: "a new password here"
            )
            XCTFail("expected a credential failure")
        } catch let error as AuthError {
            XCTAssertEqual(error, .invalidCredentials)
        }

        try await backend.changePassword(
            session: result.session,
            currentPassword: "the original password",
            newPassword: "a new password here"
        )
        _ = try await backend.signIn(email: "user@example.com", password: "a new password here")
    }

    func testAppleSignInMatchesOnIdentifierNotEmail() async throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let backend = LocalAuthBackend(context: context)

        // First authorisation: Apple supplies name and email.
        let first = try await backend.signIn(apple: AppleCredential(
            userIdentifier: "001.abcdef", email: "relay@privaterelay.appleid.com", fullName: "Real Name"
        ))
        XCTAssertEqual(first.displayName, "Real Name")

        // Every later authorisation: identifier only. The stored name must survive.
        let second = try await backend.signIn(apple: AppleCredential(userIdentifier: "001.abcdef"))
        XCTAssertEqual(second.userID, first.userID, "must match the same account")
        XCTAssertEqual(second.displayName, "Real Name", "a nil name must not blank the stored one")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserAccount>()), 1)
    }

    func testApplePasswordChangeIsRefusedWithAClearReason() async throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let backend = LocalAuthBackend(context: context)
        let session = try await backend.signIn(apple: AppleCredential(userIdentifier: "001.abcdef"))

        do {
            try await backend.changePassword(
                session: session, currentPassword: "x", newPassword: "a new password here"
            )
            XCTFail("expected a refusal")
        } catch let error as AuthError {
            XCTAssertEqual(error, .providerDoesNotSupportPasswords)
        }
    }

    func testSignOutLeavesAUsableGuestAndKeepsTheAccount() async throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let backend = LocalAuthBackend(context: context)
        let result = try await backend.signUp(
            email: "user@example.com", password: "a good long password", displayName: "Tester"
        )

        try await backend.signOut(session: result.session)

        let active = try context.activeAccount()
        XCTAssertTrue(active.isGuest, "the app must stay usable after signing out")

        // The account row survives, so signing back in restores everything.
        let signedIn = try await backend.signIn(email: "user@example.com", password: "a good long password")
        XCTAssertEqual(signedIn.userID, result.session.userID)
    }

    /// "Delete my account" that leaves the review log behind is not deletion.
    func testDeleteAccountRemovesStudyDataButKeepsBundledDictionary() async throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let backend = LocalAuthBackend(context: context)
        let result = try await backend.signUp(
            email: "user@example.com", password: "a good long password", displayName: "Tester"
        )

        let bundled = try TestStore.makeEntry(in: context, headword: "abandon")
        try TestStore.makeCard(in: context, for: bundled, due: referenceDate)
        let own = try TestStore.makeEntry(in: context, headword: "myownword")
        own.isUserCreated = true
        try context.save()

        try await backend.deleteAccount(session: result.session)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Card>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewLog>()), 0)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<Entry>(predicate: #Predicate { $0.isUserCreated })),
            0,
            "the user's own words are their data and must go"
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<Entry>(predicate: #Predicate { !$0.isUserCreated })),
            1,
            "bundled content is not user data and stays"
        )
        XCTAssertTrue(try context.activeAccount().isGuest, "a usable guest must be left behind")
    }

    func testExactlyOneAccountIsEverActive() async throws {
        let context = try TestStore.makeContext()
        _ = try context.activeAccount()
        let backend = LocalAuthBackend(context: context)

        _ = try await backend.signUp(
            email: "first@example.com", password: "a good long password", displayName: "First"
        )
        let signedOutSession = try await backend.signIn(
            email: "first@example.com", password: "a good long password"
        )
        try await backend.signOut(session: signedOutSession)
        _ = try await backend.signUp(
            email: "second@example.com", password: "a good long password", displayName: "Second"
        )

        let active = try context.fetch(
            FetchDescriptor<UserAccount>(predicate: #Predicate { $0.isActive })
        )
        XCTAssertEqual(active.count, 1, "every query scopes by one userID, so exactly one may be active")
    }
}
