# Security Policy

Koban stores personal financial data, so we take security reports seriously and we try to be precise about what the app does and does not protect.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately through GitHub: open the repository's **Security** tab → **Report a vulnerability**. Include:

- the affected app (Windows or macOS) and version,
- steps to reproduce or a proof of concept,
- what an attacker needs (a copy of `koban.db`, local access, a malicious import file, …) and what they gain.

We aim to acknowledge reports within 7 days and to agree on a disclosure date with you. Koban is a small project maintained in spare time, so please allow reasonable time for a fix before publishing.

## Supported versions

Koban is pre-1.0. Only the latest release of each app (Koban for Windows, Koban for macOS) receives security fixes.

## Security model (Vault Format v2)

Both `koban-windows` and `koban-mac` store the financial ledger inside one SQLite database file, `koban.db`:

- Windows: `%LOCALAPPDATA%\Koban\koban.db`
- macOS: `~/Library/Application Support/Koban/koban.db`
- or wherever you moved it (such as an iCloud Drive, OneDrive, or Dropbox folder), plus automatic backups and WebDAV remote copies.

Vault Format v2 separates the **Data Encryption Key (DEK)** from the credentials used to unlock it, following KeePassXC / modern password-safe design:

1. **Random 256-bit DEK + AES-256-GCM with AAD:** Every vault generates a random 256-bit DEK encrypted only in `key_slots`. The DEK lives in process memory only while the vault is unlocked and is cleared/zeroized when you lock or minimize (if enabled). All ledger payloads and key slots use `AES-256-GCM` with fresh 96-bit random nonces and Additional Authenticated Data (`AAD`) binding every ciphertext to its vault ID, slot ID, or ledger sequence number (`vault:v2:<vault_id>:slot:<slot_id>`, `vault:v2:<vault_id>:ledger:<seq>`).
2. **Argon2id Master Password KDF (no empty/default passwords):** Every Vault v2 database requires a Master Password (minimum **12 characters** standalone, or **8 characters** when paired with a Composite Key File). Passwords are normalized to Unicode NFC and stretched with RFC 9106 **Argon2id** (`65536 KiB` memory, `3` iterations, `4` parallel lanes) and a unique 16-byte random salt per slot. There is no built-in default key in v2.
3. **Optional Composite Key File (KeePassXC-style 2FA):** You can pair your Master Password with a local `.key` file (or any arbitrary file hashed with SHA-256). The secret is combined via `HMAC-SHA256(keyfile_secret, SHA256(NFC(passphrase)))` before Argon2id, so an attacker who steals your cloud-synced `koban.db` cannot test passphrases offline without also obtaining the local Key File.
4. **160-bit Recovery Key:** Optional emergency slot encoded in Crockford Base32 (`XXXX-XXXX-...`), derived via `HKDF-SHA256`, displayed once at creation and stored out-of-band by the user.
5. **Hardware / Biometric Quick Unlock (device-local only):** Quick-unlock credentials never enter `koban.db` or cloud backups:
   - **Windows:** Windows Hello TPM `KeyCredentialManager` (`UserConsentVerifier` + hardware key challenge) combined with user-bound Windows DPAPI (`CryptProtectData`) protecting the local cached DEK.
   - **macOS:** Per-vault DEK stored in the macOS Keychain (`com.roland-matuz.koban.vault` / `vault2:<vaultID>`) gated by `LAContext` Touch ID / device owner authentication. **Important signing caveat:** ad-hoc signed macOS builds lack Apple's Data-Protection Keychain entitlement, so the item resides in the user's **login keychain** where Koban itself enforces the `LAContext` Touch ID check; other software running under your macOS user may trigger a standard macOS keychain prompt. Do not enable Touch ID quick unlock on shared/untrusted login sessions unless built with a Developer ID + Data-Protection entitlement.
6. **OS Credential Store for WebDAV:** WebDAV passwords are stored in Windows DPAPI (`webdav.bin`) on Windows and macOS Keychain (`com.roland-matuz.koban.webdav`) on macOS rather than sitting plaintext inside ledger exports.
7. **Minimal Unencrypted Metadata & Zero Browser Plaintext Cache:** The entire financial ledger (transactions, budgets, categories, accounts, settings, and owner display name) is sealed into one `encrypted_ledger` blob with no per-record type/count/timestamp leaks. WebView2 browser `localStorage` plaintext caches are actively purged and never written.
8. **Cloud-Folder & WebDAV Sync Safety:** Both apps force `PRAGMA journal_mode = DELETE` and `PRAGMA synchronous = FULL`, write changes atomically via a staged temporary file swap, validate downloaded WebDAV files (rejecting SQLite views/triggers, unsupported future `format_version > 2`, and default-key v1 files), detect concurrent external modifications via SHA-256 comparison, and offer deterministic record-level merging rather than blind overwrites.

### Legacy Vault Format v1 Compatibility & Caveats

- Existing v1 vaults can be opened for one-step migration to Vault Format v2, which derives a fresh v2 vault DEK, rewrites `encrypted_ledger`, drops legacy `encrypted_records`, enables `PRAGMA secure_delete = ON`, and runs `VACUUM` to scrub old SQLite pages.
- Vault v1 databases and v1 backups (`koban-latest.db`, `koban-daily-*.db`, etc.) created **without** a custom v1 passphrase used a public built-in key and offer no confidentiality against someone holding the file. Upgrade or securely delete legacy v1 backups from **Backups & Exports** after migrating.

## Threat model

**Vault Format v2 protects against:**

- Offline attackers who obtain `koban.db` from a cloud drive, WebDAV server, backup disk, or lost device (mitigated by 256-bit DEK, Argon2id 64 MiB KDF, and optional Composite Key File stored separately from the cloud folder),
- Unauthorized access when Koban is locked (DEK is cleared from memory on lock; unlock UI never decrypts ledger records beforehand),
- Undetected ciphertext tampering or cross-context swapping (`AES-256-GCM` + structured AAD),
- Cloud-sync database corruption or silent data loss (`DELETE` journal mode, atomic writes, SHA-256 drift detection, and record-level merge).

**Out of scope:**

- Malware or code running under your OS user session while the vault is unlocked,
- An attacker with administrator/root access, keyloggers, hardware probes, or physical access to an unlocked device,
- Extracting secrets from process memory while the vault is unlocked,
- Silent remote rollback by a malicious WebDAV/cloud provider serving an earlier valid snapshot (always review unexpected sync conflicts or backup dates).

## Good practices for users

- Use a unique Master Password of **12+ characters** (or **8+ characters + a `.key` file** kept outside your cloud sync folder).
- Back up your **160-bit Recovery Key** offline (password manager or paper safe); without at least one Master Password (plus Key File if enabled) or Recovery Key, Vault v2 data cannot be recovered.
- Upgrade or purge any legacy Vault v1 backups after migrating to v2.
- Use an app-specific password or scoped token for WebDAV rather than your main cloud account password.
