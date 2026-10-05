import Foundation

/// 把某个模型写进别的 Agent 的配置文件。
///
/// 只做两件事：**先备份**，再改写文件里能识别的 model 字段。
/// 认不出来（既不是 TOML 也不是 JSON、或者文件只读）就直接拒绝，不猜格式、不硬写。
enum HubAgentSync {

    enum Format: String {
        case toml = "TOML · model"
        case json = "JSON · model"
    }

    enum Failure: LocalizedError {
        case missing(String)
        case readonly(String)
        case unsupported(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missing(let path): return "配置文件不存在：\(path)"
            case .readonly(let path): return "配置文件没有写入权限：\(path)"
            case .unsupported(let reason): return "无法安全改写：\(reason)"
            case .failed(let reason): return "写入失败：\(reason)"
            }
        }
    }

    struct Plan {
        struct ConfiguredModel: Identifiable, Equatable {
            var id: String { "\(supplier)\u{0000}\(model)" }
            var supplier: String
            var model: String
            var isLocked: Bool = false
            var lockReason: String? = nil
            var isAIManaged: Bool = false
        }

        var agentName: String
        var fileURL: URL
        var format: Format
        var currentModel: String?
        var configuredModels: [ConfiguredModel]
        var changeSummary: String
        /// 这个格式能不能同时登记多个模型。
        ///
        /// TOML 的 `model = …` 和 JSON 顶层的 `model` 都只有一格，写进去是**替换**当前模型；
        /// 只有带 `provider.<id>.models` 字典的格式才真的能一次列好几个。
        /// 单格客户端的“添加模型”由 Agent 页面只写入 default 允许列表，
        /// 不替换客户端当前的 `model`；这里的 apply 仅保留给显式同步调用。
        var holdsModelList: Bool
        /// 配置文件里那条线路指向哪个 Agent：`…/agents/<名字>/v1` 里的「名字」。
        ///
        /// 网关按 Agent 发线路，界面拿它决定「这个客户端能切到哪些模型」。
        /// 读不出来就是 nil —— 那种情况下不猜，界面也不会摆出一批写进去其实发不出去的模型名。
        var modelRoute: String?
    }

    struct Result {
        var backupURL: URL
        var previousModel: String?
    }

    // MARK: 路径

    static var backupsDirectory: URL {
        RouterStore.supportDirectory.appendingPathComponent("config-backups", isDirectory: true)
    }

    /// 常见 Agent 的配置文件候选路径。只有真实存在的文件才会被用。
    static func candidates(for agentName: String) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let key = normalized(agentName)
        let table: [(String, [String])] = [
            ("codex", [".codex/config.toml"]),
            ("claude", [".claude/settings.json", ".claude.json"]),
            ("zcode", [".zcode/settings.json", ".zcode/v2/config.json", ".zcode/config.json"]),
            ("opencode", [".config/opencode/opencode.json", ".opencode/config.json"]),
            ("dsh", [".dsh/config.json", ".dsh/settings.json"]),
        ]
        guard let match = table.first(where: { key.contains($0.0) || $0.0.contains(key) }) else { return [] }
        return match.1.map { home.appendingPathComponent($0) }
    }

    /// 命中第一条真实存在的候选文件。
    static func detect(agentName: String, fileManager: FileManager = .default) -> URL? {
        candidates(for: agentName).first { fileManager.fileExists(atPath: $0.path) }
    }

    /// 按用户登记的路径找配置文件（支持 `~`）。文件不在就返回 nil ——
    /// 绝不因为「名字像 Codex」就顺手去读别的文件，那会让界面显示错客户端的模型。
    static func detect(path: String, fileManager: FileManager = .default) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: 预览

    static func plan(agentName: String, fileURL: URL, fileManager: FileManager = .default) throws -> Plan {
        guard fileManager.fileExists(atPath: fileURL.path) else { throw Failure.missing(fileURL.path) }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw Failure.unsupported("读不出文本内容（可能是二进制或编码不是 UTF-8）")
        }
        let ext = fileURL.pathExtension.lowercased()

        if ext == "toml" {
            if let current = tomlTopLevelModel(in: text) {
                return Plan(
                    agentName: agentName,
                    fileURL: fileURL,
                    format: .toml,
                    currentModel: current,
                    configuredModels: codexConfiguredModels(in: fileURL, current: current,
                                                            currentSupplier: tomlProvider(in: text) ?? "客户端配置"),
                    changeSummary: current.isEmpty
                        ? "第 1 行写入 model 字段"
                        : "把 model 从 “\(current)” 改成新模型（只改这一行）",
                    holdsModelList: false,
                    modelRoute: tomlProviderRoute(in: text)
                )
            }
            return Plan(
                agentName: agentName,
                fileURL: fileURL,
                format: .toml,
                currentModel: nil,
                configuredModels: codexConfiguredModels(in: fileURL, current: nil,
                                                        currentSupplier: tomlProvider(in: text) ?? "客户端配置"),
                changeSummary: "文件顶部新增一行 model 字段（原有内容不动）",
                holdsModelList: false,
                modelRoute: tomlProviderRoute(in: text)
            )
        }

        guard ext == "json" else {
            throw Failure.unsupported("不认识的配置格式 .\(ext)：只处理 .toml 和 .json")
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw Failure.unsupported("顶层不是 JSON 对象")
        }
        // ZCode 不把当前选择写在 config.json 顶层；它会把最近一次真正使用的
        // 模型写进自己的任务索引。只读回这个事实，不能用 provider 名称或第一
        // 个模型臆测“当前正在用”。
        let rawCurrent = dictionary["model"] as? String
        // OpenCode 把当前模型写成 `provider-id/model`，但模型池和 provider.models
        // 保存的是右侧真实模型名。统一取末段，避免同一模型被错误显示成“不在模型池”。
        let current = rawCurrent.map {
            normalized(agentName).contains("opencode") ? modelLeaf($0) : $0
        } ?? (normalized(agentName).contains("zcode") ? zcodeCurrentModel(fileURL: fileURL) : nil)
        let configured = jsonConfiguredModels(dictionary: dictionary, current: current)
        return Plan(
            agentName: agentName,
            fileURL: fileURL,
            format: .json,
            currentModel: current,
            configuredModels: configured,
            changeSummary: current == nil
                ? "顶层新增 model 字段（其它字段原样保留）"
                : "把顶层 model 从 “\(current ?? "")” 改成新模型（其它字段原样保留）",
            holdsModelList: jsonHoldsModelList(dictionary: dictionary),
            modelRoute: jsonRoute(dictionary: dictionary)
        )
    }

    /// 顶层 `model_provider` 指的是哪张供应商表（表名后缀），没写就 nil。
    private static func tomlProviderID(in text: String) -> String? {
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("[") else { break }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "model_provider" else { continue }
            return unquoted(String(parts[1]))
        }
        return nil
    }

    /// 供应商显示名：能用 `[model_providers.<id>].name` 就用它，没有才退回 id。
    ///
    /// 直接把 `ai_assistant_default` 这种内部 id 摆给用户看，他既不知道这是谁，
    /// 也看不出它其实就是「AI助手 · 默认助手」这条线路。
    private static func tomlProvider(in text: String) -> String? {
        guard let id = tomlProviderID(in: text) else { return nil }
        if let name = tomlValue(in: text, table: "model_providers.\(id)", key: "name"), !name.isEmpty {
            return name
        }
        return id
    }

    private static func tomlProviderRoute(in text: String) -> String? {
        guard let id = tomlProviderID(in: text),
              let baseURL = tomlValue(in: text, table: "model_providers.\(id)", key: "base_url") else { return nil }
        return routeAgent(inBaseURL: baseURL)
    }

    /// JSON 客户端的线路：兼容旧的 snake_case，也兼容 ZCode 实际使用的
    /// `provider.<id>.options.baseURL`。
    private static func jsonRoute(dictionary: [String: Any]) -> String? {
        if let top = (dictionary["base_url"] as? String) ?? (dictionary["baseURL"] as? String),
           let route = routeAgent(inBaseURL: top) { return route }
        guard let providers = dictionary["provider"] as? [String: Any] else { return nil }
        for (_, raw) in providers {
            guard let provider = raw as? [String: Any] else { continue }
            let options = provider["options"] as? [String: Any]
            let baseURL = (provider["base_url"] as? String)
                ?? (provider["baseURL"] as? String)
                ?? (options?["baseURL"] as? String)
                ?? (options?["base_url"] as? String)
            guard let baseURL, let route = routeAgent(inBaseURL: baseURL) else { continue }
            return route
        }
        return nil
    }

    private static func modelLeaf(_ value: String) -> String {
        guard let slash = value.lastIndex(of: "/") else { return value }
        return String(value[value.index(after: slash)...])
    }

    /// ZCode 的任务索引值形如 `provider|uuid/model` 或 `provider|model`。
    /// 只返回模型名，供应商仍由 config.json 的 provider 模型表负责显示和着色。
    private static func zcodeCurrentModel(fileURL: URL) -> String? {
        let database = fileURL.deletingLastPathComponent().appendingPathComponent("tasks-index.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path,
                             "SELECT model FROM tasks WHERE model IS NOT NULL AND trim(model) <> '' ORDER BY updated_at DESC LIMIT 1;"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        // sqlite3 可能在 ZCode 正写 WAL 时返回非零状态，但 stdout 仍会带出
        // 最近一条已提交记录；只要有一行可读就使用它，避免界面退回“尚未配置”。
        guard let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
              let raw = text.split(whereSeparator: { $0.isNewline }).first else { return nil }
        let providerAndModel = raw.split(separator: "|", maxSplits: 1).last.map(String.init) ?? String(raw)
        let model = providerAndModel.split(separator: "/").last.map(String.init) ?? providerAndModel
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 从 `…/agents/<名字>/v1` 里取出 `<名字>`。
    ///
    /// 拿不到（直连网关、直连供应商）就返回 nil：宁可让界面少列几个候选，
    /// 也不猜一批名字写进客户端 —— 名字不在那条线路上，网关根本发不出去。
    static func routeAgent(inBaseURL text: String) -> String? {
        let parts = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let index = parts.firstIndex(of: "agents"), parts.count > index + 1 else { return nil }
        let name = parts[index + 1]
        return name.isEmpty ? nil : name
    }

    /// 这个格式是不是真能同时列多个模型（见 `Plan.holdsModelList`）。
    private static func jsonHoldsModelList(dictionary: [String: Any]) -> Bool {
        guard let providers = dictionary["provider"] as? [String: Any] else { return false }
        return providers.values.contains { raw in
            ((raw as? [String: Any])?["models"] as? [String: Any])?.isEmpty == false
        }
    }

    /// 读 TOML 里某张表下的某个键，只在表头到下一个表头之间找，不会串到别的表里。
    private static func tomlValue(in text: String, table: String, key: String) -> String? {
        var inside = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inside = tomlTableName(line) == table
                continue
            }
            guard inside else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            return unquoted(String(parts[1]))
        }
        return nil
    }

    /// `[model_providers.x]` / `[[plugins]]` → `model_providers.x` / `plugins`（引号按字面去掉）。
    private static func tomlTableName(_ line: String) -> String {
        var name = line
        while name.hasPrefix("[") { name.removeFirst() }
        if let end = name.firstIndex(of: "]") { name = String(name[..<end]) }
        return name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
    }

    /// 读 TOML 字符串值的统一入口：去掉行尾注释、两侧空白和引号。
    private static func unquoted(_ raw: String) -> String {
        let head = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? raw
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func jsonConfiguredModels(dictionary: [String: Any], current: String?) -> [Plan.ConfiguredModel] {
        var result: [Plan.ConfiguredModel] = []
        if let providers = dictionary["provider"] as? [String: Any] {
            for (providerID, raw) in providers {
                guard let provider = raw as? [String: Any] else { continue }
                let namedSupplier = (provider["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let supplier = (namedSupplier?.isEmpty == false ? namedSupplier : nil) ?? providerID
                let isAIManaged = providerID.lowercased().hasPrefix("ai-assistant-")
                let locked = (provider["enabled"] as? Bool) == false
                    || provider["systemDisabledReason"] as? String != nil
                let lockReason = provider["systemDisabledReason"] as? String
                if let models = provider["models"] as? [String: Any] {
                    result.append(contentsOf: models.keys.map {
                        Plan.ConfiguredModel(supplier: supplier, model: $0,
                                             isLocked: locked,
                                             lockReason: lockReason.map { "未解锁：\($0)" },
                                             isAIManaged: isAIManaged)
                    })
                }
            }
        }
        if let current, !current.isEmpty,
           !result.contains(where: { $0.model == current }) {
            result.insert(Plan.ConfiguredModel(supplier: "当前配置", model: current), at: 0)
        }
        var unique: [String: Plan.ConfiguredModel] = [:]
        for item in result { unique[item.id] = item }
        return unique.values.sorted {
            if $0.isAIManaged != $1.isAIManaged { return !$0.isAIManaged }
            return "\($0.supplier)\u{0000}\($0.model)" < "\($1.supplier)\u{0000}\($1.model)"
        }
    }

    /// Codex 的内置模型目录独立于 config.toml 当前选中的 model。
    /// 目录中明确带 upgrade/migration 信息的模型显示为灰色，不猜会员状态。
    private static func codexConfiguredModels(in fileURL: URL, current: String?, currentSupplier: String) -> [Plan.ConfiguredModel] {
        let catalogURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("ai-assistant-models.json")
        let fallbackCatalogURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("codex-router/merged-models.json")
        var result: [Plan.ConfiguredModel] = []
        let catalogData = (try? Data(contentsOf: catalogURL)) ?? (try? Data(contentsOf: fallbackCatalogURL))
        if let data = catalogData,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = object["models"] as? [[String: Any]] {
            for item in models {
                guard let slug = item["slug"] as? String, !slug.isEmpty else { continue }
                // 原生 GPT 一直属于 Codex；外部模型只有进入 client_assignments.codex
                // 才属于这个客户端，避免把 4202 的全局目录冒充 Codex 已接入清单。
                let native = slug.lowercased().hasPrefix("gpt-")
                let visible = (item["visibility"] as? String ?? "list") != "hide"
                // 目录里的可见非原生行就是 Codex 已发布的第三方/别名模型；
                // 不再只看 client_assignments，否则 default Agent 新增的三方线路
                // 即使已同步进目录，也会在 AI助手卡片里消失。
                guard (native && visible) || (!native && visible) else { continue }
                let display = (item["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let supplier: String
                if native {
                    supplier = display?.isEmpty == false ? "Codex · \(display!)" : "Codex 内置模型"
                } else {
                    supplier = display?.isEmpty == false ? "AI助手 · \(display!)" : "AI助手 · Codex 分配"
                }
                let upgrade = item["upgrade"] as? [String: Any]
                let reason = upgrade?["migration_markdown"] as? String
            // Codex 原生目录与 AI助手发布的第三方别名共用一份 catalog。
            // 这里必须把非 gpt 行标成 AI 管理模型，否则 Agent 卡片会把
            // DeepSeek / Jev / TeamoRouter 误画成“客户端原生模型”，
            // 既造成数量看起来不一致，也会让“添加模型”误判为已写入客户端。
            result.append(Plan.ConfiguredModel(supplier: supplier, model: slug,
                                                   isLocked: upgrade != nil,
                                                   lockReason: reason ?? (upgrade == nil ? nil : "需要迁移或升级"),
                                                   isAIManaged: !native))
            }
        }
        if let current, !current.isEmpty,
           !result.contains(where: { $0.model == current }) {
            let native = current.lowercased().hasPrefix("gpt-")
            result.insert(Plan.ConfiguredModel(supplier: currentSupplier,
                                               model: current,
                                               isAIManaged: !native), at: 0)
        }
        var unique: [String: Plan.ConfiguredModel] = [:]
        for item in result { unique[item.id] = item }
        return unique.values.sorted { "\($0.supplier)\u{0000}\($0.model)" < "\($1.supplier)\u{0000}\($1.model)" }
    }

    // MARK: 写入

    static func apply(_ plan: Plan, model: String, fileManager: FileManager = .default) throws -> Result {
        guard fileManager.isWritableFile(atPath: plan.fileURL.path) else {
            throw Failure.readonly(plan.fileURL.path)
        }
        let backup = try backUp(plan.fileURL, fileManager: fileManager)
        let previous: String?
        switch plan.format {
        case .toml:
            let text = try read(plan.fileURL)
            let updated = try tomlReplacingModel(in: text, with: model)
            try write(updated, to: plan.fileURL)
            previous = plan.currentModel
        case .json:
            let text = try read(plan.fileURL)
            guard let data = text.data(using: .utf8),
                  var dictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw Failure.unsupported("顶层不是 JSON 对象")
            }
            previous = dictionary["model"] as? String
            dictionary["model"] = model
            let updated = try JSONSerialization.data(
                withJSONObject: dictionary,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            guard let output = String(data: updated, encoding: .utf8) else {
                throw Failure.failed("序列化失败")
            }
            try write(output + "\n", to: plan.fileURL)
        }
        return Result(backupURL: backup, previousModel: previous)
    }

    static func backUp(_ fileURL: URL, fileManager: FileManager = .default) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let directory = backupsDirectory
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let backup = directory.appendingPathComponent("\(stamp)-\(fileURL.lastPathComponent)")
            try? fileManager.removeItem(at: backup)
            try fileManager.copyItem(at: fileURL, to: backup)
            return backup
        } catch {
            throw Failure.failed("备份失败：\(error.localizedDescription)")
        }
    }

    // MARK: TOML

    /// 只认表头之前（顶层）的 model = "..."，避免误改 [model_providers.x] 里的东西。
    static func tomlTopLevelModel(in text: String) -> String? {
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            if let value = tomlModelValue(in: line) { return value }
        }
        return nil
    }

    /// 是 model 行就返回值（可能为空串），不是 model 行返回 nil。
    private static func tomlModelValue(in line: String) -> String? {
        let stripped = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line
        let parts = stripped.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "model" else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    static func tomlReplacingModel(in text: String, with model: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        let literal = "model = \"\(escape(model))\""
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            guard tomlModelValue(in: line) != nil else { continue }
            let indent = String(lines[index].prefix { $0 == " " || $0 == "\t" })
            lines[index] = indent + literal
            return lines.joined(separator: "\n")
        }
        lines.insert(literal, at: 0)
        return lines.joined(separator: "\n")
    }

    enum CodexReadOnlyAuthMode: String {
        case official
        case direct

        var providerID: String { self == .official ? "codex_official" : "deepseek_direct" }
        var catalogPath: String {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return (self == .official
                    ? home.appendingPathComponent(".codex/codex-router/merged-models.json")
                    : home.appendingPathComponent(".codex/codex-direct-models.json")).path
        }
        var providerBlock: String {
            switch self {
            case .official:
                return """
                [model_providers.codex_official]
                name = "OpenAI 官方账号"
                requires_openai_auth = true
                wire_api = "responses"
                supports_websockets = true
                """
            case .direct:
                return """
                [model_providers.deepseek_direct]
                name = "DeepSeek · API 直连"
                base_url = "https://api.deepseek.com/v1"
                wire_api = "responses"
                requires_openai_auth = false
                env_key = "DEEPSEEK_API_KEY"
                """
            }
        }
    }

    static func codexReadOnlyAuthMode(for model: String) -> CodexReadOnlyAuthMode? {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("gpt-") || value == "codex-auto-review" { return .official }
        if value.hasPrefix("deepseek-") { return .direct }
        return nil
    }

    /// 只读模式的 Codex 双通道。只改 Codex 自己的 config.toml，绝不改 router.json/4230。
    static func applyCodexReadOnlySelection(fileURL: URL, model: String) throws -> Result {
        guard let mode = codexReadOnlyAuthMode(for: model) else {
            throw Failure.unsupported("只读模式暂不支持 (model)：目前只允许官方 gpt-* 或 DeepSeek 直连")
        }
        guard FileManager.default.isWritableFile(atPath: fileURL.path) else {
            throw Failure.readonly(fileURL.path)
        }
        let original = try read(fileURL)
        let backup = try backUp(fileURL)
        var updated = original
        updated = replaceTopLevelScalar(in: updated, key: "model", value: model)
        updated = replaceTopLevelScalar(in: updated, key: "model_provider", value: mode.providerID)
        updated = replaceTopLevelScalar(in: updated, key: "openai_base_url", value: nil)
        updated = replaceTopLevelScalar(in: updated, key: "model_catalog_json", value: mode.catalogPath)
        updated = replaceManagedProviderBlock(in: updated, mode: mode)
        try write(updated, to: fileURL)
        return Result(backupURL: backup, previousModel: tomlTopLevelModel(in: original))
    }

    private static let readOnlyProviderBegin = "# BEGIN ai-assistant-read-only-auth-managed"
    private static let readOnlyProviderEnd = "# END ai-assistant-read-only-auth-managed"

    private static func replaceTopLevelScalar(in text: String, key: String, value: String?) -> String {
        var lines = text.components(separatedBy: "\n")
        var found = false
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard trimmed.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == key else { continue }
            found = true
            if let value {
                let indent = String(lines[index].prefix { $0 == " " || $0 == "\t" })
                lines[index] = indent + "\(key) = \"\(escape(value))\""
            } else {
                lines[index] = ""
            }
            break
        }
        if !found, let value { lines.insert("\(key) = \"\(escape(value))\"", at: 0) }
        return lines.joined(separator: "\n")
    }

    private static func replaceManagedProviderBlock(in text: String,
                                                    mode: CodexReadOnlyAuthMode) -> String {
        let block = "\(readOnlyProviderBegin)\n\(mode.providerBlock)\n\(readOnlyProviderEnd)"
        let pattern = "(?ms)^\\Q\(readOnlyProviderBegin)\\E\\n.*?^\\Q\(readOnlyProviderEnd)\\E\\n?"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if regex.firstMatch(in: text, range: range) != nil {
                return regex.stringByReplacingMatches(in: text, range: range, withTemplate: block + "\n")
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + block + "\n"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func read(_ url: URL) throws -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure.failed("读取失败：\(url.path)")
        }
        return text
    }

    private static func write(_ text: String, to url: URL) throws {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
    }
}
