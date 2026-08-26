import AppKit
import ApplicationServices
import Foundation

enum CCSwitchError: LocalizedError {
    case databaseUnavailable
    case configUnavailable
    case providerNotFound(String)
    case activeProviderSectionMissing(String)
    case accessibilityPermissionRequired
    case appUnavailable
    case enableButtonNotFound(String)
    case pressFailed(String)
    case verificationTimedOut(String)
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable: return "无法读取 CC Switch 数据库"
        case .configUnavailable: return "无法读取 Codex config.toml"
        case .providerNotFound(let value): return "没有找到供应商：\(value)"
        case .activeProviderSectionMissing(let value): return "Codex 配置缺少当前供应商定义：\(value)"
        case .accessibilityPermissionRequired: return "需要在系统设置中允许 Bar Control 使用辅助功能"
        case .appUnavailable: return "没有找到正在运行的 CC Switch"
        case .enableButtonNotFound(let name): return "没有找到 \(name) 的启用按钮"
        case .pressFailed(let name): return "无法点击 \(name) 的启用按钮"
        case .verificationTimedOut(let name): return "CC Switch 未能确认已切换到 \(name)"
        case .modelNotFound(let value): return "没有找到模型：\(value)"
        }
    }
}

struct CodexCompatibilityResult: Sendable {
    let changed: Bool
    let activeProviderID: String
    let modelID: String?
    let compatibilityProviderIDs: [String]
}

struct CCSwitchProviderStore: Sendable {
    static let compatibilityProviderIDs = ["custom", "cc-switch-official"]

    private struct Row: Decodable {
        let id: String
        let name: String
        let category: String?
        let isCurrent: Int

        enum CodingKeys: String, CodingKey {
            case id, name, category
            case isCurrent = "is_current"
        }
    }

    private let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cc-switch/cc-switch.db")
    private let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cc-switch/settings.json")
    private let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/config.toml")

    func providers() async throws -> [RemoteProviderSummary] {
        let databasePath = databaseURL.path
        return try await Task.detached(priority: .utility) {
            guard FileManager.default.isReadableFile(atPath: databasePath) else {
                throw CCSwitchError.databaseUnavailable
            }
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [
                "-json",
                databasePath,
                "SELECT id,name,category,is_current FROM providers WHERE app_type='codex' ORDER BY is_current DESC,sort_index,created_at;"
            ]
            process.standardOutput = output
            process.standardError = error
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CCSwitchError.databaseUnavailable
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let rows = try JSONDecoder().decode([Row].self, from: data)
            return rows.map {
                RemoteProviderSummary(
                    id: $0.id,
                    name: $0.name,
                    category: $0.category,
                    isCurrent: $0.isCurrent != 0
                )
            }
        }.value
    }

    func resolve(_ value: String) async throws -> RemoteProviderSummary {
        let available = try await providers()
        let normalized = Self.normalized(value)
        guard let provider = available.first(where: {
            let name = Self.normalized($0.name)
            return $0.id == value || name == normalized || name.contains(normalized) || normalized.contains(name)
        }) else {
            throw CCSwitchError.providerNotFound(value)
        }
        return provider
    }

    func providerConfigModel(id: String) -> (model: String, reasoning: String?)? {
        let databasePath = databaseURL.path
        guard FileManager.default.isReadableFile(atPath: databasePath) else { return nil }
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-json",
            databasePath,
            "SELECT settings_config FROM providers WHERE id='\(id)' AND app_type='codex';"
        ]
        process.standardOutput = output
        process.standardError = error
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard
            let rows = try? JSONDecoder().decode([SettingsConfigRow].self, from: data),
            let settings = rows.first?.settings_config,
            let object = try? JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any],
            let config = object["config"] as? String
        else { return nil }
        let model = Self.firstQuotedValue(in: config, key: "model")
        let reasoning = Self.firstQuotedValue(in: config, key: "model_reasoning_effort")
        guard let model else { return nil }
        return (model, reasoning)
    }

    @discardableResult
    func reconcileCodexConfiguration(
        provider: RemoteProviderSummary? = nil
    ) throws -> CodexCompatibilityResult {
        guard var text = try? String(contentsOf: configURL, encoding: .utf8) else {
            throw CCSwitchError.configUnavailable
        }

        let providerID = provider?.id ?? currentProviderIDFromSettings()
        let setting = providerID.flatMap { providerConfigModel(id: $0) }

        if let setting {
            let modelLine = "model = \"\(setting.model)\""
            if let range = text.range(of: #"(?m)^model\s*=.*$"#, options: .regularExpression) {
                text.replaceSubrange(range, with: modelLine)
            } else {
                text = modelLine + "\n" + text
            }
            if let reasoning = setting.reasoning {
                let reasoningLine = "model_reasoning_effort = \"\(reasoning)\""
                if let range = text.range(
                    of: #"(?m)^model_reasoning_effort\s*=.*$"#,
                    options: .regularExpression
                ) {
                    text.replaceSubrange(range, with: reasoningLine)
                } else {
                    text = reasoningLine + "\n" + text
                }
            }
        }

        let patched = try Self.compatibilityPatchedConfig(text)
        let changed = patched.text != (try? String(contentsOf: configURL, encoding: .utf8))
        if changed {
            try backupLiveConfig(reason: "provider-compatibility")
            try patched.text.write(to: configURL, atomically: true, encoding: .utf8)
        }
        return CodexCompatibilityResult(
            changed: changed,
            activeProviderID: patched.activeProviderID,
            modelID: Self.firstQuotedValue(in: patched.text, key: "model"),
            compatibilityProviderIDs: Self.compatibilityProviderIDs
        )
    }

    func applyProviderModel(_ provider: RemoteProviderSummary) async throws {
        _ = try reconcileCodexConfiguration(provider: provider)
    }

    /// 读取当前 Codex 默认模型（~/.codex/config.toml 的 model 行）。
    func currentModelFromConfig() -> String? {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        return Self.firstQuotedValue(in: text, key: "model")
    }

    func currentProviderID() -> String? {
        currentProviderIDFromSettings()
    }

    /// 读取指定供应商的模型目录（来自 CC Switch 数据库 modelCatalog），并标记当前使用中的模型。
    func modelCatalog(providerID: String) -> [RemoteModelSummary] {
        let current = currentModelFromConfig()
        guard let settings = providerSettings(providerID: providerID) else { return [] }
        guard
            let catalog = settings["modelCatalog"] as? [String: Any],
            let models = catalog["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { entry -> RemoteModelSummary? in
            guard let id = entry["model"] as? String, !id.isEmpty else { return nil }
            let name = (entry["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return RemoteModelSummary(id: id, name: name, isCurrent: id == current)
        }
    }

    /// 把指定模型写为 Codex 默认模型：更新 ~/.codex/config.toml + CC Switch 数据库该供应商的 config 行，避免被 CC Switch 恢复覆盖。
    func setCurrentModel(_ modelID: String, providerID: String) throws {
        guard var text = try? String(contentsOf: configURL, encoding: .utf8) else {
            throw CCSwitchError.configUnavailable
        }
        let modelLine = "model = \"\(modelID)\""
        if let range = text.range(of: #"(?m)^model\s*=.*$"#, options: .regularExpression) {
            text.replaceSubrange(range, with: modelLine)
        } else {
            text = modelLine + "\n" + text
        }
        try text.write(to: configURL, atomically: true, encoding: .utf8)
        try updateProviderConfigModelLine(providerID: providerID, model: modelID)
        _ = try reconcileCodexConfiguration()
    }

    // MARK: - Codex 线程附加信息（置顶 / 按会话模型）

    /// 从 Codex 桌面状态库读取线程附加信息（is_pinned / model），供手机端置顶与按会话模型展示。
    /// 在后台线程运行，sqlite3 子进程带硬超时（到点 terminate），避免 daemon 持锁时卡死中继。
    func threadExtras() async -> [String: ThreadExtra] {
        await Task.detached(priority: .utility) {
            Self.queryThreadExtrasSync(timeout: 4)
        }.value
    }

    /// 写回线程置顶状态（与桌面 Codex 一致）。成功返回 true。
    func setThreadPinned(threadID: String, pinned: Bool) async -> Bool {
        await Task.detached(priority: .utility) {
            let escaped = threadID.replacingOccurrences(of: "'", with: "''")
            let value = pinned ? "1" : "0"
            let sql = "PRAGMA busy_timeout=2000; UPDATE threads SET is_pinned=\(value) WHERE id='\(escaped)';"
            return Self.runSQLiteWrite(stateDBPath: Self.codexStateDatabasePath, sql: sql, timeout: 4)
        }.value
    }

    private static let codexStateDatabasePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/state_5.sqlite").path

    private static func queryThreadExtrasSync(timeout: TimeInterval) -> [String: ThreadExtra] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-json",
            // 用 URI 的 _timeout 设置 busy timeout；不要在脚本里放 PRAGMA，
            // 否则 sqlite3 -json 会输出两个 JSON 数组导致整体解析失败。
            "file:\(codexStateDatabasePath)?mode=ro&_timeout=2000",
            "SELECT id, is_pinned, model, rollout_path FROM threads;"
        ]
        process.standardOutput = output
        process.standardError = output
        guard (try? process.run()) != nil else {
            RelayFileLog.append("threadExtras: run failed path=\(codexStateDatabasePath)")
            return [:]
        }
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 1)
            RelayFileLog.append("threadExtras: sqlite timed out, terminated")
            return [:]
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorText = String(data: data, encoding: .utf8) ?? ""
            RelayFileLog.append(
                "threadExtras: sqlite failed status=\(process.terminationStatus) err=\(String(errorText.prefix(200)))"
            )
            return [:]
        }
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            RelayFileLog.append("threadExtras: json parse failed bytes=\(data.count)")
            return [:]
        }
        var result: [String: ThreadExtra] = [:]
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty else { continue }
            let pinned = (row["is_pinned"] as? NSNumber)?.boolValue ?? false
            let model = row["model"] as? String
            let rolloutPath = row["rollout_path"] as? String
            result[id] = ThreadExtra(pinned: pinned, model: model, rolloutPath: rolloutPath)
        }
        RelayFileLog.append("threadExtras: rows=\(rows.count) parsed=\(result.count)")
        return result
    }

    private static func runSQLiteWrite(
        stateDBPath: String,
        sql: String,
        timeout: TimeInterval = 4
    ) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["file:\(stateDBPath)?mode=rw", sql]
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 1)
            return false
        }
        return process.terminationStatus == 0
    }

    /// 解析并返回某供应商的 settings_config JSON。失败返回 nil。
    private func providerSettings(providerID: String) -> [String: Any]? {
        let databasePath = databaseURL.path
        guard FileManager.default.isReadableFile(atPath: databasePath) else { return nil }
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-json",
            databasePath,
            "SELECT settings_config FROM providers WHERE id='\(providerID)' AND app_type='codex';"
        ]
        process.standardOutput = output
        process.standardError = error
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard
            let rows = try? JSONDecoder().decode([SettingsConfigRow].self, from: data),
            let settings = rows.first?.settings_config,
            let object = try? JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any]
        else { return nil }
        return object
    }

    private func updateProviderConfigModelLine(providerID: String, model: String) throws {
        let databasePath = databaseURL.path
        guard
            var settings = providerSettings(providerID: providerID),
            var config = settings["config"] as? String
        else { throw CCSwitchError.providerNotFound(providerID) }

        let modelLine = "model = \"\(model)\""
        if let range = config.range(of: #"(?m)^model\s*=.*$"#, options: .regularExpression) {
            config.replaceSubrange(range, with: modelLine)
        } else {
            config = modelLine + "\n" + config
        }
        settings["config"] = config
        let updated = try JSONSerialization.data(withJSONObject: settings, options: .sortedKeys)
        let updatedString = String(decoding: updated, as: UTF8.self)
        let escaped = updatedString.replacingOccurrences(of: "'", with: "''")
        let sql = "UPDATE providers SET settings_config='\(escaped)' WHERE id='\(providerID)' AND app_type='codex';"
        try Self.runSQLite(databasePath: databasePath, sql: sql)
    }

    private static func runSQLite(databasePath: String, sql: String) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databasePath, sql]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CCSwitchError.databaseUnavailable }
    }

    private struct SettingsConfigRow: Decodable {
        let settings_config: String
    }

    // MARK: - 直写切换（不依赖辅助功能点 CC Switch 界面）

    /// 直接激活供应商：合并 config.toml、写 auth.json、写 settings.json 的 currentProviderCodex、生成模型目录。
    func activateProviderDirect(_ provider: RemoteProviderSummary) throws {
        try backupSwitchState()
        try setCurrentProviderInDatabase(provider.id)
        guard let settings = providerSettings(providerID: provider.id) else {
            throw CCSwitchError.databaseUnavailable
        }
        guard let targetConfig = settings["config"] as? String, !targetConfig.isEmpty else {
            throw CCSwitchError.providerNotFound(provider.name)
        }
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        let current = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let merged = Self.mergeConfig(target: targetConfig, into: current)
        try merged.write(to: configURL, atomically: true, encoding: .utf8)

        if let auth = settings["auth"] as? [String: Any] {
            let authURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/auth.json")
            let data = try JSONSerialization.data(withJSONObject: auth, options: [.sortedKeys])
            try data.write(to: authURL, options: .atomic)
        }

        try updateCurrentProviderCodex(provider.id)
        try? writeCatalogFile(settings: settings)
        _ = try reconcileCodexConfiguration(provider: provider)
    }

    private func setCurrentProviderInDatabase(_ id: String) throws {
        let sql = "UPDATE providers SET is_current=(id='\(id)') WHERE app_type='codex';"
        try Self.runSQLite(databasePath: databaseURL.path, sql: sql)
    }

    private func updateCurrentProviderCodex(_ id: String) throws {
        guard let data = try? Data(contentsOf: settingsURL),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CCSwitchError.databaseUnavailable }
        obj["currentProviderCodex"] = id
        let newData = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try newData.write(to: settingsURL, options: .atomic)
    }

    private func writeCatalogFile(settings: [String: Any]) throws {
        let catalogURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/cc-switch-model-catalog.json")
        guard let mc = settings["modelCatalog"] as? [String: Any],
              let models = mc["models"] as? [[String: Any]], !models.isEmpty else { return }
        var entries: [[String: Any]] = []
        for (index, m) in models.enumerated() {
            guard let slug = m["model"] as? String else { continue }
            let name = (m["displayName"] as? String) ?? slug
            let levels = (m["reasoningLevels"] as? [String]) ?? ["high"]
            let input = (m["inputModalities"] as? [String]) ?? ["text"]
            let context = (m["contextWindow"] as? Int) ?? 1_048_576
            let reasoning = levels.map { ["effort": $0, "description": Self.reasoningDescription($0)] }
            let entry: [String: Any] = [
                "slug": slug, "display_name": name, "description": name,
                "default_reasoning_level": (m["defaultReasoningLevel"] as? String) ?? "high",
                "supported_reasoning_levels": reasoning,
                "shell_type": "shell_command", "visibility": "list", "supported_in_api": true,
                "priority": 1000 + index,
                "additional_speed_tiers": [], "service_tiers": [],
                "availability_nux": NSNull(), "upgrade": NSNull(),
                "model_messages": ["instructions_template": "You are Codex, a coding agent. You and the user share the same workspace and collaborate to achieve the user's goals."],
                "include_skills_usage_instructions": false, "include_plugin_usage_instructions": false,
                "include_apps_usage_instructions": true, "default_reasoning_summary": "none",
                "support_verbosity": false, "default_verbosity": NSNull(),
                "apply_patch_tool_type": NSNull(), "web_search_tool_type": "text",
                "truncation_policy": ["mode": "bytes", "limit": 10_000],
                "supports_image_detail_original": input.contains("image"),
                "supports_parallel_tool_calls": (m["supportsParallelToolCalls"] as? Bool) ?? false,
                "supports_reasoning_summaries": true, "supports_search_tool": false,
                "context_window": context, "max_context_window": context,
                "effective_context_window_percent": 95, "experimental_supported_tools": [],
                "input_modalities": input, "use_responses_lite": false,
                "base_instructions": "You are Codex, a coding agent. You and the user share the same workspace and collaborate to achieve the user's goals."
            ]
            entries.append(entry)
        }
        let catalog = ["models": entries]
        let data = try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])
        try data.write(to: catalogURL, options: .atomic)
    }

    private static func reasoningDescription(_ effort: String) -> String {
        switch effort {
        case "low": return "Fast responses with lighter reasoning"
        case "medium": return "Balances speed and reasoning depth for everyday tasks"
        case "xhigh": return "Extra high reasoning depth for complex problems"
        case "max": return "Maximum reasoning depth for the hardest problems"
        case "ultra": return "Maximum reasoning with automatic task delegation"
        default: return "Greater reasoning depth for complex problems"
        }
    }

    /// 把目标供应商模板合并进当前 config：保留当前里目标模板没定义的部分（如 [mcp_servers] 等公共段）。
    private static func mergeConfig(target: String, into current: String) -> String {
        let (tScalars, tSecs) = parseSections(target)
        let (cScalars, cSecs) = parseSections(current)
        let tHeaders = Set(tSecs.map { $0.0 })
        let tKeys = Set(tScalars.map { $0.components(separatedBy: "=")[0].trimmingCharacters(in: .whitespaces) })
        var out: [String] = []
        out.append(contentsOf: tScalars)
        for line in cScalars {
            let key = line.components(separatedBy: "=")[0].trimmingCharacters(in: .whitespaces)
            if !tKeys.contains(key) { out.append(line) }
        }
        out.append("")
        for (header, lines) in tSecs {
            out.append("[\(header)]")
            out.append(contentsOf: lines)
            out.append("")
        }
        for (header, lines) in cSecs where !tHeaders.contains(header) {
            out.append("[\(header)]")
            out.append(contentsOf: lines)
            out.append("")
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func parseSections(_ text: String) -> (scalars: [String], sections: [(String, [String])]) {
        var scalars: [String] = []
        var sections: [(String, [String])] = []
        var curHeader: String?
        var curLines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("[") {
                if let h = curHeader { sections.append((h, curLines)) }
                curHeader = String(s.dropFirst().dropLast())
                curLines = []
            } else if curHeader != nil {
                curLines.append(String(line))
            } else if !s.isEmpty, s.contains("="), !s.hasPrefix("#") {
                scalars.append(String(line))
            }
        }
        if let h = curHeader { sections.append((h, curLines)) }
        return (scalars, sections)
    }

    private static func firstQuotedValue(in text: String, key: String) -> String? {
        let pattern = "(?m)^\\s*" + NSRegularExpression.escapedPattern(for: key) + "\\s*=\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    static func compatibilityPatchedConfig(
        _ text: String
    ) throws -> (text: String, activeProviderID: String) {
        guard let activeProviderID = firstQuotedValue(in: text, key: "model_provider") else {
            throw CCSwitchError.activeProviderSectionMissing("未设置 model_provider")
        }

        let originalEndsWithNewline = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if originalEndsWithNewline, lines.last == "" { lines.removeLast() }

        let sections = providerSections(in: lines)
        guard let activeSection = sections.first(where: { $0.id == activeProviderID }) else {
            throw CCSwitchError.activeProviderSectionMissing(activeProviderID)
        }
        let activeBody = trimmedBody(Array(lines[(activeSection.start + 1)..<activeSection.end]))

        var removals: [Range<Int>] = []
        var aliasesToAppend: [String] = []
        for alias in compatibilityProviderIDs where alias != activeProviderID {
            let matches = sections.filter { $0.id == alias }
            if matches.count == 1 {
                let body = trimmedBody(Array(lines[(matches[0].start + 1)..<matches[0].end]))
                if body == activeBody { continue }
            }
            removals.append(contentsOf: matches.map { $0.start..<$0.end })
            aliasesToAppend.append(alias)
        }

        let duplicateActiveSections = sections.filter { $0.id == activeProviderID }.dropFirst()
        removals.append(contentsOf: duplicateActiveSections.map { $0.start..<$0.end })

        guard !removals.isEmpty || !aliasesToAppend.isEmpty else {
            return (text, activeProviderID)
        }

        for range in removals.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            lines.removeSubrange(range)
        }
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeLast()
        }
        for alias in aliasesToAppend {
            lines.append("")
            lines.append("[model_providers.\(alias)]")
            lines.append(contentsOf: activeBody)
        }
        var result = lines.joined(separator: "\n")
        if originalEndsWithNewline || !result.isEmpty { result += "\n" }
        return (result, activeProviderID)
    }

    private struct ProviderSection {
        let id: String
        let start: Int
        let end: Int
    }

    private static func providerSections(in lines: [String]) -> [ProviderSection] {
        var sections: [ProviderSection] = []
        for index in lines.indices {
            guard let id = providerID(fromHeader: lines[index]) else { continue }
            var end = index + 1
            while end < lines.count, !isTableHeader(lines[end]) { end += 1 }
            sections.append(ProviderSection(id: id, start: index, end: end))
        }
        return sections
    }

    private static func providerID(fromHeader line: String) -> String? {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "[model_providers."
        guard value.hasPrefix(prefix), value.hasSuffix("]") else { return nil }
        var id = String(value.dropFirst(prefix.count).dropLast())
        if id.hasPrefix("\"") && id.hasSuffix("\"") && id.count >= 2 {
            id.removeFirst()
            id.removeLast()
        }
        return id.isEmpty ? nil : id
    }

    private static func isTableHeader(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("[") && value.hasSuffix("]")
    }

    private static func trimmedBody(_ lines: [String]) -> [String] {
        var result = lines
        while result.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            result.removeFirst()
        }
        while result.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            result.removeLast()
        }
        return result
    }

    private func backupLiveConfig(reason: String) throws {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        let manager = FileManager.default
        let base = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BarControlRemote/SwitchBackups", isDirectory: true)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let directory = base.appendingPathComponent(
            "\(reason)-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.copyItem(at: configURL, to: directory.appendingPathComponent("config.toml"))
    }

    @MainActor
    func switchProvider(_ provider: RemoteProviderSummary) async throws -> RemoteProviderSummary {
        if provider.isCurrent { return provider }
        try backupSwitchState()

        let promptKey = "AXTrustedCheckOptionPrompt"
        guard AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else {
            throw CCSwitchError.accessibilityPermissionRequired
        }
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.ccswitch.desktop"
        ).first else {
            _ = try await NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/Applications/CC Switch.app"),
                configuration: NSWorkspace.OpenConfiguration()
            )
            try await Task.sleep(for: .seconds(1))
            guard let launched = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.ccswitch.desktop"
            ).first else { throw CCSwitchError.appUnavailable }
            return try await switchUsingAccessibility(provider, application: launched, hideAfter: true)
        }

        let hideAfter = !application.isActive
        return try await switchUsingAccessibility(provider, application: application, hideAfter: hideAfter)
    }

    private func currentProviderIDFromSettings() -> String? {
        guard
            let data = try? Data(contentsOf: settingsURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["currentProviderCodex"] as? String
    }

    @MainActor
    private func switchUsingAccessibility(
        _ provider: RemoteProviderSummary,
        application: NSRunningApplication,
        hideAfter: Bool
    ) async throws -> RemoteProviderSummary {
        application.activate(options: [.activateAllWindows])
        try await Task.sleep(for: .milliseconds(400))
        await ensureWindowVisible(application: application)
        defer {
            if hideAfter { application.hide() }
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let elements = flattenedElements(appElement)
        let normalizedName = Self.normalized(provider.name)

        guard let nameIndex = elements.firstIndex(where: { element in
            Self.normalized(elementLabel(element.element)) == normalizedName
                && axString(element.element, kAXRoleAttribute) != kAXButtonRole
        }) else {
            throw CCSwitchError.enableButtonNotFound(provider.name)
        }

        var enableButton: AXUIElement?
        for element in elements[(nameIndex + 1)...] {
            let role = axString(element.element, kAXRoleAttribute) ?? ""
            let label = elementLabel(element.element)
            if role == kAXHeadingRole, Self.normalized(label) != normalizedName {
                break
            }
            if role == kAXButtonRole, label == "启用" || label == "使用中" {
                enableButton = element.element
                break
            }
        }

        guard let enableButton else {
            throw CCSwitchError.enableButtonNotFound(provider.name)
        }
        let buttonTitle = axString(enableButton, kAXTitleAttribute)
            ?? axString(enableButton, kAXDescriptionAttribute)
            ?? ""
        if buttonTitle != "使用中" {
            guard AXUIElementPerformAction(enableButton, kAXPressAction as CFString) == .success else {
                throw CCSwitchError.pressFailed(provider.name)
            }
        }

        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(350))
            let current = try await providers().first(where: \.isCurrent)
            if current?.id == provider.id, currentProviderIDFromSettings() == provider.id {
                return current ?? provider
            }
        }
        throw CCSwitchError.verificationTimedOut(provider.name)
    }

    /// 托盘应用用 NSRunningApplication 激活不一定能显示主窗口，AX 拿不到 WINDOWS；
    /// 这时用 LaunchServices 的 `open -a` 强制把窗口拉起来，再做辅助功能扫描。
    @MainActor
    private func ensureWindowVisible(application: NSRunningApplication) async {
        if Self.hasAXWindow(application.processIdentifier) { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "CC Switch"]
        try? process.run()
        try? await Task.sleep(for: .milliseconds(800))
        application.activate(options: [.activateAllWindows])
        try? await Task.sleep(for: .milliseconds(400))
    }

    private static func hasAXWindow(_ pid: pid_t) -> Bool {
        let root = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value) == .success else {
            return false
        }
        return ((value as? [AXUIElement])?.isEmpty == false)
    }

    private func flattenedElements(_ root: AXUIElement) -> [(element: AXUIElement, index: Int)] {
        var result: [(AXUIElement, Int)] = []
        var stack = [root]
        var index = 0
        while let current = stack.popLast(), index < 3_000 {
            result.append((current, index))
            index += 1
            let children = axElements(current, kAXChildrenAttribute)
            for child in children.reversed() {
                stack.append(child)
            }
        }
        return result
    }

    private func elementLabel(_ element: AXUIElement) -> String {
        axString(element, kAXTitleAttribute)
            ?? axString(element, kAXDescriptionAttribute)
            ?? axString(element, kAXValueAttribute)
            ?? ""
    }

    private func backupSwitchState() throws {
        let manager = FileManager.default
        let base = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BarControlRemote/SwitchBackups", isDirectory: true)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = base.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json"),
            databaseURL,
            settingsURL
        ]
        for source in candidates where manager.fileExists(atPath: source.path) {
            try manager.copyItem(at: source, to: directory.appendingPathComponent(source.lastPathComponent))
        }
    }

    private func findElement(
        in root: AXUIElement,
        maxDepth: Int,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        if predicate(root) { return root }
        guard maxDepth > 0 else { return nil }
        for child in axElements(root, kAXChildrenAttribute) {
            if let found = findElement(in: child, maxDepth: maxDepth - 1, matching: predicate) {
                return found
            }
        }
        return nil
    }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return (value as! AXUIElement?)
    }

    private func axElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}

/// Codex 线程的桌面端附加信息（置顶状态 / 该线程实际使用的模型）。
struct ThreadExtra: Sendable {
    let pinned: Bool
    let model: String?
    let rolloutPath: String?
}
