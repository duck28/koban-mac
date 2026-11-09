import CryptoKit
import Foundation

struct WebDavSyncResult: Hashable, Sendable {
    var success: Bool
    var message: String
    var remoteSize: Int?
    var remoteModified: String?
    /// Seconds since epoch (now_secs in lib.rs).
    var timestamp: Double
    /// ETag the server reported for the file after this operation (verbatim, incl. quotes / W/).
    var etag: String? = nil
    /// Full remote file URL.
    var target: String = ""
    /// Lowercase hex sha256 of exactly the bytes uploaded / downloaded.
    var localSha256: String = ""
}

struct WebDavRemoteInfo: Hashable, Sendable {
    var exists: Bool
    var size: Int?
    var lastModified: String?
    var etag: String? = nil
}

struct WebDavError: Error, LocalizedError, Equatable {
    enum Kind: Equatable, Sendable {
        case general
        /// Transport error, timeout or HTTP 5xx (WEBDAV-SPEC §3 `offline`).
        case offline
        /// HTTP 412 / detected remote change on a non-forced push (message starts with WEBDAV_CONFLICT:).
        case conflict
    }

    var message: String
    var kind: Kind
    init(_ message: String, kind: Kind = .general) { self.message = message; self.kind = kind }
    var errorDescription: String? { message }

    static let conflictPrefix = "WEBDAV_CONFLICT:"
    var isConflict: Bool { kind == .conflict || message.hasPrefix(Self.conflictPrefix) }
    var isOffline: Bool { kind == .offline }
}

/// Per-device sync state `<db file name>.webdav-sync.json` (WEBDAV-SPEC §2). Never synced.
struct WebDavSyncState: Codable, Hashable, Sendable {
    var version: Int = 1
    var target: String
    var etag: String?
    var lastModified: String?
    var remoteSize: Int?
    var localSha256: String
    var syncedAt: Int

    enum CodingKeys: String, CodingKey { case version, target, etag, lastModified, remoteSize, localSha256, syncedAt }

    init(target: String, etag: String?, lastModified: String?, remoteSize: Int?, localSha256: String, syncedAt: Int) {
        self.target = target
        self.etag = etag
        self.lastModified = lastModified
        self.remoteSize = remoteSize
        self.localSha256 = localSha256
        self.syncedAt = syncedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        target = try c.decode(String.self, forKey: .target)
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified)
        remoteSize = try c.decodeIfPresent(Int.self, forKey: .remoteSize)
        localSha256 = try c.decode(String.self, forKey: .localSha256)
        syncedAt = (try? c.decode(Int.self, forKey: .syncedAt)) ?? Int((try? c.decode(Double.self, forKey: .syncedAt)) ?? 0)
    }

    /// Writes explicit nulls (the spec's `"etag": … | null`).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(target, forKey: .target)
        try c.encode(etag, forKey: .etag)
        try c.encode(lastModified, forKey: .lastModified)
        try c.encode(remoteSize, forKey: .remoteSize)
        try c.encode(localSha256, forKey: .localSha256)
        try c.encode(syncedAt, forKey: .syncedAt)
    }
}

/// Result of `check` (WEBDAV-SPEC §3).
struct WebDavCheckResult: Hashable, Sendable {
    enum Status: String, Sendable {
        case offline, error
        case remoteMissing = "remote_missing"
        case inSync = "in_sync"
        case localAhead = "local_ahead"
        case remoteAhead = "remote_ahead"
        case conflict
    }

    var status: Status
    var message: String
    var remoteEtag: String?
    var remoteLastModified: String?
    var remoteSize: Int?
    var firstLink: Bool = false
}

/// Port of the WebDAV commands in src-tauri/src/lib.rs (ureq → URLSession):
/// test_webdav_connection (PROPFIND Depth 0, GET fallback on 405), get_webdav_remote_info (HEAD),
/// push_to_webdav (MKCOL parent + PUT), pull_from_webdav (GET + SQLite header check + local safety copy),
/// plus the backup / primary sync engine of WEBDAV-SPEC.md (check, conditional push, sync state file).
enum WebDav {
    static let defaultRemoteFileName = "koban-vault.db"
    static let headTimeout: TimeInterval = 30
    static let transferTimeout: TimeInterval = 120

    /// webdav_auth_header
    static func authHeader(username: String, password: String) -> String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    /// webdav_target_url: base folder URL + remote file name, unless the URL already names a .db/.sqlite file.
    static func targetURL(base: String, filename: String?) -> String {
        var url = base.trimmingCharacters(in: .whitespacesAndNewlines)
        var fname = (filename ?? defaultRemoteFileName).trimmingCharacters(in: .whitespacesAndNewlines)
        if fname.isEmpty { fname = defaultRemoteFileName }
        if !url.hasSuffix("/") {
            if url.hasSuffix(".db") || url.hasSuffix(".sqlite") { return url }
            url += "/"
        }
        return url + fname
    }

    static func targetURL(_ c: WebDavConfig) -> String { targetURL(base: c.url, filename: c.remoteFileName) }

    /// Parent collection of the target (`&target[..=rfind('/')]`).
    static func parentCollectionURL(of target: String) -> String? {
        guard let idx = target.lastIndex(of: "/") else { return nil }
        return String(target[...idx])
    }

    static func request(_ method: String, _ urlString: String, username: String, password: String,
                        headers: [String: String] = [:], body: Data? = nil,
                        timeout: TimeInterval = 60) throws -> URLRequest {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            throw WebDavError("Network / TLS connection error: invalid URL \"\(urlString)\"")
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue(authHeader(username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                                password: password.trimmingCharacters(in: .whitespacesAndNewlines)),
                     forHTTPHeaderField: "Authorization")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        return req
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForResource = transferTimeout + 30
        return URLSession(configuration: cfg)
    }()

    private static func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw WebDavError("Network / TLS connection error: no HTTP response") }
            return (data, http)
        } catch let e as WebDavError {
            throw e
        } catch {
            throw TransportError(underlying: error.localizedDescription)
        }
    }

    private struct TransportError: Error { var underlying: String }

    private static func header(_ resp: HTTPURLResponse, _ name: String) -> String? {
        resp.value(forHTTPHeaderField: name)
    }

    static func nowSecs() -> Double { Double(Int(Date().timeIntervalSince1970)) }

    static let authFailedMessage = "Authentication failed. Please verify your WebDAV username and password / app token."

    /// test_webdav_connection
    static func testConnection(url: String, username: String, password: String) async throws -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw WebDavError("WebDAV URL cannot be empty.") }
        do {
            let (_, resp) = try await send(try request("PROPFIND", trimmed, username: username, password: password,
                                                       headers: ["Depth": "0"], timeout: headTimeout))
            let status = resp.statusCode
            if status < 400 {
                if (200...299).contains(status) || status == 207 {
                    return "WebDAV connection verified successfully (HTTP 207/200)."
                }
                return "WebDAV server responded with status: \(status)"
            }
            if status == 401 || status == 403 {
                throw WebDavError(authFailedMessage)
            } else if status == 405 {
                do {
                    let (_, getResp) = try await send(try request("GET", trimmed, username: username, password: password,
                                                                  timeout: headTimeout))
                    if getResp.statusCode < 400 { return "WebDAV connection verified successfully (HTTP GET)." }
                    throw WebDavError("WebDAV server responded with HTTP \(status): status code \(getResp.statusCode)")
                } catch let t as TransportError {
                    throw WebDavError("WebDAV server responded with HTTP \(status): \(t.underlying)")
                }
            } else if status == 404 {
                throw WebDavError("WebDAV folder was not found (HTTP 404). Check the remote URL.")
            }
            throw WebDavError("WebDAV server returned HTTP error: \(status)")
        } catch let t as TransportError {
            throw WebDavError("Network / TLS connection error: \(t.underlying)", kind: .offline)
        }
    }

    /// HEAD of the target. 404 ⇒ exists: false. Transport errors / 5xx ⇒ `.offline`, 401/403 ⇒ auth message.
    static func head(target: String, username: String, password: String) async throws -> WebDavRemoteInfo {
        do {
            let (_, resp) = try await send(try request("HEAD", target, username: username, password: password,
                                                       timeout: headTimeout))
            let code = resp.statusCode
            if code == 404 { return WebDavRemoteInfo(exists: false) }
            if code >= 500 { throw WebDavError("WebDAV server error (HTTP \(code)).", kind: .offline) }
            if code == 401 || code == 403 { throw WebDavError(authFailedMessage) }
            if code >= 400 { throw WebDavError("Failed to query remote WebDAV file (HTTP \(code)).") }
            return WebDavRemoteInfo(exists: true, size: header(resp, "Content-Length").flatMap { Int($0) },
                                    lastModified: header(resp, "Last-Modified"), etag: header(resp, "ETag"))
        } catch let t as TransportError {
            throw WebDavError("WebDAV connection error: \(t.underlying)", kind: .offline)
        }
    }

    /// get_webdav_remote_info
    static func remoteInfo(url: String, username: String, password: String, filename: String?) async throws -> WebDavRemoteInfo {
        try await head(target: targetURL(base: url, filename: filename), username: username, password: password)
    }

    // MARK: - Sync state (WEBDAV-SPEC §2)

    static let syncStateSuffix = ".webdav-sync.json"

    static func syncStateURL(for localDatabase: URL) -> URL {
        URL(fileURLWithPath: localDatabase.path + syncStateSuffix)
    }

    /// The stored state, or nil when missing / unreadable / for a different target.
    static func loadSyncState(for localDatabase: URL, target: String) -> WebDavSyncState? {
        guard let data = try? Data(contentsOf: syncStateURL(for: localDatabase)),
              let s = try? JSONDecoder().decode(WebDavSyncState.self, from: data),
              s.target == target else { return nil }
        return s
    }

    static func writeSyncState(_ s: WebDavSyncState, for localDatabase: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? enc.encode(s) else { return }
        try? data.write(to: syncStateURL(for: localDatabase), options: .atomic)
    }

    static func deleteSyncState(for localDatabase: URL) {
        try? FileManager.default.removeItem(at: syncStateURL(for: localDatabase))
    }

    static func recordSync(_ r: WebDavSyncResult, for localDatabase: URL) {
        writeSyncState(WebDavSyncState(target: r.target, etag: r.etag, lastModified: r.remoteModified,
                                       remoteSize: r.remoteSize, localSha256: r.localSha256,
                                       syncedAt: Int(r.timestamp)), for: localDatabase)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// sha256 of the local DB file; nil when it can't be read.
    static func sha256Hex(fileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return sha256Hex(data)
    }

    /// localDirty = S missing OR sha256(local DB file) ≠ S.localSha256.
    static func isLocalDirty(_ localDatabase: URL, state: WebDavSyncState?) -> Bool {
        guard let state else { return true }
        return sha256Hex(fileAt: localDatabase) != state.localSha256
    }

    /// Weak ETag comparison (RFC 9110 §8.8.3.2): `W/"x"` and `"x"` name the same version. Servers
    /// such as nginx mark a tag weak on some responses only (e.g. compressed ones), so a plain string
    /// compare reported a remote change — and a conflict after every local save.
    static func sameEtag(_ a: String, _ b: String) -> Bool {
        func opaque(_ t: String) -> Substring {
            let t = t.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("W/") ? t.dropFirst(2) : Substring(t)
        }
        return opaque(a) == opaque(b)
    }

    /// remoteChanged = R exists AND (S missing OR (both etags ? etag differs : lastModified or size differs)).
    static func isRemoteChanged(_ r: WebDavRemoteInfo, state: WebDavSyncState?) -> Bool {
        guard r.exists else { return false }
        guard let s = state else { return true }
        if let se = s.etag, let re = r.etag { return !sameEtag(re, se) }
        return r.lastModified != s.lastModified || r.size != s.remoteSize
    }

    // MARK: - check (WEBDAV-SPEC §3)

    static func check(localDatabase: URL, config c: WebDavConfig) async -> WebDavCheckResult {
        let target = targetURL(c)
        let remote: WebDavRemoteInfo
        do {
            remote = try await head(target: target, username: c.username, password: c.password ?? "")
        } catch let e as WebDavError {
            return WebDavCheckResult(status: e.isOffline ? .offline : .error, message: e.message)
        } catch {
            return WebDavCheckResult(status: .offline, message: error.localizedDescription)
        }
        guard remote.exists else {
            return WebDavCheckResult(status: .remoteMissing, message: "No vault exists at the WebDAV location yet.")
        }
        let state = loadSyncState(for: localDatabase, target: target)
        let dirty = isLocalDirty(localDatabase, state: state)
        let changed = isRemoteChanged(remote, state: state)
        var r = WebDavCheckResult(status: .inSync, message: "", remoteEtag: remote.etag,
                                  remoteLastModified: remote.lastModified, remoteSize: remote.size,
                                  firstLink: state == nil)
        switch (changed, dirty) {
        case (false, false): r.status = .inSync; r.message = "Local vault and WebDAV copy are in sync."
        case (false, true): r.status = .localAhead; r.message = "This device has changes that are not uploaded yet."
        case (true, false): r.status = .remoteAhead; r.message = "The WebDAV copy has newer changes."
        case (true, true): r.status = .conflict; r.message = "Both the WebDAV copy and this device changed since the last sync."
        }
        return r
    }

    // MARK: - push

    /// push_to_webdav: uploads the local (encrypted) database file and records the sync state.
    /// `force == false` with a stored state makes the upload conditional (If-Match, or a HEAD comparison
    /// when no strong ETag is known); a remote change then throws `WEBDAV_CONFLICT:`.
    static func push(localDatabase: URL, url: String, username: String, password: String, filename: String?,
                     force: Bool = true) async throws -> WebDavSyncResult {
        guard FileManager.default.fileExists(atPath: localDatabase.path) else {
            throw WebDavError("Local SQLite database does not exist to upload.")
        }
        let data: Data
        do { data = try Data(contentsOf: localDatabase) } catch {
            throw WebDavError("Failed to read local database: \(error.localizedDescription)")
        }
        let target = targetURL(base: url, filename: filename)
        let conflictError = WebDavError(
            "\(WebDavError.conflictPrefix) The WebDAV copy was changed on another device since this device last synced.",
            kind: .conflict)

        var headers = ["Content-Type": "application/x-sqlite3"]
        if !force, let s = loadSyncState(for: localDatabase, target: target) {
            if let etag = s.etag, !etag.hasPrefix("W/") {
                headers["If-Match"] = etag
            } else {
                // No strong ETag to match on: compare what the server reports now with the stored state.
                let r = try await head(target: target, username: username, password: password)
                if r.exists && isRemoteChanged(r, state: s) { throw conflictError }
            }
        }

        if let parent = parentCollectionURL(of: target),
           let mkcol = try? request("MKCOL", parent, username: username, password: password, timeout: headTimeout) {
            _ = try? await send(mkcol) // ignored, like the Rust build (the folder usually exists)
        }

        do {
            var (_, resp) = try await send(try request("PUT", target, username: username, password: password,
                                                       headers: headers, body: data, timeout: transferTimeout))
            if resp.statusCode == 412, headers["If-Match"] != nil {
                // A deleted remote file also fails If-Match: that's not a conflict, just upload it again.
                let r = try await head(target: target, username: username, password: password)
                guard !r.exists else { throw conflictError }
                headers["If-Match"] = nil
                (_, resp) = try await send(try request("PUT", target, username: username, password: password,
                                                       headers: headers, body: data, timeout: transferTimeout))
            }
            if resp.statusCode == 412 { throw conflictError }
            if resp.statusCode >= 500 {
                throw WebDavError("WebDAV upload failed with HTTP status: \(resp.statusCode)", kind: .offline)
            }
            guard resp.statusCode < 400 else {
                if resp.statusCode == 401 || resp.statusCode == 403 { throw WebDavError(authFailedMessage) }
                throw WebDavError("WebDAV upload failed with HTTP status: \(resp.statusCode)")
            }
            var etag = header(resp, "ETag")
            var lastModified = header(resp, "Last-Modified")
            var size: Int? = data.count
            if etag == nil || lastModified == nil,
               let r = try? await head(target: target, username: username, password: password), r.exists {
                etag = r.etag ?? etag
                lastModified = r.lastModified ?? lastModified
                size = r.size ?? size
            }
            let result = WebDavSyncResult(success: true,
                                          message: "Encrypted database (\(data.count / 1024) KB) uploaded to WebDAV successfully.",
                                          remoteSize: size, remoteModified: lastModified, timestamp: nowSecs(),
                                          etag: etag, target: target, localSha256: sha256Hex(data))
            recordSync(result, for: localDatabase)
            return result
        } catch let t as TransportError {
            throw WebDavError("Network transport error during WebDAV upload: \(t.underlying)", kind: .offline)
        }
    }

    static let sqliteHeader = Data("SQLite format 3\0".utf8)

    /// pull_from_webdav: downloads the remote database, keeps a `koban-pre-webdav-sync-<secs>.db`
    /// copy of the local file next to it, then replaces the local file and records the sync state.
    static func pull(localDatabase: URL, url: String, username: String, password: String, filename: String?) async throws -> WebDavSyncResult {
        let (data, result) = try await download(url: url, username: username, password: password, filename: filename)
        try installDownloadedDatabase(data, at: localDatabase, result: result)
        return result
    }

    /// The network half of pull_from_webdav (the app closes its open vault before installing the file).
    static func download(url: String, username: String, password: String, filename: String?) async throws -> (Data, WebDavSyncResult) {
        let target = targetURL(base: url, filename: filename)
        let data: Data
        let resp: HTTPURLResponse
        do {
            (data, resp) = try await send(try request("GET", target, username: username, password: password,
                                                      timeout: transferTimeout))
        } catch let t as TransportError {
            throw WebDavError("Network transport error during WebDAV download: \(t.underlying)", kind: .offline)
        }
        if resp.statusCode == 404 {
            throw WebDavError("No database found on WebDAV server at this path (HTTP 404). Push your local database first to initialize cloud sync.")
        }
        if resp.statusCode >= 500 {
            throw WebDavError("WebDAV download failed with HTTP status: \(resp.statusCode)", kind: .offline)
        }
        if resp.statusCode == 401 || resp.statusCode == 403 { throw WebDavError(authFailedMessage) }
        guard resp.statusCode < 400 else { throw WebDavError("WebDAV download failed with HTTP status: \(resp.statusCode)") }
        guard data.count >= 16, data.prefix(16) == sqliteHeader else {
            throw WebDavError("Downloaded remote file is not a valid SQLite database.")
        }
        return (data, WebDavSyncResult(success: true,
                                       message: "Encrypted database (\(data.count / 1024) KB) downloaded and synchronized successfully.",
                                       remoteSize: data.count, remoteModified: header(resp, "Last-Modified"),
                                       timestamp: nowSecs(), etag: header(resp, "ETag"), target: target,
                                       localSha256: sha256Hex(data)))
    }

    /// Validates the SQLite header, writes a safety copy of the current file, replaces it, and (with a
    /// download result) records the sync state next to it. Works when no local file exists yet.
    static func installDownloadedDatabase(_ data: Data, at localDatabase: URL, result: WebDavSyncResult? = nil) throws {
        guard data.count >= 16, data.prefix(16) == sqliteHeader else {
            throw WebDavError("Downloaded remote file is not a valid SQLite database.")
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: localDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: localDatabase.path) {
            let backup = localDatabase.deletingLastPathComponent()
                .appendingPathComponent("koban-pre-webdav-sync-\(Int(nowSecs())).db")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: localDatabase, to: backup)
        }
        do { try data.write(to: localDatabase, options: .atomic) } catch {
            throw WebDavError("Failed to save downloaded database: \(error.localizedDescription)")
        }
        // Stale rollback journals would be replayed into the new file.
        for suffix in ["-journal", "-wal", "-shm"] { try? fm.removeItem(atPath: localDatabase.path + suffix) }
        if let result { recordSync(result, for: localDatabase) }
    }

    /// "Keep this device's version": saves the current remote file next to the local DB as
    /// `koban-webdav-conflict-<secs>.db` before it is overwritten. Returns the saved file (nil when the
    /// remote file no longer exists).
    @discardableResult
    static func saveRemoteConflictCopy(next localDatabase: URL, url: String, username: String, password: String,
                                       filename: String?) async throws -> URL? {
        let data: Data
        do {
            (data, _) = try await download(url: url, username: username, password: password, filename: filename)
        } catch let e as WebDavError where e.message.contains("HTTP 404") {
            return nil
        }
        let out = localDatabase.deletingLastPathComponent()
            .appendingPathComponent("koban-webdav-conflict-\(Int(nowSecs())).db")
        do { try data.write(to: out, options: .atomic) } catch {
            throw WebDavError("Failed to save the WebDAV copy as a backup: \(error.localizedDescription)")
        }
        return out
    }
}
