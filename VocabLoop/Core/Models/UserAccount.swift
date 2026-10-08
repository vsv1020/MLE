import Foundation
import SwiftData

/// How the current session was established.
public enum AuthProvider: String, Codable, CaseIterable, Hashable, Sendable {
    /// No account. A first-class, fully functional mode — not a trial.
    case guest
    /// Email + password verified against the on-device store.
    case local
    /// Sign in with Apple.
    case apple
    /// Email + password verified by the server.
    case remote
    /// Google account, via Google's OAuth sign-in page.
    case google

    public var displayName: String {
        switch self {
        case .guest: "游客"
        case .local: "邮箱"
        case .apple: "Apple"
        case .remote: "邮箱"
        case .google: "Google"
        }
    }

    /// `true` when credentials can be changed in-app. Apple manages its own.
    public var supportsPasswordChange: Bool { self == .local || self == .remote }
}

/// A person using the app.
///
/// Exactly one account row is marked ``isActive`` at a time. A guest row is created
/// on first launch so that every downstream query has a `userID` to scope by — which
/// is what makes "sign up later and keep your progress" a data *relabelling* rather
/// than a migration.
@Model
public final class UserAccount {
    /// Local identity. Stable across sign-out and re-sign-in for the same account,
    /// and never reused.
    @Attribute(.unique) public var userID: String

    /// Lower-cased and trimmed. `nil` for guest and possible for Apple accounts,
    /// which may withhold the address.
    public var email: String?
    public var displayName: String
    public var providerRaw: String

    // MARK: Local credential material
    //
    // Only ever populated for `.local`. The password itself is never stored, and the
    // hash lives in the database rather than the Keychain deliberately: the Keychain
    // holds the *session*, which must be revocable independently of the credential.

    /// PBKDF2-HMAC-SHA256 output.
    public var passwordHash: Data?
    /// Per-user random salt, 16 bytes.
    public var passwordSalt: Data?
    /// Stored per-user so the work factor can be raised for new accounts without
    /// invalidating existing ones.
    public var passwordIterations: Int

    /// Hash of the one-time recovery code issued at sign-up.
    ///
    /// An offline account cannot be recovered by email, so "forgot password" needs
    /// something the user holds. A recovery code shown once at sign-up is the honest
    /// answer; a security question would be both weaker and more annoying. Hashed with
    /// the same PBKDF2 parameters as the password, because a stored recovery code is
    /// a password.
    public var recoveryCodeHash: Data?
    public var recoveryCodeSalt: Data?
    /// Set when the code has been spent, so it cannot be replayed.
    public var recoveryCodeUsedAt: Date?

    /// Opaque, stable, per-developer-team user ID from Apple. The only reliable
    /// identifier Apple gives us — the email may be a relay address or absent.
    public var appleUserIdentifier: String?

    /// Google's stable account ID (the ID token's `sub`). Matched on instead of email, for
    /// the same reason as Apple's: a Google account's address can change.
    public var googleUserIdentifier: String?

    /// Server-side ID, once the account has been registered remotely.
    public var remoteID: String?

    public var isActive: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastSignedInAt: Date?

    /// Set when the user requests deletion but the server has not yet confirmed.
    /// Local data is removed immediately; this row lingers only to carry the pending
    /// server-side delete in the outbox.
    public var deletionRequestedAt: Date?

    @Relationship(deleteRule: .cascade)
    public var preferences: StudyPreferences?

    public init(
        userID: String = UUID().uuidString,
        email: String? = nil,
        displayName: String,
        provider: AuthProvider,
        isActive: Bool = true,
        now: Date = Date()
    ) {
        self.userID = userID
        self.email = email?.normalizedEmail
        self.displayName = displayName
        self.providerRaw = provider.rawValue
        self.passwordIterations = 0
        self.isActive = isActive
        self.createdAt = now
        self.updatedAt = now
        self.preferences = StudyPreferences()
    }

    public var provider: AuthProvider {
        get { AuthProvider(rawValue: providerRaw) ?? .guest }
        set { providerRaw = newValue.rawValue }
    }

    public var isGuest: Bool { provider == .guest }

    /// Two initials for the avatar, falling back to the email's first character.
    public var initials: String {
        let source = displayName.isEmpty ? (email ?? "?") : displayName
        let parts = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" })
        let letters = parts.prefix(2).compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    public static func makeGuest(now: Date = Date()) -> UserAccount {
        UserAccount(displayName: "游客", provider: .guest, now: now)
    }

    public func touch(_ now: Date = Date()) { updatedAt = now }
}

extension String {
    /// Email addresses are compared case-insensitively, and stray whitespace from
    /// autofill is the single most common cause of "wrong password" reports.
    public var normalizedEmail: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
