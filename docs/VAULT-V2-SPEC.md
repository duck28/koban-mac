# Koban vault format v2: key hierarchy, unlock methods, migration — shared spec (Windows + macOS)

Status: **Draft** · Applies to: `koban-windows` (Rust `src-tauri/src/lib.rs` + React) and `koban-mac` (`KobanKit/Sources/KobanCore/Vault`, `Koban/Features/Settings`).

Both builds MUST implement identical formats so one `koban.db` keeps working across Windows and macOS devices, backups and WebDAV. Any constant in this document is part of the format: change it on both sides or not at all.

---

## 0. Why (v1 problems this spec fixes)

| v1 behaviour | Consequence |
|---|---|
| Without a custom passphrase the ledger key is derived from the hardcoded `koban-aes256gcm-treasury-vault-v1-key`; the salt is in the same file. | Every default vault (and every backup / WebDAV copy of it) is readable by anyone who has the file. Public once the source is public. |
| Passkey / Windows Hello "wrapping" uses key = KDF(`"koban-passkey-wrap:" + credentialId`, vault salt); both inputs are plaintext in `vault_meta`. | The wrapped passphrase is recoverable from the file alone; the passkey adds no cryptographic protection. The WebAuthn assertion signature is never verified. |
| Ledger is decrypted at launch, before the lock screen. | The lock screen is UI only for default vaults. |
| KDF: 10 000 × SHA-256. | Cheap to brute-force on GPUs. |
| Every save mirrors the full ledger (incl. WebDAV password) as base64 into WebView2 `localStorage` (`koban_encrypted_vault_v1`, `src/utils/storage.ts`). | Plaintext copy on disk in the WebView2 profile. |
| `load_ledger_db` stores the passphrase in `SESSION_KEY` before checking it decrypts. | A wrong input can become the key for the next save. |
| `encrypted_records` stores `record_kind`, record ids and `updated_at` in plaintext. | Leaks counts of transactions / accounts / goals and edit times. |
| Master passphrase verifier (PBKDF2) stored next to the ciphertext. | Redundant second offline-guessing oracle; GCM already authenticates. |

## 1. Threat model

**In scope (the vault must resist):**
- Offline attacker with a copy of `koban.db`: stolen/lost disk, copied backup folder, compromised or curious WebDAV provider, synced cloud folder, leaked `koban-pre-webdav-sync-*.db` / `koban-webdav-conflict-*.db` files.
- Someone at the user's unlocked computer opening Koban while it is locked (lock screen must be a real cryptographic gate).
- Tampering with the file (swapping ciphertext rows, rolling key slots between vaults) — must be detected, not silently accepted.

**Out of scope (documented in `SECURITY.md`, best effort only):**
- Malware or another process running as the same OS user while the vault is unlocked.
- Admin/root compromise, keyloggers, evil-maid attacks.
- Memory forensics of a running, unlocked app (we zeroize keys, but JS strings cannot be reliably wiped).
- Rollback of a WebDAV file to an older, validly encrypted version (detectable only via the sync state; not a crypto goal).

**Security goals:** confidentiality and integrity of the ledger against the in-scope attacker, as strong as the user's weakest *enrolled* unlock method; no secret needed to decrypt exists in the file or the binary.

## 2. Key hierarchy

```
                 ┌──────────────────────────── per vault, random ───────────────────────────┐
                 │                         DEK  (32 random bytes)                            │
                 └───────────────┬───────────────────────────────────────────────────────────┘
                                 │ HKDF-SHA256(ikm = DEK, salt = vault_id, info = "koban/v2/ledger")
                                 ▼
                          ledger_key (32 B) ── AES-256-GCM ──► encrypted_vault.ledger_state

 DEK is stored only wrapped (AES-256-GCM) by one KEK per key slot:

  synced slots (in koban.db, table key_slots)        device slots (never in koban.db)
  ├─ passphrase   KEK = Argon2id(passphrase)         ├─ windows_hello  KEK from TPM-backed Hello key signature (+ DPAPI)
  ├─ recovery     KEK = HKDF(recovery key)           └─ mac_keychain   DEK itself stored in Keychain, .biometryCurrentSet
  └─ webauthn_prf KEK = HKDF(PRF output)  (optional, phase 3)
```

Rules:
- The DEK is generated once per vault (`getrandom` / `SecRandomCopyBytes`) and never leaves native code (Rust / Swift). The React layer never sees the DEK, a KEK or the passphrase after submitting it.
- A vault MUST always have at least one **portable** slot (`passphrase` or `recovery`). Device slots cannot exist alone, because the file travels (WebDAV, backups, second device).
- Changing the passphrase rewrites only the passphrase slot. The ledger is not re-encrypted.
- Device slots are not stored in `koban.db` because `koban.db` is synced: a slot only one device can open does not belong in a file every device downloads.

## 3. File format (SQLite, journal mode DELETE as today)

### 3.1 `vault_meta` (plaintext)

| key | value | notes |
|---|---|---|
| `format_version` | `"2"` | Readers MUST refuse unknown higher versions (never overwrite them). |
| `vault_id` | base64 (std, padded) of 16 random bytes | Stable vault identity; replaces `salt_b64` as identity (Keychain account, device-slot file name). |
| `cipher` | `"AES-256-GCM"` | Informational. |
| `custom_passphrase` | `"true"` | **Tripwire for v1 builds** (see §7.4). Always `"true"` in v2. |
| `auth_settings` | JSON, see §6.3 | Only what the lock screen needs. No verifier, no wrapped secrets, no display name. |
| `salt_b64` | v1 salt, kept as is | **Unused by v2.** Kept so v1 builds don't write into a v2 file: v1 `ensure_vault_salt` / `ensureSalt` insert a new salt when the row is missing, which would modify the file and mark it dirty for WebDAV. |

Removed in v2: `kdf`, `auth_config` (contents move into the encrypted ledger or `auth_settings`).

### 3.2 `key_slots` (new)

```sql
CREATE TABLE IF NOT EXISTS key_slots (
    id             TEXT PRIMARY KEY,   -- base64url(16 random bytes), no padding
    kind           TEXT NOT NULL,      -- 'passphrase' | 'recovery' | 'webauthn_prf'
    label          TEXT NOT NULL,      -- user-visible, e.g. "Passphrase", "Recovery key (2026-11-10)"
    params         TEXT NOT NULL,      -- JSON, per kind (§4)
    nonce_b64      TEXT NOT NULL,      -- 12 bytes
    ciphertext_b64 TEXT NOT NULL,      -- wrapped DEK: ciphertext ‖ tag (48 bytes)
    created_at     INTEGER NOT NULL
);
```

Wrapped DEK = `AES-256-GCM(key = KEK, nonce = random 12 B, plaintext = DEK, aad = "koban/v2/slot/" ‖ vault_id ‖ "/" ‖ slot.id ‖ "/" ‖ slot.kind)`.

AAD binds a slot to its vault, row and kind: copying a slot from another vault or editing its kind fails authentication.

### 3.3 `encrypted_vault` (unchanged schema)

Row `ledger_state`: `AES-256-GCM(ledger_key, random nonce, LedgerState JSON, aad = "koban/v2/ledger/" ‖ vault_id ‖ "/ledger_state")`.

### 3.4 `encrypted_records` — dropped

Dropped in v2 (`DROP TABLE`, then `VACUUM`). The full-state row is already the source of truth; the mirror leaks metadata (§0). The "encrypted records" count in Settings is computed after decryption instead.

### 3.5 Encoding conventions

- All AAD strings are UTF-8, concatenated without separators other than those written above; `vault_id` in AAD is its base64 text as stored.
- Base64: standard alphabet, padded, for `*_b64` columns (as v1). base64url without padding for ids (as v1 passkey ids).
- Nonces are always 12 random bytes from the OS CSPRNG. Never counters, never reused.

## 4. Slot kinds

### 4.1 `passphrase` (required)

```json
{ "kdf": "argon2id", "v": 19, "m_kib": 65536, "t": 3, "p": 4, "salt_b64": "<16 random bytes>" }
```

- KEK = Argon2id(password = NFC(passphrase) as UTF-8, salt, m, t, p, tag length 32), RFC 9106. Defaults are the RFC 9106 second recommended option (64 MiB, 3 passes, 4 lanes). Parameters are read from the slot, so they can be raised later without a format change.
- **No trimming** in v2. Both sides apply Unicode NFC (`String.precomposedStringWithCanonicalMapping` / `unicode-normalization` crate). The UI refuses passphrases with leading/trailing whitespace when setting them. (v1 trimmed inconsistently; legacy unlock in §7 tries as-typed, then trimmed.)
- Policy when setting: minimum 12 characters + a strength meter; offer a generated passphrase. No maximum below 1024 bytes.
- Target cost: about 0.5–1 s on a low-end supported machine. Benchmark before freezing the defaults (open question Q4).

Libraries: Rust `argon2` (RustCrypto). Swift: CryptoKit has no Argon2 → vendor the PHC reference implementation (`phc-winner-argon2`, CC0 / Apache-2.0) as a SwiftPM C target in KobanKit. Both are checked against RFC 9106 test vectors and the shared vectors (§9).

### 4.2 `recovery` (strongly recommended, offered at setup)

```json
{ "kdf": "hkdf-sha256", "salt_b64": "<16 random bytes>" }
```

- Recovery key = 20 random bytes (160 bits), shown as Crockford Base32: 32 characters in 8 groups of 4 (`K7Q2-…`). Input is case-insensitive; `-` and spaces are ignored; `O→0`, `I/L→1`.
- KEK = HKDF-SHA256(ikm = 20 key bytes, salt, info = `"koban/v2/recovery-kek"`). It is high-entropy, so no slow KDF is needed.
- Shown once. Setup asks the user to type back the last group before continuing. Settings can "Replace recovery key" (new slot, old slot deleted).

### 4.3 `webauthn_prf` (optional, phase 3 — depends on spike, Q5)

```json
{ "credential_id": "<base64url>", "rp_id": "<rp id used at registration>", "prf_salt_b64": "<32 random bytes>" }
```

- Registration requests `extensions: { prf: {} }`. Enroll only if `getClientExtensionResults().prf.enabled === true`.
- Unlock: `navigator.credentials.get` with `extensions.prf.eval.first = prf_salt`, `userVerification: "required"`. The 32-byte PRF output is passed to Rust: KEK = HKDF-SHA256(ikm = PRF output, salt = prf_salt, info = `"koban/v2/webauthn-prf-kek"`).
- No PRF support means no `webauthn_prf` slot. We do **not** fall back to a "UI-only passkey": a passkey that cannot derive a key is not offered as an unlock method.
- Signature verification is not needed for confidentiality, because the PRF output is the secret. Wrong authenticator ⇒ GCM failure.

### 4.4 Device slot: `windows_hello` (Windows, phase 2)

Not in `koban.db`. Stored in `%LOCALAPPDATA%\Koban\device-slots\<vault_id_base64url>.json`:

```json
{ "version": 1, "kind": "windows_hello", "key_name": "koban-vault-<vault_id_base64url>",
  "challenge_b64": "<32 random bytes>", "nonce_b64": "...", "ciphertext_b64": "<DPAPI(wrapped DEK)>" }
```

- Uses `Windows.Security.Credentials.KeyCredentialManager` (TPM-backed RSA key that Windows Hello gates). Enrollment: `RequestCreateAsync(key_name, ReplaceExisting)`. Unlock: `OpenAsync(key_name)` → `RequestSignAsync(challenge)`. Hello signatures are RSA PKCS#1 v1.5, which is deterministic, so the same challenge always gives the same signature.
- KEK = HKDF-SHA256(ikm = signature, salt = challenge, info = `"koban/v2/windows-hello-kek"`). Wrapped DEK as in §3.2 with AAD `"koban/v2/device/" ‖ vault_id ‖ "/windows_hello"`; the whole wrapped blob is additionally protected with DPAPI (`CryptProtectData`, user scope). The file alone is useless off this user account.
- Called via the `windows` crate (`Security_Credentials`, `Win32_Security_Cryptography`), **not** by spawning PowerShell. `UserConsentVerifier` (current v1 code) only says "the user is present" and must not be used as an unlock method.
- Verify determinism on real hardware during implementation (sign twice, compare). If a device returns differing signatures, refuse enrollment there.

### 4.5 Device slot: `mac_keychain` (macOS, phase 2)

- Keychain generic password, service `com.roland-matuz.koban.vault`, account `vault2:<vault_id>`, value = DEK (32 raw bytes) — **not** the passphrase.
- Access control: `SecAccessControlCreateWithFlags(kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet)` in the data-protection keychain (`kSecUseDataProtectionKeychain`). Requires a signed build with `keychain-access-groups`. Re-enrolling a fingerprint invalidates it; the user falls back to the passphrase and re-enables Touch ID.
- `.userPresence` (Touch ID or Mac password) is acceptable as an alternative flag for Macs without Touch ID. Same storage, clearly labelled "Mac password".

**Ad-hoc signed builds (decided, D3):** release builds are ad-hoc signed today (`CODE_SIGN_IDENTITY: "-"`), so the data-protection keychain is not available. Until the app is signed with a Developer ID, Touch ID unlock uses a **weaker mode**:
- The DEK is stored in the login keychain (same service/account as above), and the app reads it only after a successful `LAContext` evaluation. The Touch ID check is enforced by Koban, not by the OS. Other software running as the user can request the item; macOS asks the user for permission first.
- Off by default. Enabling it shows: "Touch ID here is a convenience lock. Software running under your account could read the vault key after macOS asks you. Use your passphrase if that matters to you." `SECURITY.md` documents the same.
- The keychain ACL trusts the app by its code signature, which changes with every ad-hoc build. After each update macOS may ask once more for access, or the item may be unreadable; then the user unlocks with the passphrase and Touch ID is re-armed automatically.
- Turning it off deletes the item. The lock screen offers "Re-key vault" (§5 `vault_rekey`) for users who think the key was read.
- Once the app is Developer ID signed with `keychain-access-groups`, new enrollments use the data-protection keychain with `.biometryCurrentSet`, and existing login-keychain items are moved on the next Touch ID unlock.

## 5. Native API (replaces the v1 commands)

Rust commands / Swift `KobanVault` methods. No command accepts or returns the DEK.

| Command | Behaviour |
|---|---|
| `vault_status()` | `{ formatVersion, vaultId, slots: [{id, kind, label}], deviceSlot: bool, unlocked: bool, needsMigration: bool }`. Never decrypts. |
| `vault_create(passphrase)` | New DEK + `vault_id`, passphrase slot, empty ledger. Returns status. |
| `vault_unlock_passphrase(passphrase)` / `vault_unlock_recovery(key)` / `vault_unlock_prf(slotId, prfOutputB64)` / `vault_unlock_device()` | Tries the slot(s). On success: DEK held in native memory (`Zeroizing<[u8;32]>` / `SymmetricKey`), returns the decrypted ledger JSON. On failure: error, **session state untouched**. |
| `vault_lock()` | Zeroizes the DEK. The front end drops its ledger state and shows the lock screen. |
| `vault_save(ledgerJson, …backup opts)` | Requires unlocked. Encrypts with the session DEK. |
| `vault_set_passphrase(current, new)` | Requires unlocked **and** re-entry of the current passphrase (or a just-completed unlock within 60 s). Rewrites the passphrase slot only. |
| `vault_create_recovery_key()` → `string` | Requires unlocked. Replaces the recovery slot; returns the key for one-time display. |
| `vault_enroll_device()` / `vault_remove_device()` | Requires unlocked. |
| `vault_add_prf_slot(credentialId, rpId, prfSaltB64, prfOutputB64)` / `vault_remove_slot(id)` | Refuses to remove the last portable slot. |
| `vault_rekey()` | New DEK, re-encrypts the ledger, rewraps synced slots, re-creates this device's device slot. Other devices' device slots fail and fall back to the passphrase. |
| `vault_open_backup(path, secret)` | Opens a backup (v1 or v2) read-only into memory for preview / restore; restore re-encrypts into the current vault under the session DEK. |

Removed: `set_vault_passphrase`, `load_ledger_db(passphrase)`, `wrap_vault_secret_for_credential`, `unwrap_vault_secret_for_credential`, `verify_windows_hello`, `get_auth_config` / `save_auth_config` (replaced by `auth_settings` + ledger settings).

## 6. Flows

### 6.1 First run (new vault)

1. Name, currency, etc. (unchanged onboarding steps).
2. **Choose a passphrase** (required; policy §4.1). Show "Generate one for me".
3. **Recovery key**: shown, with copy/print and a "type the last group" confirmation. A "Skip (not recommended)" option sits behind a warning that a forgotten passphrase means permanent data loss.
4. **Faster unlock** (optional): Windows Hello / Touch ID; passkey (PRF) when available.
5. `vault_create` → save.

### 6.2 Launch / unlock

1. `vault_status()`. If `needsMigration` → §7.
2. Lock screen lists only methods that can actually unlock this vault on this device: device slot (auto-prompt if `auth_settings.autoPromptDevice`), passkey, passphrase, recovery key ("Forgot passphrase?").
3. Nothing is decrypted before a successful unlock. There is no "Continue without login".
4. After a recovery-key unlock, force setting a new passphrase.

### 6.3 `auth_settings` (plaintext, minimal)

```json
{ "autoPromptDevice": true, "autoLockMinutes": 15 }
```

Everything else from v1 `AuthConfig` (`userDisplayName`, passkey labels, …) moves into `LedgerState.settings` (encrypted). The lock screen shows slot labels from `key_slots`. `autoLockMinutes` stays plaintext so the timer works before the ledger is parsed. Tampering with it only weakens auto-lock for an attacker who already has file write access.

### 6.4 Lock / auto-lock

`vault_lock()` + clear React ledger state + clear WebDAV credentials from front-end memory. WebDAV background sync pauses while locked (it needs no DEK, it moves ciphertext, but the credentials live in the encrypted ledger).

### 6.5 New device via WebDAV

Download (unchanged, §WEBDAV-SPEC) → `vault_status` → unlock with passphrase / recovery / synced passkey → offer device enrollment. Before replacing a local file, pull checks the downloaded `format_version` and refuses versions it does not know.

### 6.6 Backups

Backups are byte copies of `koban.db`, so they carry `key_slots` and open with the passphrase or recovery key that was valid **when the backup was taken**. The UI states this next to the backup settings. Restoring re-encrypts into the current vault; it never replaces the current vault's key slots.

## 7. Migration v1 → v2

### 7.1 Detection

`format_version` absent, `kdf = 'SHA256-10000-Salted'`, `salt_b64` present.

### 7.2 Procedure (both platforms)

1. Decrypt the v1 ledger: if `custom_passphrase = 'true'` ask for the passphrase (try as typed, then trimmed); otherwise use the legacy constant. The constant moves into an isolated `legacy_v1` module used only for reading. No code path encrypts with it.
2. "Secure your vault" screen (cannot be skipped): new passphrase (prefilled option "Keep my current passphrase" when one existed), recovery key, optional device unlock. Existing Windows passkey / Hello records are **not** carried over (their wrapped secrets are compromised by design). The user re-enrolls.
3. In **one SQLite transaction**: `PRAGMA secure_delete = ON`; generate DEK + `vault_id`; insert slots; rewrite `encrypted_vault.ledger_state` under v2; `DROP TABLE encrypted_records`; delete `kdf` and `auth_config` (keep `salt_b64`, §3.1); set `format_version = '2'`, `custom_passphrase = 'true'`. Commit, then `VACUUM`.
4. Post-migration cleanup:
   - Windows: `localStorage.removeItem('koban_encrypted_vault_v1')` and `'koban_auth_config_v1'`. Stop writing them. Done in phase 0: the desktop app no longer writes them and purges them after a successful encrypted load or save. Only the browser preview (`npm run dev` without Tauri) still uses them, and labels that storage "not encrypted".
   - macOS: delete Keychain items of service `com.roland-matuz.koban.touchid` for this vault (they hold the v1 passphrase).
5. **Legacy files screen**: list `koban-latest.db`, `koban-daily-*.db`, `koban-backup-*.db`, `koban-pre-webdav-sync-*.db`, `koban-webdav-conflict-*.db` in the backup folder and next to the DB that are still v1. Explain that default-key v1 files are readable by anyone. Offer "Delete" (to the OS trash/recycle bin) or "Upgrade" (re-encrypt each to v2 under the current DEK). The remote WebDAV file is upgraded by the next push.
6. Then re-run `perform_backup_to_dir` so the backup folder holds a v2 copy.

Note for release notes: SSDs and WebView2's LevelDB cannot guarantee that old bytes are physically erased. Users with a sensitive v1 history should treat old copies as exposed.

### 7.3 Failure handling

If anything before commit fails, the v1 file is untouched (SQLite atomicity). No automatic pre-migration copy is written, because for default-key vaults that copy would be readable by anyone.

### 7.4 Mixed versions (old build meets v2 file)

A v1 build that opens a v2 file (WebDAV primary, shared folder):
- Windows v1: reads `custom_passphrase = 'true'` → `saveBlocked` + lock screen → v1 KDF fails. The UI may then unlock into an empty ledger (`handleUnlockSuccess` unlocks even when the reload fails), but `saveBlocked` stays set, so **it does not overwrite the vault or push it to WebDAV.** This is why the tripwire key is kept. Without it, v1 would treat the file as a default vault, fail to decrypt, show setup and save a blank ledger over it.
- macOS v1: `KobanVault.load` throws `passphraseRequired` → locked.

Still: release both platforms' v2 together, and have the v2 WebDAV push refuse to overwrite a remote whose `format_version` is higher than its own.

## 8. Other changes shipped with v2

- Remove the `localStorage` ledger/auth mirrors (§7.2.4) — do this **first**, even before v2 lands.
- Rust: `zeroize` for DEK/KEK buffers. Swift: keep keys in `SymmetricKey`, not `Data`/`String`.
- Correct UI copy: no "PBKDF2" claims; describe Argon2id + AES-256-GCM.
- Replace the PowerShell-based Windows Hello calls with `windows` crate calls (the current `check_windows_hello_available` reports `AVAILABLE` on any exception).

## 9. Test vectors and cross-platform tests

Shared file `docs/vault-v2-test-vectors.json` (identical in both repos), consumed by `cargo test` and `swift test`:
- Argon2id RFC 9106 §5.3 vector + one vector with our default parameters.
- HKDF-SHA256 for each `info` string above.
- Slot unwrap: fixed KEK, nonce, DEK, vault_id, slot id → expected ciphertext; plus tampered-AAD cases that must fail.
- Recovery key Base32 encode/decode, including case and confusable characters.
- NFC: a passphrase in NFD form unlocks a slot created from its NFC form.

Fixture databases committed to both test suites: `v1-default.db`, `v1-custom.db` (known passphrase), `v2.db` (created on Windows), `v2-mac.db` (created on macOS). Each platform must open all four, migrate both v1 fixtures, and refuse a `v3` fixture without modifying it.

## 10. Phases

| Phase | Scope | Blocks open-sourcing? |
|---|---|---|
| 0 | Remove `localStorage` mirrors; stop creating passkey "wrapped" secrets; add `SECURITY.md` with the threat model and the v1 caveat. | Yes |
| 1 | v2 format, passphrase + recovery slots, native-held DEK, real lock screen, migration, test vectors (both platforms, one release). | Yes |
| 2 | Device slots: Windows Hello (`KeyCredentialManager`), macOS Keychain DEK (weaker login-keychain mode until Developer ID signing, D3). | No (no fast unlock until then) |
| 3 | WebAuthn PRF slot, after the spike (Q5). | No |
| 4 | Hardening: Tauri capabilities review, WebDAV password in the OS credential store, Windows code signing. (Done early in M1: CSP, file commands limited to user-chosen paths, patched SheetJS, CI with audits, pinned Actions.) | Recommended |

## 11. Decisions (2026-11-10)

| # | Decision |
|---|---|
| D1 | Both repos are licensed **Apache-2.0**. |
| D2 | The repos go public **after phase 1 (v2 format) ships** on both platforms, not before. |
| D3 | macOS stays ad-hoc signed for now; Touch ID unlock uses the documented weaker login-keychain mode (§4.5) until Developer ID signing exists. |
| D4 | A passphrase is **required** (no passphrase-less mode, former Q1): at least 12 characters, strength meter, "generate one" option (former Q2, §4.1). |
| D5 | Windows code signing is deferred to phase 4; releases publish `SHA256SUMS.txt` meanwhile. |

## 12. Open questions

- **Q3** Any consumer of `encrypted_records` besides the record count? (Draft assumes none.)
- **Q4** Argon2id defaults after benchmarking on the slowest supported Windows machine and an Intel Mac.
- **Q5** Spike: does WebView2 in Tauri 2 (origin `http://tauri.localhost` on Windows) support WebAuthn with the PRF extension through Windows Hello, and is the rp id stable across app updates? If not, `webauthn_prf` is limited to roaming security keys or dropped.
- ~~**Q6** macOS signing~~ — answered: builds are ad-hoc signed; see D3.
