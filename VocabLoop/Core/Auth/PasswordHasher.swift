import Foundation
import CommonCrypto

/// PBKDF2-HMAC-SHA256 password hashing for locally stored accounts.
///
/// PBKDF2 rather than Argon2id or scrypt for one reason: it is in CommonCrypto, so it
/// needs no dependency. Argon2id would be the better choice on a server; on a device
/// where the attacker who can read the database can usually also read the Keychain, the
/// marginal gain does not justify vendoring a crypto library.
///
/// Parameters follow OWASP's 2023 guidance for PBKDF2-HMAC-SHA256: 600,000 iterations,
/// a 16-byte random salt per user, and a 32-byte derived key. The iteration count is
/// stored *per account* so it can be raised for new sign-ups without invalidating
/// existing passwords.
public enum PasswordHasher {
    public static let iterations = 600_000
    public static let saltByteCount = 16
    public static let derivedKeyByteCount = 32

    public enum HashError: LocalizedError {
        case derivationFailed(status: Int32)
        case randomGenerationFailed(status: Int32)

        public var errorDescription: String? {
            switch self {
            case .derivationFailed(let status): "密码加密失败（错误码 \(status)）。"
            case .randomGenerationFailed(let status): "安全随机数生成失败（错误码 \(status)）。"
            }
        }
    }

    public static func makeSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: saltByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw HashError.randomGenerationFailed(status: status) }
        return Data(bytes)
    }

    public static func hash(password: String, salt: Data, iterations: Int = PasswordHasher.iterations) throws -> Data {
        // Unicode normalisation matters: "é" typed as one codepoint and as e + combining
        // accent are different byte sequences, so the same password entered on two
        // keyboards would otherwise fail to match. NFC on both sides fixes it.
        let normalised = password.precomposedStringWithCanonicalMapping
        let passwordData = Data(normalised.utf8)

        var derived = [UInt8](repeating: 0, count: derivedKeyByteCount)
        let status: Int32 = derived.withUnsafeMutableBufferPointer { out in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        out.baseAddress,
                        out.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw HashError.derivationFailed(status: status) }
        return Data(derived)
    }

    /// Verify a password against a stored hash.
    ///
    /// The comparison is constant-time. `Data == Data` short-circuits on the first
    /// differing byte, which leaks how much of the hash was correct — the classic timing
    /// side channel, and the reason this function exists rather than a plain `==`.
    public static func verify(
        password: String,
        hash: Data,
        salt: Data,
        iterations: Int
    ) -> Bool {
        guard let candidate = try? self.hash(password: password, salt: salt, iterations: iterations) else {
            return false
        }
        return constantTimeEquals(candidate, hash)
    }

    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        // Length is not secret, but returning early on a mismatch still tells the
        // attacker nothing useful — the hash length is fixed by construction.
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[rhs.startIndex + (index - lhs.startIndex)]
        }
        return difference == 0
    }
}

/// One-time recovery codes for offline password reset.
///
/// An offline account has no email to send a reset link to, so recovery has to be
/// something the user holds. The code is shown exactly once at sign-up, stored only as
/// a PBKDF2 hash, and invalidated after use.
public enum RecoveryCode {
    /// Crockford-style base32: no `I`, `L`, `O` or `U`, so a handwritten code cannot be
    /// misread as a digit and cannot spell anything unfortunate.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let groupCount = 4
    static let groupLength = 4

    /// 16 characters from a 32-symbol alphabet — 80 bits of entropy, which is far more
    /// than a password and still transcribable by hand.
    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: groupCount * groupLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PasswordHasher.HashError.randomGenerationFailed(status: status)
        }
        // `% alphabet.count` is unbiased *only* because 256 is an exact multiple of 32. With any
        // other alphabet size the low symbols would be over-represented and the code would have
        // less entropy than it looks like it has, so the property is asserted rather than assumed.
        assert(256 % alphabet.count == 0, "a non-power-of-two alphabet makes this draw biased")
        let characters = bytes.map { alphabet[Int($0) % alphabet.count] }
        return stride(from: 0, to: characters.count, by: groupLength)
            .map { String(characters[$0..<min($0 + groupLength, characters.count)]) }
            .joined(separator: "-")
    }

    /// Strip formatting and fold the characters a user is likely to mistype.
    ///
    /// Someone reading a code off paper will type `O` for `0` and `I` for `1`. Folding
    /// them is not a weakness — those characters are not in the alphabet, so the mapping
    /// is unambiguous.
    public static func normalise(_ code: String) -> String {
        code.uppercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
            .replacingOccurrences(of: "U", with: "V")
    }
}
