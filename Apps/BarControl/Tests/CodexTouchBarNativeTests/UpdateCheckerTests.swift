import XCTest
@testable import CodexTouchBarNative

@MainActor
final class UpdateCheckerTests: XCTestCase {

    // MARK: - 版本号

    func testVersionParsingAcceptsCommonForms() {
        XCTAssertEqual(AppVersion("0.40.0")?.description, "0.40.0")
        XCTAssertEqual(AppVersion("v0.40.0")?.description, "0.40.0")
        XCTAssertEqual(AppVersion("0.40")?.description, "0.40")
        XCTAssertEqual(AppVersion("0.40.0+97")?.description, "0.40.0")
        XCTAssertEqual(AppVersion("0.40.0-beta.2")?.description, "0.40.0-beta.2")
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("dev"))
        XCTAssertNil(AppVersion("0.40.x"))
    }

    func testVersionOrderingUsesNumbersNotStrings() {
        XCTAssertLessThan(AppVersion("0.39.9")!, AppVersion("0.39.10")!)
        XCTAssertLessThan(AppVersion("0.9.0")!, AppVersion("0.10.0")!)
        XCTAssertLessThan(AppVersion("0.40")!, AppVersion("0.40.1")!)
        XCTAssertEqual(AppVersion("0.40.0")!, AppVersion("0.40")!)
        XCTAssertGreaterThan(AppVersion("1.0.0")!, AppVersion("0.99.9")!)
    }

    func testPrereleaseSortsBeforeStable() {
        XCTAssertLessThan(AppVersion("0.41.0-beta.1")!, AppVersion("0.41.0")!)
        XCTAssertLessThan(AppVersion("0.41.0-beta.9")!, AppVersion("0.41.0-beta.10")!)
        XCTAssertGreaterThan(AppVersion("0.41.0-beta.1")!, AppVersion("0.40.0")!)
    }

    // MARK: - 解析

    func testManifestURLPointsAtBarControlSubdirectory() {
        XCTAssertEqual(UpdateChecker.manifestURL.path, "/cth123456/bar-control/main/Apps/BarControl/docs/updates.json")
    }

    func testManifestDecoding() throws {
        let json = """
        {"releases":[
          {"version":"0.41.0","name":"更新检查","notes":"第一行\\n第二行",
           "url":"https://example.com/releases/v0.41.0",
           "published_at":"2026-11-10T12:00:00Z"},
          {"version":"bad","name":"忽略我"}
        ]}
        """
        let releases = try UpdateChecker.decodeManifest(Data(json.utf8))
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases[0].versionText, "0.41.0")
        XCTAssertEqual(releases[0].name, "更新检查")
        XCTAssertEqual(releases[0].notes, "第一行\n第二行")
        XCTAssertEqual(releases[0].pageURL.absoluteString, "https://example.com/releases/v0.41.0")
        XCTAssertNotNil(releases[0].publishedAt)
    }

    func testGitHubReleaseDecodingSkipsDraftAndPrerelease() throws {
        let json = """
        [
          {"tag_name":"v0.42.0","name":"正式版","body":"说明","html_url":"https://example.com/42",
           "draft":false,"prerelease":false,"published_at":"2026-11-10T12:00:00Z"},
          {"tag_name":"v0.43.0","name":"草稿","body":"","html_url":"https://example.com/43",
           "draft":true,"prerelease":false,"published_at":"2026-11-10T12:00:00Z"},
          {"tag_name":"v0.44.0-beta.1","name":"测试版","body":"","html_url":"https://example.com/44",
           "draft":false,"prerelease":true,"published_at":"2026-11-10T12:00:00Z"}
        ]
        """
        let stable = try UpdateChecker.decodeGitHubReleases(Data(json.utf8), allowPrerelease: false)
        XCTAssertEqual(stable.map(\.versionText), ["0.42.0"])

        let withBeta = try UpdateChecker.decodeGitHubReleases(Data(json.utf8), allowPrerelease: true)
        XCTAssertEqual(withBeta.map(\.versionText), ["0.42.0", "0.44.0-beta.1"])
    }

    func testTagDecodingIgnoresArchiveTags() throws {
        let json = """
        [{"name":"v0.41.0"},{"name":"archive/ai-assistant-20261006"},{"name":"nightly"}]
        """
        let releases = try UpdateChecker.decodeGitHubTags(Data(json.utf8))
        XCTAssertEqual(releases.map(\.versionText), ["0.41.0"])
        XCTAssertEqual(releases[0].pageURL, UpdateChecker.releasesPage)
    }

    // MARK: - 策略

    func testAutoCheckRespectsToggleAndInterval() {
        let now = Date()
        XCTAssertTrue(UpdatePolicy.shouldAutoCheck(enabled: true, lastCheckAt: nil, now: now))
        XCTAssertFalse(UpdatePolicy.shouldAutoCheck(enabled: false, lastCheckAt: nil, now: now))
        XCTAssertFalse(UpdatePolicy.shouldAutoCheck(
            enabled: true, lastCheckAt: now.addingTimeInterval(-3600), now: now
        ))
        XCTAssertTrue(UpdatePolicy.shouldAutoCheck(
            enabled: true, lastCheckAt: now.addingTimeInterval(-25 * 3600), now: now
        ))
    }

    func testPromptIsSuppressedForSkippedVersion() {
        let release = makeRelease("0.41.0")
        let outcome = UpdateCheckOutcome.available(release)
        XCTAssertFalse(UpdatePolicy.shouldPrompt(
            outcome: outcome, skippedVersion: "0.41.0",
            lastPromptedVersion: nil, lastPromptedAt: nil, now: Date()
        ))
        XCTAssertTrue(UpdatePolicy.shouldPrompt(
            outcome: outcome, skippedVersion: "0.40.0",
            lastPromptedVersion: nil, lastPromptedAt: nil, now: Date()
        ))
    }

    func testPromptCooldownPerVersion() {
        let now = Date()
        let outcome = UpdateCheckOutcome.available(makeRelease("0.41.0"))
        XCTAssertFalse(UpdatePolicy.shouldPrompt(
            outcome: outcome, skippedVersion: nil,
            lastPromptedVersion: "0.41.0",
            lastPromptedAt: now.addingTimeInterval(-3600), now: now
        ))
        XCTAssertTrue(UpdatePolicy.shouldPrompt(
            outcome: outcome, skippedVersion: nil,
            lastPromptedVersion: "0.41.0",
            lastPromptedAt: now.addingTimeInterval(-25 * 3600), now: now
        ))
        // 不同版本不受上一个版本的冷却影响。
        XCTAssertTrue(UpdatePolicy.shouldPrompt(
            outcome: outcome, skippedVersion: nil,
            lastPromptedVersion: "0.40.5",
            lastPromptedAt: now.addingTimeInterval(-60), now: now
        ))
    }

    func testPromptIgnoresNonAvailableOutcomes() {
        let now = Date()
        XCTAssertFalse(UpdatePolicy.shouldPrompt(
            outcome: .upToDate(latest: "0.40.0"), skippedVersion: nil,
            lastPromptedVersion: nil, lastPromptedAt: nil, now: now
        ))
        XCTAssertFalse(UpdatePolicy.shouldPrompt(
            outcome: .failed("网络不可用"), skippedVersion: nil,
            lastPromptedVersion: nil, lastPromptedAt: nil, now: now
        ))
        XCTAssertFalse(UpdatePolicy.shouldPrompt(
            outcome: .noPublishedRelease, skippedVersion: nil,
            lastPromptedVersion: nil, lastPromptedAt: nil, now: now
        ))
    }

    // MARK: - 端到端（本地桩，不访问网络）

    func testCheckUsesManifestAndRecordsSuccessfulCheck() async {
        let checker = makeChecker { _ in
            (200, Data(self.manifestJSON(version: "9.9.9").utf8))
        }
        let result = await checker.check(force: true)
        guard case let .available(release) = result.outcome else {
            return XCTFail("expected available, got \(result.outcome)")
        }
        XCTAssertEqual(release.versionText, "9.9.9")
        XCTAssertEqual(release.notes, "示例更新说明")
        XCTAssertNotNil(checker.lastCheckAt)
    }

    func testCheckFallsBackToGitHubReleasesWhenManifestMissing() async {
        let checker = makeChecker { request in
            if request.url?.host == "raw.githubusercontent.com" {
                return (404, Data())
            }
            let json = """
            [{"tag_name":"v9.9.9","name":"回退来源","body":"来自 Releases",
              "html_url":"https://example.com/999","draft":false,"prerelease":false,
              "published_at":"2026-11-10T12:00:00Z"}]
            """
            return (200, Data(json.utf8))
        }
        let result = await checker.check(force: true)
        guard case let .available(release) = result.outcome else {
            return XCTFail("expected available, got \(result.outcome)")
        }
        XCTAssertEqual(release.name, "回退来源")
    }

    func testCheckReportsNoPublishedReleaseWhenEverythingIs404() async {
        let checker = makeChecker { _ in (404, Data()) }
        let result = await checker.check(force: true)
        XCTAssertEqual(result.outcome, .noPublishedRelease)
        XCTAssertNotNil(checker.lastCheckAt)
    }

    func testCheckReportsRateLimitWithoutThrowing() async {
        let checker = makeChecker { request in
            request.url?.host == "raw.githubusercontent.com" ? (404, Data()) : (403, Data())
        }
        let result = await checker.check(force: true)
        guard case let .failed(message) = result.outcome else {
            return XCTFail("expected failed, got \(result.outcome)")
        }
        XCTAssertTrue(message.contains("限流"), message)
        XCTAssertNil(checker.lastCheckAt, "失败的检查不应写入上次成功时间")
    }

    func testUpToDateWhenPublishedVersionIsNotNewer() async {
        let checker = makeChecker { _ in
            (200, Data(self.manifestJSON(version: "0.0.0").utf8))
        }
        let result = await checker.check(force: true)
        XCTAssertEqual(result.outcome, .upToDate(latest: "0.0.0"))
    }

    func testManifestCarriesInstallAsset() throws {
        let json = """
        {"releases":[{"version":"0.41.0","name":"带安装包","notes":"说明",
          "url":"https://example.com/41","published_at":"2026-11-10T12:00:00Z",
          "asset_url":"https://example.com/BarControl-0.41.0.zip",
          "sha256":"ABCDEF0123"}]}
        """
        let releases = try UpdateChecker.decodeManifest(Data(json.utf8))
        XCTAssertEqual(releases.first?.assetURL?.absoluteString, "https://example.com/BarControl-0.41.0.zip")
        XCTAssertEqual(releases.first?.assetSHA256, "abcdef0123")
        XCTAssertEqual(releases.first?.canInstallInApp, true)
    }

    func testGitHubReleasePicksZipAssetAndDigest() throws {
        let json = """
        [{"tag_name":"v0.42.0","name":"正式版","body":"说明","html_url":"https://example.com/42",
          "draft":false,"prerelease":false,"published_at":"2026-11-10T12:00:00Z",
          "assets":[
            {"name":"notes.txt","browser_download_url":"https://example.com/notes.txt","size":10,"digest":null},
            {"name":"BarControl-0.42.0.zip","browser_download_url":"https://example.com/a.zip",
             "size":123,"digest":"sha256:00ff"}
          ]}]
        """
        let releases = try UpdateChecker.decodeGitHubReleases(Data(json.utf8), allowPrerelease: false)
        XCTAssertEqual(releases.first?.assetURL?.absoluteString, "https://example.com/a.zip")
        XCTAssertEqual(releases.first?.assetSHA256, "00ff")
    }

    func testAtomFeedDecoding() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <title>Bar Control 0.42.0</title>
            <link rel="alternate" type="text/html" href="https://github.com/example/bar-control/releases/tag/v0.42.0"/>
            <updated>2026-11-10T12:00:00Z</updated>
          </entry>
          <entry>
            <title>Bar Control 0.41.0</title>
            <link rel="alternate" type="text/html" href="https://github.com/example/bar-control/releases/tag/v0.41.0"/>
            <updated>2026-10-01T12:00:00Z</updated>
          </entry>
        </feed>
        """
        let releases = try UpdateChecker.decodeAtomFeed(Data(xml.utf8))
        XCTAssertEqual(releases.map(\.versionText), ["0.42.0", "0.41.0"])
        XCTAssertEqual(releases.first?.pageURL.absoluteString,
                       "https://github.com/example/bar-control/releases/tag/v0.42.0")
        XCTAssertNotNil(releases.first?.publishedAt)
        XCTAssertFalse(releases.first?.canInstallInApp ?? true, "Atom 只有版本，没有安装包")
    }

    // MARK: - 一键更新

    func testSHA256MatchesKnownDigest() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertEqual(try UpdateInstaller.sha256(of: tmp),
                       "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    func testZipRoundTripAndInstallScriptReplacesTarget() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("install-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let newApp = staging.appendingPathComponent("Bar Control.app", isDirectory: true)
        try fm.createDirectory(at: newApp.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: newApp.appendingPathComponent("Contents/version.txt"))

        let zip = root.appendingPathComponent("update.zip")
        let zipper = Process()
        zipper.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zipper.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", newApp.path, zip.path]
        try zipper.run()
        zipper.waitUntilExit()
        XCTAssertEqual(zipper.terminationStatus, 0)

        let extracted = try UpdateInstaller.extractApp(from: zip, in: root)
        XCTAssertEqual(extracted.lastPathComponent, "Bar Control.app")

        let target = root.appendingPathComponent("Installed.app", isDirectory: true)
        try fm.createDirectory(at: target.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("Contents/version.txt"))

        let script = UpdateInstaller.installScript(
            source: extracted,
            target: target,
            pid: try deadPID(),
            relaunch: false,
            backup: root.appendingPathComponent("backup.app")
        )
        let scriptURL = root.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/sh")
        runner.arguments = [scriptURL.path]
        try runner.run()
        runner.waitUntilExit()
        XCTAssertEqual(runner.terminationStatus, 0)
        let installed = try String(contentsOf: target.appendingPathComponent("Contents/version.txt"), encoding: .utf8)
        XCTAssertEqual(installed, "new", "脚本应等待旧进程退出后替换整个 .app")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("backup.app").path))
    }

    private func deadPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo $$"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 999_999
    }

    // MARK: - 辅助

    private func makeRelease(_ version: String) -> SoftwareRelease {
        SoftwareRelease(
            version: AppVersion(version)!,
            name: "示例",
            notes: "",
            pageURL: URL(string: "https://example.com")!,
            publishedAt: nil
        )
    }

    private func manifestJSON(version: String) -> String {
        """
        {"releases":[{"version":"\(version)","name":"示例版本","notes":"示例更新说明",
          "url":"https://example.com/releases/\(version)",
          "published_at":"2026-11-10T12:00:00Z"}]}
        """
    }

    private func makeChecker(_ handler: @escaping (URLRequest) -> (Int, Data)) -> UpdateChecker {
        StubURLProtocol.handler = handler
        let suite = "UpdateCheckerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return UpdateChecker(defaults: defaults, session: session, currentVersion: "0.40.0")
    }
}

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
