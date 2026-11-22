import CryptoKit
import XCTest
@testable import KobanCore

final class VaultCryptoTests: XCTestCase {
    func testRFC9106Argon2idOfficialVector() throws {
        let password = Data(repeating: 0x01, count: 32)
        let salt = Data(repeating: 0x02, count: 16)
        let secret = Data(repeating: 0x03, count: 8)
        let ad = Data(repeating: 0x04, count: 12)
        let tag = try Argon2id.derive(
            password: password,
            salt: salt,
            secret: secret,
            associatedData: ad,
            memoryKiB: 32,
            iterations: 3,
            parallelism: 4,
            tagLength: 32
        )
        XCTAssertEqual(
            tag.map { String(format: "%02x", $0) }.joined(),
            "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659"
        )
    }

    func testSharedVaultV2Vectors() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let vectorsURL = repoRoot.appendingPathComponent("docs/vault-v2-test-vectors.json")
        let data = try Data(contentsOf: vectorsURL)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let vidB64 = try XCTUnwrap(root["vault_id_b64"] as? String)
        let hkdfVec = try XCTUnwrap(root["hkdf_ledger"] as? [String: Any])
        let dekBytes = try XCTUnwrap(VaultCrypto.dataFromHex(try XCTUnwrap(hkdfVec["dek_hex"] as? String)))
        let vidBytes = try XCTUnwrap(VaultCrypto.dataFromHex(try XCTUnwrap(hkdfVec["vault_id_hex"] as? String)))
        XCTAssertEqual(vidBytes.base64EncodedString(), vidB64)

        let ledgerKey = VaultCrypto.deriveLedgerKey(dek: SymmetricKey(data: dekBytes), vaultIDBytes: vidBytes)
        XCTAssertEqual(
            ledgerKey.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() },
            try XCTUnwrap(hkdfVec["ledger_key_hex"] as? String)
        )

        let def = try XCTUnwrap(root["koban_argon2id_default"] as? [String: Any])
        let defSalt = try XCTUnwrap(VaultCrypto.dataFromHex(try XCTUnwrap(def["salt_hex"] as? String)))
        let defKEK = try VaultCrypto.derivePassphraseKEK(
            passphraseNFC: try XCTUnwrap(def["passphrase_nfc"] as? String),
            salt: defSalt,
            memoryKiB: UInt32(try XCTUnwrap(def["m_kib"] as? Int)),
            iterations: UInt32(try XCTUnwrap(def["t"] as? Int)),
            parallelism: UInt32(try XCTUnwrap(def["p"] as? Int))
        )
        XCTAssertEqual(
            defKEK.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() },
            try XCTUnwrap(def["kek_hex"] as? String)
        )

        let nfcVec = try XCTUnwrap(root["nfc_normalization"] as? [String: Any])
        let nfcSalt = try XCTUnwrap(VaultCrypto.dataFromHex(try XCTUnwrap(nfcVec["salt_hex"] as? String)))
        let nfdKEK = try VaultCrypto.derivePassphraseKEK(
            passphraseNFC: VaultCrypto.normalizeNFC(try XCTUnwrap(nfcVec["nfd"] as? String)),
            salt: nfcSalt,
            memoryKiB: UInt32(try XCTUnwrap(nfcVec["m_kib"] as? Int)),
            iterations: UInt32(try XCTUnwrap(nfcVec["t"] as? Int)),
            parallelism: UInt32(try XCTUnwrap(nfcVec["p"] as? Int))
        )
        XCTAssertEqual(
            nfdKEK.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() },
            try XCTUnwrap(nfcVec["kek_hex"] as? String)
        )

        let comp = try XCTUnwrap(root["composite_keyfile"] as? [String: Any])
        let kfSecret = try XCTUnwrap(VaultCrypto.dataFromHex(try XCTUnwrap(comp["keyfile_secret_hex"] as? String)))
        let compSalt = try XCTUnwrap(VaultCrypto.dataFromHex(try XCTUnwrap(comp["salt_hex"] as? String)))
        let compIKM = VaultCrypto.deriveCompositeIKM(passphraseNFC: try XCTUnwrap(comp["passphrase"] as? String), keyfileSecret: kfSecret)
        XCTAssertEqual(
            compIKM.map { String(format: "%02x", $0) }.joined(),
            try XCTUnwrap(comp["ikm_hex"] as? String)
        )
        let compKEK = try VaultCrypto.deriveCompositeKEK(
            passphraseNFC: try XCTUnwrap(comp["passphrase"] as? String),
            keyfileSecret: kfSecret,
            salt: compSalt,
            memoryKiB: UInt32(try XCTUnwrap(comp["m_kib"] as? Int)),
            iterations: UInt32(try XCTUnwrap(comp["t"] as? Int)),
            parallelism: UInt32(try XCTUnwrap(comp["p"] as? Int))
        )
        XCTAssertEqual(
            compKEK.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() },
            try XCTUnwrap(comp["kek_hex"] as? String)
        )

        let rec = try XCTUnwrap(root["recovery_key"] as? [String: Any])
        let recBytes = try XCTUnwrap(VaultCrypto.dataFromHex(try XCTUnwrap(rec["recovery_bytes_hex"] as? String)))
        XCTAssertEqual(VaultCrypto.encodeCrockfordBase32(recBytes), try XCTUnwrap(rec["crockford_grouped"] as? String))
        let recKEK = VaultCrypto.deriveRecoveryKEK(recoveryBytes: recBytes, salt: vidBytes)
        XCTAssertEqual(
            recKEK.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() },
            try XCTUnwrap(rec["kek_hex"] as? String)
        )

        let sw = try XCTUnwrap(root["slot_wrap"] as? [String: Any])
        let sAAD = VaultCrypto.slotAAD(
            vaultIDB64: vidB64,
            slotID: try XCTUnwrap(sw["slot_id"] as? String),
            kind: try XCTUnwrap(sw["kind"] as? String)
        )
        XCTAssertEqual(String(data: sAAD, encoding: .utf8), try XCTUnwrap(sw["aad"] as? String))
        let unwrappedDEK = try VaultCrypto.open(
            nonceB64: try XCTUnwrap(sw["nonce_b64"] as? String),
            ciphertextB64: try XCTUnwrap(sw["ciphertext_b64"] as? String),
            key: nfdKEK,
            aad: sAAD
        )
        XCTAssertEqual(unwrappedDEK, dekBytes)

        let le = try XCTUnwrap(root["ledger_encrypt"] as? [String: Any])
        let lAAD = VaultCrypto.ledgerAAD(vaultIDB64: vidB64)
        XCTAssertEqual(String(data: lAAD, encoding: .utf8), try XCTUnwrap(le["aad"] as? String))
        let decLedger = try VaultCrypto.open(
            nonceB64: try XCTUnwrap(le["nonce_b64"] as? String),
            ciphertextB64: try XCTUnwrap(le["ciphertext_b64"] as? String),
            key: ledgerKey,
            aad: lAAD
        )
        XCTAssertEqual(String(data: decLedger, encoding: .utf8), try XCTUnwrap(le["plaintext"] as? String))
    }

    func testTamperedAADAndKeyFiles() throws {
        let key = SymmetricKey(data: VaultCrypto.randomBytes(32))
        let aad = VaultCrypto.slotAAD(vaultIDB64: "vid", slotID: "slot1", kind: "passphrase")
        let sealed = try VaultCrypto.seal(Data("secret-dek".utf8), key: key, aad: aad)

        XCTAssertThrowsError(
            try VaultCrypto.open(
                nonceB64: sealed.nonceB64,
                ciphertextB64: sealed.ciphertextB64,
                key: key,
                aad: VaultCrypto.slotAAD(vaultIDB64: "vid", slotID: "slot2", kind: "passphrase")
            )
        ) { error in
            XCTAssertEqual(error as? VaultCrypto.CryptoError, .authenticationFailed)
        }

        let (json, secret, fp) = try VaultCrypto.generateKeyFileJSON(createdAt: 1_700_000_000)
        let extracted = try VaultCrypto.extractKeyFileSecret(from: Data(json.utf8))
        XCTAssertEqual(extracted.secret, secret)
        XCTAssertEqual(extracted.fingerprint, fp)

        let arbitrary = try VaultCrypto.extractKeyFileSecret(from: Data("random binary keyfile".utf8))
        XCTAssertEqual(arbitrary.secret.count, 32)
    }

    func testCrockfordConfusablesRoundTrip() throws {
        let raw = Data((0..<20).map { UInt8($0 * 11 & 0xff) })
        let encoded = VaultCrypto.encodeCrockfordBase32(raw)
        let confusable = encoded.lowercased().replacingOccurrences(of: "0", with: "o").replacingOccurrences(of: "1", with: "l")
        XCTAssertEqual(try VaultCrypto.decodeCrockfordBase32(confusable), raw)
    }
}
