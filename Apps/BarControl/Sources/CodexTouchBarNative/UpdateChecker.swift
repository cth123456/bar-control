import AppKit
import Foundation

/// 版本号：接受 `0.40.0`、`v0.40.0`、`0.40.0-beta.2`。
/// 预发布版排在同号正式版之前，避免 beta 被当成更新推给正式版用户。
struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    let numbers: [Int]
    let prerelease: String?

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        let pieces = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = pieces[0].split(separator: ".")
        guard !core.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in core {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        self.numbers = numbers
        self.prerelease = pieces.count > 1 && !pieces[1].isEmpty ? String(pieces[1]) : nil
    }

    var description: String {
        let core = numbers.map(String.init).joined(separator: ".")
        return prerelease.map { "\(core)-\($0)" } ?? core
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        // 0.40 与 0.40.0 视为同一版本：缺省位按 0 补齐。
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return false }
        }
        return lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, _):
            return false
        case (_, nil):
            return true
        case let (left?, right?):
            return Self.prereleaseIsOlder(left, right)
        }
    }

    private static func prereleaseIsOlder(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map(String.init)
        let right = rhs.split(separator: ".").map(String.init)
        for index in 0..<max(left.count, right.count) {
            if index >= left.count { return true }
            if index >= right.count { return false }
            let l = left[index], r = right[index]
            if l == r { continue }
            if let ln = Int(l), let rn = Int(r) { return ln < rn }
            if Int(l) != nil { return true }
            if Int(r) != nil { return false }
            return l < r
        }
        return false
    }
}

struct SoftwareRelease: Equatable {
    let version: AppVersion
    let name: String
    let notes: String
    let pageURL: URL
    let publishedAt: Date?
    /// 一键更新用的安装包（zip）；没有时退化为打开下载页。
    var assetURL: URL? = nil
    var assetSHA256: String? = nil

    var versionText: String { version.description }
    var canInstallInApp: Bool { assetURL != nil }
}

enum UpdateCheckOutcome: Equatable {
    case upToDate(latest: String?)
    case available(SoftwareRelease)
    case noPublishedRelease
    case failed(String)
}

struct UpdateCheckResult: Equatable {
    let outcome: UpdateCheckOutcome
    let checkedAt: Date
}

/// 纯策略：不碰网络和偏好，方便直接测“什么时候该查、什么时候该弹”。
enum UpdatePolicy {
    static let autoCheckInterval: TimeInterval = 24 * 60 * 60
    static let promptCooldown: TimeInterval = 24 * 60 * 60

    static func shouldAutoCheck(
        enabled: Bool,
        lastCheckAt: Date?,
        now: Date,
        interval: TimeInterval = autoCheckInterval
    ) -> Bool {
        guard enabled else { return false }
        guard let lastCheckAt else { return true }
        return now.timeIntervalSince(lastCheckAt) >= interval
    }

    /// 新版本只在“没被跳过”且“同一版本 24 小时内没弹过”时提示。
    static func shouldPrompt(
        outcome: UpdateCheckOutcome,
        skippedVersion: String?,
        lastPromptedVersion: String?,
        lastPromptedAt: Date?,
        now: Date,
        cooldown: TimeInterval = promptCooldown
    ) -> Bool {
        guard case let .available(release) = outcome else { return false }
        let version = release.versionText
        if skippedVersion == version { return false }
        if lastPromptedVersion == version,
           let lastPromptedAt,
           now.timeIntervalSince(lastPromptedAt) < cooldown {
            return false
        }
        return true
    }
}

/// 检查更新：优先读仓库里的静态清单（不限流、可写更新说明），
/// 清单不存在时回退到 GitHub Releases / Tags。
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    static let repository = "cth123456/bar-control"
    static let repositoryPage = URL(string: "https://github.com/\(repository)")!
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    static let issuesPage = URL(string: "https://github.com/\(repository)/issues")!
    static let manifestURL = URL(string: "https://raw.githubusercontent.com/\(repository)/main/docs/updates.json")!
    static let releasesAPI = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=10")!
    static let tagsAPI = URL(string: "https://api.github.com/repos/\(repository)/tags?per_page=30")!
    /// Atom 订阅是公开网页，不需要 token，也没有 API 的每小时限流。
    static let releasesAtom = URL(string: "https://github.com/\(repository)/releases.atom")!
    static let tagsAtom = URL(string: "https://github.com/\(repository)/tags.atom")!

    enum DefaultsKey {
        static let autoCheck = "updateAutoCheckEnabled.v1"
        static let lastCheck = "updateLastCheckAt.v1"
        static let skipped = "updateSkippedVersion.v1"
        static let promptedVersion = "updateLastPromptedVersion.v1"
        static let promptedAt = "updateLastPromptedAt.v1"
    }

    private let defaults: UserDefaults
    private let session: URLSession
    private let versionOverride: String?
    private var cachedResult: UpdateCheckResult?
    private var lastAttemptAt: Date?
    private var isFetching = false

    init(defaults: UserDefaults = .standard, session: URLSession = .shared,
         currentVersion: String? = nil) {
        self.defaults = defaults
        self.session = session
        self.versionOverride = currentVersion
    }

    // MARK: - 当前版本

    var currentVersionText: String {
        versionOverride
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    var currentBuildText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    var currentVersion: AppVersion {
        AppVersion(currentVersionText) ?? AppVersion("0.0.0")!
    }

    // MARK: - 偏好

    var autoCheckEnabled: Bool {
        get { defaults.object(forKey: DefaultsKey.autoCheck) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DefaultsKey.autoCheck) }
    }

    var lastCheckAt: Date? {
        let stamp = defaults.double(forKey: DefaultsKey.lastCheck)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    var skippedVersion: String? {
        defaults.string(forKey: DefaultsKey.skipped)
    }

    var lastPromptedVersion: String? {
        defaults.string(forKey: DefaultsKey.promptedVersion)
    }

    var lastPromptedAt: Date? {
        let stamp = defaults.double(forKey: DefaultsKey.promptedAt)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    func markPrompted(_ release: SoftwareRelease, at date: Date = Date()) {
        defaults.set(release.versionText, forKey: DefaultsKey.promptedVersion)
        defaults.set(date.timeIntervalSince1970, forKey: DefaultsKey.promptedAt)
    }

    func skip(_ release: SoftwareRelease) {
        defaults.set(release.versionText, forKey: DefaultsKey.skipped)
    }

    func clearSkippedVersion() {
        defaults.removeObject(forKey: DefaultsKey.skipped)
    }

    func shouldPrompt(_ result: UpdateCheckResult, now: Date = Date()) -> Bool {
        UpdatePolicy.shouldPrompt(
            outcome: result.outcome,
            skippedVersion: skippedVersion,
            lastPromptedVersion: lastPromptedVersion,
            lastPromptedAt: lastPromptedAt,
            now: now
        )
    }

    // MARK: - 检查

    func check(force: Bool) async -> UpdateCheckResult {
        if isFetching, let cachedResult { return cachedResult }
        if !force, let lastAttemptAt,
           Date().timeIntervalSince(lastAttemptAt) < 120,
           let cachedResult {
            return cachedResult
        }
        isFetching = true
        lastAttemptAt = Date()
        defer { isFetching = false }

        var releases: [SoftwareRelease] = []
        var failure: String?

        do {
            let (data, status) = try await fetch(Self.manifestURL)
            if status == 200 {
                releases = (try? Self.decodeManifest(data)) ?? []
            }
        } catch {
            failure = "网络不可用"
        }

        if releases.isEmpty, failure == nil {
            do {
                let (data, status) = try await fetch(Self.releasesAtom)
                if status == 200 {
                    releases = (try? Self.decodeAtomFeed(data)) ?? []
                } else if status != 404 {
                    failure = Self.message(for: status)
                }
            } catch {
                failure = "网络不可用"
            }
        }

        // 页面订阅也拿不到时才用 API（未登录每小时 60 次，容易限流）。
        if releases.isEmpty, failure == nil {
            do {
                let (data, status) = try await fetch(Self.releasesAPI)
                if status == 200 {
                    releases = (try? Self.decodeGitHubReleases(data, allowPrerelease: currentVersion.prerelease != nil)) ?? []
                } else if status != 404 {
                    failure = Self.message(for: status)
                }
            } catch {
                failure = "网络不可用"
            }
        }

        if releases.isEmpty, failure == nil {
            do {
                let (data, status) = try await fetch(Self.tagsAtom)
                if status == 200 {
                    releases = (try? Self.decodeAtomFeed(data)) ?? []
                } else if status != 404 {
                    failure = Self.message(for: status)
                }
            } catch {
                failure = "网络不可用"
            }
        }

        if releases.isEmpty, failure == nil {
            do {
                let (data, status) = try await fetch(Self.tagsAPI)
                if status == 200 {
                    releases = (try? Self.decodeGitHubTags(data)) ?? []
                } else if status != 404 {
                    failure = Self.message(for: status)
                }
            } catch {
                failure = "网络不可用"
            }
        }

        let outcome: UpdateCheckOutcome
        if let newest = releases.max(by: { $0.version < $1.version }) {
            if newest.version > currentVersion {
                outcome = .available(newest)
            } else {
                outcome = .upToDate(latest: newest.versionText)
            }
            defaults.set(Date().timeIntervalSince1970, forKey: DefaultsKey.lastCheck)
        } else if let failure {
            outcome = .failed(failure)
        } else {
            outcome = .noPublishedRelease
            defaults.set(Date().timeIntervalSince1970, forKey: DefaultsKey.lastCheck)
        }

        let result = UpdateCheckResult(outcome: outcome, checkedAt: Date())
        cachedResult = result
        AppLog.write("update check outcome=\(Self.describe(outcome)) current=\(currentVersionText)")
        return result
    }

    static func describe(_ outcome: UpdateCheckOutcome) -> String {
        switch outcome {
        case let .upToDate(latest): return "up-to-date latest=\(latest ?? "unknown")"
        case let .available(release): return "available \(release.versionText)"
        case .noPublishedRelease: return "no-published-release"
        case let .failed(message): return "failed \(message)"
        }
    }

    private func fetch(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func message(for status: Int) -> String {
        switch status {
        case 403, 429:
            return "GitHub 接口限流（本机 IP 每小时 60 次），稍后重试"
        case 500...599:
            return "更新服务暂时不可用"
        default:
            return "更新服务返回 \(status)"
        }
    }

    // MARK: - 解析（用固定 JSON 测试，不依赖网络）

    private struct Manifest: Decodable {
        let releases: [ManifestRelease]
    }

    private struct ManifestRelease: Decodable {
        let version: String
        let name: String?
        let notes: String?
        let url: String?
        let published_at: String?
        let asset_url: String?
        let sha256: String?
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int64?
        let digest: String?
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
        let published_at: String?
        let assets: [GitHubAsset]?
    }

    private struct GitHubTag: Decodable {
        let name: String
    }

    static func decodeManifest(_ data: Data) throws -> [SoftwareRelease] {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        return manifest.releases.compactMap { item -> SoftwareRelease? in
            guard let version = AppVersion(item.version) else { return nil }
            let url = item.url.flatMap(URL.init(string:)) ?? releasesPage
            return SoftwareRelease(
                version: version,
                name: item.name?.isEmpty == false ? item.name! : "Bar Control \(version.description)",
                notes: item.notes ?? "",
                pageURL: url,
                publishedAt: parseDate(item.published_at),
                assetURL: item.asset_url.flatMap(URL.init(string:)),
                assetSHA256: item.sha256?.lowercased()
            )
        }
    }

    static func decodeGitHubReleases(_ data: Data, allowPrerelease: Bool) throws -> [SoftwareRelease] {
        let items = try JSONDecoder().decode([GitHubRelease].self, from: data)
        return items.compactMap { item -> SoftwareRelease? in
            if item.draft == true { return nil }
            if item.prerelease == true && !allowPrerelease { return nil }
            guard let version = AppVersion(item.tag_name) else { return nil }
            let url = URL(string: item.html_url) ?? releasesPage
            let asset = item.assets?.first { $0.name.lowercased().hasSuffix(".zip") }
            let digest = asset?.digest?
                .replacingOccurrences(of: "sha256:", with: "")
                .lowercased()
            return SoftwareRelease(
                version: version,
                name: item.name?.isEmpty == false ? item.name! : "Bar Control \(version.description)",
                notes: item.body ?? "",
                pageURL: url,
                publishedAt: parseDate(item.published_at),
                assetURL: asset.flatMap { URL(string: $0.browser_download_url) },
                assetSHA256: digest
            )
        }
    }

    /// 解析 GitHub 的 releases.atom / tags.atom（公开页面，不受 API 限流）。
    static func decodeAtomFeed(_ data: Data) throws -> [SoftwareRelease] {
        let parser = AtomFeedParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { return [] }
        return parser.entries.compactMap { entry -> SoftwareRelease? in
            guard let url = URL(string: entry.link),
                  let versionPart = entry.link.split(separator: "/").last,
                  let version = AppVersion(String(versionPart)) else { return nil }
            return SoftwareRelease(
                version: version,
                name: entry.title.isEmpty ? "Bar Control \(version.description)" : entry.title,
                notes: "",
                pageURL: url,
                publishedAt: parseDate(entry.updated)
            )
        }
    }

    static func decodeGitHubTags(_ data: Data) throws -> [SoftwareRelease] {
        let items = try JSONDecoder().decode([GitHubTag].self, from: data)
        return items.compactMap { item in
            guard !item.name.contains("/"), let version = AppVersion(item.name) else { return nil }
            return SoftwareRelease(
                version: version,
                name: "Bar Control \(version.description)",
                notes: "",
                pageURL: releasesPage,
                publishedAt: nil
            )
        }
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

/// GitHub releases.atom / tags.atom 的最小解析器（只取标题、链接、时间）。
final class AtomFeedParser: NSObject, XMLParserDelegate {
    struct Entry {
        var title = ""
        var link = ""
        var updated = ""
    }

    private(set) var entries: [Entry] = []
    private var current: Entry?
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        buffer = ""
        if elementName == "entry" {
            current = Entry()
        }
        if elementName == "link",
           attributeDict["rel"] == "alternate" || attributeDict["rel"] == nil,
           let href = attributeDict["href"],
           current != nil {
            current?.link = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        defer { buffer = "" }
        guard current != nil else { return }
        switch elementName {
        case "title":
            current?.title = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        case "updated":
            if current?.updated.isEmpty == true {
                current?.updated = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case "entry":
            if let entry = current, !entry.link.isEmpty {
                entries.append(entry)
            }
            current = nil
        default:
            break
        }
    }
}
