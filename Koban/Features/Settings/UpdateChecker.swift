import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    static let releasesAPIURL = URL(string: "https://api.github.com/repos/duck28/koban-mac/releases/latest")!
    static let releasesPageURL = URL(string: "https://github.com/duck28/koban-mac/releases")!

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.4.0"
    }

    var latestVersion: String?
    var updateAvailable = false
    var releaseURL: URL?
    var downloadURL: URL?
    var isChecking = false
    var lastError: String?
    var hasChecked = false
    var bannerDismissed = false

    @ObservationIgnored private var didStartupCheck = false

    private init() {}

    func checkOnLaunchIfEnabled(autoCheck: Bool) {
        guard !didStartupCheck, autoCheck else { return }
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["KOBAN_SNAPSHOT"] != nil || env["KOBAN_PERF"] != nil { return }
        #endif
        didStartupCheck = true
        Task { await checkNow(notifyStore: nil) }
    }

    func checkNow(notifyStore: LedgerStore? = nil) async {
        guard !isChecking else { return }
        isChecking = true
        lastError = nil
        defer { isChecking = false }

        do {
            var request = URLRequest(url: Self.releasesAPIURL)
            request.timeoutInterval = 10
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Koban-Mac/\(currentVersion)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            if http.statusCode == 404 {
                hasChecked = true
                latestVersion = currentVersion
                updateAvailable = false
                releaseURL = Self.releasesPageURL
                downloadURL = nil
                if let notifyStore {
                    notifyStore.notify(
                        L10n.t("settings.updates.upToDate")
                            .replacingOccurrences(of: "{version}", with: currentVersion)
                    )
                }
                return
            }

            guard (200...299).contains(http.statusCode) else {
                throw NSError(
                    domain: "UpdateChecker",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "GitHub Releases returned HTTP \(http.statusCode)"]
                )
            }

            let decoded = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let cleanedLatest = decoded.tagName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)

            latestVersion = cleanedLatest
            releaseURL = URL(string: decoded.htmlUrl) ?? Self.releasesPageURL
            let dmgAsset = decoded.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            let zipAsset = decoded.assets.first { $0.name.lowercased().hasSuffix(".zip") }
            if let assetURL = (dmgAsset ?? zipAsset)?.browserDownloadUrl {
                downloadURL = URL(string: assetURL)
            } else {
                downloadURL = nil
            }
            updateAvailable = Self.isNewerVersion(current: currentVersion, latest: cleanedLatest)
            hasChecked = true
            if updateAvailable {
                bannerDismissed = false
                if let notifyStore {
                    notifyStore.notify(
                        L10n.t("settings.updates.available")
                            .replacingOccurrences(of: "{latest}", with: cleanedLatest)
                            .replacingOccurrences(of: "{current}", with: currentVersion)
                    )
                }
            } else if let notifyStore {
                notifyStore.notify(
                    L10n.t("settings.updates.upToDate")
                        .replacingOccurrences(of: "{version}", with: currentVersion)
                )
            }
        } catch {
            let msg = error.localizedDescription
            lastError = msg
            hasChecked = true
            if let notifyStore {
                notifyStore.notify(
                    L10n.t("settings.updates.error").replacingOccurrences(of: "{error}", with: msg)
                )
            }
        }
    }

    func openDownloadOrRelease() {
        NSWorkspace.shared.open(downloadURL ?? releaseURL ?? Self.releasesPageURL)
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(releaseURL ?? Self.releasesPageURL)
    }

    nonisolated static func parseSemver(_ version: String) -> (Int, Int, Int)? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]) else { return nil }
        let patchPrefix = parts[2].prefix(while: { $0.isNumber })
        guard !patchPrefix.isEmpty, let patch = Int(patchPrefix) else { return nil }
        return (major, minor, patch)
    }

    nonisolated static func isNewerVersion(current: String, latest: String) -> Bool {
        guard let c = parseSemver(current), let l = parseSemver(latest) else { return false }
        return l > c
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlUrl: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case assets
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tagName = try c.decode(String.self, forKey: .tagName)
            htmlUrl = try c.decodeIfPresent(String.self, forKey: .htmlUrl) ?? UpdateChecker.releasesPageURL.absoluteString
            assets = try c.decodeIfPresent([GitHubAsset].self, forKey: .assets) ?? []
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadUrl: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }
}
