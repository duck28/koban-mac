# Koban WebDAV: Backup vs Primary storage — shared spec (Windows + macOS)

Both builds MUST implement identical semantics and file formats so one vault can be shared by Windows and macOS devices.

## Today
`settings.webdav` (inside the encrypted ledger, so it is synced too): `{enabled, url, username, password?, remoteFileName?, autoSync?, lastSyncAt?, lastSyncStatus?, lastSyncMessage?}`. Manual Test / Push / Pull; when `enabled && autoSync` every local save is followed by a fire-and-forget PUT that overwrites the remote file. Pull replaces the local DB (keeping `koban-pre-webdav-sync-<secs>.db` next to it) and reloads. Remote target = `webdav_target_url(url, remoteFileName)` (default file `koban-vault.db`). Journal mode is DELETE, so the main DB file is complete after each save.

## 1. Config (synced, in the ledger)
Add to `WebDavConfig`: `mode?: 'backup' | 'primary'` (absent ⇒ `'backup'`). Swift: `var mode: WebDavMode?` with raw values `backup` / `primary`. No other new synced fields.

## 2. Per-device sync state (NOT synced)
File next to the active local DB: `<db file name>.webdav-sync.json` (e.g. `koban.db.webdav-sync.json`), UTF-8 JSON:
```json
{ "version": 1, "target": "<full remote file URL>", "etag": "\"abc\"" | null, "lastModified": "<HTTP date>" | null,
  "remoteSize": 12345 | null, "localSha256": "<lowercase hex sha256 of the local DB file bytes>", "syncedAt": 1731150000 }
```
- Written after every successful push or pull (also manual ones, in both modes). `localSha256` = sha256 of exactly the bytes uploaded / downloaded. `etag`/`lastModified`/`remoteSize` = what the server reports for the file after that operation: take ETag/Last-Modified from the PUT/GET response; if the PUT response lacks ETag, do a HEAD afterwards. Store ETag verbatim (including quotes / `W/`).
- A state whose `target` differs from the current target counts as missing.
- Moving / resetting the DB location must move/copy this file with the DB (like the -wal/-shm handling). Restoring a backup or importing a .db over the local DB deletes it (local is then "dirty").

Definitions (S = state, R = HEAD of remote):
- `localDirty` = S missing OR sha256(local DB file) ≠ S.localSha256.
- `remoteChanged` = R exists AND (S missing OR (S.etag && R.etag ? R.etag ≠ S.etag : (R.lastModified ≠ S.lastModified OR R.size ≠ S.remoteSize))).
- ETags are compared weakly: strip a leading `W/` from both before comparing (nginx reports `W/"x"` on some responses and `"x"` on others). `If-Match` is only sent with a strong stored ETag; with a weak one, push does the HEAD comparison instead.

## 3. Operations (backend: Rust commands / Swift core)
- **check** (HEAD target) → `{ status, message, remoteEtag?, remoteLastModified?, remoteSize?, firstLink }` with status:
  - `offline`: transport error, timeout, or HTTP 5xx.
  - `error`: 401/403 (auth message as today) or other 4xx except 404.
  - `remote_missing`: 404.
  - `in_sync`: !remoteChanged && !localDirty
  - `local_ahead`: !remoteChanged && localDirty
  - `remote_ahead`: remoteChanged && !localDirty
  - `conflict`: remoteChanged && localDirty. `firstLink = true` when S is missing (this device never synced with this target).
- **push**(…, `force: bool`): if `!force` and S exists: send `If-Match: S.etag` when S.etag is set; otherwise HEAD first and treat a lastModified/size mismatch as conflict. HTTP 412 (or detected mismatch) ⇒ error whose message starts with `WEBDAV_CONFLICT:`. On success write S. Backup mode always pushes with `force = true` (same behaviour as today). MKCOL of the parent as today.
- **pull**: as today (validate SQLite header, keep `koban-pre-webdav-sync-<secs>.db`, replace local file), then write S.
- **connect / download vault** (new device): pull into the active local DB path even when no local DB exists, then write S.
- Timeouts: 30 s for HEAD, 120 s for GET/PUT.

## 4. Automatic behaviour
Active only when `enabled && url && username && password`.

**Backup mode** (`mode` absent or `backup`): unchanged: after each save, if `autoSync`, push with `force = true`, fire-and-forget; never pulls automatically. Write S on success.

**Primary mode** (`mode === 'primary'`): the remote file is the master copy shared by devices; the local DB is an encrypted offline cache. `autoSync` is implied (UI hides/locks that toggle).
1. **On startup**, right after the ledger is loaded from the local DB (before or behind the lock screen; it must not need user interaction unless there is a conflict), and **when switching a configured vault to primary**, run *sync-now*:
   - `remote_missing` → push(force: true) — toast "Cloud vault initialized on WebDAV."
   - `local_ahead` → push(force: false)
   - `remote_ahead` → flush pending local save first; if that makes local dirty, re-check (→ conflict); else pull, then reload the ledger from the local DB exactly like the manual Pull does (keep this device's WebDAV settings, as the manual pull already does on each platform) — toast "Loaded the latest vault from WebDAV."
   - `conflict` → show the conflict dialog (§5).
   - `offline` → status "Offline — working from the local cache. Changes will sync when the server is reachable." (no dialog)
   - `in_sync` → nothing.
2. **After every successful local save**: debounce 2 s, then push(force: false). `WEBDAV_CONFLICT:` → conflict dialog. Transport error → offline status (retry on next check).
3. **Periodic**: run *sync-now* every 5 minutes and whenever the app/window regains focus. Never run two sync operations concurrently (queue at most one follow-up), and don't auto-sync while the conflict dialog is open or sync is paused.
4. While paused (conflict deferred), no automatic pushes/pulls; the status shows "Sync paused — the cloud vault and this device both changed." with a "Resolve…" action that reopens the dialog.

Status shown in the WebDAV card (and kept in `lastSyncStatus` / `lastSyncMessage` / `lastSyncAt` like today): Synced (time) · Syncing… · Offline — local cache · Sync paused — conflict · Error: …

## 5. Conflict dialog (modal)
Title: "Cloud vault changed on another device". Body: "Both the WebDAV copy and this device have changes since the last sync. Choose which version to keep — the other one is kept as a backup file." Show remote Last-Modified and local last-save time if known.
- **Use cloud version** → pull (local preserved as `koban-pre-webdav-sync-<secs>.db`), reload.
- **Keep this device's version** → before overwriting, GET the remote and save it next to the local DB as `koban-webdav-conflict-<secs>.db`, then push(force: true).
- **Decide later** → pause sync (§4.4).
`firstLink` variant — title "A Koban vault already exists at this WebDAV location", buttons "Use the cloud vault" / "Upload this device's data" / "Cancel" (Cancel switches `mode` back to `backup`).

## 6. UI
WebDAV card (Windows `WebDavSyncCard.tsx`, macOS `WebDavSyncCard`): add **Storage Mode** segmented control:
- **Backup copy** — "Uploads this device's vault to WebDAV after changes. Never downloads automatically."
- **Primary storage** — "The WebDAV file is the master copy shared by all your devices (Windows and Mac). This device keeps an encrypted local cache for offline use and syncs on launch, after every change, and every 5 minutes."
Plus the live status line (§4) with "Sync now" and, when paused, "Resolve…". Keep Test / Push / Pull. Same look as the existing card.

**New device**: on first run (Windows onboarding step 1 next to "Import Existing Data…"; macOS SetupScreen next to "Open Existing koban.db…") add **"Open Vault from WebDAV…"**: form with URL, username, password/app token, remote file name (default `koban-vault.db`), Test button, "Download & Open". It downloads into the active local DB path (preserving an existing local file as `koban-pre-webdav-sync-<secs>.db`), writes S, reloads (a custom-passphrase vault shows the normal passphrase/lock screen), and then ensures `settings.webdav = {…downloaded config, enabled: true, mode: 'primary', url/username/password/remoteFileName as entered}` and saves (which pushes nothing new because… it will be dirty after the save: that's fine, the next push uses If-Match and succeeds).

All new UI text in English (the existing WebDAV card isn't localized either).
