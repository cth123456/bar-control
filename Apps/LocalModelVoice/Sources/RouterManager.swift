import AppKit
import Darwin

// MARK: - router.json 读写层

/// GUI 与 unified_router.py 共用同一个 router.json。
/// 供应商是唯一真相来源，Agent 只记录供应商 id 的顺序，
/// 因此改一条供应商的 Key / 地址 / 模型，所有引用它的 Agent 一起生效。
final class RouterStore {
    static let gatewayLaunchdLabel = "com.local.localmodelvoice.gateway-4230"
    static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalSiriLLM", isDirectory: true)

    static var gatewayLaunchdPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(gatewayLaunchdLabel).plist")
    }

    static var gatewayLaunchdTarget: String {
        "gui/\(getuid())/\(gatewayLaunchdLabel)"
    }

    static func gatewayLaunchdManaged(port: Int) -> Bool {
        port == 4230 && FileManager.default.fileExists(atPath: gatewayLaunchdPlistURL.path)
    }

    @discardableResult
    static func launchctl(_ arguments: [String]) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (
                process.terminationStatus == 0,
                String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            return (false, error.localizedDescription)
        }
    }

    static func ensureGatewayLaunchdLoaded() -> Bool {
        if launchctl(["print", gatewayLaunchdTarget]).ok { return true }
        guard FileManager.default.fileExists(atPath: gatewayLaunchdPlistURL.path) else { return false }
        return launchctl(["bootstrap", "gui/\(getuid())", gatewayLaunchdPlistURL.path]).ok
    }

    static func kickGatewayLaunchd() -> Bool {
        guard ensureGatewayLaunchdLoaded() else { return false }
        return launchctl(["kickstart", "-k", gatewayLaunchdTarget]).ok
    }

    static func stopGatewayLaunchd() -> Bool {
        launchctl(["bootout", gatewayLaunchdTarget]).ok
    }

    static var defaultConfigURL: URL {
        let override = ProcessInfo.processInfo.environment["LOCAL_SIRI_ROUTER_CONFIG"] ?? ""
        if !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return supportDirectory.appendingPathComponent("router.json")
    }

    /// 优先用安装副本；开发目录里直接用仓库里的脚本。
    static var scriptURL: URL? {
        let installed = supportDirectory.appendingPathComponent("unified_router.py")
        if FileManager.default.fileExists(atPath: installed.path) {
            return installed
        }
        let developed = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/unified_router.py")
        return FileManager.default.fileExists(atPath: developed.path) ? developed : nil
    }

    let configURL: URL
    private(set) var root: [String: Any] = ["version": 1, "connections": [], "providers": [], "agents": []]

    init(configURL: URL = RouterStore.defaultConfigURL) {
        self.configURL = configURL
    }

    /// 与 unified_router.py 同源的运行统计：只读它真实写入的 attempts / successes，
    /// GUI 不做任何推算，没有记录的线路就显示空。
    var statsURL: URL {
        let override = ProcessInfo.processInfo.environment["LOCAL_SIRI_ROUTER_STATS"] ?? ""
        if !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return configURL.deletingLastPathComponent().appendingPathComponent("router-stats.json")
    }

    var healthURL: URL {
        let override = ProcessInfo.processInfo.environment["LOCAL_SIRI_ROUTER_HEALTH"] ?? ""
        if !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return configURL.deletingLastPathComponent().appendingPathComponent("router-health.json")
    }

    private(set) var stats: [String: [String: Any]] = [:]
    private(set) var health: [String: Any] = [:]

    func loadStats() {
        stats = [:]
        guard let data = try? Data(contentsOf: statsURL),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return }
        stats = parsed
    }

    func loadHealth() {
        guard let data = try? Data(contentsOf: healthURL),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { health = [:]; return }
        health = parsed
    }

    func recordHealth(connectionID: String, probe: [String: Any]) {
        var connections = health["connections"] as? [String: [String: Any]] ?? [:]
        let check: [String: Any] = [
            "ok": (probe["ok"] as? Bool) ?? false,
            "status": (probe["status"] as? String) ?? "unreachable",
            "latency_ms": probe["latency_ms"] ?? NSNull(),
            "error": probe["error"] ?? "",
            // 结论的来源：catalog=读了 /models 列表，generation=发了一次 1 token 生成。
            // 界面要分开说，否则「读不到列表」会被误报成「线路不通」。
            "method": probe["method"] ?? "",
            "probe_model": probe["probe_model"] ?? "",
        ]
        connections["connection:\(connectionID)"] = check
        var providers = health["providers"] as? [String: [String: Any]] ?? [:]
        for provider in self.providers where (provider["connection_id"] as? String) == connectionID {
            if let id = provider["id"] as? String { providers[id] = check }
        }
        health = [
            "checked_at": ISO8601DateFormatter().string(from: Date()),
            "connections": connections,
            "providers": providers,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: health, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try FileManager.default.createDirectory(
                at: healthURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: healthURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: healthURL.path)
        } catch {
            // Health is a volatile indicator; a write failure must not undo a model import.
        }
    }

    var providers: [[String: Any]] { (root["providers"] as? [[String: Any]]) ?? [] }
    var connections: [[String: Any]] { (root["connections"] as? [[String: Any]]) ?? [] }
    var agents: [[String: Any]] { (root["agents"] as? [[String: Any]]) ?? [] }
    var clientAssignments: [String: [String]] {
        (root["client_assignments"] as? [String: Any])?.reduce(into: [:]) { result, item in
            guard let values = item.value as? [String] else { return }
            result[item.key] = values
        } ?? [:]
    }
    /// Backward-compatible first entry for callers that only need one model.
    var jevModelMap: [String: String] {
        jevModelCandidates.reduce(into: [:]) { result, item in
            if let first = item.value.first { result[item.key] = first }
        }
    }

    /// Ordered candidates per Jev tier. Legacy string values become one-item
    /// arrays; new JSON arrays preserve the user's left-to-right failover order.
    var jevModelCandidates: [String: [String]] {
        guard let raw = root["jev_model_map"] as? [String: Any] else { return [:] }
        return raw.reduce(into: [:]) { result, item in
            if let value = item.value as? String, !value.isEmpty {
                result[item.key] = [value]
            } else if let values = item.value as? [String] {
                result[item.key] = values.filter { !$0.isEmpty }
            }
        }
    }

    /// 语音助手（App 的云端通道）默认走哪个 Agent；unified_router.py 读同一个键。
    /// 单独一个键而不是"顺序里的第一个"，是因为没有命令行参数的调用方无法指定 Agent。
    var assistantAgentID: String { (root["assistant_agent"] as? String) ?? "" }

    func setAssistantAgent(id: String) {
        root["assistant_agent"] = id
    }

    /// 给界面看的一句话：没设置就说明脚本自己的回落顺序。
    var assistantAgentLabel: String {
        let chosen = assistantAgentID
        if chosen.isEmpty { return "未设置（脚本回落 omni → default）" }
        if agentIndex(id: chosen) == nil { return "\(chosen)（已删除，回落 omni → default）" }
        return chosen
    }

    // MARK: 总路由网关

    /// 网关的 agent_id 决定「所有指向网关的客户端」默认落到哪个 Agent 链路上。
    var gatewayAgentID: String {
        let value = (gateway["agent_id"] as? String) ?? ""
        return value.isEmpty ? "omni" : value
    }

    var gatewayPort: Int {
        (gateway["port"] as? NSNumber)?.intValue ?? 4230
    }

    private var gateway: [String: Any] {
        (root["gateway"] as? [String: Any]) ?? [:]
    }

    func setGatewayAgent(id: String) {
        var settings = gateway
        settings["agent_id"] = id
        root["gateway"] = settings
    }

    func setGatewayPort(_ port: Int) {
        var settings = gateway
        settings["port"] = port
        root["gateway"] = settings
    }

    func setGatewayKey(_ key: String) {
        var settings = gateway
        settings["api_key"] = key
        root["gateway"] = settings
    }

    /// 网关进程的启动参数：端口和 Agent 当场传进去。
    /// 这样界面上刚改、还没保存的值也能立刻生效，而且只影响这一次运行——
    /// unified_router.py 把它们当本进程的临时监听覆盖，不会写回 router.json。
    static func gatewayLaunchArguments(script: URL, port: Int, agentID: String) -> [String] {
        var arguments = [script.path, "--serve"]
        // 0 是「让系统挑一个空闲端口」，属于合法请求；只有越界值才丢掉。
        if (0...65535).contains(port) {
            arguments += ["--port", String(port)]
        }
        let agent = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !agent.isEmpty {
            arguments += ["--agent-id", agent]
        }
        return arguments
    }

    /// 界面上填的数优先（那是用户此刻的意图），填得不对就退回保存过的值，并给一句人话。
    /// 起网关是「看现在填了什么」，不是「看上次保存了什么」——否则改完端口不点保存再启动，
    /// 用户看到的就是旧端口上的服务。
    static func gatewayLaunchPort(fieldText: String, saved: Int) -> (port: Int, note: String?) {
        let text = fieldText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return (saved, nil) }
        guard let value = Int(text), value > 0, value < 65536 else {
            return (saved, "界面上填的端口「\(text)」不是 1-65535 的数字，这次先用保存过的 \(saved)。")
        }
        if value != saved {
            return (value, "这次用界面上填的端口 \(value) 启动；保存后才会写进 router.json。")
        }
        return (value, nil)
    }

    func setJevModel(tier: String, providerID: String) {
        var mapping = jevModelCandidates
        mapping[tier] = providerID.isEmpty ? [] : [providerID]
        root["jev_model_map"] = mapping
    }

    func setJevModels(tier: String, providerIDs: [String]) {
        var mapping = jevModelCandidates
        mapping[tier] = providerIDs.filter { !$0.isEmpty }
        root["jev_model_map"] = mapping
    }

    func load() throws {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            root = ["version": 1, "connections": [[String: Any]](), "providers": [[String: Any]](), "agents": [[String: Any]]()]
            try save()
            return
        }
        do {
            let data = try Data(contentsOf: configURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RouterError.invalid("router.json 顶层必须是对象")
            }
            root = object
        } catch let error as RouterError {
            throw error
        } catch {
            throw RouterError.invalid("router.json 解析失败：\(error.localizedDescription)")
        }
        if root["providers"] == nil { root["providers"] = [[String: Any]]() }
        if root["connections"] == nil { root["connections"] = [[String: Any]]() }
        if root["agents"] == nil { root["agents"] = [[String: Any]]() }
    }

    func save() throws {
        let directory = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        if FileManager.default.fileExists(atPath: configURL.path) {
            let backup = directory.appendingPathComponent("router.json.bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: configURL, to: backup)
        }
        try data.write(to: configURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configURL.path
        )
    }

    // MARK: 读取

    func providerID(at index: Int) -> String? {
        let items = providers
        guard items.indices.contains(index) else { return nil }
        return items[index]["id"] as? String
    }

    func agentID(at index: Int) -> String? {
        let items = agents
        guard items.indices.contains(index) else { return nil }
        return items[index]["id"] as? String
    }

    func agentIndex(id: String) -> Int? {
        agents.firstIndex { ($0["id"] as? String) == id }
    }

    func providerName(id: String) -> String {
        for provider in providers where (provider["id"] as? String) == id {
            return (provider["name"] as? String) ?? id
        }
        return "\(id)（已删除）"
    }

    func connection(id: String) -> [String: Any]? {
        connections.first { ($0["id"] as? String) == id }
    }

    func connectionName(id: String) -> String {
        (connection(id: id)?["name"] as? String) ?? id
    }

    /// 「同地址」的规范化口径：去首尾空白、去首尾 `/`、大小写不敏感。
    /// addConnection 的重复合并和 App 收编时的「借用已有连接」必须是同一把尺子，
    /// 否则会出现「以为要新建、其实把用户的连接改名清表」这种改坏配置的路径。
    static func normalizedAddress(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    @discardableResult
    func addConnection(name: String, baseURL: String, apiKey: String, wireAPI: String,
                       catalog: [[String: Any]], selectedModelIDs: [String],
                       source: String = "manual") -> String {
        // 同一个地址 + 同一个协议重复点「添加」不该再造一条半成品记录：
        // 探针超时后用户往往会再点一次，合并到已有连接里就不会留下要手删的僵尸行。
        let normalizedURL = Self.normalizedAddress(baseURL)
        if !normalizedURL.isEmpty,
           let existing = connections.first(where: { connection in
               let other = Self.normalizedAddress((connection["base_url"] as? String) ?? "")
               let wire = (connection["wire_api"] as? String) ?? "chat_completions"
               return other == normalizedURL && wire == wireAPI
           }),
           let identifier = existing["id"] as? String, !identifier.isEmpty {
            var fields: [String: Any] = ["models": catalog]
            if !name.isEmpty { fields["name"] = name }
            if !apiKey.isEmpty { fields["api_key"] = apiKey }
            updateConnection(id: identifier, with: fields)
            selectedModelIDs.forEach { _ = addModel(connectionID: identifier, modelID: $0) }
            return identifier
        }
        var items = connections
        let identifier = uniqueIdentifier(base: name, taken: items.compactMap { $0["id"] as? String })
        items.append([
            "id": identifier,
            "name": name.isEmpty ? identifier : name,
            "kind": "openai_compatible",
            "enabled": true,
            "base_url": baseURL,
            "api_key": apiKey,
            "wire_api": wireAPI,
            "models": catalog,
            "source": source,
        ])
        root["connections"] = items
        selectedModelIDs.forEach { _ = addModel(connectionID: identifier, modelID: $0) }
        return identifier
    }

    func updateConnection(id: String, with fields: [String: Any]) {
        var items = connections
        guard let index = items.firstIndex(where: { ($0["id"] as? String) == id }) else {
            // Flat router.json entries are surfaced by HubModel as synthetic
            // connections.  Editing one must update the original provider,
            // not silently do nothing.
            if let providerIndex = providers.firstIndex(where: { ($0["id"] as? String) == id }) {
                updateProvider(at: providerIndex, with: fields)
            }
            return
        }
        var item = items[index]
        for (key, value) in fields {
            if let text = value as? String, text.isEmpty, ["base_url", "api_key"].contains(key) {
                item.removeValue(forKey: key)
            } else {
                item[key] = value
            }
        }
        items[index] = item
        root["connections"] = items
        var models = providers
        for index in models.indices where (models[index]["connection_id"] as? String) == id {
            let model = (models[index]["model"] as? String) ?? ""
            let name = (item["name"] as? String) ?? id
            models[index]["name"] = model.isEmpty ? name : "\(name) · \(model)"
        }
        root["providers"] = models
    }

    func resolvedProvider(at index: Int) -> [String: Any]? {
        guard providers.indices.contains(index) else { return nil }
        let provider = providers[index]
        let connectionID = provider["connection_id"] as? String ?? ""
        guard !connectionID.isEmpty, let connection = connection(id: connectionID) else { return provider }
        return connection.merging(provider) { _, modelValue in modelValue }
    }

    @discardableResult
    func addModel(connectionID: String, modelID: String) -> String? {
        guard !modelID.isEmpty else { return nil }
        guard let connection = connection(id: connectionID) else {
            // Legacy flat schema: clone the existing provider as another
            // model route so the editor can still grow the model pool.
            guard let source = providers.first(where: { ($0["id"] as? String) == connectionID }) else { return nil }
            if let existing = providers.first(where: {
                ($0["model"] as? String) == modelID
                    && ($0["base_url"] as? String) == (source["base_url"] as? String)
                    && ($0["api_key"] as? String) == (source["api_key"] as? String)
                    && ($0["wire_api"] as? String) == (source["wire_api"] as? String)
            }) {
                return existing["id"] as? String
            }
            let identifier = uniqueIdentifier(
                base: "\(connectionID)-\(modelID)",
                taken: providers.compactMap { $0["id"] as? String }
            )
            var item = source
            item["id"] = identifier
            item["model"] = modelID
            item["name"] = "\((source["name"] as? String) ?? connectionID) · \(modelID)"
            item["source"] = "hub-model"
            var items = providers
            items.append(item)
            root["providers"] = items
            return identifier
        }
        if let existing = providers.first(where: {
            ($0["connection_id"] as? String) == connectionID && ($0["model"] as? String) == modelID
        }) {
            return existing["id"] as? String
        }
        let identifier = uniqueIdentifier(
            base: "\(connectionID)-\(modelID)",
            taken: providers.compactMap { $0["id"] as? String }
        )
        var item: [String: Any] = [
            "id": identifier,
            "name": "\((connection["name"] as? String) ?? connectionID) · \(modelID)",
            "connection_id": connectionID,
            "kind": "openai_compatible",
            "enabled": (connection["enabled"] as? Bool) ?? true,
            "model": modelID,
            "source": "api-model-list",
        ]
        if let wire = connection["wire_api"] as? String { item["wire_api"] = wire }
        var items = providers
        items.append(item)
        root["providers"] = items
        return identifier
    }

    // MARK: 修改

    @discardableResult
    func addProvider(name: String) -> Int {
        var items = providers
        let identifier = uniqueIdentifier(base: name, taken: items.compactMap { $0["id"] as? String })
        var provider: [String: Any] = [
            "id": identifier,
            "name": name.isEmpty ? identifier : name,
            "kind": "openai_compatible",
            "enabled": true,
            "wire_api": "chat_completions",
            "base_url": "https://",
            "model": "",
            "api_key": "",
            "timeout_seconds": 120,
        ]
        provider["name"] = provider["name"]
        items.append(provider)
        root["providers"] = items
        return items.count - 1
    }

    @discardableResult
    func addAgent(name: String) -> Int {
        var items = agents
        let taken = items.compactMap { $0["id"] as? String }
        let identifier = uniqueIdentifier(base: name, taken: taken)
        items.append([
            "id": identifier,
            "name": name.isEmpty ? identifier : name,
            "provider_ids": [String](),
            "system_prompt": "",
        ])
        root["agents"] = items
        return items.count - 1
    }

    func removeProvider(at index: Int) {
        var items = providers
        guard items.indices.contains(index) else { return }
        let identifier = items[index]["id"] as? String
        items.remove(at: index)
        root["providers"] = items
        guard let identifier else { return }
        var updatedAgents = agents
        for item in updatedAgents.indices {
            var ids = (updatedAgents[item]["provider_ids"] as? [String]) ?? []
            ids.removeAll { $0 == identifier }
            updatedAgents[item]["provider_ids"] = ids
        }
        root["agents"] = updatedAgents
    }

    func removeAgent(at index: Int) {
        var items = agents
        guard items.indices.contains(index) else { return }
        let removed = items[index]["id"] as? String
        items.remove(at: index)
        root["agents"] = items
        // 删掉的正好是助手默认 Agent：别留一个指向空气的 assistant_agent。
        if let removed, assistantAgentID == removed {
            root["assistant_agent"] = (items.first?["id"] as? String) ?? "default"
        }
    }

    /// 删掉整个供应商：连同它的模型线路一起移除，并把各 Agent / Jev 档位里指向这些线路的绑定摘干净。
    func removeConnection(id: String) {
        guard !id.isEmpty else { return }
        // Synthetic connection backed by a flat provider.
        if !connections.contains(where: { ($0["id"] as? String) == id }),
           let providerIndex = providers.firstIndex(where: { ($0["id"] as? String) == id }) {
            removeProvider(at: providerIndex)
            return
        }
        root["connections"] = connections.filter { ($0["id"] as? String) != id }

        let kept = providers.filter { ($0["connection_id"] as? String) != id }
        let keptIDs = Set(kept.compactMap { $0["id"] as? String })
        root["providers"] = kept

        var updatedAgents = agents
        for item in updatedAgents.indices {
            var ids = (updatedAgents[item]["provider_ids"] as? [String]) ?? []
            ids.removeAll { !keptIDs.contains($0) }
            updatedAgents[item]["provider_ids"] = ids
        }
        root["agents"] = updatedAgents

        var mapping = jevModelMap
        for (tier, providerID) in mapping where !keptIDs.contains(providerID) {
            mapping.removeValue(forKey: tier)
        }
        root["jev_model_map"] = mapping
    }

    /// 只删连接本身，挂在它下面的线路行解绑保留。
    /// `removeConnection` 会连线路行一起删掉（那是「删供应商」的语义），
    /// 还原 App 收编时必须留着用户的原始线路行，所以单独走这一条。
    func removeConnectionKeepingProviders(id: String) {
        guard !id.isEmpty else { return }
        root["connections"] = connections.filter { ($0["id"] as? String) != id }
        var items = providers
        for index in items.indices where (items[index]["connection_id"] as? String) == id {
            items[index].removeValue(forKey: "connection_id")
        }
        root["providers"] = items
    }

    /// 单条线路解绑（真删 `connection_id` 键）。
    /// 不能写空串：那会留下「引用一条空 id 连接」的悬空行，页面和网关都会认错。
    @discardableResult
    func unbindProvider(providerID: String) -> Bool {
        guard let index = providers.firstIndex(where: { ($0["id"] as? String) == providerID }),
              providers[index]["connection_id"] != nil else { return false }
        var items = providers
        items[index].removeValue(forKey: "connection_id")
        root["providers"] = items
        return true
    }

    /// 添加到 Agent：默认追加到末尾，同一个供应商不会重复出现。
    @discardableResult
    func assign(providerID: String, toAgentAt index: Int) -> Bool {
        var items = agents
        guard items.indices.contains(index), !providerID.isEmpty else { return false }
        var ids = (items[index]["provider_ids"] as? [String]) ?? []
        guard !ids.contains(providerID) else { return false }
        ids.append(providerID)
        items[index]["provider_ids"] = ids
        root["agents"] = items
        return true
    }

    func removeProvider(_ providerID: String, fromAgentAt index: Int) {
        var items = agents
        guard items.indices.contains(index) else { return }
        var ids = (items[index]["provider_ids"] as? [String]) ?? []
        ids.removeAll { $0 == providerID }
        items[index]["provider_ids"] = ids
        root["agents"] = items
    }

    /// 调整顺序 = 调整故障转移优先级（越靠前越先试）。
    func moveProvider(inAgentAt index: Int, from: Int, to: Int) {
        var items = agents
        guard items.indices.contains(index) else { return }
        var ids = (items[index]["provider_ids"] as? [String]) ?? []
        guard ids.indices.contains(from), to >= 0, to < ids.count, from != to else { return }
        let moved = ids.remove(at: from)
        ids.insert(moved, at: to)
        items[index]["provider_ids"] = ids
        root["agents"] = items
    }

    /// 由 Agent 管理页一次性写回拖拽后的完整线路顺序。
    func setProviderOrder(_ providerIDs: [String], forAgentAt index: Int) {
        var items = agents
        guard items.indices.contains(index) else { return }
        items[index]["provider_ids"] = providerIDs
        root["agents"] = items
    }

    func renameAgent(at index: Int, to name: String) {
        var items = agents
        guard items.indices.contains(index) else { return }
        items[index]["name"] = name
        root["agents"] = items
    }

    /// 表单保存：只覆盖表单负责的键，保留 bridge_dir 之类的手工字段。
    func updateProvider(at index: Int, with fields: [String: Any]) {
        var items = providers
        guard items.indices.contains(index) else { return }
        var provider = items[index]
        let removable = ["base_url", "api_key", "api_key_file", "executable", "model"]
        for (key, value) in fields {
            if let text = value as? String, text.isEmpty, removable.contains(key) {
                provider.removeValue(forKey: key)
            } else if let list = value as? [String], list.isEmpty {
                provider.removeValue(forKey: key)
            } else {
                provider[key] = value
            }
        }
        items[index] = provider
        root["providers"] = items
    }

    func uniqueIdentifier(base: String, taken: [String]) -> String {
        var slug = ""
        for character in base.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "provider" }
        guard taken.contains(slug) else { return slug }
        var counter = 2
        while taken.contains("\(slug)-\(counter)") { counter += 1 }
        return "\(slug)-\(counter)"
    }

    enum RouterError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case let .invalid(message): return message
            }
        }
    }

    /// 无界面自检：拖拽入库 / 顺序 / 删除解绑 / 供应商配置改动对 Agent 的自动同步。
    /// 返回 0 表示全部通过，1 表示有断言失败。
    static func selfTest() -> Int32 {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-selftest-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("router.json")
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }

        let store = RouterStore(configURL: url)
        do {
            try store.load()
            check(store.providers.isEmpty && store.agents.isEmpty, "新配置从空白开始")

            let providerIndex = store.addProvider(name: "TeamoRouter · GPT-6 Astra")
            store.updateProvider(at: providerIndex, with: [
                "base_url": "https://api.teamorouter.com/v1",
                "model": "gpt-6-astra",
                "api_key": "sk-first",
                "wire_api": "chat_completions",
            ])
            let providerID = store.providerID(at: providerIndex) ?? ""
            check(providerID == "teamorouter-gpt-6-astra", "供应商 id 由名称生成：\(providerID)")

            // The live router uses this flat provider schema (no connections
            // array).  The Lunacy hub must still be able to edit it and add a
            // second model without silently dropping the change.
            store.updateConnection(id: providerID, with: ["base_url": "https://api.example.test/v1"])
            check(
                (store.providers.first { ($0["id"] as? String) == providerID }?["base_url"] as? String)
                    == "https://api.example.test/v1",
                "平面供应商可从连接编辑器更新"
            )
            let flatModelID = store.addModel(connectionID: providerID, modelID: "gpt-6-astra-legacy") ?? ""
            check(!flatModelID.isEmpty && store.providers.contains { ($0["id"] as? String) == flatModelID },
                  "平面供应商可复制出第二条模型线路")

            let connectionID = store.addConnection(
                name: "Test API",
                baseURL: "https://models.example.test/v1",
                apiKey: "sk-connection-test",
                wireAPI: "responses",
                catalog: [["id": "model-a", "name": "Model A", "owned_by": "test"]],
                selectedModelIDs: ["model-a"]
            )
            let connectionProviderIndex = store.providers.firstIndex {
                ($0["connection_id"] as? String) == connectionID
            } ?? -1
            let connectionProvider = store.resolvedProvider(at: connectionProviderIndex) ?? [:]
            check(connectionID == "test-api", "供应商连接单独保存：\(connectionID)")
            check((connectionProvider["base_url"] as? String) == "https://models.example.test/v1", "模型路由继承供应商 Base URL")
            check((connectionProvider["api_key"] as? String) == "sk-connection-test", "模型路由继承供应商 Key")

            let emptyConnectionID = store.addConnection(
                name: "No Model Yet",
                baseURL: "https://empty.example.test/v1",
                apiKey: "",
                wireAPI: "chat_completions",
                catalog: [],
                selectedModelIDs: []
            )
            check(store.connection(id: emptyConnectionID) != nil,
                  "供应商可先保存，模型稍后再加入")

            let agentIndex = store.addAgent(name: "编码")
            check(store.assign(providerID: providerID, toAgentAt: agentIndex), "模型添加到 Agent")
            check(store.assign(providerID: providerID, toAgentAt: agentIndex) == false, "重复模型被忽略")

            // 助手默认 Agent：写盘后仍生效，删掉它也不能留悬空引用
            let assistantAgent = store.addAgent(name: "coding")
            store.setAssistantAgent(id: store.agentID(at: assistantAgent) ?? "")
            check(store.assistantAgentID == "coding", "助手默认 Agent 记为 coding")

            let secondProvider = store.addProvider(name: "AgentRouter")
            let secondID = store.providerID(at: secondProvider) ?? ""
            check(store.assign(providerID: secondID, toAgentAt: agentIndex), "第二个供应商入库")
            store.moveProvider(inAgentAt: agentIndex, from: 1, to: 0)
            try store.save()

            // 换一个实例重新读盘：模拟下次打开软件
            let reopened = RouterStore(configURL: url)
            try reopened.load()
            let agent = reopened.agents.first ?? [:]
            let ids = (agent["provider_ids"] as? [String]) ?? []
            check(ids == [secondID, providerID], "顺序已持久化（越靠前越优先）：\(ids)")

            // 改供应商的 Key/模型 → 引用它的 Agent 必须看到新值
            let index = reopened.providers.firstIndex { ($0["id"] as? String) == providerID } ?? -1
            reopened.updateProvider(at: index, with: [
                "api_key": "sk-second",
                "model": "gpt-6-astra-turbo",
            ])
            try reopened.save()
            let after = RouterStore(configURL: url)
            try after.load()
            let linked = after.providers.first { ($0["id"] as? String) == providerID } ?? [:]
            check((linked["api_key"] as? String) == "sk-second", "改 Key 后 Agent 取到新 Key")
            check((linked["model"] as? String) == "gpt-6-astra-turbo", "改模型后 Agent 取到新模型")
            check((after.agents.first?["provider_ids"] as? [String])?.count == 2, "Agent 引用未被改配置破坏")
            check(after.assistantAgentID == "coding", "助手默认 Agent 已持久化：\(after.assistantAgentID)")
            check(after.assistantAgentLabel == "coding", "界面能读出助手默认 Agent")

            // 总路由网关设置：默认值 + 写盘 + 重载
            check(after.gatewayPort == 4230, "网关默认端口 4230")
            check(after.gatewayAgentID == "omni", "网关默认 Agent omni")
            after.setGatewayAgent(id: "coding")
            after.setGatewayPort(4321)
            after.setGatewayKey("sk-gateway-test")
            try after.save()
            let gatewayReloaded = RouterStore(configURL: url)
            try gatewayReloaded.load()
            check(gatewayReloaded.gatewayAgentID == "coding", "网关 Agent 已持久化")
            check(gatewayReloaded.gatewayPort == 4321, "网关端口已持久化")
            check(
                (gatewayReloaded.root["gateway"] as? [String: Any])?["api_key"] as? String
                    == "sk-gateway-test",
                "网关密钥已持久化"
            )

            // 启动参数：端口 / Agent 当场传下去（临时覆盖，不写盘）
            let launchScript = URL(fileURLWithPath: "/tmp/unified_router.py")
            check(
                RouterStore.gatewayLaunchArguments(script: launchScript, port: 4321, agentID: "coding")
                    == ["/tmp/unified_router.py", "--serve", "--port", "4321", "--agent-id", "coding"],
                "网关启动参数带上端口和 Agent"
            )
            check(
                RouterStore.gatewayLaunchArguments(script: launchScript, port: 0, agentID: "   ")
                    == ["/tmp/unified_router.py", "--serve", "--port", "0"],
                "端口 0 = 系统自选；Agent 空白就不传"
            )
            check(
                RouterStore.gatewayLaunchArguments(script: launchScript, port: -5, agentID: "")
                    == ["/tmp/unified_router.py", "--serve"],
                "越界的值不往下传，让脚本用默认值"
            )

            // 界面优先：改了没保存也立刻生效；填错则退回保存值并说明
            check(RouterStore.gatewayLaunchPort(fieldText: "", saved: 4230) == (4230, nil), "端口留空用保存值")
            let edited = RouterStore.gatewayLaunchPort(fieldText: " 5000 ", saved: 4230)
            check(edited.port == 5000 && edited.note != nil, "界面上填的端口优先，并提示还没保存")
            let unchanged = RouterStore.gatewayLaunchPort(fieldText: "4230", saved: 4230)
            check(unchanged.port == 4230 && unchanged.note == nil, "填的和保存的一样就不啰嗦")
            let typo = RouterStore.gatewayLaunchPort(fieldText: "abc", saved: 4230)
            check(typo.port == 4230 && typo.note != nil, "端口填错：退回保存值并说明原因")
            let outOfRange = RouterStore.gatewayLaunchPort(fieldText: "70000", saved: 4230)
            check(outOfRange.port == 4230 && outOfRange.note != nil, "端口越界：同样退回保存值")

            // 删掉的正好是助手默认 Agent：必须自动改指一个仍然存在的 Agent
            after.removeAgent(at: after.agentIndex(id: "coding") ?? -1)
            try after.save()
            let moved = RouterStore(configURL: url)
            try moved.load()
            check(
                moved.agentIndex(id: moved.assistantAgentID) != nil,
                "删除助手默认 Agent 后自动改指存在的 Agent：\(moved.assistantAgentID)"
            )

            // 删除供应商 → 自动从所有 Agent 解绑
            let removeIndex = after.providers.firstIndex { ($0["id"] as? String) == secondID } ?? -1
            after.removeProvider(at: removeIndex)
            try after.save()
            let cleaned = RouterStore(configURL: url)
            try cleaned.load()
            check((cleaned.agents.first?["provider_ids"] as? [String]) == [providerID], "删除供应商后自动解绑")
            check(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent("router.json.bak").path),
                "保存前留有 router.json.bak"
            )
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
            check(mode == 0o600, "配置权限 600（含明文 Key）")
        } catch {
            print("FAIL 自检异常：\(error.localizedDescription)")
            failures += 1
        }
        try? FileManager.default.removeItem(at: directory)
        print(failures == 0 ? "自检全部通过" : "自检失败 \(failures) 项")
        return failures == 0 ? 0 : 1
    }
}

// MARK: - 管理窗口

/// 供应商池 + Agent 面板：把供应商拖到某个 Agent 下即完成分配，
/// 供应商的 API 配置只有一份，改完全部 Agent 自动同步。
final class RouterManagerWindowController: NSWindowController,
    NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {

    private static let providerDragType = NSPasteboard.PasteboardType("com.localmodelvoice.provider-id")

    private let store = RouterStore()
    private var providerRows: [[String: Any]] = []
    private var agentRows: [[String: Any]] = []
    private var memberRows: [[String: Any]] = []
    private var isReloading = false
    private var externalMode = false

    private let providersTable = NSTableView()
    private let agentsTable = NSTableView()
    private let memberTable = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let logView = NSTextView()
    /// 单次 router 调用的硬上限：超时就终止进程，避免界面上留下永远「进行中」的记录。
    private static let defaultRunTimeout: TimeInterval = 90
    private let connectedSummary = NSTextField(labelWithString: "0")
    private let onlineSummary = NSTextField(labelWithString: "0 / 0")
    private let modelSummary = NSTextField(labelWithString: "0")
    private let latencySummary = NSTextField(labelWithString: "—")

    private let nameField = NSTextField(string: "")
    private let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let enabledCheck = NSButton(checkboxWithTitle: "启用", target: nil, action: nil)
    private let wirePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let timeoutField = NSTextField(string: "120")
    private let baseURLField = NSTextField(string: "")
    private let modelField = NSTextField(string: "")
    private let apiKeyField = NSSecureTextField(string: "")
    private let apiKeyFileField = NSTextField(string: "")
    private let executableField = NSTextField(string: "")
    private let argumentsView = NSTextView()

    private let gatewayInfoLabel = NSTextField(labelWithString: "点「刷新网关」读取总路由地址与密钥")
    private let gatewayKeyField = NSTextField(string: "")
    private let gatewayPortField = NSTextField(string: "")
    private let jevLunaPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let jevTerraPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let jevSolPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let jevAstraPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let jevStatusLabel = NSTextField(labelWithString: "")
    private var jevPopupIDs: [String] = []
    private let externalAgentsLabel = NSTextField(labelWithString: "尚未扫描外部 Agent")
    private var providerAdvancedSection: NSView?
    private var gatewaySection: NSView?
    private var logSection: NSView?
    private var providerDetailsToggle: NSButton?
    private var gatewayToggle: NSButton?
    private var logToggle: NSButton?
    private var gatewayProcess: Process?
    private var gatewaySnippets: [String: String] = [:]
    private weak var externalSyncPathField: NSTextField?

    private let kinds = ["openai_compatible", "dsh_bridge", "command"]
    private let wires = ["chat_completions", "responses"]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "统一 Agent 路由 · 供应商与 Agent 管理"
        window.minSize = NSSize(width: 980, height: 720)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 把路由面板交给中枢窗口的页签复用。
    ///
    /// 面板原先住在自己的独立窗口里；同一个 NSView 不能有两个父视图，所以这里
    /// 先把路由窗口的 contentView 摘空，再返回面板本体。
    func detachPanelView() -> NSView {
        reloadFromDisk(note: false)
        appendLog("""
        配置文件：\(store.configURL.path)
        · 左侧「供应商池」= 线路 + 模型；把它拖到右侧某个 Agent 上即完成分配，立即写盘。
        · 供应商配置只有一份，改完点「保存到所选供应商」，所有引用它的 Agent 自动同步。
        · Agent 下的顺序就是故障转移优先级；点「导入全部线路」可把 ~/.dsh 的线路一次性拉进池子，
          选中某个 Agent 时会同步挂到它下面。
        · 「总路由网关」是给所有客户端用的一个入口：填供应商 → 拖到对应 Agent → 启动网关，
          再把 Codex / Claude 的接入片段贴到客户端，就实现每个 Agent 分开管理。
        """)
        refreshGateway()
        discoverExternalAgents()
        guard let content = window?.contentView else { return NSView() }
        window?.delegate = nil
        window?.contentView = NSView()
        return content
    }

    /// 退出应用前必须收掉网关子进程，否则会留下孤儿监听端口。
    func shutdownGateway() {
        // 4230 的生产实例由 launchd 托管，不能因为 AI助手退出而把共享网关杀掉。
        if RouterStore.gatewayLaunchdManaged(port: store.gatewayPort) {
            gatewayProcess = nil
            return
        }
        gatewayProcess?.terminate()
        gatewayProcess = nil
    }

    /// The main hub owns strategy switching now, but the gateway process still
    /// lives here so the legacy diagnostics panel and the main page share one
    /// process. Starting it is idempotent for this app instance.
    func startGatewayIfNeeded() {
        if RouterStore.gatewayLaunchdManaged(port: store.gatewayPort) {
            // 4230 由 launchd 托管后是共享基础设施：只要端口已经在监听，就不该
            // 再 kickstart -k（-k 会先杀再起，把健康网关打掉，紧接着的启动复核
            // 会在重启窗口里误判成「网关没保住」退回只读）。
            if !HubStrategySync.isListening(host: "127.0.0.1", port: store.gatewayPort) {
                startGateway()
            }
            return
        }
        guard gatewayProcess == nil else { return }
        startGateway()
    }

    // MARK: 界面搭建

    private func buildContent() {
        configure(providersTable)
        providersTable.addTableColumn(column("启用", 42))
        providersTable.addTableColumn(column("供应商", 125))
        providersTable.addTableColumn(column("模型", 120))
        providersTable.addTableColumn(column("来源", 80))
        providersTable.addTableColumn(column("连通 / 延迟", 80))
        providersTable.registerForDraggedTypes([Self.providerDragType])
        providersTable.setDraggingSourceOperationMask(.copy, forLocal: true)

        configure(agentsTable)
        agentsTable.addTableColumn(column("Agent", 420))
        agentsTable.registerForDraggedTypes([Self.providerDragType])

        configure(memberTable)
        memberTable.addTableColumn(column("顺序", 44))
        memberTable.addTableColumn(column("模型 / 供应商", 390))

        let pageTitle = NSTextField(labelWithString: "本地路由 · 供应商与模型")
        pageTitle.font = .systemFont(ofSize: 21, weight: .bold)
        let pageSubtitle = NSTextField(labelWithString: "供应商只配置一次；模型从模型库加入 Agent，改 URL / Key 后所有引用自动同步。")
        pageSubtitle.font = .systemFont(ofSize: 12)
        pageSubtitle.textColor = .secondaryLabelColor
        let pageHeading = NSStackView(views: [pageTitle, pageSubtitle])
        pageHeading.orientation = .vertical
        pageHeading.alignment = .leading
        pageHeading.spacing = 4

        let toolbar = NSStackView(views: [
            button("导入已有线路", #selector(importAllSources)),
            button("新增供应商并拉取模型", #selector(addProvider)),
            button("手动添加单模型", #selector(addManualProvider)),
            button("测速所有线路", #selector(probeAllConnections)),
            button("新增 Agent", #selector(addAgent)),
        ])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        for compactView in [pageHeading, toolbar] {
            compactView.setContentHuggingPriority(.required, for: .vertical)
            compactView.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        let summary = NSStackView(views: [
            summaryCard(title: "已接入供应商", value: connectedSummary, hint: "连接配置集中管理"),
            summaryCard(title: "当前在线", value: onlineSummary, hint: "只测 /models，不发生成请求"),
            summaryCard(title: "本地模型池", value: modelSummary, hint: "可加入外部 Agent"),
            summaryCard(title: "平均延迟", value: latencySummary, hint: "最近一次连接探测"),
        ])
        summary.orientation = .horizontal
        summary.spacing = 10

        let providersColumn = NSStackView(views: [
            sectionLabel("供应商模型库"),
            scroll(providersTable, height: 300),
        ])
        let membersHeader = NSStackView(views: [
            sectionLabel("所选 Agent 的模型（上方优先）"),
            button("＋ 添加模型", #selector(addMember)),
        ])
        membersHeader.orientation = .horizontal
        membersHeader.spacing = 8

        let agentsColumn = NSStackView(views: [
            sectionLabel("外部 Agent（真实配置文件）"),
            scroll(agentsTable, height: 150),
            membersHeader,
            scroll(memberTable, height: 150),
            NSStackView(views: [
                button("移除模型", #selector(removeMember)),
                button("上移优先", #selector(moveMemberUp)),
                button("下移", #selector(moveMemberDown)),
                button("设为助手默认", #selector(setAssistantAgentDefault)),
                button("删除 Agent", #selector(removeAgent)),
            ]),
        ])
        let columns = NSStackView(views: [providersColumn, agentsColumn])
        columns.orientation = .horizontal
        columns.spacing = 14
        columns.distribution = .fillEqually
        columns.alignment = .top
        for column in [providersColumn, agentsColumn] {
            column.orientation = .vertical
            column.distribution = .fill
            column.spacing = 6
            column.alignment = .leading
        }

        let form = buildForm()
        let formButtons = NSStackView(views: [
            button("保存供应商配置", #selector(saveProviderEdits)),
        ])
        formButtons.orientation = .horizontal
        formButtons.spacing = 8

        let gatewayButtons = NSStackView(views: [
            button("刷新网关", #selector(refreshGateway)),
            button("启动网关", #selector(startGateway)),
            button("停止网关", #selector(stopGateway)),
            button("复制 Codex 片段", #selector(copyCodexSnippet)),
            button("复制 Claude 片段", #selector(copyClaudeSnippet)),
        ])
        gatewayButtons.orientation = .horizontal
        gatewayButtons.spacing = 8

        gatewayInfoLabel.font = NSFont.systemFont(ofSize: 12)
        gatewayInfoLabel.textColor = .secondaryLabelColor
        gatewayKeyField.font = NSFont.systemFont(ofSize: 12)
        gatewayKeyField.lineBreakMode = .byTruncatingMiddle
        gatewayKeyField.isSelectable = true
        gatewayKeyField.placeholderString = "网关密钥（自动生成）"
        gatewayPortField.font = NSFont.systemFont(ofSize: 12)
        gatewayPortField.placeholderString = "端口"
        gatewayPortField.translatesAutoresizingMaskIntoConstraints = false
        gatewayPortField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        gatewayKeyField.translatesAutoresizingMaskIntoConstraints = false
        gatewayKeyField.widthAnchor.constraint(equalToConstant: 360).isActive = true

        let gatewayRow = NSStackView(views: [
            gatewayInfoLabel, label("端口"), gatewayPortField,
            label("密钥"), gatewayKeyField,
            button("保存端口 / 密钥", #selector(saveGatewaySecret)),
        ])
        gatewayRow.orientation = .horizontal
        gatewayRow.spacing = 8
        gatewayRow.alignment = .centerY

        let gatewayColumn = NSStackView(views: [
            sectionLabel("总路由网关（所有 Agent 共用这一个地址，网关内部按 Agent 做故障转移）"),
            gatewayRow,
            gatewayButtons,
        ])
        gatewayColumn.orientation = .vertical
        gatewayColumn.alignment = .leading
        gatewayColumn.spacing = 6

        let providerAdvanced = NSStackView(views: [
            sectionLabel("编辑所选供应商"), form, formButtons,
            NSStackView(views: [
                button("移除所选模型", #selector(removeProvider)),
                button("刷新线路状态", #selector(probeAllConnections)),
                button("只导入 DSH", #selector(importDSH)),
                button("重新载入", #selector(reloadConfig)),
                button("运行自检", #selector(runDoctor)),
            ]),
        ])
        providerAdvanced.orientation = .vertical
        providerAdvanced.alignment = .leading
        providerAdvanced.spacing = 8
        providerAdvanced.isHidden = true
        providerAdvancedSection = providerAdvanced

        gatewayColumn.isHidden = true
        gatewaySection = gatewayColumn

        let jevColumn = buildJevSection()
        let externalAgentsColumn = buildExternalAgentsSection()

        let providerToggle = button("供应商设置 ▸", #selector(toggleProviderDetails))
        let gatewayDisclosure = button("总路由网关 ▸", #selector(toggleGatewayDetails))
        let logDisclosure = button("日志 ▸", #selector(toggleLog))
        providerDetailsToggle = providerToggle
        gatewayToggle = gatewayDisclosure
        logToggle = logDisclosure
        let secondaryControls = NSStackView(views: [
            providerToggle, gatewayDisclosure, logDisclosure,
        ])
        secondaryControls.orientation = .horizontal
        secondaryControls.spacing = 8
        secondaryControls.setContentHuggingPriority(.required, for: .vertical)
        secondaryControls.setContentCompressionResistancePriority(.required, for: .vertical)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentHuggingPriority(.required, for: .vertical)
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        configureLogView()
        let logScroll = embed(logView, height: 150)
        let logSection = NSStackView(views: [sectionLabel("操作记录"), logScroll])
        logSection.orientation = .vertical
        logSection.alignment = .leading
        logSection.spacing = 6
        logSection.isHidden = true
        self.logSection = logSection

        let root = NSStackView(views: [
            pageHeading, summary, toolbar, columns, statusLabel, secondaryControls,
            jevColumn, externalAgentsColumn, providerAdvanced, gatewayColumn, logSection,
        ])
        root.orientation = .vertical
        root.distribution = .fill
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            // The hosted scroll view keeps the page's native intrinsic width;
            // this preserves a readable two-column table instead of stretching
            // every cell across a very wide display.
        ])
        window?.contentView = content
    }

    private func summaryCard(title: String, value: NSTextField, hint: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        value.font = .systemFont(ofSize: 22, weight: .bold)
        value.textColor = .labelColor
        let hintLabel = NSTextField(labelWithString: hint)
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [titleLabel, value, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let box = NSBox()
        box.boxType = .custom
        box.borderType = .lineBorder
        box.cornerRadius = 9
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        box.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        box.setContentHuggingPriority(.defaultLow, for: .horizontal)
        box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return box
    }

    private func buildJevSection() -> NSView {
        let title = sectionLabel("Jev 档位模型")
        let note = NSTextField(labelWithString: "Jev 自动选择最低够用档位；这里设置 Luna / Terra / Sol / Astra 各自实际使用的本地路由模型。保存后运行中的 Jev 服务会自动读取。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let rows: [(String, NSPopUpButton)] = [("Luna", jevLunaPopup), ("Terra", jevTerraPopup), ("Sol", jevSolPopup), ("Astra", jevAstraPopup)]
        for (_, popup) in rows {
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 250).isActive = true
        }
        let stack = NSStackView(views: rows.map { label, popup in
            let row = NSStackView(views: [labelField(label), popup])
            row.orientation = .horizontal
            row.spacing = 8
            return row
        })
        stack.orientation = .horizontal
        stack.spacing = 14
        let save = button("保存 Jev 映射", #selector(saveJevMapping))
        jevStatusLabel.font = .systemFont(ofSize: 11)
        jevStatusLabel.textColor = .secondaryLabelColor
        let root = NSStackView(views: [title, note, stack, NSStackView(views: [save, jevStatusLabel])])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 7
        root.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.7).cgColor
        card.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            root.topAnchor.constraint(equalTo: card.topAnchor),
            root.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        configureJevPopups()
        return card
    }

    private func buildExternalAgentsSection() -> NSView {
        let title = sectionLabel("检测到的外部 Agent")
        let note = NSTextField(labelWithString: "只读扫描 Codex、ZCode、OpenCode 和 Claude Code。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        externalAgentsLabel.font = .systemFont(ofSize: 11)
        externalAgentsLabel.textColor = .secondaryLabelColor
        let scanButton = button("扫描外部 Agent", #selector(discoverExternalAgents))
        let root = NSStackView(views: [title, note, NSStackView(views: [scanButton, externalAgentsLabel])])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.7).cgColor
        box.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            root.topAnchor.constraint(equalTo: box.topAnchor),
            root.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    @objc private func discoverExternalAgents() {
        runRouter(arguments: ["--discover-agents"], label: "扫描外部 Agent") { [weak self] output in
            guard let self, let payload = Self.jsonObject(in: output),
                  let agents = payload["agents"] as? [[String: Any]] else {
                self?.externalAgentsLabel.stringValue = "扫描失败"
                return
            }
            self.externalMode = true
            self.agentRows = agents.enumerated().map { index, agent in
                var row = agent
                row["id"] = "external-\(index)"
                row["name"] = agent["client"] as? String ?? "外部 Agent"
                row["provider_ids"] = [String]()
                row["external_client"] = agent["client"] as? String ?? ""
                row["external_path"] = agent["path"] as? String ?? ""
                row["external_models"] = agent["models"] as? [String] ?? []
                return row
            }
            self.agentsTable.reloadData()
            if !self.agentRows.isEmpty {
                self.agentsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                self.reloadMembers()
            }
            let summary = agents.map { agent -> String in
                let client = agent["client"] as? String ?? "未知客户端"
                let current = agent["current_model"] as? String ?? ""
                let models = (agent["models"] as? [String])?.count ?? 0
                return current.isEmpty ? "\(client)：\(models) 个模型" : "\(client)：\(current)"
            }.joined(separator: "  ·  ")
            self.externalAgentsLabel.stringValue = agents.isEmpty ? "未发现可读的外部 Agent 配置" : summary
        }
    }

    @objc private func syncExternalAgent() {
        guard !agentRows.isEmpty else { showNotice("没有 Agent", "先新增或导入一个 Agent。"); return }
        let client = NSPopUpButton(frame: .zero, pullsDown: false)
        client.addItems(withTitles: ["Codex", "ZCode", "Claude Code", "OpenCode"])
        let agent = NSPopUpButton(frame: .zero, pullsDown: false)
        agent.addItems(withTitles: agentRows.map { ($0["name"] as? String) ?? ($0["id"] as? String) ?? "Agent" })
        let path = NSTextField(string: client.indexOfSelectedItem == 0
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml").path
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zcode/v2/config.json").path)
        path.placeholderString = "客户端配置文件路径"
        externalSyncPathField = path
        client.target = self
        client.action = #selector(syncClientChanged(_:))
        let form = NSStackView(views: [
            NSStackView(views: [labelField("客户端"), client]),
            NSStackView(views: [labelField("Agent"), agent]),
            NSStackView(views: [labelField("配置"), path]),
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        let alert = NSAlert()
        alert.messageText = "同步外部 Agent"
        alert.informativeText = "会先备份目标配置，再把它指向 AI助手 的本地 Agent 网关。"
        alert.accessoryView = form
        alert.addButton(withTitle: "备份并同步")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn,
              agentRows.indices.contains(agent.indexOfSelectedItem),
              let agentID = agentRows[agent.indexOfSelectedItem]["id"] as? String else { return }
        let clientName = ["codex", "zcode", "claude", "opencode"][client.indexOfSelectedItem]
        runRouter(
            arguments: ["--sync-agent", "--sync-client", clientName, "--sync-path", path.stringValue, "--sync-agent-id", agentID],
            label: "同步 \(clientName)"
        )
    }

    @objc private func syncClientChanged(_ sender: NSPopUpButton) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            ".codex/config.toml",
            ".zcode/v2/config.json",
            ".claude/settings.json",
            ".config/opencode/opencode.json",
        ]
        guard paths.indices.contains(sender.indexOfSelectedItem) else { return }
        externalSyncPathField?.stringValue = home.appendingPathComponent(paths[sender.indexOfSelectedItem]).path
    }

    private func labelField(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        field.widthAnchor.constraint(equalToConstant: 42).isActive = true
        return field
    }

    private func configureJevPopups() {
        let modelProviders = providerRows.filter { provider in
            let model = provider["model"] as? String ?? ""
            return !model.isEmpty && provider["id"] as? String != nil
        }
        jevPopupIDs = modelProviders.compactMap { $0["id"] as? String }
        let titles = modelProviders.compactMap { provider -> String? in
            let id = provider["id"] as? String
            let model = provider["model"] as? String ?? ""
            guard let id, !id.isEmpty, !model.isEmpty else { return nil }
            return "\(model)  ·  \((provider["name"] as? String) ?? id)"
        }
        [jevLunaPopup, jevTerraPopup, jevSolPopup, jevAstraPopup].forEach {
            $0.removeAllItems()
            $0.addItem(withTitle: "未设置（使用默认）")
            $0.addItems(withTitles: titles)
        }
        let maps = store.jevModelMap
        for (tier, popup) in [("luna", jevLunaPopup), ("terra", jevTerraPopup), ("sol", jevSolPopup), ("astra", jevAstraPopup)] {
            if let id = maps[tier], let provider = providerRows.first(where: { ($0["id"] as? String) == id }),
               let model = provider["model"] as? String {
                popup.selectItem(withTitle: "\(model)  ·  \((provider["name"] as? String) ?? id)")
            }
        }
    }

    @objc private func saveJevMapping() {
        let mappings: [(String, NSPopUpButton)] = [("luna", jevLunaPopup), ("terra", jevTerraPopup), ("sol", jevSolPopup), ("astra", jevAstraPopup)]
        for (tier, popup) in mappings {
            let selected = popup.indexOfSelectedItem
            guard selected > 0, jevPopupIDs.indices.contains(selected - 1) else { continue }
            store.setJevModel(tier: tier, providerID: jevPopupIDs[selected - 1])
        }
        persist("Jev 档位模型映射已保存（Luna / Terra / Sol / Astra）")
        jevStatusLabel.stringValue = "已写入 router.json；Jev 下一次决策读取新映射。"
    }

    private func buildForm() -> NSView {
        kindPopup.addItems(withTitles: ["中转站 / OpenAI 兼容", "DSH 桥", "命令"])
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged)
        wirePopup.addItems(withTitles: ["chat_completions", "responses"])
        enabledCheck.state = .on
        for field in [nameField, timeoutField, baseURLField, modelField, apiKeyField,
                      apiKeyFileField, executableField] {
            field.font = NSFont.systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingMiddle
            field.placeholderString = field === timeoutField ? "秒" : ""
        }
        apiKeyField.placeholderString = "sk-...（留空则用下面的 Key 文件）"
        apiKeyFileField.placeholderString = "可选：一行文本的 Key 文件路径"
        baseURLField.placeholderString = "https://api.example.com/v1"
        modelField.placeholderString = "模型 id，如 gpt-6-astra"
        executableField.placeholderString = "/Applications/ChatGPT.app/Contents/Resources/codex"
        timeoutField.toolTip = "等不到回答就换下一条供应商的秒数"
        gridColumnWidths()

        let empty = NSGridCell.emptyContentView
        let grid = NSGridView(views: [
            [label("名称"), nameField, label("类型"), kindPopup],
            [label("协议"), wirePopup, label("超时(秒)"), timeoutField],
            [empty, baseURLField, empty, empty],
            [empty, modelField, empty, empty],
            [empty, apiKeyField, empty, empty],
            [empty, apiKeyFileField, empty, empty],
            [empty, executableField, empty, empty],
            [label("参数"), embed(argumentsView, height: 62), empty, empty],
            [label("启用"), enabledCheck, empty, empty],
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        for range in [(row: 2, length: 1), (row: 3, length: 1), (row: 4, length: 1),
                      (row: 5, length: 1), (row: 6, length: 1), (row: 7, length: 1)] {
            grid.mergeCells(
                inHorizontalRange: NSRange(location: 1, length: 3),
                verticalRange: NSRange(location: range.row, length: range.length)
            )
        }
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 3).xPlacement = .fill
        _ = wirePopup
        configureArgumentsView()
        return grid
    }

    private func gridColumnWidths() {
        for field in [nameField, baseURLField, modelField, apiKeyField, apiKeyFileField,
                      executableField] {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        }
        timeoutField.widthAnchor.constraint(equalToConstant: 70).isActive = true
    }

    private func configureArgumentsView() {
        argumentsView.isEditable = true
        argumentsView.isRichText = false
        argumentsView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        argumentsView.toolTip = "命令类型：每行一个参数，含空格/引号的参数原样写在一行里"
    }

    private func configureLogView() {
        logView.isEditable = false
        logView.isRichText = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    }

    private func configure(_ table: NSTableView) {
        table.headerView = NSTableHeaderView()
        table.rowHeight = 22
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self
        table.dataSource = self
    }

    private func column(_ title: String, _ width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
        column.title = title
        column.width = width
        column.minWidth = 40
        return column
    }

    private func scroll(_ table: NSTableView, height: CGFloat) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true
        scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        return scrollView
    }

    private func embed(_ textView: NSTextView, height: CGFloat) -> NSScrollView {
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true
        scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        return scrollView
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: 12)
        field.alignment = .right
        return field
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.boldSystemFont(ofSize: 12)
        return field
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    private func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return view
    }

    // MARK: 数据刷新

    private func reloadFromDisk(note: Bool = true) {
        isReloading = true
        let selectedProvider = currentProviderID
        let selectedAgent = currentAgentID
        do {
            try store.load()
        } catch {
            appendLog("读取配置失败：\(error.localizedDescription)")
        }
        store.loadStats()
        store.loadHealth()
        providerRows = store.providers
        agentRows = store.agents
        configureJevPopups()
        providersTable.reloadData()
        agentsTable.reloadData()
        restoreSelection(provider: selectedProvider, agent: selectedAgent)
        isReloading = false
        if note { appendLog("已重新载入 \(store.configURL.path)") }
        refreshStatus()
    }

    private func restoreSelection(provider: String?, agent: String?) {
        if let provider, let index = providerRows.firstIndex(where: { ($0["id"] as? String) == provider }) {
            providersTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        if let agent, let index = agentRows.firstIndex(where: { ($0["id"] as? String) == agent }) {
            agentsTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !agentRows.isEmpty {
            agentsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        reloadMembers()
        loadForm()
    }

    private func reloadMembers() {
        guard let index = selectedAgentIndex, agentRows.indices.contains(index) else {
            memberRows = []
            memberTable.reloadData()
            return
        }
        if externalMode {
            let models = (agentRows[index]["external_models"] as? [String]) ?? []
            memberRows = models.map { ["id": $0, "name": "外部配置", "model": $0, "external": true] }
            memberTable.reloadData()
            return
        }
        let ids = (agentRows[index]["provider_ids"] as? [String]) ?? []
        memberRows = ids.map { identifier in
            store.providers.first { ($0["id"] as? String) == identifier }
                ?? ["id": identifier, "name": "\(identifier)（已删除）"]
        }
        memberTable.reloadData()
    }

    private func refreshStatus() {
        let checkedAt = (store.health["checked_at"] as? String) ?? "尚未测速"
        let supplierKeys = Set(providerRows.compactMap { provider -> String? in
            if let connectionID = provider["connection_id"] as? String, !connectionID.isEmpty {
                return connectionID
            }
            guard let name = provider["name"] as? String, !name.isEmpty else { return nil }
            return name.components(separatedBy: " · ").first ?? name
        })
        connectedSummary.stringValue = "\(supplierKeys.count)"
        modelSummary.stringValue = "\(providerRows.count)"
        // Connection health is the denominator. Legacy/local command routes do
        // not have an HTTP connection and must not turn the badge into "1 / 0".
        let checks = store.health["connections"] as? [String: [String: Any]] ?? [:]
        // Ignore health entries left over from a temporary/self-test config.
        let activeChecks = store.connections.compactMap { connection -> [String: Any]? in
            guard let id = connection["id"] as? String else { return nil }
            return checks["connection:\(id)"]
        }
        let online = activeChecks.filter { ($0["ok"] as? Bool) == true }
        onlineSummary.stringValue = "\(online.count) / \(store.connections.count)"
        let latencies = online.compactMap { ($0["latency_ms"] as? NSNumber)?.doubleValue }
        latencySummary.stringValue = latencies.isEmpty ? "—" : "\(Int((latencies.reduce(0, +) / Double(latencies.count)).rounded())) ms"
        statusLabel.stringValue = "\(providerRows.count) 个模型 · \(store.connections.count) 个 API 连接 · \(agentRows.count) 个 Agent"
            + " · 助手默认：\(store.assistantAgentLabel) · 最近测速：\(checkedAt)"
    }

    private func persist(_ note: String) {
        do {
            try store.save()
            appendLog(note)
        } catch {
            appendLog("保存失败：\(error.localizedDescription)")
        }
        providerRows = store.providers
        agentRows = store.agents
        providersTable.reloadData()
        agentsTable.reloadData()
        restoreSelection(provider: currentProviderID, agent: currentAgentID)
        refreshStatus()
    }

    private var selectedProviderIndex: Int? {
        let row = providersTable.selectedRow
        return providerRows.indices.contains(row) ? row : nil
    }

    private var selectedAgentIndex: Int? {
        let row = agentsTable.selectedRow
        return agentRows.indices.contains(row) ? row : nil
    }

    private var currentProviderID: String? {
        selectedProviderIndex.flatMap { providerRows[$0]["id"] as? String }
    }

    private var currentAgentID: String? {
        selectedAgentIndex.flatMap { agentRows[$0]["id"] as? String }
    }

    // MARK: 表单

    private func loadForm() {
        guard let index = selectedProviderIndex else { return }
        let provider = store.resolvedProvider(at: index) ?? providerRows[index]
        let connectionID = (provider["connection_id"] as? String) ?? ""
        nameField.stringValue = connectionID.isEmpty
            ? ((provider["name"] as? String) ?? "")
            : store.connectionName(id: connectionID)
        let kind = (provider["kind"] as? String) ?? "openai_compatible"
        kindPopup.selectItem(at: max(kinds.firstIndex(of: kind) ?? 0, 0))
        enabledCheck.state = ((provider["enabled"] as? Bool) ?? true) ? .on : .off
        let wire = (provider["wire_api"] as? String) ?? "chat_completions"
        wirePopup.selectItem(at: max(wires.firstIndex(of: wire) ?? 0, 0))
        let timeout = (provider["timeout_seconds"] as? NSNumber)?.stringValue ?? "120"
        timeoutField.stringValue = timeout
        baseURLField.stringValue = (provider["base_url"] as? String) ?? ""
        modelField.stringValue = (provider["model"] as? String) ?? ""
        apiKeyField.stringValue = (provider["api_key"] as? String) ?? ""
        apiKeyFileField.stringValue = (provider["api_key_file"] as? String) ?? ""
        executableField.stringValue = (provider["executable"] as? String) ?? ""
        let arguments = (provider["arguments"] as? [String]) ?? []
        argumentsView.string = arguments.joined(separator: "\n")
        updateFieldAvailability()
    }

    @objc private func kindChanged() {
        updateFieldAvailability()
    }

    private func updateFieldAvailability() {
        let kind = kinds[max(kindPopup.indexOfSelectedItem, 0)]
        let isCommand = kind == "command"
        let isHTTP = kind == "openai_compatible"
        executableField.isEnabled = isCommand
        argumentsView.isEditable = isCommand
        baseURLField.isEnabled = isHTTP
        modelField.isEnabled = isHTTP
        wirePopup.isEnabled = isHTTP
        apiKeyField.isEnabled = isHTTP
        apiKeyFileField.isEnabled = isHTTP
        if kind == "dsh_bridge" {
            baseURLField.stringValue = ""
            modelField.stringValue = ""
        }
    }

    // MARK: 按钮动作

    @objc private func toggleProviderDetails(_ sender: NSButton) {
        guard let section = providerAdvancedSection else { return }
        section.isHidden.toggle()
        sender.title = section.isHidden ? "供应商设置 ▸" : "供应商设置 ▾"
    }

    @objc private func toggleGatewayDetails(_ sender: NSButton) {
        guard let section = gatewaySection else { return }
        section.isHidden.toggle()
        sender.title = section.isHidden ? "总路由网关 ▸" : "总路由网关 ▾"
    }

    @objc private func toggleLog(_ sender: NSButton) {
        guard let section = logSection else { return }
        section.isHidden.toggle()
        sender.title = section.isHidden ? "日志 ▸" : "日志 ▾"
    }

    /// 选单上的前缀：谁明确不能用、谁还没试过，摆到名字前面，
    /// 免得把一条 401 的线路加进故障转移顺序，每次请求白等一轮。
    private func autoPickPrefix(for provider: [String: Any]) -> String {
        guard let identifier = provider["id"] as? String else { return "" }
        if let receipt = HubReceiptLedger.shared.receipt(for: identifier) {
            if receipt.excludesFromAutoPick {
                let code = receipt.httpCode.map { " HTTP \($0)" } ?? ""
                return "[不自动挑 · \(receipt.outcomeLabel)\(code)] "
            }
            return "[可用] "
        }
        return HubReceiptLedger.shared.isTracked(identifier) ? "[还没试过] " : ""
    }

    @objc private func addMember() {
        guard let agentIndex = selectedAgentIndex else {
            showNotice("先选择一个 Agent", "在右侧 Agent 列表中选择目标 Agent，再添加模型。")
            return
        }
        let existing = Set(externalMode
            ? ((agentRows[agentIndex]["external_models"] as? [String]) ?? [])
            : ((agentRows[agentIndex]["provider_ids"] as? [String]) ?? []))
        let candidates = providerRows.filter { !existing.contains(($0["id"] as? String) ?? "") }
        guard !candidates.isEmpty else {
            showNotice("没有可添加的模型", providerRows.isEmpty
                ? "请先新增供应商并填写模型，或导入已有线路。"
                : "模型库中的项目已全部添加到这个 Agent。")
            return
        }

        let labels = candidates.map { provider -> String in
            let name = (provider["name"] as? String) ?? (provider["id"] as? String) ?? "未命名"
            let model = (provider["model"] as? String) ?? ""
            let detail = model.isEmpty ? kindLabel(provider) : model
            return "\(autoPickPrefix(for: provider))\(name)  ·  \(detail)"
        }
        let excluded = candidates.filter { provider in
            guard let identifier = provider["id"] as? String else { return false }
            return HubReceiptLedger.shared.receipt(for: identifier)?.excludesFromAutoPick == true
        }.count
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        picker.addItems(withTitles: labels)

        let alert = NSAlert()
        alert.messageText = "添加模型到 Agent"
        alert.informativeText = "模型会追加到故障转移顺序末尾，并立即保存。供应商配置只保存一份，修改后自动同步。"
            + (excluded > 0
               ? "其中 \(excluded) 条有网关真实失败回执（如 HTTP 401 密钥被拒），已标成「不自动挑」："
                 + "混进故障转移顺序只会让每次请求多等一轮，修好并成功调用一次就会自动解除。"
               : "")
        alert.accessoryView = picker
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn,
              candidates.indices.contains(picker.indexOfSelectedItem),
              let identifier = candidates[picker.indexOfSelectedItem]["id"] as? String else { return }

        let agentName = (agentRows[agentIndex]["name"] as? String) ?? "Agent"
        if externalMode {
            guard let client = agentRows[agentIndex]["external_client"] as? String,
                  let path = agentRows[agentIndex]["external_path"] as? String,
                  let provider = store.resolvedProvider(at: providerRows.firstIndex(where: { ($0["id"] as? String) == identifier }) ?? -1),
                  let model = provider["model"] as? String, !model.isEmpty else {
                showNotice("该 Agent 暂不支持自动写入", "当前客户端配置无法识别，先只读展示。")
                return
            }
            let lower = client.lowercased()
            let clientID: String?
            if lower.contains("codex") {
                clientID = "codex"
            } else if lower.contains("zcode") {
                clientID = "zcode"
            } else if lower.contains("claude") {
                clientID = "claude"
            } else if lower.contains("opencode") {
                clientID = "opencode"
            } else {
                clientID = nil
            }
            guard let clientID else {
                showNotice("该 Agent 暂不支持自动写入", "客户端类型未注册，先只读展示。")
                return
            }
            let args = [
                "--add-agent-model", "--sync-client", clientID, "--sync-path", path,
                "--sync-agent-id", agentName, "--model", model,
                "--provider-id", identifier,
            ]
            runRouter(arguments: args, label: "添加 (model) 到 (agentName)") { [weak self] _ in
                guard let self else { return }
                var row = self.agentRows[agentIndex]
                var models = (row["external_models"] as? [String]) ?? []
                if !models.contains(model) { models.append(model) }
                row["external_models"] = models
                self.agentRows[agentIndex] = row
                self.reloadMembers()
            }
            return
        }
        guard store.assign(providerID: identifier, toAgentAt: agentIndex) else {
            showNotice("模型已存在", "这个模型已经在所选 Agent 的列表中。")
            return
        }
        persist("已将 \(identifier) 添加到 Agent「\(agentName)」并同步保存")
    }

    private func showNotice(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func importDSH() {
        runRouter(
            arguments: ["--import-dsh"],
            label: "导入 DSH 配置",
            reloadAfter: true
        )
    }

    /// 一键把本地已有的线路全部拉进供应商池：DSH + Codex 配置。
    /// 选中的 Agent 会被同步加上这些线路，拖拽之外的批量入口。
    @objc private func importAllSources() {
        var arguments = ["--import", "all"]
        if let index = selectedAgentIndex, let identifier = agentRows[index]["id"] as? String {
            arguments += ["--agent-target", identifier]
        }
        runRouter(
            arguments: arguments,
            label: "导入全部线路",
            reloadAfter: true
        )
    }

    // MARK: 总路由网关

    @objc private func refreshGateway() {
        gatewayPortField.stringValue = String(store.gatewayPort)
        runRouter(arguments: ["--gateway-info"], label: "读取网关信息") { [weak self] output in
            guard let self, let info = Self.jsonObject(in: output) else {
                self?.appendLog("没能解析网关信息，看上面的原始输出。")
                return
            }
            let base = (info["base_url"] as? String) ?? ""
            let agent = (info["resolved_agent"] as? String) ?? ""
            let count = (info["providers"] as? [Any])?.count ?? 0
            self.gatewayInfoLabel.stringValue =
                "\(base) → Agent「\(agent)」（\(count) 条线路）"
            self.gatewayKeyField.stringValue = (info["api_key"] as? String) ?? ""
            self.gatewaySnippets = [
                "codex": (info["codex_snippet"] as? String) ?? "",
                "claude": (info["claude_snippet"] as? String) ?? "",
            ]
        }
    }

    @objc private func setGatewayAgentDefault() {
        guard let index = selectedAgentIndex,
              let identifier = agentRows[index]["id"] as? String else {
            appendLog("先在右侧 Agent 列表里选一个，再设为网关默认。")
            return
        }
        store.setGatewayAgent(id: identifier)
        persist("所有指向网关的客户端现在默认走 Agent「\(identifier)」")
        refreshGateway()
    }

    @objc private func saveGatewaySecret() {
        let portText = gatewayPortField.stringValue.trimmingCharacters(in: .whitespaces)
        if let port = Int(portText), port > 0, port < 65536 {
            store.setGatewayPort(port)
        } else if !portText.isEmpty {
            appendLog("端口要填 1-65535 的数字。")
            return
        }
        let key = gatewayKeyField.stringValue.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
            store.setGatewayKey(key)
        }
        persist("网关设置已写入（端口 \(store.gatewayPort)）")
        refreshGateway()
    }

    @objc private func startGateway() {
        guard gatewayProcess == nil else {
            appendLog("网关已经在运行。点「停止网关」再重启。")
            return
        }
        let launchPort = RouterStore.gatewayLaunchPort(
            fieldText: gatewayPortField.stringValue,
            saved: store.gatewayPort
        )
        if RouterStore.gatewayLaunchdManaged(port: launchPort.port) {
            if RouterStore.kickGatewayLaunchd() {
                appendLog("4230 已由 launchd 托管，已请求启动 / 恢复；不再启动第二个 Python 进程。")
            } else {
                appendLog("无法启动 launchd 网关：请重新运行 AI助手安装器。")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.refreshGateway()
            }
            return
        }
        guard let script = RouterStore.scriptURL else {
            appendLog("找不到 unified_router.py：先运行 ./install.command。")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // 界面上填的端口 + 当前的网关 Agent 都当场传；脚本只当本次运行的临时监听覆盖，
        // 不写回 router.json——所以「端口错了要保存两次」这类坑不会发生。
        let launch = launchPort
        process.arguments = RouterStore.gatewayLaunchArguments(
            script: script,
            port: launch.port,
            agentID: store.gatewayAgentID
        )
        var environment = ProcessInfo.processInfo.environment
        environment["LOCAL_SIRI_ROUTER_CONFIG"] = store.configURL.path
        environment["LOCAL_SIRI_ROUTER_STATS"] = store.statsURL.path
        environment["LOCAL_SIRI_ROUTER_HEALTH"] = store.healthURL.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.appendLog(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.gatewayProcess = nil
                self.appendLog("网关已退出（退出码 \(finished.terminationStatus)）。")
            }
        }
        do {
            try process.run()
            gatewayProcess = process
            if let note = launch.note { appendLog(note) }
            appendLog("网关启动中：http://127.0.0.1:\(launch.port)/v1")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.refreshGateway()
            }
        } catch {
            appendLog("网关启动失败：\(error.localizedDescription)")
        }
    }

    @objc private func stopGateway() {
        let stopPort = RouterStore.gatewayLaunchPort(
            fieldText: gatewayPortField.stringValue,
            saved: store.gatewayPort
        ).port
        if RouterStore.gatewayLaunchdManaged(port: stopPort) {
            if RouterStore.stopGatewayLaunchd() {
                appendLog("已停止 launchd 网关；再次点击「启动网关」可恢复。")
            } else {
                appendLog("launchd 网关当前未加载，或停止失败。")
            }
            gatewayProcess = nil
            return
        }
        guard let process = gatewayProcess else {
            appendLog("网关没在运行。")
            return
        }
        gatewayProcess = nil
        process.terminate()
        appendLog("已停止网关。")
    }

    @objc private func copyCodexSnippet() {
        copyToPasteboard(gatewaySnippets["codex"] ?? "", what: "Codex 接入片段")
    }

    @objc private func copyClaudeSnippet() {
        copyToPasteboard(gatewaySnippets["claude"] ?? "", what: "Claude 接入片段")
    }

    private func copyToPasteboard(_ text: String, what: String) {
        guard !text.isEmpty else {
            appendLog("还没有片段，先点「刷新网关」。")
            return
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        appendLog("\(what)已复制：\n\(text)")
    }

    private static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    @objc private func addProvider() {
        let alert = NSAlert()
        alert.messageText = "新增供应商并读取模型"
        alert.informativeText = "填写 Base URL 和 API Key；AI助手只请求模型列表，不会发送生成请求。"
        alert.addButton(withTitle: "读取模型")
        alert.addButton(withTitle: "取消")
        let name = NSTextField(string: "")
        name.placeholderString = "供应商名称，例如 DeepSeek"
        let baseURL = NSTextField(string: "")
        baseURL.placeholderString = "https://api.example.com/v1"
        let apiKey = NSSecureTextField(string: "")
        apiKey.placeholderString = "API Key（只保存在本机）"
        let wire = NSPopUpButton(frame: .zero, pullsDown: false)
        wire.addItems(withTitles: ["chat_completions", "responses"])

        func row(_ title: String, _ view: NSView) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 78).isActive = true
            view.widthAnchor.constraint(equalToConstant: 330).isActive = true
            let row = NSStackView(views: [label, view])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            return row
        }
        let form = NSStackView(views: [
            row("名称", name), row("Base URL", baseURL), row("API Key", apiKey), row("协议", wire),
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.frame = NSRect(x: 0, y: 0, width: 420, height: 132)
        alert.accessoryView = form
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmedName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else {
            showNotice("信息不完整", "供应商名称和 Base URL 都要填写。")
            return
        }
        let request: [String: Any] = [
            "base_url": trimmedURL,
            "api_key": apiKey.stringValue,
            "wire_api": wire.indexOfSelectedItem == 1 ? "responses" : "chat_completions",
        ]
        guard let input = try? JSONSerialization.data(withJSONObject: request),
              let inputText = String(data: input, encoding: .utf8) else {
            showNotice("请求无法编码", "请检查 URL 和输入内容后重试。")
            return
        }
        runRouter(
            arguments: ["--fetch-models"],
            standardInput: inputText,
            label: "读取 \(trimmedName) 的模型列表"
        ) { [weak self] output in
            guard let self, let result = Self.jsonObject(in: output) else {
                self?.showNotice("读取失败", "供应商没有返回可解析的模型列表。可用「手动添加单模型」继续。")
                return
            }
            guard (result["ok"] as? Bool) == true,
                  let models = result["models"] as? [[String: Any]], !models.isEmpty else {
                self.showNotice("无法读取模型", (result["error"] as? String) ?? "该 URL 不支持 OpenAI 兼容的 /models 接口；可手动添加单模型。")
                return
            }
            self.chooseModels(
                name: trimmedName,
                baseURL: trimmedURL,
                apiKey: apiKey.stringValue,
                wireAPI: request["wire_api"] as? String ?? "chat_completions",
                models: models,
                probe: result
            )
        }
    }

    private func chooseModels(name: String, baseURL: String, apiKey: String,
                              wireAPI: String, models: [[String: Any]], probe: [String: Any]) {
        let buttons: [(String, NSButton)] = models.compactMap { model in
            guard let id = model["id"] as? String, !id.isEmpty else { return nil }
            let owner = (model["owned_by"] as? String) ?? ""
            let label = owner.isEmpty ? id : "\(id)  ·  \(owner)"
            let check = NSButton(checkboxWithTitle: label, target: nil, action: nil)
            check.state = .off
            return (id, check)
        }
        guard !buttons.isEmpty else {
            showNotice("没有可选模型", "该供应商的 /models 响应里没有模型 ID。")
            return
        }
        let rows = buttons.map { $0.1 }
        let list = NSStackView(views: rows)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: CGFloat(buttons.count * 28)))
        document.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: min(360, max(140, CGFloat(buttons.count * 28)))))
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let alert = NSAlert()
        alert.messageText = "选择要加入本地路由的模型"
        let latency = (probe["latency_ms"] as? NSNumber)?.intValue
        alert.informativeText = "\(name)：\(models.count) 个模型 · \(latency.map { "\($0) ms" } ?? "已连通")。只勾选常用模型；之后可逐个添加到 Agent。"
        alert.accessoryView = scroll
        alert.addButton(withTitle: "添加已选模型")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selected = buttons.compactMap { $0.1.state == .on ? $0.0 : nil }
        guard !selected.isEmpty else {
            showNotice("尚未选择模型", "至少勾选一个模型，才会把供应商加入本地路由。")
            return
        }
        let connectionID = store.addConnection(
            name: name,
            baseURL: baseURL,
            apiKey: apiKey,
            wireAPI: wireAPI,
            catalog: models,
            selectedModelIDs: selected
        )
        store.recordHealth(connectionID: connectionID, probe: probe)
        persist("已添加供应商 \(name) · \(selected.count) 个模型（\(connectionID)）")
    }

    @objc private func addManualProvider() {
        let alert = NSAlert()
        alert.messageText = "手动添加单模型"
        alert.informativeText = "适用于没有开放 /models 列表的 API。"
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "供应商和模型名称"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let index = store.addProvider(name: field.stringValue.trimmingCharacters(in: .whitespaces))
        persist("已新增手动模型 \(store.providerID(at: index) ?? "")")
        providersTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        loadForm()
        if let providerAdvancedSection, providerAdvancedSection.isHidden {
            providerAdvancedSection.isHidden = false
            providerDetailsToggle?.title = "供应商设置 ▾"
        }
    }

    @objc private func probeAllConnections() {
        runRouter(arguments: ["--probe-all-connections"], label: "测速所有 HTTP 线路", timeout: 300,
                  reloadAfter: true) { [weak self] output in
            guard let self, let result = Self.jsonObject(in: output),
                  let checks = result["providers"] as? [String: [String: Any]] else { return }
            let connected = checks.values.filter { ($0["ok"] as? Bool) == true }.count
            self.appendLog("连通探测完成：\(connected) 条 HTTP 线路可连接；只请求 /models，未发送生成请求。")
        }
    }

    @objc private func removeProvider() {
        guard let index = selectedProviderIndex else { return }
        let provider = providerRows[index]
        let identifier = (provider["id"] as? String) ?? ""
        let users = agentRows.filter { (($0["provider_ids"] as? [String]) ?? []).contains(identifier) }
            .compactMap { $0["name"] as? String }
        let alert = NSAlert()
        alert.messageText = "删除供应商「\((provider["name"] as? String) ?? identifier)」？"
        alert.informativeText = users.isEmpty
            ? "它没有被任何 Agent 使用。"
            : "同时会从这些 Agent 下移除：\(users.joined(separator: "、"))"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.removeProvider(at: index)
        persist("已删除供应商 \(identifier)")
    }

    @objc private func addAgent() {
        let alert = NSAlert()
        alert.messageText = "新增 Agent"
        alert.informativeText = "名称（例如 编码、写作、语音助手）："
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Agent 名称"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let index = store.addAgent(name: field.stringValue.trimmingCharacters(in: .whitespaces))
        persist("已新增 Agent \(store.agentID(at: index) ?? "")")
        agentsTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        reloadMembers()
    }

    @objc private func removeAgent() {
        guard let index = selectedAgentIndex else { return }
        let agent = agentRows[index]
        let alert = NSAlert()
        alert.messageText = "删除 Agent「\((agent["name"] as? String) ?? "")」？"
        alert.informativeText = "供应商本身不会被删除，只是解除这个 Agent 的引用。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let identifier = (agent["id"] as? String) ?? ""
        store.removeAgent(at: index)
        persist("已删除 Agent \(identifier)")
    }

    @objc private func reloadConfig() {
        reloadFromDisk()
    }

    /// 语音助手的云端通道没有命令行参数，只能靠 router.json 里的 assistant_agent。
    @objc private func setAssistantAgentDefault() {
        guard let index = selectedAgentIndex,
              let identifier = agentRows[index]["id"] as? String else {
            appendLog("先在右侧 Agent 列表里选一个，再设为助手默认。")
            return
        }
        store.setAssistantAgent(id: identifier)
        persist("语音助手默认 Agent 已设为 \(identifier)")
    }

    @objc private func saveProviderEdits() {
        guard let index = selectedProviderIndex else {
            appendLog("先在上面的供应商池里选一条再保存。")
            return
        }
        let connectionID = providerRows[index]["connection_id"] as? String ?? ""
        if !connectionID.isEmpty {
            store.updateConnection(id: connectionID, with: [
                "name": nameField.stringValue.trimmingCharacters(in: .whitespaces),
                "base_url": baseURLField.stringValue.trimmingCharacters(in: .whitespaces),
                "api_key": apiKeyField.stringValue.trimmingCharacters(in: .whitespaces),
                "wire_api": wires[max(wirePopup.indexOfSelectedItem, 0)],
            ])
            store.updateProvider(at: index, with: [
                "enabled": enabledCheck.state == .on,
                "model": modelField.stringValue.trimmingCharacters(in: .whitespaces),
            ])
            persist("已保存连接 \(connectionID)（该供应商的所有模型同步生效）")
            return
        }

        var fields: [String: Any] = [
            "name": nameField.stringValue.trimmingCharacters(in: .whitespaces),
            "kind": kinds[max(kindPopup.indexOfSelectedItem, 0)],
            "enabled": enabledCheck.state == .on,
            "wire_api": wires[max(wirePopup.indexOfSelectedItem, 0)],
            "base_url": baseURLField.stringValue.trimmingCharacters(in: .whitespaces),
            "model": modelField.stringValue.trimmingCharacters(in: .whitespaces),
            "api_key": apiKeyField.stringValue.trimmingCharacters(in: .whitespaces),
            "api_key_file": apiKeyFileField.stringValue.trimmingCharacters(in: .whitespaces),
            "executable": executableField.stringValue.trimmingCharacters(in: .whitespaces),
        ]
        let arguments = argumentsView.string
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        fields["arguments"] = arguments
        if let timeout = Double(timeoutField.stringValue.trimmingCharacters(in: .whitespaces)) {
            fields["timeout_seconds"] = timeout
        }
        store.updateProvider(at: index, with: fields)
        let identifier = providerRows[index]["id"] as? String ?? ""
        persist("已保存供应商 \(identifier)（引用它的 Agent 已同步）")
    }

    @objc private func testSelectedProvider() {
        guard let index = selectedProviderIndex,
              let identifier = providerRows[index]["id"] as? String else {
            appendLog("先选一条供应商再测试。")
            return
        }
        runRouter(
            arguments: ["--provider", identifier],
            standardInput: "只回复一句话：连接正常。\n",
            label: "测试 \(identifier)",
            timeout: 120,
            reloadAfter: true
        )
    }

    @objc private func runDoctor() {
        runRouter(arguments: ["--doctor"], label: "doctor")
    }

    @objc private func removeMember() {
        guard let agentIndex = selectedAgentIndex, let identifier = currentMemberID else { return }
        store.removeProvider(identifier, fromAgentAt: agentIndex)
        persist("已从该 Agent 移除 \(identifier)")
    }

    @objc private func moveMemberUp() {
        moveMember(by: -1)
    }

    @objc private func moveMemberDown() {
        moveMember(by: 1)
    }

    private var currentMemberID: String? {
        let row = memberTable.selectedRow
        guard memberRows.indices.contains(row) else { return nil }
        return memberRows[row]["id"] as? String
    }

    private func moveMember(by offset: Int) {
        guard let agentIndex = selectedAgentIndex, let memberID = currentMemberID,
              let from = memberRows.firstIndex(where: { ($0["id"] as? String) == memberID }) else {
            return
        }
        let target = from + offset
        guard target >= 0, target < memberRows.count else { return }
        isReloading = true
        store.moveProvider(inAgentAt: agentIndex, from: from, to: target)
        isReloading = false
        persist("已调整顺序（越靠前越先尝试）")
        memberTable.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
    }

    // MARK: 运行 Python 路由

    private func runRouter(
        arguments: [String],
        standardInput: String? = nil,
        label: String,
        timeout: TimeInterval = RouterManagerWindowController.defaultRunTimeout,
        reloadAfter: Bool = false,
        completion: ((String) -> Void)? = nil
    ) {
        guard let script = RouterStore.scriptURL else {
            appendLog("找不到 unified_router.py：先运行 ./install.command，或在开发目录下构建。")
            return
        }
        appendLog("$ python3 \(script.lastPathComponent) \(redactedArguments(arguments).joined(separator: " "))")
        statusLabel.stringValue = "\(label)…"
        var environment = ProcessInfo.processInfo.environment
        environment["LOCAL_SIRI_ROUTER_CONFIG"] = store.configURL.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path] + arguments
            process.environment = environment
            let input = Pipe()
            let output = Pipe()
            let error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            var result = ""
            var timedOut = false
            do {
                try process.run()
                if let standardInput {
                    input.fileHandleForWriting.write(Data(standardInput.utf8))
                }
                input.fileHandleForWriting.closeFile()
                // 没有看门狗的话，慢探针会让这次运行永远停在「进行中」，
                // 界面上就留下一条要手删的记录。超时就终止进程并如实报告。
                let started = Date()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    timedOut = true
                    process.terminate()
                }
                let outData = output.fileHandleForReading.readDataToEndOfFile()
                let errData = error.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let elapsed = Date().timeIntervalSince(started)
                if process.terminationReason == .uncaughtSignal, elapsed >= timeout - 1 {
                    timedOut = true
                }
                result = String(data: outData, encoding: .utf8) ?? ""
                let errorText = (String(data: errData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !errorText.isEmpty {
                    result += (result.isEmpty ? "" : "\n") + "[stderr] " + errorText
                }
                if timedOut {
                    result += "\n[已超时 \(Int(timeout)) 秒并已终止：没有写回半成品配置，可以重试或换一条线路]"
                }
                result += "\n[退出码 \(process.terminationStatus)]"
            } catch {
                result = "启动失败：\(error.localizedDescription)"
            }
            let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self else { return }
                self.appendLog(text.isEmpty ? "(无输出)" : text)
                if reloadAfter { self.reloadFromDisk(note: false) }
                self.statusLabel.stringValue = "\(label)完成"
                completion?(text)
            }
        }
    }

    /// 子进程参数会出现在 UI 日志里；密钥只能留在受保护的 router.json/环境中。
    private func redactedArguments(_ arguments: [String]) -> [String] {
        var result = arguments
        for index in result.indices where result[index] == "--provider-key" {
            let value = index + 1
            if result.indices.contains(value) { result[value] = "（已隐藏）" }
        }
        return result
    }

    private func appendLog(_ text: String) {
        let line = text.hasSuffix("\n") ? text : text + "\n"
        logView.string += line
        logView.scrollToEndOfDocument(nil)
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView {
        case providersTable: return providerRows.count
        case agentsTable: return agentRows.count
        case memberTable: return memberRows.count
        default: return 0
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let index = tableView.tableColumns.firstIndex { $0.identifier == tableColumn?.identifier } ?? 0
        var text = ""
        var color = NSColor.labelColor
        var toolTip = ""
        if tableView === providersTable {
            guard providerRows.indices.contains(row) else { return nil }
            let provider = providerRows[row]
            switch index {
            case 0:
                let enabled = (provider["enabled"] as? Bool) ?? true
                text = enabled ? "✓" : "✗"
                color = enabled ? .systemGreen : .secondaryLabelColor
            case 1:
                let connectionID = (provider["connection_id"] as? String) ?? ""
                let name = connectionID.isEmpty
                    ? ((provider["name"] as? String) ?? "")
                    : store.connectionName(id: connectionID)
                let identifier = (provider["id"] as? String) ?? ""
                text = name.isEmpty ? identifier : name
            case 2:
                text = (provider["model"] as? String) ?? "—"
            case 3:
                text = kindLabel(provider)
                color = .secondaryLabelColor
            default:
                let identifier = (provider["id"] as? String) ?? ""
                let checks = store.health["providers"] as? [String: [String: Any]] ?? [:]
                let check = checks[identifier] ?? [:]
                if (check["status"] as? String) == "local" {
                    text = "本地"
                    color = .secondaryLabelColor
                } else if (check["ok"] as? Bool) == true {
                    let latency = (check["latency_ms"] as? NSNumber)?.intValue
                    text = latency.map { "● \($0)ms" } ?? "● 已通"
                    color = .systemGreen
                } else if (check["ok"] as? Bool) == false {
                    text = "● 不通"
                    color = .systemRed
                    toolTip = (check["error"] as? String) ?? "连接失败"
                } else {
                    text = "○ 待测"
                    color = .secondaryLabelColor
                }
            }
        } else if tableView === agentsTable {
            guard agentRows.indices.contains(row) else { return nil }
            let agent = agentRows[row]
            if index == 0 {
                let name = (agent["name"] as? String) ?? ""
                let assistant = (agent["id"] as? String) == store.assistantAgentID
                let count = externalMode
                    ? ((agent["external_models"] as? [String])?.count ?? 0)
                    : ((agent["provider_ids"] as? [String])?.count ?? 0)
                let current = externalMode ? " · 配置：\((agent["current_model"] as? String) ?? "未指定")" : ""
                text = "\(name)  ·  \(count) 个模型\(current)" + (assistant ? "  ·  助手默认" : "")
                if assistant { color = .systemBlue }
            } else {
                let ids = (agent["provider_ids"] as? [String]) ?? []
                let modelCount = ids.filter { identifier in
                    guard let provider = store.providers.first(where: { ($0["id"] as? String) == identifier }) else {
                        return false
                    }
                    return !(provider["kind"] as? String == "dsh_bridge")
                        && !(provider["model"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }.count
                let bridgeCount = max(0, ids.count - modelCount)
                text = ids.isEmpty
                    ? "（空：把左侧供应商拖进来）"
                    : "\(modelCount) 个模型" + (bridgeCount > 0 ? " + \(bridgeCount) 个执行桥" : "")
                        + "： " + ids.map { store.providerName(id: $0) }.joined(separator: "  →  ")
                if ids.isEmpty { color = .secondaryLabelColor }
            }
        } else if tableView === memberTable {
            guard memberRows.indices.contains(row) else { return nil }
            if index == 0 {
                text = "\(row + 1)"
                color = .secondaryLabelColor
            } else {
                let provider = memberRows[row]
                let name = (provider["name"] as? String) ?? ""
                let model = (provider["model"] as? String) ?? ""
                let connectionID = (provider["connection_id"] as? String) ?? ""
                let sourceName = connectionID.isEmpty ? name : store.connectionName(id: connectionID)
                let priority = row == 0 ? "当前" : "备选 \(row)"
                text = model.isEmpty
                    ? "\(priority)  ·  \(sourceName)  ·  \(kindLabel(provider))"
                    : "\(priority)  ·  \(model)  ·  \(sourceName)"
                // External config rows are intentionally read-only snapshots and
                // do not carry the local router's base_url/kind fields.
                if provider["external"] as? Bool == true {
                    color = .secondaryLabelColor
                } else if provider["base_url"] == nil, provider["kind"] == nil {
                    color = .systemRed
                }
            }
        }
        let field = reusableCell(tableView)
        field.stringValue = text
        field.textColor = color
        field.toolTip = toolTip.isEmpty ? nil : toolTip
        field.font = index >= 2 && tableView !== agentsTable
            ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            : NSFont.systemFont(ofSize: 12)
        return field
    }

    private func reusableCell(_ tableView: NSTableView) -> NSTextField {
        let identifier = NSUserInterfaceItemIdentifier("router-cell")
        if let field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            return field
        }
        let field = NSTextField(labelWithString: "")
        field.identifier = identifier
        field.lineBreakMode = .byTruncatingTail
        field.font = NSFont.systemFont(ofSize: 12)
        return field
    }

    private func kindLabel(_ provider: [String: Any]) -> String {
        switch (provider["kind"] as? String) ?? "" {
        case "dsh_bridge": return "DSH 桥"
        case "command": return "命令"
        case "openai_compatible", "openai-compatible", "http":
            let wire = (provider["wire_api"] as? String) ?? "chat_completions"
            return wire == "responses" ? "中转站 · responses" : "中转站 · chat"
        default: return (provider["kind"] as? String) ?? "未设置"
        }
    }

    /// 直接用 router-stats.json 里的真实数字：成功次数 / 尝试次数 + 最近一次失败原因。
    private func statsLabel(_ provider: [String: Any]) -> (String, NSColor) {
        guard let identifier = provider["id"] as? String else { return ("— 未使用", .secondaryLabelColor) }
        // 网关有真实回执就照它说：状态码 + 服务方原话，比「未使用」有用得多。
        if let receipt = HubReceiptLedger.shared.receipt(for: identifier) {
            let code = receipt.httpCode.map { "HTTP \($0) · \(receipt.outcomeLabel)" } ?? receipt.outcomeLabel
            let message = receipt.providerMessage.isEmpty ? "" : " · \(receipt.providerMessage)"
            return ("\(receipt.successRateText) · \(code)\(message)",
                    receipt.excludesFromAutoPick ? .systemRed : .systemGreen)
        }
        guard let entry = store.stats[identifier],
              let attempts = (entry["attempts"] as? NSNumber)?.intValue, attempts > 0 else {
            return ("还没试过", .secondaryLabelColor)
        }
        let successes = (entry["successes"] as? NSNumber)?.intValue ?? 0
        let rate = Int((Double(successes) / Double(attempts) * 100).rounded())
        let error = ((entry["last_error"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = error.isEmpty
            ? "成功 \(successes)/\(attempts) 次 · \(rate)%"
            : "成功 \(successes)/\(attempts) 次 · \(rate)% · \(error)"
        return (text, successes == attempts ? .systemGreen : .systemOrange)
    }

    private func detailLabel(_ provider: [String: Any]) -> String {
        if let executable = provider["executable"] as? String, !executable.isEmpty {
            return executable
        }
        if (provider["kind"] as? String) == "dsh_bridge" {
            return "由 DSH 客户端桥接"
        }
        let model = (provider["model"] as? String) ?? "（缺模型）"
        let base = (provider["base_url"] as? String) ?? "（缺地址）"
        return "\(model) @ \(base)"
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        if (notification.object as? NSTableView) === agentsTable {
            reloadMembers()
        } else if (notification.object as? NSTableView) === providersTable {
            loadForm()
        }
    }

    // MARK: 拖拽

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tableView === providersTable, providerRows.indices.contains(row),
              let identifier = providerRows[row]["id"] as? String else {
            return nil
        }
        let item = NSPasteboardItem()
        item.setString(identifier, forType: Self.providerDragType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard tableView === agentsTable,
              info.draggingPasteboard.string(forType: Self.providerDragType) != nil else {
            return []
        }
        tableView.setDropRow(row, dropOperation: .on)
        return .copy
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard tableView === agentsTable,
              let identifier = info.draggingPasteboard.string(forType: Self.providerDragType),
              !agentRows.isEmpty else {
            return false
        }
        let index = row < 0 ? agentRows.count - 1 : min(row, agentRows.count - 1)
        let agentName = (agentRows[index]["name"] as? String) ?? ""
        if store.assign(providerID: identifier, toAgentAt: index) {
            persist("已把 \(identifier) 拖到 Agent「\(agentName)」并写入配置")
        } else {
            appendLog("「\(agentName)」下已经有 \(identifier) 了。")
        }
        agentsTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        reloadMembers()
        return true
    }
}

// MARK: - 线路回执：只读网关自己写的 router-stats.json

/// 一条线路「最近一次真实回执」的读法。
///
/// 数据只有一个来源：网关写进 router-stats.json 的 `attempts` / `successes` /
/// `failures` / `last_error` / `last_attempt_at`。界面上的错误原因必须从这里来，
/// 抠不出人话就照原文摆着，不自己编一句「连接失败」。
struct HubLineReceipt {
    /// 回执的类别。判断「要不要排除出自动挑选」只看这里，不看界面的颜色。
    enum Kind: String {
        case keyRejected      // 401（干净的 JSON 体）：钥匙被拒
        case gatewayBlocked   // 401 / 403 但身上带着拦截页特征：被网关 / 盾挡下，不是钥匙的问题
        case missingModel     // 404：地址上没有这个模型
        case quotaExhausted   // 402：额度用尽
        case throttled        // 429：被限流
        case badRequest       // 400 / 422：请求被服务方拒绝
        case serverSide       // 5xx：服务方自己出错
        case transport        // 连不上 / 超时（没有 HTTP 码）
        case unknown

        var shortReason: String {
            switch self {
            case .keyRejected: return "密钥被拒"
            case .gatewayBlocked: return "被网关挡下"
            case .missingModel: return "地址上没有这个模型"
            case .quotaExhausted: return "额度用尽"
            case .throttled: return "被限流"
            case .badRequest: return "请求被服务方拒绝"
            case .serverSide: return "服务方服务器出错"
            case .transport: return "连不上或超时"
            case .unknown: return "服务方拒绝了这次调用"
            }
        }

        /// 这条回执会不会「自己好」。不会自己好的才排除出自动挑选。
        /// 「被网关挡下」算会自己好：盾会放行、网络会变，同一把 Key 过一会儿可能就通了，
        /// 拿它判死等于把一条好线路永久拉黑。
        var isPermanent: Bool {
            switch self {
            case .keyRejected, .missingModel: return true
            case .gatewayBlocked, .quotaExhausted, .throttled, .badRequest, .serverSide, .transport, .unknown:
                return false
            }
        }

        /// 这句话是给人看的下一步，不是客套话。
        /// 「被网关挡下」这一句只在正文命中硬特征（真拦截页）时才用；
        /// 只命中软特征时 `parse` 另给一句不下结论的 —— 不确定的事不写成确定的话。
        var nextStep: String {
            switch self {
            case .keyRejected: return "换一把能用的 Key，或把这条线路删掉"
            case .gatewayBlocked: return "换网络或加代理再试，不是 Key 的问题"
            case .missingModel: return "改模型名或地址；重试也不会变"
            case .quotaExhausted: return "今天不再重试，明天自动恢复"
            case .throttled: return "过一会儿能再试，不是坏了"
            case .badRequest: return "多半是这个模型不吃这种请求，看服务方原话"
            case .serverSide: return "稍后重试"
            case .transport: return "检查地址、网络或本地服务是否在跑"
            case .unknown: return "看服务方原话再决定"
            }
        }
    }

    let providerID: String
    let kind: Kind
    let httpCode: Int?
    let attempts: Int
    let successes: Int
    let failures: Int
    let at: Date?
    let atText: String
    let rawText: String
    let providerMessage: String
    /// 这句话是谁说的：有 HTTP 响应才是「服务方原话」；
    /// 连不上 / 超时那种是本机（网关）自己记下的错，不能挂在服务方名下。
    var messageAttribution: String { httpCode == nil ? "本机记下的错" : "服务方原话" }
    /// 回执是不是「当天」的。402 这种额度类回执只有当天的才作数。
    let isFromToday: Bool
    let excludesFromAutoPick: Bool
    let exclusionNote: String
    /// 「凭什么这么判」。目前只有「被网关挡下」一类会带：把命中的特征词摆出来。
    /// 别的类别依据就是 HTTP 码 / 服务方原话本身，不再多写一行。
    let evidenceNote: String?
    let receiptLine: String

    var shortCode: String { httpCode.map { "HTTP \($0)" } ?? "无 HTTP 码" }

    /// 一句话结论，给只有一行的位置（选单前缀、状态栏）用：说人话，不摆代码。
    /// 判死的那几类就是 `Kind.shortReason`（「密钥被拒」「额度用尽」），
    /// 会自己好的那几类如实说「上次失败但会自己好」，不让「能用」盖过「刚失败过」。
    var outcomeLabel: String {
        excludesFromAutoPick ? kind.shortReason : "\(kind.shortReason)（会自己好）"
    }

    var successRateText: String {
        Self.successRateText(successes: successes, attempts: attempts)
    }

    /// 成功率只有这一份算法：界面（`successRateText`）和回执行（`receiptLine`）都用它，不各算一份。
    static func successRateText(successes: Int, attempts: Int) -> String {
        guard attempts > 0 else { return "没调用过" }
        let rate = Int((Double(successes) / Double(attempts) * 100).rounded())
        return "\(successes)/\(attempts) · \(rate)%"
    }

    /// 年龄说法：「刚刚 / 12 分钟前 / 3 小时前 / 9 天前」。
    static func ageText(since date: Date?, now: Date) -> String {
        guard let date else { return "时间未知" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return "刚刚" }
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86_400)) 天前"
    }

    /// 把网关写下的一行原文（`last_error`）读成人话。
    /// 值来自真实文件，解析规则只有这一份，界面和验证工具都走它。
    static func parse(providerID: String,
                      entry: [String: Any],
                      now: Date = Date()) -> HubLineReceipt? {
        let raw = ((entry["last_error"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }   // 没有回执 ≠ 失败；空串是网关成功时清掉的

        let attempts = (entry["attempts"] as? NSNumber)?.intValue ?? 0
        let successes = (entry["successes"] as? NSNumber)?.intValue ?? 0
        let failures = (entry["failures"] as? NSNumber)?.intValue ?? max(attempts - successes, 0)
        let atText = ((entry["last_attempt_at"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let at = timestamp(atText)

        let code = httpStatus(in: raw)
        let message = providerMessage(in: raw)
        let kind = classify(code: code, raw: raw)
        let isToday = at.map { Calendar.current.isDateInToday($0) } ?? false
        let age = ageText(since: at, now: now)

        // 排除规则：只会「自己好」的回执不排除。钥匙被拒 / 模型不存在，多久以前发生都不会自己好。
        // 额度用尽只有当天的回执作数 —— 9 天前的「今日额度已耗尽」说的是 9 天前那天。
        let excludes = kind.isPermanent || (kind == .quotaExhausted && isToday)
        var note: String
        if excludes {
            note = "已排除自动挑选：\(kind.shortReason)，重试也不会变。"
            note += kind == .quotaExhausted
                ? "回执是今天的：今天不再重试，本地日期翻到明天后自动解除（在那之前成功调用一次也会立刻解除）。"
                : "要恢复：把线路修好后再成功调用一次，或删掉这条线路。"
        } else if kind == .quotaExhausted {
            note = "不排除：这条回执是 \(age) 的，早过了当天熔断（额度类回执次日自动解除），重新调用一次才知道现在能不能用。"
        } else if kind == .gatewayBlocked && gatewayBlockEvidence(in: raw).hard.isEmpty {
            // 只命中软特征（干净 JSON 里写着 access denied / 拦截…）：可能是网关挡的，
            // 也可能是服务方自己的规矩（账号未实名这种并不会自己好）——不替人下结论，
            // 所以这里不用 Kind.nextStep 那句「换网络或加代理再试」。
            note = "不排除：这条还不能确定是不是网关挡的，正文只命中通用短语。原样再试一次；还是失败就照服务方原话办。"
        } else {
            note = "不排除：这类回执会自己好，\(kind.nextStep)。"
        }
        if kind.isPermanent && !isToday && !atText.isEmpty {
            note += "（回执是 \(age) 的，钥匙要是已经换过，成功调用一次就会自动解除。）"
        }

        // 「被网关挡下」这一类要能自证凭什么这么判，但只写人话：
        // 命中的特征词是给工具（`Tools/verify-receipt-classify.command`）做证据的，
        // 不往界面上甩（界面只说「这张回复是拦截页」／「只有一句通用短语，看不出」）。
        var evidenceNote: String?
        if kind == .gatewayBlocked {
            let evidence = gatewayBlockEvidence(in: raw)
            evidenceNote = evidence.hard.isEmpty
                ? "判定依据：这条回复里只有一句常见的拒绝短语，看不出是不是网关挡的。"
                : "判定依据：这条回复是一张拦截页（机器验证 / 防护页），不是服务方的接口回复。"
        }

        // 有 HTTP 码就把码和说法都摆上（HTTP 401 · 密钥被拒）；没有码的那种
        // （连不上 / 超时）只说一次，免得写成「连不上或超时 · 连不上或超时」。
        let statusPart = code.map { "HTTP \($0) · \(kind.shortReason)" } ?? kind.shortReason
        var line = "最近回执 \(displayTime(at, fallback: atText))（\(age)）· \(statusPart)"
        // 成功率跟回执摆在同一行：看「这台最近怎么了」时，一眼知道它历史上是稳还是不稳。
        if attempts > 0 { line += " · 成功率 \(Self.successRateText(successes: successes, attempts: attempts))" }
        if excludes { line += " · 已排除自动挑选" }

        return HubLineReceipt(
            providerID: providerID,
            kind: kind,
            httpCode: code,
            attempts: attempts,
            successes: successes,
            failures: failures,
            at: at,
            atText: atText,
            rawText: raw,
            providerMessage: message,
            isFromToday: isToday,
            excludesFromAutoPick: excludes,
            exclusionNote: note,
            evidenceNote: evidenceNote,
            receiptLine: line
        )
    }

    /// `HTTP 401: {...}` → 401。没有 HTTP 码（网络错误）返回 nil。
    static func httpStatus(in raw: String) -> Int? {
        let upper = raw.uppercased()
        guard upper.hasPrefix("HTTP") else { return nil }
        let digits = raw.drop { !$0.isNumber }.prefix { $0.isNumber }
        guard let code = Int(digits), (100...599).contains(code) else { return nil }
        return code
    }

    static func classify(code: Int?, raw: String = "") -> Kind {
        switch code {
        // 401 / 403 有两种长相：服务方说「钥匙不对」（干净的 JSON 体），
        // 和中间的盾 / 网关直接甩过来一张拦截页（HTML、challenge、captcha…）。
        // 后者跟 Key 没关系 —— 判死等于把一条好线路永久拉黑，所以单独归一类。
        case .some(401), .some(403):
            return looksLikeGatewayBlock(raw) ? .gatewayBlocked : .keyRejected
        case .some(402): return .quotaExhausted
        case .some(404): return .missingModel
        case .some(429): return .throttled
        case .some(400), .some(422): return .badRequest
        case .some(let code) where (500...599).contains(code): return .serverSide
        case .none: return .transport
        case .some: return .unknown
        }
    }

    /// 拦截页特征。只看「像不像一张盾甩过来的页面」，不猜服务方的业务错误码。
    /// 方向是「宁可放过，不可错杀」：把一张陌生页面当成拦截页，顶多多试几次；
    /// 把盾的 401 / 403 当成「钥匙被拒」，这条线路从此进不了自动挑选。
    /// 分两档：硬特征只有真拦截页才会带（HTML 骨架、盾的名字、人机验证），
    /// 软特征是干净 JSON 里也可能出现的通用短语（access denied…）。两档都放行，
    /// 但话不能说满 —— 只命中软特征是「不能确定」，不是「换网络就能解决」。
    static let gatewayBlockHardMarkers = ["<!doctype html", "<html", "</html>", "<head", "cloudflare",
                                         "cf-ray", "captcha", "challenge", "just a moment",
                                         "attention required", "人机验证"]
    static let gatewayBlockSoftMarkers = ["access denied", "request blocked",
                                          "web application firewall", "拦截", "防护"]

    /// 命中的特征词，硬 / 软分开摆。界面上的「判定依据」和文案口吻都由它决定。
    static func gatewayBlockEvidence(in raw: String) -> (hard: [String], soft: [String]) {
        let text = raw.lowercased()
        return (gatewayBlockHardMarkers.filter { text.contains($0) },
                gatewayBlockSoftMarkers.filter { text.contains($0) })
    }

    static func looksLikeGatewayBlock(_ raw: String) -> Bool {
        let evidence = gatewayBlockEvidence(in: raw)
        return !evidence.hard.isEmpty || !evidence.soft.isEmpty
    }

    /// 服务方自己的那句话。JSON 里常见 message / detail / error.message，抠不出来就用冒号后面的原文。
    static func providerMessage(in raw: String) -> String {
        let body: String
        if let colon = raw.firstIndex(of: ":") {
            let after = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            body = raw.uppercased().hasPrefix("HTTP") ? after : raw
        } else {
            body = raw
        }
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let text = message(inJSON: object) {
            return text
        }
        return body.count > 200 ? String(body.prefix(200)) + "…" : body
    }

    private static func message(inJSON object: Any) -> String? {
        if let array = object as? [Any] {
            for element in array {
                if let text = message(inJSON: element) { return text }
            }
            return nil
        }
        guard let dictionary = object as? [String: Any] else { return nil }
        for key in ["message", "detail", "msg", "reason"] {
            if let text = (dictionary[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        for key in ["error", "data"] {
            if let nested = dictionary[key], let text = message(inJSON: nested) { return text }
        }
        for key in ["type", "code"] {
            if let text = dictionary[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    static func timestamp(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) { return date }
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    static func displayTime(_ date: Date?, fallback: String) -> String {
        guard let date else { return fallback.isEmpty ? "时间未知" : fallback }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

/// 所有回执的只读入口：盯着 router-stats.json 的修改时间，变了才重新读。
/// 界面上任何地方要「最近一次真实回执」，都从这里拿，别再自己读一遍文件。
final class HubReceiptLedger {
    static let shared = HubReceiptLedger()

    /// 与 RouterStore.statsURL 同一口径：环境变量优先，其次配置文件同目录。
    static var defaultStatsURL: URL {
        let override = ProcessInfo.processInfo.environment["LOCAL_SIRI_ROUTER_STATS"] ?? ""
        if !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let config = ProcessInfo.processInfo.environment["LOCAL_SIRI_ROUTER_CONFIG"] ?? ""
        if !config.isEmpty {
            return URL(fileURLWithPath: (config as NSString).expandingTildeInPath)
                .deletingLastPathComponent().appendingPathComponent("router-stats.json")
        }
        return RouterStore.supportDirectory.appendingPathComponent("router-stats.json")
    }

    let statsURL: URL
    private let lock = NSLock()
    private var loadedStamp: Date?
    private var loadedSize: Int?
    private var loadedURL: URL?
    private var entries: [String: [String: Any]] = [:]

    init(statsURL: URL = HubReceiptLedger.defaultStatsURL) {
        self.statsURL = statsURL
    }

    /// 只在文件动过时重新读；读不到文件就把缓存清掉（不假装有回执）。
    func refreshIfNeeded(force: Bool = false) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: statsURL.path)
        let stamp = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? NSNumber)?.intValue
        lock.lock()
        let isSame = !force && loadedURL == statsURL && loadedStamp == stamp && loadedSize == size
        lock.unlock()
        guard !isSame else { return }

        var parsed: [String: [String: Any]] = [:]
        if let data = try? Data(contentsOf: statsURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            parsed = object
        }
        lock.lock()
        entries = parsed
        loadedURL = statsURL
        loadedStamp = stamp
        loadedSize = size
        lock.unlock()
    }

    /// 网关写下的这一行的原始统计（没有记录返回 nil）。
    func rawEntry(for providerID: String) -> [String: Any]? {
        refreshIfNeeded()
        lock.lock(); defer { lock.unlock() }
        return entries[providerID]
    }

    /// 最近一次真实回执。返回 nil = 网关没写过失败回执（成功过、或从没调用过）。
    func receipt(for providerID: String, now: Date = Date()) -> HubLineReceipt? {
        guard let entry = rawEntry(for: providerID) else { return nil }
        return HubLineReceipt.parse(providerID: providerID, entry: entry, now: now)
    }

    func allReceipts(now: Date = Date()) -> [HubLineReceipt] {
        refreshIfNeeded()
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return snapshot.keys.sorted().compactMap {
            HubLineReceipt.parse(providerID: $0, entry: snapshot[$0] ?? [:], now: now)
        }
    }

    /// 这条线路在网关的账本里有没有记录 = 至少被真实调用过一次。
    /// 没有记录 ≠ 失败：可能只是从没试过（界面要把它和「试过且坏了」分开说）。
    func isTracked(_ providerID: String) -> Bool {
        rawEntry(for: providerID) != nil
    }

    /// 直接读一个文件里的全部回执（验证工具用，不碰界面缓存）。
    static func receipts(inFileAt url: URL, now: Date = Date()) -> [HubLineReceipt] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return [] }
        return object.keys.sorted().compactMap {
            HubLineReceipt.parse(providerID: $0, entry: object[$0] ?? [:], now: now)
        }
    }
}
