import CryptoKit
import Foundation

/// Byte-compatible port of the vault crypto in src-tauri/src/lib.rs
/// (`derive_aes256_key`, `encrypt_aes256_gcm`, `decrypt_aes256_gcm`).
///
/// Do not change any constant here without changing the Rust side too —
/// both builds must be able to open the same koban.db.
enum VaultCrypto {
    /// Used when the user has not set a custom vault passphrase.
    static let defaultSecret = "koban-aes256gcm-treasury-vault-v1-key"
    static let kdfIterations: UInt32 = 10_000
    static let kdfDomain = "koban-aes-256-gcm-v1"
    static let nonceLength = 12
    static let tagLength = 16

    enum CryptoError: Error, Equatable {
        case invalidBase64
        case invalidNonceLength
        case ciphertextTooShort
        /// Wrong passphrase or corrupted data (GCM authentication failed).
        case authenticationFailed
    }

    struct SealedValue: Equatable, Sendable {
        var nonceB64: String
        var ciphertextB64: String
    }

    /// hash = SHA256(salt ‖ secret ‖ "koban-aes-256-gcm-v1")
    /// repeat 10 000×: hash = SHA256(hash ‖ salt ‖ round as u32 little-endian)
    static func deriveKey(secret: String, salt: Data) -> SymmetricKey {
        SymmetricKey(data: deriveKeyBytes(secret: secret, salt: salt))
    }

    static func deriveKeyBytes(secret: String, salt: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(secret.utf8))
        hasher.update(data: Data(kdfDomain.utf8))
        var hash = Data(hasher.finalize())

        for round in 0..<kdfIterations {
            var h = SHA256()
            h.update(data: hash)
            h.update(data: salt)
            withUnsafeBytes(of: round.littleEndian) { h.update(bufferPointer: $0) }
            hash = Data(h.finalize())
        }
        return hash
    }

    /// AES-256-GCM with a random 96-bit nonce. Ciphertext is stored as
    /// `ciphertext ‖ tag` (the `aes-gcm` crate's layout), both base64 (standard, padded).
    static func seal(_ plaintext: Data, key: SymmetricKey, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> SealedValue {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        let nonceData = box.nonce.withUnsafeBytes { Data($0) }
        return SealedValue(
            nonceB64: nonceData.base64EncodedString(),
            ciphertextB64: (box.ciphertext + box.tag).base64EncodedString()
        )
    }

    static func open(nonceB64: String, ciphertextB64: String, key: SymmetricKey) throws -> Data {
        guard let nonceData = Data(base64Encoded: nonceB64),
              let combined = Data(base64Encoded: ciphertextB64) else {
            throw CryptoError.invalidBase64
        }
        guard nonceData.count == nonceLength else { throw CryptoError.invalidNonceLength }
        guard combined.count >= tagLength else { throw CryptoError.ciphertextTooShort }

        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: combined.prefix(combined.count - tagLength),
                tag: combined.suffix(tagLength)
            )
            return try AES.GCM.open(box, using: key)
        } catch {
            throw CryptoError.authenticationFailed
        }
    }

    static func randomBytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }
}
