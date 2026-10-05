import Foundation

/// 生成 Codex 客户端自己的模型目录。
///
/// 4230 是 Codex 的统一入口；模型目录应由 router.json default Agent 加上
/// 4202 原生目录生成，不能把 4202 picker 的一次性刷新结果当成客户端切换的
/// 前置条件。4202 picker 仍由它自己管理，这里不直接改 merged-models.json。
enum HubCodexCatalogSync {

    struct Result {
        var ok: Bool
        var changed: Bool
        var modelCount: Int
        var backupURL: URL?
        var message: String
    }

    static func managerURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".local/share/jev-codex-router/router/bin/control")
    }

    static func localCatalogScriptURL(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                      fileManager: FileManager = .default) -> URL? {
        let installed = home.appendingPathComponent(
            "Library/Application Support/LocalSiriLLM/sync-codex-agent-catalog.py"
        )
        if fileManager.isExecutableFile(atPath: installed.path) { return installed }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/sync-codex-agent-catalog.py")
        return fileManager.isExecutableFile(atPath: source.path) ? source : nil
    }

    static func sync(routerURL: URL,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     fileManager: FileManager = .default) -> Result {
        guard fileManager.fileExists(atPath: routerURL.path) else {
            return Result(ok: false, changed: false, modelCount: 0, backupURL: nil,
                          message: "找不到 router.json：未同步 Codex 模型目录")
        }
        guard let data = try? Data(contentsOf: routerURL),
              let router = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Result(ok: false, changed: false, modelCount: 0, backupURL: nil,
                          message: "router.json 格式无法读取：未同步 Codex 模型目录")
        }
        let models = assignedModels(from: router)
        guard !models.isEmpty else {
            return Result(ok: false, changed: false, modelCount: 0, backupURL: nil,
                          message: "Codex 没有可发布的客户端分配，未调用 4202")
        }

        let liveConfig = home.appendingPathComponent(
            "Library/Application Support/LocalSiriLLM/router.json"
        ).standardizedFileURL.path
        if routerURL.standardizedFileURL.path == liveConfig,
           let script = localCatalogScriptURL(home: home, fileManager: fileManager) {
            let result = runPython(script: script)
            if result.status == 0 {
                return Result(
                    ok: true,
                    changed: true,
                    modelCount: models.count,
                    backupURL: nil,
                    message: "已同步 Codex 本地模型目录（原生模型 + default Agent）"
                )
            }
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let failure = detail.isEmpty ? "退出码 \(result.status)" : detail
            return Result(
                ok: false,
                changed: false,
                modelCount: models.count,
                backupURL: nil,
                message: "本地 Codex 模型目录同步失败：\(failure)"
            )
        }

        let manager = managerURL(home: home)
        guard fileManager.isExecutableFile(atPath: manager.path) else {
            return Result(ok: false, changed: false, modelCount: models.count, backupURL: nil,
                          message: "找不到 4202 模型管理命令：未直接改写 merged-models.json")
        }

        var changed = false
        for model in models where !isNativeCodexModel(model) {
            let result = run(manager: manager, arguments: ["picker", "set", model, "show"])
            guard result.status == 0 else {
                let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return Result(ok: false, changed: changed, modelCount: models.count, backupURL: nil,
                              message: "4202 未接受 \(model)：\(detail.isEmpty ? "退出码 \(result.status)" : detail)")
            }
            changed = true
        }
        return Result(ok: true, changed: changed, modelCount: models.count, backupURL: nil,
                      message: changed
                        ? "已通过 4202 模型管理命令发布 \(models.count) 个 Codex 分配"
                        : "分配中的模型均为 Codex 原生模型，无需改写 4202")
    }

    private static func assignedModels(from router: [String: Any]) -> [String] {
        guard let assignments = router["client_assignments"] as? [String: Any],
              let raw = assignments["codex"] as? [String] else { return [] }
        var result: [String] = []
        for item in raw {
            let model = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { continue }
            // 模型池展示的是供应商的短名，4202 picker 接受的是自己的规范 slug。
            // 之前把 `deepseek-v4-pro` 原样交给 picker，4202 会返回
            // "Unknown model slug"，导致 UI 看起来写入了 router.json、实际路由目录
            // 没发布，下一次切换仍然失败。
            let normalized = codexSlug(for: model)
            if !result.contains(normalized) { result.append(normalized) }
        }
        return result
    }

    private static func codexSlug(for model: String) -> String {
        if model.contains("/") { return model }
        switch model.lowercased() {
        case "jev-auto": return "jev/auto"
        case "deepseek-flash": return "deepseek/deepseek-v4.1-flash"
        case "deepseek-v4-flash": return "deepseek/deepseek-v4-flash"
        case "deepseek-v4-flash-vision-exp": return "deepseek/deepseek-v4-flash-vision-exp"
        case "deepseek-v4.1-flash": return "deepseek/deepseek-v4.1-flash"
        case "deepseek-v4-pro": return "deepseek/deepseek-v4-pro"
        default: return model
        }
    }

    private static func isNativeCodexModel(_ model: String) -> Bool {
        model.lowercased().hasPrefix("gpt-")
    }

    private struct CommandResult {
        var status: Int32
        var output: String
    }

    private static func run(manager: URL, arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = manager
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return CommandResult(status: process.terminationStatus,
                                  output: String(decoding: data, as: UTF8.self))
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
    }

    private static func runPython(script: URL) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return CommandResult(
                status: process.terminationStatus,
                output: String(decoding: data, as: UTF8.self)
            )
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
    }
}
