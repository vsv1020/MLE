import Foundation
import Security

/// Keychain-backed storage for the current ``Session``.
///
/// The session lives in the Keychain rather than `UserDefaults` for two reasons: a
/// bearer token in a plist is readable from a filesystem backup, and the Keychain gives
/// us `kSecAttrAccessibleAfterFirstUnlock` — available to a background refresh but not
/// while the device has never been unlocked since boot.
///
/// Not `WhenUnlocked`, because a background sync must be able to read the token; not
/// `Always`, because that is deprecated and readable from an unencrypted backup.
public struct KeychainStore: Sendable {
    public let service: String
    public let account: String

    public init(service: String = "com.vocabloop.app", account: String = "session") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(_ session: Session) throws {
        let data = try JSONEncoder().encode(session)

        // Update-then-add rather than delete-then-add: a delete/add pair leaves a window
        // where the app has no stored session, and a crash inside it signs the user out.
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AuthError.keychain(status: updateStatus)
        }

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AuthError.keychain(status: addStatus)
        }
    }

    /// The stored session, or `nil` if there is none.
    ///
    /// A stored blob that no longer decodes — an app update that changed ``Session`` —
    /// is treated as absent and cleared, rather than throwing. Failing to launch because
    /// of a stale token is a worse outcome than asking the user to sign in again.
    public func load() throws -> Session? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            guard let session = try? JSONDecoder().decode(Session.self, from: data) else {
                try? delete()
                return nil
            }
            return session
        case errSecItemNotFound:
            return nil
        default:
            throw AuthError.keychain(status: status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.keychain(status: status)
        }
    }
}
