import AppKit
import CryptoKit
import Foundation

enum UpdateInstallError: LocalizedError, Equatable {
    case noAsset
    case downloadFailed(String)
    case checksumMismatch
    case invalidArchive
    case signatureInvalid
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAsset:
            return "这个版本没有提供安装包，只能打开下载页"
        case let .downloadFailed(message):
            return "下载失败：\(message)"
        case .checksumMismatch:
            return "安装包校验失败，已取消更新"
        case .invalidArchive:
            return "安装包格式不正确，已取消更新"
        case .signatureInvalid:
            return "安装包签名无效，已取消更新"
        case let .installFailed(message):
            return "替换应用失败：\(message)"
        }
    }
}

/// 下载 → 校验 → 解压 → 验签 → 等 App 退出后替换 → 重新打开。
/// 只在用户点「立即更新」时执行；任何一步失败都保留旧版本。
@MainActor
final class UpdateInstaller {
    static let shared = UpdateInstaller()

    private(set) var isInstalling = false

    /// 正常安装到 /Applications；测试用 BARC_UPDATE_TARGET 指向临时目录。
    static var targetAppURL: URL {
        if let raw = ProcessInfo.processInfo.environment["BARC_UPDATE_TARGET"], !raw.isEmpty {
            return URL(fileURLWithPath: raw)
        }
        return URL(fileURLWithPath: "/Applications/Bar Control.app")
    }

    func install(
        _ release: SoftwareRelease,
        progress: @escaping @MainActor (String, Double) -> Void
    ) async throws {
        guard !isInstalling else { return }
        guard let assetURL = release.assetURL else { throw UpdateInstallError.noAsset }
        isInstalling = true
        defer { isInstalling = false }

        let fm = FileManager.default
        let workspace = fm.temporaryDirectory
            .appendingPathComponent("BarControlUpdate-\(release.versionText)-\(UUID().uuidString)",
                                    isDirectory: true)
        try? fm.createDirectory(at: workspace, withIntermediateDirectories: true)

        progress("正在下载 \(release.versionText)…", 0)
        let zip = workspace.appendingPathComponent("update.zip")
        do {
            try await download(assetURL, to: zip) { fraction in
                progress("正在下载 \(release.versionText)…", fraction)
            }
        } catch {
            throw UpdateInstallError.downloadFailed(error.localizedDescription)
        }

        progress("正在校验安装包…", 1)
        if let expected = release.assetSHA256, !expected.isEmpty {
            let actual = try Self.sha256(of: zip)
            guard actual == expected.lowercased() else {
                throw UpdateInstallError.checksumMismatch
            }
        }

        progress("正在解压…", 1)
        let app = try Self.extractApp(from: zip, in: workspace)

        progress("正在验证签名…", 1)
        try Self.verifySignature(app)

        progress("正在替换应用…", 1)
        let target = Self.targetAppURL
        let relaunch = ProcessInfo.processInfo.environment["BARC_UPDATE_NO_RELAUNCH"] != "1"
        let script = Self.installScript(
            source: app,
            target: target,
            pid: ProcessInfo.processInfo.processIdentifier,
            relaunch: relaunch,
            backup: workspace.appendingPathComponent("backup.app")
        )
        let scriptURL = workspace.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        do {
            try process.run()
        } catch {
            throw UpdateInstallError.installFailed(error.localizedDescription)
        }
        AppLog.write("update install started version=\(release.versionText) target=\(target.path)")
    }

    // MARK: - 下载

    private func download(
        _ url: URL,
        to destination: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        if url.isFileURL {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            progress(1)
            return
        }
        let delegate = UpdateDownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.attach(continuation)
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    // MARK: - 校验与解压

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func extractApp(from zip: URL, in workspace: URL) throws -> URL {
        let payload = workspace.appendingPathComponent("payload", isDirectory: true)
        try? FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, payload.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateInstallError.invalidArchive }

        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
        // 允许 zip 外面多包一层目录。
        for item in items {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory, item.pathExtension != "app" else { continue }
            let nested = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
            if let app = nested.first(where: { $0.pathExtension == "app" }) { return app }
        }
        throw UpdateInstallError.invalidArchive
    }

    static func verifySignature(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateInstallError.signatureInvalid }
    }

    /// 等旧进程退出后替换；失败时把备份移回来。
    static func installScript(source: URL, target: URL, pid: Int32,
                              relaunch: Bool, backup: URL) -> String {
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let openLine = relaunch ? "/usr/bin/open \"$TARGET\"" : "true"
        return """
        #!/bin/sh
        set -u
        PID=\(pid)
        SOURCE=\(quote(source.path))
        TARGET=\(quote(target.path))
        BACKUP=\(quote(backup.path))
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        rm -rf "$BACKUP"
        if [ -d "$TARGET" ]; then mv "$TARGET" "$BACKUP" || exit 1; fi
        if ! /usr/bin/ditto "$SOURCE" "$TARGET"; then
          rm -rf "$TARGET"
          if [ -d "$BACKUP" ]; then mv "$BACKUP" "$TARGET"; fi
          exit 1
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
        rm -rf "$BACKUP"
        \(openLine)
        """
    }
}

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @MainActor (Double) -> Void
    private let lock = NSLock()
    private var finished = false
    private var completion: CheckedContinuation<Void, Error>?

    init(destination: URL, progress: @escaping @MainActor (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        completion = continuation
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            let fm = FileManager.default
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in self.progress(min(1, max(0, fraction))) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else {
            finish(.success(()))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let completion else { return }
        finished = true
        self.completion = nil
        switch result {
        case .success:
            completion.resume()
        case let .failure(error):
            completion.resume(throwing: error)
        }
    }
}
