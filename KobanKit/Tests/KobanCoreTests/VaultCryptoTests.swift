import CryptoKit
import XCTest
@testable import KobanCore

/// Expected values below were generated with the exact `derive_aes256_key` code from
/// src-tauri/src/lib.rs and the same `aes-gcm 0.10` / `sha2 0.10` crates. If these fail,
/// macOS and Windows can no longer open each other's vaults.
final class VaultCryptoTests: XCTestCase {
    private let salt = Data((0..<16).map { UInt8($0) }) // 00 01 02 … 0f

    func testSaltFixture() {
        XCTAssertEqual(salt.base64EncodedString(), "AAECAwQFBgcICQoLDA0ODw==")
    }

    func testKeyDerivationMatchesRustWithDefaultSecret() {
        let key = VaultCrypto.deriveKeyBytes(secret: VaultCrypto.defaultSecret, salt: salt)
        XCTAssertEqual(key.hex, "ca869c8c009679f7da06a1df657fb14ff94d65f3c34c15ec4eabc5575dc89cd1")
    }

    func testKeyDerivationMatchesRustWithCustomPassphrase() {
        let key = VaultCrypto.deriveKeyBytes(secret: "correct horse battery staple", salt: salt)
        XCTAssertEqual(key.hex, "87bc60f3472091e63f673c69327f78dd4494655486e1695d72ec00b1f2e42020")
    }

    func testDecryptsCiphertextProducedByRust() throws {
        let key = VaultCrypto.deriveKey(secret: VaultCrypto.defaultSecret, salt: salt)
        let plaintext = try VaultCrypto.open(
            nonceB64: "CxYhLDdCTVhjb3qF",
            ciphertextB64: "RkZ6fW+8Bbm2ReE/c3HYSgPP3a9guCU6B6DaHenqft7TYq3cAhYKwoyCraov",
            key: key
        )
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), #"{"version":1,"hello":"koban"}"#)
    }

    func testEncryptsExactlyLikeRustForFixedNonce() throws {
        let key = VaultCrypto.deriveKey(secret: VaultCrypto.defaultSecret, salt: salt)
        let nonce = try AES.GCM.Nonce(data: Data([11, 22, 33, 44, 55, 66, 77, 88, 99, 111, 122, 133]))
        let sealed = try VaultCrypto.seal(Data(#"{"version":1,"hello":"koban"}"#.utf8), key: key, nonce: nonce)
        XCTAssertEqual(sealed.nonceB64, "CxYhLDdCTVhjb3qF")
        XCTAssertEqual(sealed.ciphertextB64, "RkZ6fW+8Bbm2ReE/c3HYSgPP3a9guCU6B6DaHenqft7TYq3cAhYKwoyCraov")
    }

    func testWrongKeyFailsAuthentication() throws {
        let wrong = VaultCrypto.deriveKey(secret: "not the secret", salt: salt)
        XCTAssertThrowsError(try VaultCrypto.open(
            nonceB64: "CxYhLDdCTVhjb3qF",
            ciphertextB64: "RkZ6fW+8Bbm2ReE/c3HYSgPP3a9guCU6B6DaHenqft7TYq3cAhYKwoyCraov",
            key: wrong
        )) { error in
            XCTAssertEqual(error as? VaultCrypto.CryptoError, .authenticationFailed)
        }
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
