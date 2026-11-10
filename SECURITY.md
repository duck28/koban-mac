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

## Current security model (vault format v1)

Both apps keep the ledger in one SQLite file, `koban.db`:

- Windows: `%LOCALAPPDATA%\Koban\koban.db`
- macOS: `~/Library/Application Support/Koban/koban.db`
- or wherever you moved it, plus automatic backups and the WebDAV copy, which are byte copies of the same file.

The ledger is stored as AES-256-GCM ciphertext with a random nonce per write. The key is derived from a secret and a random per-vault salt with 10 000 rounds of salted SHA-256.

### Known limitations

These are known, documented weaknesses of format v1. Reports about them are welcome only if they show something beyond what is listed here.

1. **Without a custom vault passphrase, the vault is not protected against anyone who has the file.** The secret then is a constant built into the app (and visible in this source code). Anyone who has a copy of `koban.db`, a backup or the WebDAV file can decrypt it. **Set a custom vault passphrase** (in **Backups & Exports**, in both apps) if your file could leave your control.
2. **Passkey / Windows Hello / Touch ID sign-in is a convenience check, not encryption.** It confirms you are present; it does not derive the vault key.
   - Windows: credentials enrolled by builds before this policy was added may contain a copy of the vault passphrase that can be recovered from `koban.db` alone. New credentials no longer store one. To remove an old one, make sure you know your vault passphrase, then delete the credential in Settings and enroll it again.
   - macOS: the passphrase for Touch ID unlock is kept in the Keychain. Current release builds are ad-hoc signed and lack the data-protection keychain entitlement, so **it is always stored in the login keychain**, where Koban itself (not macOS) enforces the Touch ID check. Other software running as you can request the item after macOS asks for permission. Don't enable Touch ID unlock if that matters to you.
3. **For vaults without a custom passphrase, the lock screen only hides the UI.** The ledger is already decrypted in memory when it appears.
4. **The key derivation is weak** (10 000 × SHA-256). A short custom passphrase can be brute-forced offline. Use a long, unique passphrase.
5. **Some metadata is not encrypted:** record types, record ids, counts and modification times (`encrypted_records`), and the sign-in settings (`vault_meta.auth_config`, including the display name and a PBKDF2 hash of the master passphrase).
6. **Older Windows builds also kept a plain (base64) copy of the ledger in the WebView2 browser storage** (the app's WebView2 profile, typically `%LOCALAPPDATA%\com.roland-matuz.koban\EBWebView`). Current builds no longer write it and delete it after the next successful load or save. Deleted data may remain on the disk until the storage is compacted or the disk space is reused.

## Threat model

**Koban aims to protect against** (fully once vault format v2 ships, see below):

- someone who obtains a copy of `koban.db`, a backup or the WebDAV file (stolen or lost device, shared or cloud folder, WebDAV provider),
- someone opening Koban on your computer while it is locked,
- undetected tampering with the encrypted data.

**Out of scope:**

- malware or other software running under your OS account while the vault is unlocked,
- an attacker with administrator/root access, keyloggers or physical tampering with your device,
- recovering data from the memory of a running, unlocked app,
- a WebDAV server serving an older, valid copy of your vault (rollback).

## Roadmap: vault format v2

[`docs/VAULT-V2-SPEC.md`](docs/VAULT-V2-SPEC.md) describes the replacement: a random per-vault key, a required passphrase stretched with Argon2id, a recovery key, Windows Hello / Touch ID / passkeys that actually derive or release the key, a lock screen that decrypts nothing until you unlock, and a migration from v1. Until v2 ships, the limitations above apply.

## Good practices for users

- Set a long, unique custom vault passphrase and store it in a password manager.
- Treat old backups (`koban-latest.db`, `koban-daily-*.db`, `koban-backup-*.db`, `koban-pre-webdav-sync-*.db`, `koban-webdav-conflict-*.db`) like the vault itself: they open with the passphrase that was active when they were made, or with no passphrase at all if none was set.
- Use an app-specific password or token for WebDAV, not your main account password.
