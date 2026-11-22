import CryptoKit
import Foundation

/// Byte-compatible port of `src-tauri/src/vault_crypto.rs` (Vault Format v2) plus
/// read-only legacy v1 helpers for migration and v1 backup restore.
///
/// Do not change any constant or domain string here without changing the Rust side too —
/// both platforms read and write the exact same `koban.db` and `.key` formats.
enum VaultCrypto {
    static let defaultArgon2MemoryKiB: UInt32 = 65_536
    static let defaultArgon2Iterations: UInt32 = 3
    static let defaultArgon2Parallelism: UInt32 = 4
    static let minPassphraseLength = 12
    static let minCompositePassphraseLength = 8

    static let ledgerHKDFInfo = Data("koban/v2/ledger".utf8)
    static let recoveryHKDFInfo = Data("koban/v2/recovery-kek".utf8)

    static let nonceLength = 12
    static let tagLength = 16

    enum CryptoError: Error, Equatable {
        case invalidBase64
        case invalidNonceLength
        case ciphertextTooShort
        /// Wrong credentials, tampered ciphertext, or AAD mismatch.
        case authenticationFailed
        case invalidRecoveryKey(String)
        case invalidKeyFile(String)
        case kdfFailed(String)
    }

    struct SealedValue: Equatable, Sendable {
        var nonceB64: String
        var ciphertextB64: String
    }

    // MARK: - Unicode & Encoding Helpers

    static func normalizeNFC(_ raw: String) -> String {
        raw.precomposedStringWithCanonicalMapping
    }

    static func sha256Data(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(fileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return sha256Hex(data)
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status == errSecSuccess {
            return Data(bytes)
        }
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - AAD Formatters (Vault v2)

    static func slotAAD(vaultIDB64: String, slotID: String, kind: String) -> Data {
        Data("koban/v2/slot/\(vaultIDB64)/\(slotID)/\(kind)".utf8)
    }

    static func ledgerAAD(vaultIDB64: String) -> Data {
        Data("koban/v2/ledger/\(vaultIDB64)/ledger_state".utf8)
    }

    // MARK: - HKDF-SHA256 & Key Derivation

    static func hkdfSHA256(
        ikm: Data,
        salt: Data,
        info: Data,
        outputByteCount: Int = 32
    ) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: outputByteCount
        )
    }

    static func hmacSHA256(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    static func derivePassphraseKEK(
        passphraseNFC: String,
        salt: Data,
        memoryKiB: UInt32 = defaultArgon2MemoryKiB,
        iterations: UInt32 = defaultArgon2Iterations,
        parallelism: UInt32 = defaultArgon2Parallelism
    ) throws -> SymmetricKey {
        do {
            let tag = try Argon2id.derive(
                password: Data(passphraseNFC.utf8),
                salt: salt,
                memoryKiB: memoryKiB,
                iterations: iterations,
                parallelism: parallelism,
                tagLength: 32
            )
            return SymmetricKey(data: tag)
        } catch {
            throw CryptoError.kdfFailed(String(describing: error))
        }
    }

    static func deriveCompositeIKM(passphraseNFC: String, keyfileSecret: Data) -> Data {
        let passHash = sha256Data(Data(passphraseNFC.utf8))
        return hmacSHA256(key: keyfileSecret, data: passHash)
    }

    static func deriveCompositeKEK(
        passphraseNFC: String,
        keyfileSecret: Data,
        salt: Data,
        memoryKiB: UInt32 = defaultArgon2MemoryKiB,
        iterations: UInt32 = defaultArgon2Iterations,
        parallelism: UInt32 = defaultArgon2Parallelism
    ) throws -> SymmetricKey {
        let ikm = deriveCompositeIKM(passphraseNFC: passphraseNFC, keyfileSecret: keyfileSecret)
        do {
            let tag = try Argon2id.derive(
                password: ikm,
                salt: salt,
                memoryKiB: memoryKiB,
                iterations: iterations,
                parallelism: parallelism,
                tagLength: 32
            )
            return SymmetricKey(data: tag)
        } catch {
            throw CryptoError.kdfFailed(String(describing: error))
        }
    }

    static func deriveRecoveryKEK(recoveryBytes: Data, salt: Data) -> SymmetricKey {
        hkdfSHA256(ikm: recoveryBytes, salt: salt, info: recoveryHKDFInfo, outputByteCount: 32)
    }

    static func deriveLedgerKey(dek: SymmetricKey, vaultIDBytes: Data) -> SymmetricKey {
        let dekData = dek.withUnsafeBytes { Data($0) }
        return hkdfSHA256(ikm: dekData, salt: vaultIDBytes, info: ledgerHKDFInfo, outputByteCount: 32)
    }

    // MARK: - AES-256-GCM (AAD-Authenticated)

    static func seal(
        _ plaintext: Data,
        key: SymmetricKey,
        aad: Data,
        nonce: AES.GCM.Nonce = AES.GCM.Nonce()
    ) throws -> SealedValue {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        let nonceData = box.nonce.withUnsafeBytes { Data($0) }
        return SealedValue(
            nonceB64: nonceData.base64EncodedString(),
            ciphertextB64: (box.ciphertext + box.tag).base64EncodedString()
        )
    }

    static func open(
        nonceB64: String,
        ciphertextB64: String,
        key: SymmetricKey,
        aad: Data
    ) throws -> Data {
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
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw CryptoError.authenticationFailed
        }
    }

    // MARK: - Crockford Base32 (Recovery Keys)

    private static let crockfordAlphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func encodeCrockfordBase32(_ bytes: Data) -> String {
        var raw = ""
        raw.reserveCapacity((bytes.count * 8 + 4) / 5)
        var buffer: UInt32 = 0
        var bits = 0
        for b in bytes {
            buffer = (buffer << 8) | UInt32(b)
            bits += 8
            while bits >= 5 {
                bits -= 5
                let idx = Int((buffer >> bits) & 0x1f)
                raw.append(crockfordAlphabet[idx])
            }
        }
        if bits > 0 {
            let idx = Int((buffer << (5 - bits)) & 0x1f)
            raw.append(crockfordAlphabet[idx])
        }

        var grouped = ""
        for (i, ch) in raw.enumerated() {
            if i > 0 && i % 4 == 0 { grouped.append("-") }
            grouped.append(ch)
        }
        return grouped
    }

    static func decodeCrockfordBase32(_ input: String) throws -> Data {
        var out = Data()
        var buffer: UInt32 = 0
        var bits = 0

        for ch in input {
            if ch == "-" || ch.isWhitespace { continue }
            let upper = Character(String(ch).uppercased())
            let mapped: Character
            switch upper {
            case "O": mapped = "0"
            case "I", "L": mapped = "1"
            default: mapped = upper
            }
            guard let idx = crockfordAlphabet.firstIndex(of: mapped) else {
                throw CryptoError.invalidRecoveryKey("Invalid character '\(ch)' in recovery key.")
            }
            buffer = (buffer << 5) | UInt32(idx)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xff))
            }
        }
        if out.isEmpty {
            throw CryptoError.invalidRecoveryKey("Recovery key cannot be empty.")
        }
        return out
    }

    // MARK: - Koban Key File (.key)

    struct KobanKeyFile: Codable {
        var version: Int
        var format: String
        var keyB64: String
        var checksumSha256: String
        var fingerprint: String
        var createdAt: UInt64
    }

    static func generateKeyFileJSON(createdAt: UInt64 = UInt64(Date().timeIntervalSince1970)) throws -> (json: String, secret: Data, fingerprint: String) {
        let secret = randomBytes(32)
        let checksum = sha256Hex(secret)
        let fp = String(checksum.prefix(8))
        let doc = KobanKeyFile(
            version: 2,
            format: "koban-keyfile",
            keyB64: secret.base64EncodedString(),
            checksumSha256: checksum,
            fingerprint: fp,
            createdAt: createdAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(doc)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CryptoError.invalidKeyFile("Could not encode Key File JSON.")
        }
        return (json, secret, fp)
    }

    /// Accepts: (1) Koban Key File v2 JSON, (2) 64-hex string, or (3) any arbitrary file (SHA-256 of bytes).
    static func extractKeyFileSecret(from rawData: Data) throws -> (secret: Data, fingerprint: String) {
        guard !rawData.isEmpty else {
            throw CryptoError.invalidKeyFile("Selected key file is empty.")
        }

        if let text = String(data: rawData, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"), let jsonData = trimmed.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(KobanKeyFile.self, from: jsonData),
               parsed.format == "koban-keyfile" {
                guard let decoded = Data(base64Encoded: parsed.keyB64.trimmingCharacters(in: .whitespacesAndNewlines)),
                      decoded.count == 32 else {
                    throw CryptoError.invalidKeyFile("Corrupt key file: invalid payload length.")
                }
                let actual = sha256Hex(decoded)
                guard actual.lowercased() == parsed.checksumSha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                    throw CryptoError.invalidKeyFile("Corrupt key file: SHA-256 checksum mismatch.")
                }
                return (decoded, String(actual.prefix(8)))
            }

            if trimmed.count == 64, let hexDecoded = dataFromHex(trimmed), hexDecoded.count == 32 {
                return (hexDecoded, String(sha256Hex(hexDecoded).prefix(8)))
            }
        }

        let digest = sha256Data(rawData)
        return (digest, String(sha256Hex(digest).prefix(8)))
    }

    static func dataFromHex(_ hex: String) -> Data? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            let pair = String([chars[i], chars[i + 1]])
            guard let byte = UInt8(pair, radix: 16) else { return nil }
            out.append(byte)
            i += 2
        }
        return out
    }

    // MARK: - Isolated Legacy v1 Support (Read-Only Migration & Old Backup Restore Only)

    enum LegacyV1 {
        static let defaultSecret = "koban-aes256gcm-treasury-vault-v1-key"
        static let kdfIterations: UInt32 = 10_000
        static let kdfDomain = "koban-aes-256-gcm-v1"

        static func deriveKey(secret: String, salt: Data) -> SymmetricKey {
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
            return SymmetricKey(data: hash)
        }

        static func open(nonceB64: String, ciphertextB64: String, key: SymmetricKey) throws -> Data {
            guard let nonceData = Data(base64Encoded: nonceB64),
                  let combined = Data(base64Encoded: ciphertextB64) else {
                throw CryptoError.invalidBase64
            }
            guard nonceData.count == VaultCrypto.nonceLength else { throw CryptoError.invalidNonceLength }
            guard combined.count >= VaultCrypto.tagLength else { throw CryptoError.ciphertextTooShort }
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: nonceData),
                    ciphertext: combined.prefix(combined.count - VaultCrypto.tagLength),
                    tag: combined.suffix(VaultCrypto.tagLength)
                )
                return try AES.GCM.open(box, using: key)
            } catch {
                throw CryptoError.authenticationFailed
            }
        }
    }
}
