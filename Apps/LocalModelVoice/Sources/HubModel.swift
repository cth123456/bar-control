import AppKit
import Combine
import Foundation
import SwiftUI

/// Agent 页的配置策略。模型池展示与 Route 层故障转移分开：
/// 普通模型只在同名线路间切换，JEV 才允许跨模型决策。
enum HubAgentStrategy: String, CaseIterable, Identifiable {
    case readOnly
    case autoFallback
    case gateway

    var id: String { rawValue }
    var title: String {
        switch self {
        case .readOnly: return "只读 · 不改配置"
        case .autoFallback: return "自动故障转移"
        case .gateway: return "统一网关"
        }
    }
    var caption: String {
        switch self {
        case .readOnly: return "只展示 router.json 的现状"
        case .autoFallback: return "同模型线路失败时自动切换"
        case .gateway: return "所有客户端走同一个地址"
        }
    }
}

/// 一条提示活多久。数据层里那条 `notice` 和窗口顶部的横幅共用这个数，
/// 不能各算各的：否则会出现「数据里已经过期、界面上还挂着」的错位。
let hubNoticeLifetime: TimeInterval = 6

/// 中枢页面共用的数据层：字段全部读自 router.json / health.json / stats.json，动作写回同一份配置。
/// 不凭空造数据：拿不到就显示「未检查 / —」。
final class HubModel: ObservableObject {

    static let jevProviderID = "codex-router-jev-auto"
    static let jevInternalSource = "dsh:codex-router"

    struct Model: Identifiable, Equatable {
        var id: String
        var model: String
        var rank: String?
        /// Display-only supplier label, used to keep same-named models from
        /// different providers distinguishable in Agent cards.
        var supplier: String? = nil
        /// 这一行模型行自己的开关。网关发线路时只看它，所以界面必须知道，
        /// 否则「连接开着、模型关了」会被说成已启用。
        var enabled: Bool = true
        /// 这行线路的来源标记（provider 的 `source`）。界面按它分组，不再另外猜。
        var source: String = ""
        /// 这行线路挂在哪个连接下（synthetic 连接就是它自己的 id），用来查健康。
        var connectionID: String = ""
    }

    struct Connection: Identifiable {
        var id: String
        var name: String
        var baseURL: String
        var apiKey: String
        var wireAPI: String
        var timeout: Double
        var kind: String
        var models: [Model]
        var catalog: [String]
        var enabled: Bool
        var healthOK: Bool?
        var latencyMS: Int?
        var healthError: String
        /// 这条健康结论是怎么来的：`catalog` = 读了 /models 列表，`generation` = 真的发了一次
        /// 1 token 生成请求。空串 = 老数据（按列表探测理解）。界面必须把两者分开说，
        /// 否则「没读成列表」会被误说成「线路不通」。
        var healthMethod: String = ""
        /// 生成探测用的是哪个模型名（只对 `generation` 有意义）。
        var healthModel: String = ""
        var statsLabel: String
        var isLocal: Bool
        var source: String
        /// 这张卡是从「没有 connection_id 的旧 flat provider」投影出来的，router.json 的
        /// `connections` 里并没有它。空串表示它就是 router.json 里的一条真连接。
        var flatProviderID: String = ""

        /// 生成探测挑哪条模型行：先看启用的、有真名字的行；全关了才退回第一行有名字的。
        /// 挑不出来就返回空串——没有模型名就没法做生成探测。
        var probeModelID: String {
            let named = models.filter { !$0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return (named.first { $0.enabled } ?? named.first)?.model ?? ""
        }
    }

    struct Agent: Identifiable {
        var id: String
        var name: String
        var providerIDs: [String]
        var systemPrompt: String
        var configURL: URL?
        var configModel: String?
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var ok: Bool
    }

    @Published private(set) var connections: [Connection] = []
    @Published private(set) var agents: [Agent] = []
    @Published private(set) var tiers: [String: String] = [:]
    @Published private(set) var tierCandidates: [String: [String]] = [:]
    @Published private(set) var checkedAt = "尚未检查"
    @Published private(set) var gatewayPort = 0
    @Published private(set) var assistantAgentName = ""
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var notice: Notice?
    @Published var detailConnectionID: String?
    /// 内容区实际可用宽度，由窗口宿主在每次布局时写入。
    /// 页面据此决定「两列并排」还是「上下堆叠」—— 写死列宽在窄窗口里一定会互相压。
    @Published var viewportWidth: CGFloat = 0
    @Published private(set) var catalog: [String] = []
    /// 4202/Jev 的内部线路只给「Jev 档位」页使用，不进入全局模型池或 Agent 模型菜单。
    @Published private(set) var internalJevModels: [Model] = []
    @Published var strategy: HubAgentStrategy = .readOnly
    /// 界面要盯哪几个 Agent 客户端。用户可以在 Agent 页增删，落盘在 clients.json。
    @Published private(set) var clientSpecs: [HubClientSpec] = HubClientRegistry.load()

    /// 只有统一网关策略允许写客户端/Agent 配置；其它策略只读展示并运行路由策略。
    /// 所有 Agent 写入口都复用这个判断，避免 UI 标签和实际写盘权限分叉。
    static func agentWritesAllowed(for strategy: HubAgentStrategy) -> Bool {
        // 只有“AI助手接管路由”才允许写客户端/Agent 配置。
        // 自动故障转移是 Route 层策略，不能借机裁剪 Agent 的模型池。
        strategy == .gateway
    }

    var isReadOnlyMode: Bool { !Self.agentWritesAllowed(for: strategy) }

    /// 接管卡片是否真的有可写的 4230 客户端目标。
    /// 没有目标时 UI 应直接禁用入口，而不是让用户点击后才看到失败横幅。
    var gatewayWriteUnavailableReason: String? {
        guard gatewayWriteTargets().isEmpty else { return nil }
        let candidates = HubStrategySync.gatewayTargets()
        guard !candidates.isEmpty else { return "没有检测到 4230 网关客户端配置" }
        let allowed: Set<String> = Set(clientSpecs.compactMap { spec in
            guard spec.editable else { return nil }
            return HubStrategySync.client(id: spec.id, name: spec.name, path: spec.path)?.rawValue
        })
        let names = candidates.map { target in
            if !allowed.contains(target.client.rawValue) { return "\(target.displayName)未授权" }
            return target.isWritable ? target.displayName : "\(target.displayName)文件不可写"
        }
        return "当前无可写 4230 客户端：\(names.joined(separator: "、"))"
    }

    var onOpenPage: ((HubWindowController.Page) -> Void)?
    var presentLegacyRouterPanel: (() -> Void)?
    /// 统一网关进程仍由窗口控制器持有；策略切换前请它按需启动。
    var ensureGatewayRunning: (() -> Void)?
    /// 窗口宿主实现的确认框（NSAlert）。数据层不自己弹窗，只把要展示的事实交出去，
    /// 谁实现都要说清「写哪些文件、改成什么样」。
    var presentGatewayConfirm: ((HubStrategySync.WritePrompt) -> Bool)?
    /// 「把这个模型加进某个客户端」的确认框。同样是宿主实现：正文里带的是脚本真跑出来的 diff，
    /// 用户看的就是写盘前那一刻的事实。返回 true 才会写。
    var presentAgentModelConfirm: ((HubStrategySync.AgentModelWritePrompt) -> Bool)?
    /// 全局 notice 横幅（全 App 唯一一份，画在 HubWindowController 的内容列顶部）。
    /// 走容器布局把内容往下推，所以只投递文本，不关心页面当前在哪一页。
    var onNotice: ((String, Bool) -> Void)?

    private let store = RouterStore()
    private let tierOrder = ["luna", "terra", "sol", "astra"]
    private let localKey = "local"
    private var initialTierMapping: [String: String]?

    // MARK: 读

    func refresh() {
        try? store.load()
        store.loadStats()
        store.loadHealth()
        if initialTierMapping == nil { initialTierMapping = store.jevModelMap }

        let healthConnections = (store.health["connections"] as? [String: [String: Any]]) ?? [:]
        let healthProviders = (store.health["providers"] as? [String: [String: Any]]) ?? [:]

        var tierByProvider: [String: String] = [:]
        for (tier, providerID) in store.jevModelMap { tierByProvider[providerID] = tier }

        // `unified_router.py` also supports its original flat schema where each
        // provider owns its own URL/model and `connections` is intentionally
        // absent.  The Lunacy management page still needs to show those real
        // routes instead of an empty state, so expose each flat provider as a
        // one-model connection without rewriting the user's router.json.
        // 用户在 ③ 里明确收编出来的连接（台账 / source 标记 / 旧前缀三路并认）。
        // 只认「确实还存在」的连接，避免拿台账去认一个已被手删的 id。
        let adoptedConnectionIDs = Set(adoptedConnectionIDs.filter { id in
            store.connections.contains { ($0["id"] as? String) == id }
        })
        let routeProviders = store.providers.filter { provider in
            if Self.isRouteProvider(provider) { return true }
            // 「归属说了算」：带 Agent 特征的行默认不进供应商页（由 Agent 页面管），
            // 但用户在 ③ 里明确收编过、并且真的挂上了 App 建的那条连接时，
            // 它就不再是 Agent 执行器线路，按普通线路进模型池。
            guard let connectionID = provider["connection_id"] as? String, !connectionID.isEmpty else { return false }
            return adoptedConnectionIDs.contains(connectionID)
        }
        let explicitConnectionIDs = Set(store.connections
            .filter(Self.isRouteConnection)
            .compactMap { $0["id"] as? String })
        let poolProviders = routeProviders.filter { provider in
            // Jev / 4202 是唯一允许从 flat provider 投影进模型池的历史入口。
            if (provider["id"] as? String) == Self.jevProviderID { return true }
            // 其它模型必须有当前 router.json 的显式 connection_id；
            // 没有连接归属的 DSH/Codex Router 历史 flat provider 只保留在磁盘，
            // 不自动冒充用户已配置的供应商。
            guard let connectionID = provider["connection_id"] as? String,
                  explicitConnectionIDs.contains(connectionID) else { return false }
            return Self.isExternallyVisiblePoolProvider(provider)
        }
        internalJevModels = routeProviders.compactMap { provider in
            guard Self.isInternalJevProvider(provider),
                  let providerID = provider["id"] as? String,
                  let model = provider["model"] as? String,
                  !model.isEmpty else { return nil }
            let name = (provider["name"] as? String) ?? providerID
            return Model(id: providerID, model: model,
                         rank: tierByProvider[providerID], supplier: name,
                         enabled: (provider["enabled"] as? Bool) ?? true,
                         source: (provider["source"] as? String) ?? "",
                         connectionID: (provider["connection_id"] as? String) ?? "")
        }
        let routeConnectionIDs = Set(store.connections
            .filter(Self.isRouteConnection)
            .compactMap { $0["id"] as? String })

        // 兼容“旧 flat provider + 新 connections 混合”的 router.json：
        // 新增一个供应商时，旧线路没有 connection_id，不能因为 connections
        // 从空变成非空就整批从页面消失。把未归属的旧 provider 临时还原成
        // synthetic connection；编辑/删除时 RouterStore 会按 flat provider
        // 原样写回，不会凭空迁移或覆盖用户配置。
        let orphanConnections = poolProviders.compactMap { provider -> [String: Any]? in
            let providerConnectionID = (provider["connection_id"] as? String) ?? ""
            guard providerConnectionID.isEmpty || !routeConnectionIDs.contains(providerConnectionID) else {
                return nil
            }
            return Self.syntheticConnection(for: provider)
        }
        let visibleConnections: [[String: Any]] = store.connections.isEmpty
            ? orphanConnections
            : store.connections.filter { Self.isRouteConnection($0) } + orphanConnections

        connections = visibleConnections.map { connection in
            let id = (connection["id"] as? String) ?? ""
            let baseURL = (connection["base_url"] as? String) ?? ""
            let flatProviderID = (connection["flat_provider_id"] as? String) ?? ""
            let models = poolProviders.compactMap { provider -> Model? in
                let belongs = (provider["connection_id"] as? String) == id
                    || (!flatProviderID.isEmpty && (provider["id"] as? String) == flatProviderID)
                guard belongs,
                      let model = provider["model"] as? String,
                      let providerID = provider["id"] as? String else { return nil }
                let supplier = (connection["name"] as? String) ?? id
                return Model(id: providerID, model: Self.exposedModelName(providerID: providerID, model: model),
                             rank: tierByProvider[providerID], supplier: supplier,
                             enabled: (provider["enabled"] as? Bool) ?? true,
                             source: Self.effectiveSource(provider, connection: connection),
                             connectionID: id)
            }
            let health = healthConnections["connection:\(id)"]
                ?? healthProviders[id]
                ?? [:]
            var attempts = 0
            var successes = 0
            for provider in poolProviders {
                let belongs = (provider["connection_id"] as? String) == id
                    || (!flatProviderID.isEmpty && (provider["id"] as? String) == flatProviderID)
                guard belongs else { continue }
                guard let providerID = provider["id"] as? String,
                      let entry = store.stats[providerID] else { continue }
                attempts += (entry["attempts"] as? NSNumber)?.intValue ?? 0
                successes += (entry["successes"] as? NSNumber)?.intValue ?? 0
            }
            return Connection(
                id: id,
                name: (connection["name"] as? String) ?? id,
                baseURL: baseURL,
                apiKey: (connection["api_key"] as? String) ?? "",
                wireAPI: (connection["wire_api"] as? String) ?? "chat_completions",
                timeout: (connection["timeout_seconds"] as? NSNumber)?.doubleValue ?? 120,
                kind: (connection["kind"] as? String) ?? "",
                models: models,
                catalog: (connection["models"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String },
                enabled: (connection["enabled"] as? Bool) ?? true,
                healthOK: health["ok"] as? Bool,
                latencyMS: (health["latency_ms"] as? NSNumber)?.intValue,
                healthError: (health["error"] as? String) ?? "",
                healthMethod: (health["method"] as? String) ?? "",
                healthModel: (health["probe_model"] as? String) ?? "",
                statsLabel: HubModel.statsLabel(attempts: attempts, successes: successes),
                isLocal: baseURL.contains("127.0.0.1") || baseURL.lowercased().contains("localhost"),
                source: (connection["source"] as? String) ?? "",
                flatProviderID: flatProviderID
            )
        }

        _ = healthProviders

        // ③「未归属线路」是同一份 router.json 的只读投影：逐行说明它为什么没进池，
        // 引用了一个不存在的连接时单独算「引用缺口」，绝不自动改盘。
        routeLines = Self.auditRouteLines(providers: store.providers,
                                          connections: store.connections,
                                          pooledProviderIDs: Set(poolProviders.compactMap { $0["id"] as? String }))

        agents = store.agents.map { agent in
            let id = (agent["id"] as? String) ?? ""
            let name = (agent["name"] as? String) ?? id
            let fileURL = HubAgentSync.detect(agentName: id) ?? HubAgentSync.detect(agentName: name)
            let current = fileURL.flatMap { try? HubAgentSync.plan(agentName: name, fileURL: $0).currentModel }
            return Agent(
                id: id,
                name: name,
                providerIDs: (agent["provider_ids"] as? [String]) ?? [],
                systemPrompt: (agent["system_prompt"] as? String) ?? "",
                configURL: fileURL,
                configModel: current
            )
        }

        tiers = store.jevModelMap
        tierCandidates = store.jevModelCandidates
        assistantAgentName = store.assistantAgentLabel
        gatewayPort = store.gatewayPort
        if let stamp = store.health["checked_at"] as? String,
           let date = ISO8601DateFormatter().date(from: stamp) {
            checkedAt = HubModel.clockFormatter.string(from: date)
        } else {
            checkedAt = "尚未检查"
        }

        // 放在最后：复核「上次选的策略」要先知道 `gatewayPort` 和配置文件在哪。
        restoreStrategyIfRecorded()
    }

    static func statsLabel(attempts: Int, successes: Int) -> String {
        guard attempts > 0 else { return "统计 暂无调用" }
        let rate = Int((Double(successes) / Double(attempts) * 100).rounded())
        return "统计 失败 \(attempts - successes) · 成功率 \(rate)%"
    }

    static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    // MARK: 派生

    /// `providers` 同时保存本地路由线路和 Agent 客户端执行器。
    /// 后者由 Agent 页面管理，不能泄漏进供应商模型池。
    /// 一行 provider 算不算用户的普通线路。
    /// `kind` 缺失是历史常态（老版手写的扁平 provider 只有 model/base_url），
    /// 不能因为一个缺失字段把整行从页面藏掉——`isRouteConnection` 对连接已经是这条规矩，
    /// 这里对齐：先看 Agent 特征，再看 `kind`（有且不是 http 类才排除）。
    static func isRouteProvider(_ provider: [String: Any]) -> Bool {
        if isAgentMetadata(provider) { return false }
        guard let kind = (provider["kind"] as? String)?.lowercased(), !kind.isEmpty else { return true }
        return ["openai_compatible", "openai-compatible", "http"].contains(kind)
    }

    static func isInternalJevProvider(_ provider: [String: Any]) -> Bool {
        let source = (provider["source"] as? String ?? "").lowercased()
        return source == jevInternalSource
            && (provider["id"] as? String) != jevProviderID
    }

    /// 4202 的具体线路默认只留在 JEV 档位里，不向全局模型池暴露。
    /// 但用户明确把某条内部线路收编进模型池时（它带上了真实存在的 connection_id），
    /// 它就不再是「没有归属的历史 flat 行」，按普通线路处理。
    static func isExternallyVisiblePoolProvider(_ provider: [String: Any]) -> Bool {
        let source = (provider["source"] as? String ?? "").lowercased()
        guard source == jevInternalSource else { return true }
        if (provider["id"] as? String) == jevProviderID { return true }
        return !(provider["connection_id"] as? String ?? "").isEmpty
    }

    static func exposedModelName(providerID: String, model: String) -> String {
        providerID == jevProviderID ? "jev-auto" : model
    }

    /// 把旧版每个 provider 自带地址/模型的 flat 记录投影成一条供应商卡片。
    /// 这是只读投影，真正保存仍由 RouterStore 按原 schema 处理。
    private static func syntheticConnection(for provider: [String: Any]) -> [String: Any]? {
        guard let id = provider["id"] as? String, !id.isEmpty else { return nil }
        var item: [String: Any] = [
            "id": id,
            "name": id == jevProviderID ? "Jev / 4202" : ((provider["name"] as? String) ?? id),
            "enabled": (provider["enabled"] as? Bool) ?? true,
            "kind": (provider["kind"] as? String) ?? "openai_compatible",
            "source": id == jevProviderID ? "jev:4202" : ((provider["source"] as? String) ?? ""),
            "flat_provider_id": id,
        ]
        for key in ["base_url", "api_key", "wire_api", "timeout_seconds"] {
            if let value = provider[key] { item[key] = value }
        }
        if let model = provider["model"] as? String, !model.isEmpty {
            item["models"] = [["id": model]]
        }
        return item
    }

    /// `connections` is a shared catalog: some schemas also persist the HTTP
    /// endpoints used by Agent clients there.  The local-router page must only
    /// show provider/connection entries that belong to the model pool.
    static func isRouteConnection(_ connection: [String: Any]) -> Bool {
        if isAgentMetadata(connection) { return false }
        guard let kind = (connection["kind"] as? String)?.lowercased() else {
            // Old hand-written connections did not include `kind`; unless the
            // source explicitly identifies an Agent, keep them as user routes.
            return true
        }
        return ["openai_compatible", "openai-compatible", "http"].contains(kind)
    }

    /// 一行 provider 属不属于某条连接。扁平 schema 下连接行自己就是模型行（id 相同），
    /// 嵌套 schema 下靠 `connection_id` 认。写开关时两处都要落，认行靠这一份实现。
    static func providerRow(_ row: [String: Any], belongsToConnection id: String) -> Bool {
        if (row["connection_id"] as? String) == id { return true }
        return (row["id"] as? String) == id
    }

    /// 用户自己写的历史连接名，命中才当 Agent 客户端（例如旧版手写的 "Codex CLI"）。
    /// 不能只看「名字里有 agent」：用户给普通连接起名「Ark Agent Plan」时，
    /// 那一整条连接的模型会因此从页面消失。
    static let agentClientSignatures = ["codex cli", "codex-cli", "codex terra", "codex-terra",
                                        "claude code", "claude-code", "agent bridge", "agent-bridge",
                                        "agent executor", "agent-executor"]

    /// 命中 Agent 的字段与原因，逐条说清楚（页面③ 和自检共用这一份）。
    /// `source` 是机器写的稳定标识；`dsh:` 前缀的 id 也是机器键（dsh:agent* 要照旧排除）。
    /// `name` / `source_name` 是给人看的标签，只按客户端关键字或整名匹配；
    /// 用户自己命名的连接（"Ark Agent Plan" → id "ark-agent-plan"）不算 Agent 侧。
    static func agentSignatureMatch(_ item: [String: Any]) -> [String] {
        var matches: [String] = []
        let source = (item["source"] as? String ?? "").lowercased()
        if source.contains("agent") || source.contains("codex-cli") || source.contains("codex-terra") {
            matches.append("source=\(item["source"] as? String ?? "")")
        }
        let id = (item["id"] as? String ?? "").lowercased()
        if id.hasPrefix("dsh:"), id.contains("agent") || id.contains("codex-cli") || id.contains("codex-terra") {
            matches.append("id=\(item["id"] as? String ?? "")")
        }
        for key in ["name", "source_name"] {
            let label = (item[key] as? String ?? "").lowercased()
            if label.isEmpty { continue }
            if label == "agent" || label == "agents" || Self.agentClientSignatures.contains(where: label.contains) {
                matches.append("\(key)=\(item[key] as? String ?? "")")
            }
        }
        return matches
    }

    private static func isAgentMetadata(_ item: [String: Any]) -> Bool {
        !agentSignatureMatch(item).isEmpty
    }

    var poolModels: [Model] { connections.flatMap { $0.models } }

    /// default Agent 的真实可执行模型数：包含 4202 内部线路，但排除 dsh/command
    /// 这类没有模型名的执行桥。Codex 目录就是按这组模型生成，不能拿模型池数量代替。
    var defaultAgentModelCount: Int {
        guard let agent = agents.first(where: { $0.id == "default" }) else { return 0 }
        let ids = Set(agent.providerIDs)
        return routeLines.filter { ids.contains($0.id) && !$0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    var defaultAgentBridgeCount: Int {
        guard let agent = agents.first(where: { $0.id == "default" }) else { return 0 }
        return max(0, agent.providerIDs.count - defaultAgentModelCount)
    }

    /// 接管模式对外允许的模型：全局模型池与固定 default Agent 的引用交集。
    /// 不把客户端当前模型、不把隐藏的 4202 内部线路自动塞进来。
    var defaultAllowedModels: [Model] {
        guard let defaultAgent = agents.first(where: { $0.id == "default" }) else { return [] }
        let poolByID = Dictionary(uniqueKeysWithValues: poolModels.map { ($0.id, $0) })
        return defaultAgent.providerIDs.compactMap { poolByID[$0] }
    }

    /// Codex 的额外可选模型认 client_assignments.codex；Jev 作为一个独立的
    /// 自动路由候选保留一行，不把 4202 内部线路逐条投影进客户端列表。
    var codexAssignedModels: [Model] {
        let assigned = store.clientAssignments["codex"] ?? []
        var result = assigned.compactMap { requested -> Model? in
            let key = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  key.caseInsensitiveCompare("jev-auto") != .orderedSame,
                  key.caseInsensitiveCompare("jev/auto") != .orderedSame else { return nil }
            return poolModels.first {
                $0.id.caseInsensitiveCompare(key) == .orderedSame
                    || $0.model.caseInsensitiveCompare(key) == .orderedSame
            }
        }
        let defaultHasJev = agents.first(where: { $0.id == "default" })?.providerIDs.contains(Self.jevProviderID) == true
        if defaultHasJev && !result.contains(where: { $0.id == Self.jevProviderID }) {
            result.append(Model(id: Self.jevProviderID,
                                model: "jev/auto",
                                supplier: "Jev 自动路由",
                                source: Self.jevInternalSource))
        }
        return result
    }
    var onlineCount: Int { connections.filter { $0.healthOK == true }.count }
    var checkedConnections: Int { connections.filter { $0.healthOK != nil }.count }

    // MARK: 地址（一条线路真正会被用到的那个 URL）

    /// 地址在 `router.json` 里可以写两处：线路行自己的 `providers[].base_url`，
    /// 和它归属连接的 `connections[].base_url`。网关的顺序是「行自己的优先，
    /// 行没写才用连接的」（`router.py` 的 `provider.base_url or connection.base_url`）。
    /// 只显示连接里的、或只显示行里的，都会出现「看着有地址、发请求却打不通」这种要人猜的差异，
    /// 所以这里把两处合起来算一次，界面和自检都只认这个结果。
    struct AddressFact {
        /// 真正会被用来发请求的地址（已清洗换行）。
        var effective: String
        /// 上面那个地址的原文，用来查重复粘贴这类毛病。
        var raw: String
        /// true = 用的是行自己的地址。
        var fromLine: Bool
        /// true = 归属连接上有地址（不管最后用没用上）。两个都为 false 就是两处都空着。
        var fromConnection: Bool
        var lineRaw: String
        var connectionRaw: String
        /// 这个地址是从哪来的，给人看的一句话。
        var origin: String {
            if fromLine { return "线路自己的地址" }
            if !HubModel.isEmptyAddress(connectionRaw) { return "借连接上的地址" }
            return "没写地址（连接上也空着）"
        }
        /// 线路自己的地址和连接上的地址都写了、但不一样 —— 网关按行里的走。
        var lineOverridesConnection: Bool {
            HubModel.addressesDiffer(lineRaw, connectionRaw)
        }
    }

    func addressFact(of entry: Model) -> AddressFact {
        addressFact(providerID: entry.id, connectionID: entry.connectionID)
    }

    func addressFact(providerID: String, connectionID: String) -> AddressFact {
        let lineRaw = store.providers
            .first { ($0["id"] as? String) == providerID }
            .flatMap { $0["base_url"] as? String } ?? ""
        let connectionRaw: String
        if connectionID.isEmpty {
            connectionRaw = ""
        } else {
            connectionRaw = store.connections
                .first { ($0["id"] as? String) == connectionID }
                .flatMap { $0["base_url"] as? String } ?? ""
        }
        // 行里只要有非空地址，网关就用行里的；写空串等于「没写」，继续用连接的。
        let usesLine = !Self.isEmptyAddress(lineRaw)
        let raw = usesLine ? lineRaw : connectionRaw
        return AddressFact(effective: Self.cleanedAddress(raw), raw: raw, fromLine: usesLine,
                           fromConnection: !Self.isEmptyAddress(connectionRaw),
                           lineRaw: lineRaw, connectionRaw: connectionRaw)
    }

    /// 一个供应商分组：组里每条模型线路真正会用到的地址。
    /// 组标题只有一种情况敢写地址 —— 组内每条线路算出来是同一个；否则一律说明白。
    struct GroupAddress {
        /// 组内一致时才有值；不一致时留空，由 `label` 说清楚。
        var address = ""
        var isUniform = true
        /// 没有地址的线路行数。
        var missingCount = 0
        /// 组内出现了几种地址。
        var variantCount = 0
        /// 地址缺陷的一句话（重复粘贴、混了多个地址、不是 http），没有毛病就是空串。
        var defect = ""
        var defectRaw = ""
        /// 组里一条模型线路都没有。
        var isEmptyGroup = false

        /// 组里参与计算的模型线路条数（含没写地址的）。
        var lineCount = 0

        var label: String {
            if isEmptyGroup { return "这条连接还没有模型" }
            if !address.isEmpty { return "\(address) · \(lineCount) 条模型线路都走这里" }
            if missingCount == lineCount { return "这 \(lineCount) 条线路都没写地址" }
            if missingCount > 0 { return "组里 \(variantCount) 种地址，另有 \(missingCount) 条没写地址" }
            return "组里 \(variantCount) 种地址，各条线路按自己的地址发请求"
        }
    }

    func groupAddress(_ group: SupplierGroup) -> GroupAddress {
        var out = GroupAddress()
        out.lineCount = group.models.count
        if group.models.isEmpty {
            out.isEmptyGroup = true
            out.isUniform = false
        }
        var seen: Set<String> = []
        for entry in group.models {
            let fact = addressFact(of: entry)
            if fact.effective.isEmpty { out.missingCount += 1; continue }
            seen.insert(fact.effective)
            if out.defect.isEmpty, let note = Self.addressDefect(fact.raw) {
                out.defect = note
                out.defectRaw = fact.raw
            }
        }
        // 连接自己的地址也要单独查一遍：没有模型、或模型都借连接地址时，
        // 缺陷只会在连接这一侧露出来。
        for connection in group.connections where out.defect.isEmpty {
            if let note = Self.addressDefect(connection.baseURL) {
                out.defect = note
                out.defectRaw = connection.baseURL
            }
        }
        out.variantCount = seen.count
        if seen.count == 1, out.missingCount == 0 { out.address = seen.first ?? "" }
        out.isUniform = seen.count <= 1 && out.missingCount == 0 && !out.isEmptyGroup
        return out
    }

    static func isEmptyAddress(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 地址里塞了换行时，网关只会拿第一条（`unified_router.py` 读配置时 `strip()` 后取首个非空行）。
    /// 这里只还原那个真实行为并把首尾空格去掉，绝不改写 URL 本体。
    static func cleanedAddress(_ raw: String) -> String {
        raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    /// 地址有毛病时给一句人话（重复粘贴 / 连着写了多个地址 / 不是 http）；没毛病返回 nil。
    static func addressDefect(_ raw: String) -> String? {
        let parts = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let cleaned = cleanedAddress(raw)
        if !cleaned.isEmpty, !cleaned.lowercased().hasPrefix("http") {
            return "地址不是 http(s) 开头（现在是 \(cleaned)）"
        }
        guard parts.count > 1 else { return nil }
        return Set(parts).count == 1
            ? "同一地址被重复写了 \(parts.count) 次，网关只用第一条"
            : "一行里连着写了 \(parts.count) 个地址，网关只用第一条"
    }

    /// 地址缺陷是否值得一键修：修法只有一种 —— 把原文收成网关真正会用的那一条。
    static func addressesDiffer(_ lhs: String, _ rhs: String) -> Bool {
        !lhs.isEmpty && !rhs.isEmpty && lhs != rhs
    }

    /// 一键修复的清单与文案。不猜、不补、不改写 URL 本体，只动确实有缺陷的那一处。
    struct AddressRepair {
        struct ConnectionFix { var id: String; var name: String; var from: String; var to: String }
        struct LineFix { var index: Int; var id: String; var from: String; var to: String }
        var connections: [ConnectionFix] = []
        var lines: [LineFix] = []
        var isEmpty: Bool { connections.isEmpty && lines.isEmpty }
        /// 这次到底修的是哪几种毛病（去重后的原话，直接摆给用户看）。
        var defectSummary: String {
            let defects = (connections.map { HubModel.addressDefect($0.from) }
                           + lines.map { HubModel.addressDefect($0.from) }).compactMap { $0 }
            let unique = Set(defects).sorted()
            return unique.isEmpty ? "没有需要修的" : unique.joined(separator: "；")
        }
        var summary: String {
            var parts: [String] = []
            if !connections.isEmpty { parts.append("\(connections.count) 个连接") }
            if !lines.isEmpty { parts.append("\(lines.count) 条线路行") }
            return parts.joined(separator: "、")
        }
    }

    var addressRepair: AddressRepair {
        var repair = AddressRepair()
        for connection in store.connections {
            let from = (connection["base_url"] as? String) ?? ""
            guard Self.addressDefect(from) != nil else { continue }
            let to = Self.cleanedAddress(from)
            guard !to.isEmpty, to != from else { continue }
            let id = (connection["id"] as? String) ?? ""
            let name = (connection["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            repair.connections.append(.init(id: id, name: name, from: from, to: to))
        }
        for (index, provider) in store.providers.enumerated() {
            let id = (provider["id"] as? String) ?? ""
            let from = (provider["base_url"] as? String) ?? ""
            guard Self.addressDefect(from) != nil else { continue }
            let to = Self.cleanedAddress(from)
            guard !to.isEmpty, to != from else { continue }
            repair.lines.append(.init(index: index, id: id, from: from, to: to))
        }
        return repair
    }

    /// 需要修的连接里，有多少条线路正靠着它发请求（用来告诉用户影响面）。
    func linesDependingOnAddress(of connectionID: String) -> Int {
        store.providers.filter { provider in
            guard (provider["connection_id"] as? String) == connectionID else { return false }
            return Self.isEmptyAddress((provider["base_url"] as? String) ?? "")
        }.count
    }

    @discardableResult
    func repairAddresses() -> String {
        let repair = addressRepair
        guard !repair.isEmpty else { return "地址没有需要修的地方。" }
        guard performBackup(tag: "repair-address") else { return "备份失败，已中止（router.json 没有改动）" }
        for fix in repair.connections {
            store.updateConnection(id: fix.id, with: ["base_url": fix.to])
        }
        for fix in repair.lines {
            store.updateProvider(at: fix.index, with: ["base_url": fix.to])
        }
        do { try store.save() } catch { return "写盘失败：\(error.localizedDescription)" }
        refresh()
        return "已修 \(repair.summary)：地址收成网关真正会用的那一条，URL 本体没有改写"
    }

    // MARK: 供应商分组

    /// 一条供应商下挂着若干模型。本地路由页按这个结构折叠展示：
    /// 一行供应商，点开才是它下面的模型。
    struct SupplierGroup: Identifiable {
        var id: String
        var name: String
        var connections: [Connection]

        var models: [Model] { connections.flatMap { $0.models } }
        var modelCount: Int { models.count }
        var onlineCount: Int { connections.filter { $0.healthOK == true }.count }
        var failedCount: Int { connections.filter { $0.healthOK == false }.count }
        var uncheckedCount: Int { connections.filter { $0.healthOK == nil }.count }
        var isLocal: Bool { connections.contains { $0.isLocal } }
        var source: String { connections.first { !$0.source.isEmpty }?.source ?? "" }
        /// 组内最慢的一条，用来给供应商一个整体印象。
        var latencyMS: Int? {
            let values = connections.compactMap { $0.latencyMS }.filter { $0 > 0 }
            return values.max()
        }
        var baseURL: String { connections.first?.baseURL ?? "" }
    }

    /// 同一供应商在 `router.json` 里可能被拆成多条线路。
    /// 扁平 schema 下 `source` 形如 `dsh:codex-router`，`name` 形如
    /// `Codex Router · DeepSeek V4 Flash (API)` —— 两种情况都归到「Codex Router」。
    static func supplierName(for connection: Connection) -> String {
        let name = connection.name.trimmingCharacters(in: .whitespaces)
        // 「Codex Router · DeepSeek V4 Flash」取中点前半段。
        if let range = name.range(of: " · ") {
            let head = String(name[name.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { return head }
        }
        return name.isEmpty ? connection.id : name
    }

    var supplierGroups: [SupplierGroup] { HubModel.supplierGroups(of: connections) }

    /// 把任意一组线路归到供应商。页面和自检共用这一份实现，避免两处逻辑走偏。
    static func supplierGroups(of connections: [Connection]) -> [SupplierGroup] {
        var order: [String] = []
        var buckets: [String: [Connection]] = [:]
        for connection in connections {
            let key = supplierName(for: connection)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(connection)
        }
        return order.map { key in
            SupplierGroup(id: key, name: key, connections: buckets[key] ?? [])
        }
    }

    var onlineSupplierCount: Int { supplierGroups.filter { $0.onlineCount > 0 }.count }

    /// 某个 Agent 客户端「已经从本地路由拿走」的模型 id。
    ///
    /// 只有两种证据算数，其余一律不猜：
    /// 1. `router.json` 里同名 Agent 的 `provider_ids` 明确绑定的线路；
    /// 2. 客户端配置文件里当前就写着这个模型名。
    static func assignedModelIDs(agentID: String,
                                 agentName: String,
                                 currentModel: String?,
                                 agentProviderIDs: [String],
                                 pool: [Model]) -> [String] {
        let current = currentModel?.trimmingCharacters(in: .whitespaces) ?? ""
        return pool.compactMap { entry -> String? in
            if agentProviderIDs.contains(entry.id) { return entry.id }
            if !current.isEmpty, entry.model == current { return entry.id }
            return nil
        }
    }

    func assignedModels(agentID: String, agentName: String, currentModel: String?) -> [Model] {
        let key = HubModel.normalizedKey(agentID)
        let nameKey = HubModel.normalizedKey(agentName)
        let boundIDs = agents
            .filter { agent in
                let id = HubModel.normalizedKey(agent.id)
                let name = HubModel.normalizedKey(agent.name)
                return id == key || name == nameKey || id == nameKey || name == key
            }
            .flatMap { $0.providerIDs }
        let poolByID = Dictionary(uniqueKeysWithValues: poolModels.map { ($0.id, $0) })
        // 这里严格表示 Agent 线路本身；客户端当前模型即使还没绑定，
        // 也不能伪装成“已经在 Agent 线路里”。异常状态由页面单独提示。
        return boundIDs.compactMap { poolByID[$0] }
    }

    /// 某条 Agent 线路上**绑着**的模型行（含当前写着的那个）。
    ///
    /// 这里只算「线路表里有的」那一半。网关其实比线路表宽：客户端明明走的是
    /// `…/agents/<名字>/v1`，在上面点名一个没绑进这条线路的模型也不算错 —— 实跑的网关会拿
    /// 这个名字去整个模型池里找同名线路，找到就发，还顺手把它绑进这个 Agent
    /// （`unified_router.resolve_pool_provider` / `bind_provider_to_agent`；绑这一步受
    /// `settings.auto_bind_pool_models` 管，默认开着，关掉时只发不绑），而且
    /// `/v1/models` 本来就先把整池的名片发给客户端。所以「能切到哪些模型」是
    /// 这条线路绑的 ∪ 池里启用的其它行，并集在 `switchableModels(route:currentModel:)` 里合。
    func models(onRoute route: String, currentModel: String?) -> [Model] {
        let key = HubModel.normalizedKey(route)
        let boundIDs = agents
            .filter { agent in
                HubModel.normalizedKey(agent.id) == key || HubModel.normalizedKey(agent.name) == key
            }
            .flatMap { $0.providerIDs }
        let poolByID = Dictionary(uniqueKeysWithValues: poolModels.map { ($0.id, $0) })
        var rows = boundIDs.compactMap { poolByID[$0] }
        if let currentModel,
           !currentModel.trimmingCharacters(in: .whitespaces).isEmpty,
           !rows.contains(where: { Self.isCurrentModel($0, currentModel: currentModel) }),
           let current = poolModels.first(where: { Self.isCurrentModel($0, currentModel: currentModel) }) {
            rows.append(current)
        }
        // 池子里找不到这个名字（手工写的配置，或者和供应商那边的叫法对不上）：
        // 补一行占位，好让「当前正在用」这个状态在可切列表里也看得见。
        if let currentModel, !currentModel.isEmpty,
           !rows.contains(where: { $0.model == currentModel }) {
            rows.insert(Model(id: currentModel, model: currentModel), at: 0)
        }
        return rows
    }

    /// 可切列表里的一行：池子里的那一行 + 它和这个客户端的关系。
    ///
    /// 「哪个是当前」「哪个已停用」「哪个没绑在这条线路上」都在数据层算，界面照着画就行 ——
    /// 界面自己比是比不出来的：配置里存的是模型名，池子里存的是线路 id。
    struct SwitchOption: Identifiable, Equatable {
        var model: Model
        /// 客户端配置里现在就写着这个模型名。
        var isCurrent: Bool
        /// 网关眼里这行是停用的（连接关了或这一行关了）。停用也照样列出来给用户切，
        /// 只是必须标出来，别让人以为切过去就能用。
        var isDisabled: Bool
        /// 池子里有这一行，但它没绑在这个客户端走的线路上。切过去照样能用：网关会按名字在池里
        /// 找到它、发它，默认还会顺手绑进这条线路。之所以还要标出来，是因为它本来不属于这条线路 ——
        /// 不标的话用户会以为「这条线路上本来就有它」。
        var isUnbound: Bool = false

        var id: String { model.id }
    }

    /// 池子里的这一行是不是这个客户端现在写着的那个模型。
    ///
    /// 判定留在数据层：界面各自拿名字去比会走偏 —— 客户端配置里存的是模型名，池子里存的是线路 id，
    /// 两个都可能是「当前」（`assignedModelIDs` 就是这么认的）。Agent 页的「添加模型」菜单靠它
    /// 给当前那一行标「当前正在用」并置灰，免得那个模型被过滤掉之后菜单里一个可点的都没有。
    static func isCurrentModel(_ entry: Model, currentModel: String?) -> Bool {
        let current = currentModel?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !current.isEmpty else { return false }
        return entry.model == current || entry.id == current
    }

    /// 一个「只存一格模型」的客户端（Codex 的 config.toml）能切到哪些模型，含当前这个。
    ///
    /// 线路读得出来时：这条线路绑着的行 ∪ 池里启用的其它行。网关比线路表宽，池里那些行
    /// 点名叫它也能发（见 `models(onRoute:currentModel:)`），只列绑着的那几个会让 Codex 的
    /// 切换盘只剩一两个模型，而别的客户端（走网关根地址）却能列全 —— 同一台机器上两张脸。
    /// 并进来的那些挂在 `isUnbound` 上。界面**不再逐片**写「未绑定」：15 片里 12 片都挂着这个
    /// 角标，看着像整排都有毛病，而它只是「不属于这条线路、网关按名字也接得上」；这条信息放在
    /// 每一片的 tooltip 和列表下面说一次，颜色按供应商上（和 ZCode 卡的标签同一套）。
    ///
    /// 线路读不出来时退回整个模型池：客户端配置里写的是网关根地址、没有 `agents/<名字>/`
    /// 那一段时，网关本来就是按模型名自己选线路的，池子里那些名字就是都能用的。
    ///
    /// 停用的行**也留着**：用户得能把模型切回一个刚被停用的名字。藏起来的话
    /// 他只会看到「这个客户端用着一个列表里没有的模型」，而且再也切不回去。
    func switchableModels(route: String?, currentModel: String?, clientID: String? = nil) -> [SwitchOption] {
        // Agent 客户端的可选范围不是“当前 URL 对应线路”也不是整个模型池，
        // 而是固定 default 通用路由允许的模型交集。
        var rows = clientID == "codex" ? codexAssignedModels : defaultAllowedModels
        let assignedCodex = Set((store.clientAssignments["codex"] ?? []).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        if let currentModel,
           !currentModel.trimmingCharacters(in: .whitespaces).isEmpty,
           !rows.contains(where: { Self.isCurrentModel($0, currentModel: currentModel) }) {
            // 当前配置可能是被隐藏的 4202 内部模型：保留为状态行，但不把它伪装成可选模型。
            rows.insert(Model(id: currentModel, model: currentModel, supplier: "客户端当前配置"), at: 0)
        }
        // 同一个模型名可能在好几条线路上都有，所以只认第一行，否则界面上会同时冒出好几个「当前」。
        var currentTaken = false
        return rows.map { row in
            let isCurrent = !currentTaken && Self.isCurrentModel(row, currentModel: currentModel)
            if isCurrent { currentTaken = true }
            // 占位行（池子里根本没这个名字）查不到开关状态，不能因为查不到就说它已停用。
            let inPool = poolModels.contains { $0.id == row.id }
            let jevAssigned = assignedCodex.contains("jev/auto")
                || assignedCodex.contains("jev-auto")
                || assignedCodex.contains(Self.jevProviderID.lowercased())
            return SwitchOption(model: row,
                                isCurrent: isCurrent,
                                isDisabled: inPool && !providerEnabled(row.id),
                                isUnbound: clientID == "codex"
                                    && row.id == Self.jevProviderID
                                    && !jevAssigned)
        }
    }

    static func normalizedKey(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: 客户端清单（自定义增删）

    /// 加一个客户端。写盘成功才改界面 —— 存不下来就不许显示成「加上了」。
    @discardableResult
    func addClient(name: String, path: String, editable: Bool) -> Bool {
        let spec = HubClientSpec(id: "", name: name, path: path, editable: editable)
        return commitClients(clientSpecs + [spec], success: "已添加客户端：\(spec.name.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    @discardableResult
    func updateClient(id: String, name: String, path: String, editable: Bool) -> Bool {
        guard let index = clientSpecs.firstIndex(where: { $0.id == id }) else {
            notify("找不到这个客户端，权限没有修改", ok: false)
            return false
        }
        var updated = clientSpecs
        updated[index] = HubClientSpec(id: id, name: name, path: path, editable: editable)
        return commitClients(updated, success: "已更新 (name) 的独立写入权限")
    }

    /// 从清单里删一个。只删这份清单，客户端自己的配置文件一个字都不动。
    @discardableResult
    func removeClient(id: String) -> Bool {
        let removed = clientSpecs.first { $0.id == id }?.name ?? id
        return commitClients(clientSpecs.filter { $0.id != id },
                             success: "已从列表移除 \(removed)（它的配置文件没动）")
    }

    @discardableResult
    func restoreDefaultClients() -> Bool {
        commitClients(HubClientRegistry.seed, success: "已恢复默认客户端清单")
    }

    /// 清单的唯一落盘点：清洗 → 落盘 → 读回验证，全过了才更新界面。
    ///
    /// 空清单会被拒绝而不是写进去：`load()` 对空文件会回落到默认清单，
    /// 如果这里允许写空，界面上「删光了」和「重启后又冒出来」就会互相打脸。
    private func commitClients(_ specs: [HubClientSpec], success: String) -> Bool {
        let cleaned = HubClientRegistry.sanitize(specs)
        guard !cleaned.isEmpty else {
            notify("客户端清单至少要留一个；想回到最初那四个就点「恢复默认」", ok: false)
            return false
        }
        do {
            clientSpecs = try HubClientRegistry.save(cleaned)
            notify(success)
            return true
        } catch {
            notify("客户端清单没存住：\(error.localizedDescription)", ok: false)
            return false
        }
    }

    /// The Lunacy overview intentionally shows a short, stable table rather
    /// than dumping every route into the first screen.
    var overviewConnections: [Connection] {
        Array(connections.prefix(5))
    }
    var averageLatencyMS: Int? {
        // 0ms is the persisted sentinel for an unavailable/unprobed route;
        // including it makes the overview look faster as routes go offline.
        let values = connections.compactMap { latency -> Int? in
            guard let value = latency.latencyMS, value > 0, latency.healthOK == true else { return nil }
            return value
        }
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    func connection(id: String?) -> Connection? {
        guard let id else { return nil }
        return connections.first { $0.id == id }
    }

    func modelName(providerID: String) -> String {
        if let internalModel = internalJevModels.first(where: { $0.id == providerID }) {
            return "Jev / 4202 · \(internalModel.model)"
        }
        for connection in connections {
            if let model = connection.models.first(where: { $0.id == providerID }) {
                return "\(connection.name) · \(model.model)"
            }
        }
        return providerID
    }

    func isInternalJevModel(_ model: String) -> Bool {
        internalJevModels.contains { $0.model == model }
    }

    /// 将明确配置的模型加入固定 default 通用路由。模型本身仍属于全局池，
    /// 这里只增加 Agent 引用，不复制或删除 provider。
    func addModelToDefault(providerID: String) {
        guard !isReadOnlyMode else {
            notify("当前是只读监测：没有修改 default", ok: false)
            return
        }
        guard defaultAllowedModels.contains(where: { $0.id == providerID }) == false,
              poolModels.contains(where: { $0.id == providerID }),
              let index = store.agentIndex(id: "default") else {
            notify("这个模型不在当前全局模型池，或 default 不存在", ok: false)
            return
        }
        guard store.assign(providerID: providerID, toAgentAt: index) else {
            notify("这个模型已经在 default 里了", ok: false)
            return
        }
        do {
            try store.save(); refresh()
            notify("已将 \(modelName(providerID: providerID)) 加入 default")
        } catch {
            refresh(); notify("default 保存失败：\(error.localizedDescription)", ok: false)
        }
    }

    /// 从 default 解除引用，不删除全局模型池，也不动其它 Agent。
    func removeModelFromDefault(providerID: String) {
        guard !isReadOnlyMode else {
            notify("当前是只读监测：没有修改 default", ok: false)
            return
        }
        guard let index = store.agentIndex(id: "default") else {
            notify("default 不存在，未做改动", ok: false); return
        }
        store.removeProvider(providerID, fromAgentAt: index)
        do {
            try store.save(); refresh()
            notify("已从 default 移除，模型池仍保留")
        } catch {
            refresh(); notify("default 保存失败：\(error.localizedDescription)", ok: false)
        }
    }

    /// 这个模型现在真的能用吗：它所在连接开着，并且它自己那一行也开着。
    ///
    /// 加进客户端之前要靠它挡一下：往客户端里写一条池子里已停用的线路，
    /// 等于把用户刚关掉的东西又从别的门塞回去。网关发线路时看的就是模型行的 enabled。
    func providerEnabled(_ providerID: String) -> Bool {
        for connection in connections where connection.models.contains(where: { $0.id == providerID }) {
            let row = connection.models.first { $0.id == providerID }
            return connection.enabled && (row?.enabled ?? true)
        }
        return false
    }

    /// 一条线路下面的模型行是不是全关了（连接行开着、模型行全关 = 网关眼里这条线路是死的）。
    /// 供应商卡片用它把这种半开半关的状态说出来，而不是让界面显示「已启用」骗人。
    static func allModelsDisabled(_ connection: Connection) -> Bool {
        !connection.models.isEmpty && connection.models.allSatisfy { !$0.enabled }
    }

    func agentCount(providerID: String) -> Int {
        agents.filter { $0.providerIDs.contains(providerID) }.count
    }

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    // MARK: 提示

    func notify(_ text: String, ok: Bool = true) {
        notice = Notice(text: text, ok: ok)
        // 同一条消息也推给全局横幅：那是全 App 唯一一份可见提示，
        // 页面自己不再画第二份（不然同一句话会在两处出现）。
        DispatchQueue.main.async { [weak self] in
            self?.onNotice?(text, ok)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + hubNoticeLifetime) { [weak self] in
            if self?.notice?.text == text { self?.notice = nil }
        }
    }

    private func begin(_ key: String) {
        DispatchQueue.main.async { self.busy.insert(key) }
    }

    private func end(_ key: String) {
        DispatchQueue.main.async { self.busy.remove(key) }
    }

    // MARK: 网络

    enum NetError: LocalizedError {
        case badURL
        case status(Int, String)
        case catalogUnavailable
        case empty

        var errorDescription: String? {
            switch self {
            case .badURL: return "接口地址不是合法 URL"
            case .status(let code, let body):
                let tail = body.trimmingCharacters(in: .whitespacesAndNewlines).suffix(1000)
                return "HTTP \(code)\(tail.isEmpty ? "" : " · \(tail)")"
            case .catalogUnavailable:
                return "该接口不提供 GET /models；请改用标准 /api/v3 地址，或手动加入模型名"
            case .empty: return "接口返回里没有模型列表"
            }
        }
    }

    /// Return the OpenAI-compatible catalog endpoints for a provider.
    ///
    /// Ark Coding Plan deliberately has no GET /models endpoint.  Try its
    /// standard `/api/v3/models` sibling when the supplied key supports it;
    /// otherwise the editor can still save manually entered model IDs.
    static func modelCatalogURLs(baseURL: String) -> [URL]? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty,
              let base = URL(string: trimmed),
              let components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil,
              components.query == nil,
              components.fragment == nil,
              components.user == nil,
              components.password == nil else { return nil }

        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        path = path.isEmpty ? "" : "/" + path
        let lowerPath = path.lowercased()
        if lowerPath.hasSuffix("/models") { return [base] }
        for suffix in ["/chat/completions", "/responses", "/messages"] where lowerPath.hasSuffix(suffix) {
            path = String(path.dropLast(suffix.count))
            break
        }

        var paths: [String] = []
        let arkPlanSuffix = "/api/plan/v3"
        if path.lowercased().hasSuffix(arkPlanSuffix) {
            paths.append(path + "/models")
            let prefix = String(path.dropLast(arkPlanSuffix.count))
            paths.append(prefix + "/api/v3/models")
        } else if path.range(of: #"/v[0-9]+$"#, options: .regularExpression) != nil {
            paths.append(path + "/models")
            if path.lowercased() != "/v1" {
                paths.append(path + "/v1/models")
            }
        } else {
            paths.append(path + "/v1/models")
            paths.append(path + "/models")
        }

        return paths.reduce(into: [URL]()) { result, candidatePath in
            var candidate = components
            candidate.path = candidatePath
            guard let url = candidate.url, !result.contains(url) else { return }
            result.append(url)
        }
    }

    /// GET a provider's model catalog.  A 404/405/501 is allowed to fall
    /// through to the next compatible endpoint; other failures are final.
    func fetchCatalog(baseURL: String, apiKey: String, timeout: Double,
                      completion: @escaping (Result<[String], Error>) -> Void) {
        guard let urls = Self.modelCatalogURLs(baseURL: baseURL), !urls.isEmpty else {
            return completion(.failure(NetError.badURL))
        }

        func attempt(_ index: Int, sawCatalogNotFound: Bool) {
            var request = URLRequest(url: urls[index])
            request.timeoutInterval = max(5, timeout)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    return DispatchQueue.main.async { completion(.failure(error)) }
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if (200..<300).contains(code) {
                    let names = HubModel.modelNames(from: data)
                    return DispatchQueue.main.async {
                        completion(names.isEmpty && text.isEmpty
                                   ? .failure(NetError.empty)
                                   : .success(names))
                    }
                }
                let notFound = [404, 405, 501].contains(code)
                if notFound && index + 1 < urls.count {
                    return attempt(index + 1, sawCatalogNotFound: true)
                }
                DispatchQueue.main.async {
                    completion(.failure(sawCatalogNotFound || notFound
                                        ? NetError.catalogUnavailable
                                        : NetError.status(code, text)))
                }
            }.resume()
        }

        attempt(0, sawCatalogNotFound: false)
    }

    static func modelNames(from data: Data?) -> [String] {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let dictionary = object as? [String: Any] {
            let list = (dictionary["data"] as? [[String: Any]]) ?? (dictionary["models"] as? [[String: Any]]) ?? []
            return list.compactMap { $0["id"] as? String ?? $0["name"] as? String }.sorted()
        }
        if let list = object as? [[String: Any]] {
            return list.compactMap { $0["id"] as? String ?? $0["name"] as? String }.sorted()
        }
        if let list = object as? [String] { return list.sorted() }
        return []
    }

    // MARK: 探测

    /// `/api/plan/v3` 这类 Coding Plan 接口不提供 GET /models——列表探测必然 404，
    /// 但它的 key 能生成。这时唯一能证明线路可用的办法，是真的发一次最小生成请求。
    /// 下面三个静态函数只做判断和拼地址，不发请求，方便自检单独验证。
    ///
    /// chat/completions 地址：base_url 后面接 `/chat/completions`（已经带了就不重复接）。
    /// 地址不合法、或不是 http(s) 就返回 nil，绝不去猜端口。
    static func chatCompletionsURL(baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        if !trimmed.lowercased().hasSuffix("/chat/completions") { trimmed += "/chat/completions" }
        return URL(string: trimmed)
    }

    /// 发给上游的模型名。界面上偶尔带给人看的备注（`glm-5.3 (glm-latest)`），
    /// 原样发过去上游会当成不存在的模型，所以先把结尾的括号备注剥掉。
    static func probeModelID(from raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = name.range(of: #"[（(][^）)]*[）)]\s*$"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// 列表探测失败之后，还该不该改用生成探测。
    /// 只有「接口自己说没有 /models」这一种失败值得试：401 是凭据不对、超时是网络不通，
    /// 这些情况下生成探测同样会失败，只是白烧一次 token。没有模型名也无从探测。
    /// responses 类接口不认 chat_completions，这里不替它换协议，保持原样报错。
    static func needsGenerationProbe(error: Error, wireAPI: String, modelID: String) -> Bool {
        guard let netError = error as? NetError, case .catalogUnavailable = netError else { return false }
        guard !modelID.isEmpty else { return false }
        let api = wireAPI.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return api.isEmpty || api == "chat_completions"
    }

    func probe(connectionID: String) {
        guard let connection = connection(id: connectionID) else { return }
        begin("probe:\(connectionID)")
        let started = Date()
        let modelID = HubModel.probeModelID(from: connection.probeModelID)
        fetchCatalog(baseURL: connection.baseURL, apiKey: connection.apiKey, timeout: min(connection.timeout, 15)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let names):
                let latency = Int(Date().timeIntervalSince(started) * 1000)
                self.store.recordHealth(connectionID: connectionID, probe: [
                    "ok": true,
                    "status": "ready",
                    "latency_ms": latency,
                    "models": names.count,
                    "method": "catalog",
                ])
                self.refresh()
                self.notify("\(connection.name) 连通正常 · \(latency) ms" +
                            (names.isEmpty ? "" : " · \(names.count) 个模型"))
                self.end("probe:\(connectionID)")
            case .failure(let error):
                guard HubModel.needsGenerationProbe(error: error, wireAPI: connection.wireAPI, modelID: modelID) else {
                    // 不是「没有 /models」这种失败，照旧如实报错，不拿生成探测去掩盖。
                    self.recordProbeFailure(connection: connection, error: error,
                                            latency: Int(Date().timeIntervalSince(started) * 1000),
                                            method: "catalog", prefix: "")
                    self.end("probe:\(connectionID)")
                    return
                }
                // 该接口没有 /models：改用一次 1 token 的生成请求，证明这条线路真能出字。
                self.generationProbe(connectionID: connectionID, modelID: modelID) { probeResult in
                    switch probeResult {
                    case .success(let latency):
                        self.store.recordHealth(connectionID: connectionID, probe: [
                            "ok": true,
                            "status": "ready",
                            "latency_ms": latency,
                            "models": 0,
                            "method": "generation",
                            "probe_model": modelID,
                            "note": "该接口不提供 GET /models",
                        ])
                        self.refresh()
                        self.notify("\(connection.name) 连通正常 · \(latency) ms · 用模型 \(modelID) 做了一次 1 token 生成探测")
                    case .failure(let error):
                        self.recordProbeFailure(connection: connection, error: error,
                                                latency: Int(Date().timeIntervalSince(started) * 1000),
                                                method: "generation", prefix: "生成探测失败")
                    }
                    self.end("probe:\(connectionID)")
                }
            }
        }
    }

    /// 最小生成探测：`max_tokens: 1` 加一句「ping」，只看这条线路能不能真的出字。
    /// 成功只说明「凭据能生成」，不核对回复内容，也不改任何配置。
    func generationProbe(connectionID: String, modelID: String,
                         completion: @escaping (Result<Int, Error>) -> Void) {
        guard let connection = connection(id: connectionID),
              let url = HubModel.chatCompletionsURL(baseURL: connection.baseURL) else {
            completion(.failure(NetError.badURL))
            return
        }
        let started = Date()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 探测最多等 15 秒：它只是插一面小旗，不能把界面卡在「探测中…」。
        request.timeoutInterval = max(5, min(connection.timeout, 15))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !connection.apiKey.isEmpty {
            request.setValue("Bearer \(connection.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": modelID,
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 1,
            "stream": false,
        ] as [String: Any])

        URLSession.shared.dataTask(with: request) { data, response, error in
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            DispatchQueue.main.async {
                if let error { return completion(.failure(error)) }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard (200..<300).contains(code) else {
                    return completion(.failure(NetError.status(code, text)))
                }
                completion(.success(latency))
            }
        }.resume()
    }

    private func recordProbeFailure(connection: Connection, error: Error, latency: Int,
                                    method: String, prefix: String) {
        let message = error.localizedDescription
        store.recordHealth(connectionID: connection.id, probe: [
            "ok": false,
            "status": "error",
            "latency_ms": latency,
            "method": method,
            "error": prefix.isEmpty ? message : "\(prefix)：\(message)",
        ])
        refresh()
        notify("\(connection.name) 探测失败：\(message)", ok: false)
    }

    func probeAll() {
        guard !connections.isEmpty else {
            notify("还没有供应商，先添加一个再来探测", ok: false)
            return
        }
        for connection in connections { probe(connectionID: connection.id) }
    }

    // MARK: 供应商写操作

    @discardableResult
    func saveConnection(id: String?,
                        name: String,
                        baseURL: String,
                        apiKey: String,
                        wireAPI: String,
                        timeout: Double,
                        catalog: [String],
                        selected: [String]) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var trimmedBase = baseURL.trimmingCharacters(in: .whitespaces)
        while trimmedBase.hasSuffix("/") { trimmedBase.removeLast() }
        guard !trimmedBase.isEmpty else { notify("请填接口地址", ok: false); return false }

        let catalogRows = catalog.map { ["id": $0] }
        if let id, connection(id: id) != nil {
            store.updateConnection(id: id, with: [
                "name": trimmedName.isEmpty ? id : trimmedName,
                "base_url": trimmedBase,
                "api_key": apiKey,
                "wire_api": wireAPI,
                "timeout_seconds": timeout,
                "models": catalogRows,
            ])
            var changed = 0
            for model in selected {
                if store.addModel(connectionID: id, modelID: model) != nil { changed += 1 }
            }
            do { try store.save() } catch {
                refresh(); notify("供应商保存失败：\(error.localizedDescription)", ok: false); return false
            }
            refresh()
            notify("已保存 \(trimmedName.isEmpty ? id : trimmedName)：\(changed) 个模型在池子里")
            return true
        } else {
            let identifier = store.addConnection(
                name: trimmedName,
                baseURL: trimmedBase,
                apiKey: apiKey,
                wireAPI: wireAPI,
                catalog: catalogRows,
                selectedModelIDs: selected
            )
            store.updateConnection(id: identifier, with: ["timeout_seconds": timeout])
            do { try store.save() } catch {
                refresh(); notify("供应商保存失败：\(error.localizedDescription)", ok: false); return false
            }
            refresh()
            notify("已添加供应商 \(trimmedName.isEmpty ? identifier : trimmedName) · \(selected.count) 个模型")
            return true
        }
    }

    func removeConnection(id: String) {
        guard let connection = connection(id: id) else { return }
        store.removeConnection(id: id)
        try? store.save()
        if detailConnectionID == id { detailConnectionID = nil }
        refresh()
        notify("已删除供应商 \(connection.name)，相关 Agent 绑定同步清理")
    }

    func addModelsToPool(connectionID: String, models: [String]) {
        var added = 0
        for model in models where store.addModel(connectionID: connectionID, modelID: model) != nil { added += 1 }
        try? store.save()
        refresh()
        notify(added == 0 ? "没有新增模型（可能已在池子里）" : "已加入模型池 \(added) 个", ok: added > 0)
    }

    func removeModelFromPool(providerID: String) {
        guard let index = store.providers.firstIndex(where: { ($0["id"] as? String) == providerID }) else { return }
        store.removeProvider(at: index)
        try? store.save()
        refresh()
        notify("已从模型池移除，并从各 Agent 的绑定里摘掉")
    }

    /// 只解除一条 Agent 线路的引用，不删除模型池中的模型。
    /// 模型池是共享资源；Agent 页面上的移除不能误伤其它 Agent。
    func removeModelFromAgent(providerID: String, agentID: String) {
        guard !isReadOnlyMode else {
            notify("当前是只读监测：没有修改 Agent 线路", ok: false)
            return
        }
        guard let agentIndex = store.agentIndex(id: agentID) else {
            notify("找不到 Agent「\(agentID)」，没有改动", ok: false)
            return
        }
        store.removeProvider(providerID, fromAgentAt: agentIndex)
        do {
            try store.save()
            refresh()
            notify("已从 Agent「\(agentID)」线路移除，模型池保留")
        } catch {
            refresh()
            notify("Agent 线路没保存下来：\(error.localizedDescription)", ok: false)
        }
    }

    /// 按用户拖拽后的顺序保存 Agent 线路。只接受模型池中已有的 provider id，
    /// 不会把客户端配置里的陌生模型偷偷写进 router.json。
    func setAgentProviderOrder(agentID: String, providerIDs: [String]) {
        guard !isReadOnlyMode else {
            notify("当前是只读监测：没有保存 Agent 线路顺序", ok: false)
            return
        }
        guard let agentIndex = store.agentIndex(id: agentID) else {
            notify("找不到 Agent「\(agentID)」，排序没有保存", ok: false)
            return
        }
        let poolIDs = Set(poolModels.map(\.id))
        let currentIDs = (store.agents[agentIndex]["provider_ids"] as? [String]) ?? []
        let filtered = providerIDs.filter { poolIDs.contains($0) }
        let leftovers = currentIDs.filter { !filtered.contains($0) }
        let ordered = filtered + leftovers
        guard ordered != currentIDs else { return }
        store.setProviderOrder(ordered, forAgentAt: agentIndex)
        do {
            try store.save()
            refresh()
        } catch {
            refresh()
            notify("Agent 线路顺序没保存下来：\(error.localizedDescription)", ok: false)
        }
    }

    /// 删除供应商前给用户看的影响范围：返回引用了该供应商模型的 Agent 名称。
    func agentNamesUsingConnection(id: String) -> [String] {
        let providerIDs = Set(store.providers.compactMap { provider -> String? in
            let belongs = (provider["connection_id"] as? String) == id
                || (provider["id"] as? String) == id
            return belongs ? provider["id"] as? String : nil
        })
        guard !providerIDs.isEmpty else { return [] }
        return store.agents.compactMap { agent in
            let ids = Set((agent["provider_ids"] as? [String]) ?? [])
            guard !ids.isDisjoint(with: providerIDs) else { return nil }
            return (agent["name"] as? String) ?? (agent["id"] as? String)
        }
    }

    /// 停用 / 启用一条线路。
    ///
    /// 一处开关要写两处：网关（unified_router.py）把线路交给 Agent 时看的是 `providers[]`
    /// 每一行的 `enabled`，连接行上的 `enabled` 它不读。只改连接行等于装了个假开关 ——
    /// 界面显示「已停用」，网关照样把这条线路发出去。所以这里两处一起写，
    /// 写完再读回来核实：通知里说的是磁盘上的事实，不是这次调用的意图。
    func setConnectionEnabled(id: String, enabled: Bool) {
        guard let connection = connection(id: id) else {
            notify("找不到这条线路（可能刚被删掉）：先刷新一次再看", ok: false)
            return
        }
        let key = "connection-enabled:\(id)"
        guard !isBusy(key) else { return }
        begin(key)
        defer { end(key) }

        store.updateConnection(id: id, with: ["enabled": enabled])
        // 先把行号取出来再改：updateProvider 会动 store 里的数组，边遍历边改容易踩自己。
        let rowIndices = store.providers.enumerated()
            .filter { HubModel.providerRow($0.element, belongsToConnection: id) }
            .map(\.offset)
        for index in rowIndices {
            store.updateProvider(at: index, with: ["enabled": enabled])
        }
        do {
            try store.save()
        } catch {
            refresh()
            return notify("开关没写进 router.json（\(error.localizedDescription)）：界面按磁盘现状显示", ok: false)
        }
        refresh()

        // 只信读回来的：连接行 + 它下面每一行模型行。
        let connectionNow = store.connections
            .first { ($0["id"] as? String) == id }
            .flatMap { $0["enabled"] as? Bool } ?? true
        let rowStates = store.providers
            .filter { HubModel.providerRow($0, belongsToConnection: id) }
            .map { ($0["enabled"] as? Bool) ?? true }
        let wrong = rowStates.filter { $0 != enabled }.count
        guard connectionNow == enabled, wrong == 0 else {
            return notify(
                "开关没落全：\(connection.name) 的连接行读回是「\(connectionNow ? "启用" : "停用")」，"
                + "\(rowStates.count) 行模型行里还有 \(wrong) 行不一致。"
                + "可能有别的程序同时在改 router.json：先看一眼文件，别连点。",
                ok: false
            )
        }
        guard !rowStates.isEmpty else {
            return notify("已\(enabled ? "启用" : "停用") \(connection.name)，但它下面还没有模型行：先给它加一个模型", ok: enabled)
        }
        if enabled {
            notify("已启用 \(connection.name)：它的 \(rowStates.count) 条线路重新交给网关。下次往客户端同步时才会真正写进客户端配置。")
        } else {
            notify("已停用 \(connection.name)：网关不再把它的 \(rowStates.count) 条线路交给 Agent。"
                   + "已经写进客户端配置的历史内容不会自己消失 —— 要换掉它，去客户端里重新同步一条线路。")
        }
    }

    // MARK: Agent 绑定

    func assignModel(providerID: String, toAgent agentID: String) {
        guard !isReadOnlyMode else {
            notify("当前是只读监测：没有修改 Agent 线路", ok: false)
            return
        }
        guard let index = store.agentIndex(id: agentID) else { return }
        let ok = store.assign(providerID: providerID, toAgentAt: index)
        try? store.save()
        refresh()
        if !ok { notify("这个模型已经在该 Agent 里了", ok: false) }
    }

    func removeModel(providerID: String, fromAgent agentID: String) {
        guard !isReadOnlyMode else {
            notify("当前是只读监测：没有修改 Agent 线路", ok: false)
            return
        }
        guard let index = store.agentIndex(id: agentID) else { return }
        store.removeProvider(providerID, fromAgentAt: index)
        try? store.save()
        refresh()
    }

    /// 切换「Agent 线路策略」。
    ///
    /// 前两种是纯设置，点完就生效；`.gateway` 是**一次真写**（改别的客户端配置文件），
    /// 所以只有真的写盘成功才把选择停在这张卡上 —— 取消或失败时卡片留在原来的位置，
    /// 免得界面显示「统一网关」而磁盘上什么都没变。
    func applyStrategy(_ strategy: HubAgentStrategy) {
        switch strategy {
        case .readOnly:
            self.strategy = strategy
            let remembered = rememberStrategy(.readOnly)
            notify("只读模式：不会改动任何 Agent 配置" + HubModel.rememberedSuffix(remembered))
        case .autoFallback:
            self.strategy = strategy
            // 先记住这次选择再 refresh()：refresh 会去读“上次的选择”，顺序反了就会拿旧的
            // 记录来覆盖用户刚点的这一下。Route 层会按同名模型线路自动故障转移，
            // 这里绝不能裁剪 Agent 的模型池或改客户端配置。
            let remembered = rememberStrategy(.autoFallback)
            notify("自动故障转移策略已开启：不修改 Agent 模型池；普通模型只切同名线路，JEV 单独决策。"
                   + HubModel.rememberedSuffix(remembered))
        case .gateway:
            ensureGatewayRunning?()
            // 没有已授权的 4230 Agent 不是切换失败：这是一个合法的“空目标”状态。
            // 先把策略切到接管模式，让用户可以继续配置某个 Agent；语音助手仍走
            // 4202，所有已授权客户端（包括 Codex）统一接入 4230。
            if gatewayWriteTargets().isEmpty {
                self.strategy = .gateway
                let remembered = rememberStrategy(.gateway)
                notify("AI助手接管路由已开启，但当前没有已授权的 4230 Agent；请在 Agent 卡片开启“允许写入”。语音助手仍走 4202。"
                       + HubModel.rememberedSuffix(remembered))
                return
            }
            syncClientsToGateway()
        }
    }

    // MARK: 上次选的策略（落盘 → 读回 → 重新核实）

    /// 读回记录只做一次（一次启动的默认值只该被决定一次）；用户自己点过策略后，
    /// 就再也不让读回的结论改界面。
    private var strategyRecordChecked = false
    private var userPickedStrategy = false

    /// 启动时读回上次的选择；没记录就按默认的只读走，也不去造一份文件出来。
    /// 在 `refresh()` 末尾调用，因为复核要等 `gatewayPort` 从 router.json 里读出来。
    private func restoreStrategyIfRecorded() {
        guard !strategyRecordChecked else { return }
        strategyRecordChecked = true
        let url = HubModel.strategyRecordURL(siblingOf: store.configURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let record = StrategyRecord.read(from: url) else {
            // 坏了就当没有：宁可按只读跑，也不能凭空说「已经切到网关」。
            notify("上次选的策略读不出来（\(HubModel.strategyRecordName) 坏了）：这次先按只读模式跑", ok: false)
            return
        }
        switch record.strategy {
        case .readOnly, .autoFallback:
            // 纯设置，没有外部事实要复核：读回来就能用。
            settleRestore(.keep(record.strategy))
        case .gateway:
            // A gateway strategy is a live process contract, not just a
            // preference. Restore it before probing so a relaunch does not
            // leave clients pointing at a dead 4230 port until the user clicks
            // the strategy card again.
            ensureGatewayRunning?()
            revalidateGatewayRecord(record)
        }
    }

    /// `.gateway` 的复核：探活和查客户端配置都会动进程和磁盘，所以放后台，结论回主线程再改界面。
    private func revalidateGatewayRecord(_ record: StrategyRecord) {
        let configURL = store.configURL
        let configuredPort = gatewayPort
        let targets = gatewayWriteTargets()
        // “接管路由”可以先被选中、再逐个授权 Agent。没有可写目标时没有任何
        // 客户端配置需要复核；把它当成空目标状态保留，不要在每次启动时制造一条
        // 全局红色“没保住”错误，更不能影响语音助手独立使用的 4202 策略链。
        if targets.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.userPickedStrategy else { return }
                self.strategy = .gateway
            }
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let gate = HubModel.gatewayGateForRestore(configURL: configURL, port: configuredPort)
            // 空目标模式记录的是“已接管但尚未授权”，因此 gateway_base_url 可能为空。
            // 一旦用户授权了第一个 Agent，复核必须使用当前探活得到的真实地址，不能
            // 把旧的空字段当成配置丢失，再次弹出“统一网关没保住”。
            let effectiveBaseURL: String? = {
                if let recorded = record.baseURL, !recorded.isEmpty { return recorded }
                if case .ready(_, let liveBaseURL) = gate { return liveBaseURL }
                return nil
            }()
            let pointsAtGateway = HubModel.clientConfigsPointAt(baseURL: effectiveBaseURL,
                                                                targets: targets)
            let decision = HubModel.restoreDecision(recorded: .gateway,
                                                    recordedBaseURL: effectiveBaseURL,
                                                    gate: gate,
                                                    clientsPointAtGateway: pointsAtGateway)
            DispatchQueue.main.async {
                guard let self else { return }
                self.settleRestore(decision)
            }
        }
    }

    /// 复核结论落地。降级只是**显示**退回只读：记录文件不动，用户上次的选择还是他的。
    private func settleRestore(_ decision: HubModel.StrategyRestore) {
        // 复核期间用户自己点过策略，就别拿启动时算出来的旧结论盖掉他的新选择。
        guard !userPickedStrategy else { return }
        switch decision {
        case .keep(let strategy):
            self.strategy = strategy
        case .downgrade(let reason):
            self.strategy = .readOnly
            notify(reason, ok: false)
        }
    }

    /// 把「用户选了哪个策略」记进磁盘。只记选择本身：连通性、客户端配置指向谁这类事实
    /// 每次启动都重新验，写进文件只会变成一个会过期的好消息。
    ///
    /// 写不进去不算失败（选择当场就生效了），但必须说出来 —— 否则用户会以为下次不用再选。
    private func rememberStrategy(_ strategy: HubAgentStrategy, baseURL: String? = nil) -> Bool {
        strategyRecordChecked = true   // 这次的选择比磁盘上那份新，别再让读回覆盖它
        userPickedStrategy = true      // 同时作废还在路上的复核结论
        let record = StrategyRecord(strategy: strategy, baseURL: baseURL, savedAt: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: record.jsonObject) else { return false }
        return (try? data.write(to: HubModel.strategyRecordURL(siblingOf: store.configURL))) != nil
    }

    static func rememberedSuffix(_ remembered: Bool) -> String {
        remembered ? "" : "（这次的选择没能记住，重启后要重新选一次）"
    }

    // MARK: 统一网关策略：预览 → 确认 → 真写

    /// 「统一网关」不是个开关状态，而是一次真写：把客户端配置指向本地网关。
    ///
    /// 流程 = 在临时副本上干跑出真实 diff → 确认框给人看清楚 → 脚本自己备份后写盘。
    /// 客户端写入失败（脚本 stderr）绝不静默，所以每一步都有明确通知。
    private func syncClientsToGateway() {
        guard !isBusy("strategy") else { return }
        guard gatewayPort > 0 else {
            notify("统一网关还没配端口：请在本地路由高级面板里设置网关端口", ok: false)
            return
        }
        guard let scriptURL = RouterStore.scriptURL else {
            notify("找不到 unified_router.py：先运行 ./install.command 再试", ok: false)
            return
        }
        let targets = gatewayWriteTargets()
        guard !targets.isEmpty else {
            strategy = .gateway
            let remembered = rememberStrategy(.gateway)
            notify("AI助手接管路由已开启，但当前没有已授权的 4230 Agent；请在 Agent 卡片开启“允许写入”。语音助手仍走 4202。"
                   + HubModel.rememberedSuffix(remembered))
            return
        }

        let runner = HubStrategySync.Runner(
            pythonURL: HubStrategySync.pythonURL,
            scriptURL: scriptURL,
            configURL: store.configURL
        )
        let configuredPort = gatewayPort
        begin("strategy")   // 预览阶段就挡住重复点击，不让两次写入叠在一起
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 先探活，再看预览：网关连不上就一个字都不该往客户端配置里写，
            // 连预览和确认框都不该出现——那只会让人以为马上要配好一条其实连不上的链路。
            let info = HubStrategySync.gatewayInfo(runner)
            let endpoint = HubStrategySync.endpoint(info: info, fallbackPort: configuredPort)
            // Starting a local Process is asynchronous. Give it a bounded
            // grace period before declaring the port dead; otherwise the first
            // click always loses a race with the freshly spawned gateway.
            let reachable = endpoint.map { endpoint in
                let deadline = Date().addingTimeInterval(3)
                repeat {
                    if HubStrategySync.isListening(host: endpoint.host, port: endpoint.port) { return true }
                    Thread.sleep(forTimeInterval: 0.15)
                } while Date() < deadline
                return false
            } ?? false
            switch HubModel.gatewayGate(baseURL: info?.baseURL, endpoint: endpoint, reachable: reachable) {
            case .blocked(let problem):
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.end("strategy")
                    self.notify(problem, ok: false)
                }
            case .ready(let gateway, let baseURL):
                // 这里的 baseURL 是闸门验过的那一个，非可选：确认框只能带着真地址出现。
                let previews = HubStrategySync.previews(runner, targets: targets)
                let readOnly = HubStrategySync.readOnlyClientNames()
                DispatchQueue.main.async {
                    guard let self else { return }
                    let prompt = HubStrategySync.WritePrompt(
                        targets: targets, previews: previews,
                        readOnlyClients: readOnly, baseURL: baseURL
                    )
                    guard self.presentGatewayConfirm?(prompt) == true else {
                        self.end("strategy")
                        self.notify("已取消：客户端配置一个字都没改")
                        return
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        // 确认框期间网关可能已经退出，真写之前再探一次，不拿旧结论开写。
                        guard HubStrategySync.isListening(host: gateway.host, port: gateway.port) else {
                            DispatchQueue.main.async {
                                self.end("strategy")
                                self.notify("网关刚刚掉线了：客户端配置一个字都没改，先重新启动网关", ok: false)
                            }
                            return
                        }
                        let outcomes = HubStrategySync.apply(runner, targets: targets)
                        let landed = outcomes.contains(where: \.ok)
                        // 只同步 Codex 的模型目录，不碰当前 model，也不重启 Codex。
                        // 目录写入后由用户自己决定何时重启，避免打断正在进行的会话。
                        let catalogSync = landed
                            ? HubCodexCatalogSync.sync(routerURL: self.store.configURL)
                            : nil
                        DispatchQueue.main.async {
                            self.end("strategy")
                            // 真有客户端被写进去，卡片才切到「统一网关」，也才把这次选择记进磁盘：
                            // 没写成功就不记 —— 下次启动读回一个从没发生过的「已切到网关」，
                            // 等于替用户撒谎。
                            let remembered = landed ? self.rememberStrategy(.gateway, baseURL: baseURL) : false
                            if landed { self.strategy = .gateway }
                            let result = HubModel.gatewayWriteNotice(outcomes, baseURL: baseURL)
                            var notice = result.text + HubModel.rememberedSuffix(remembered)
                            if let catalogSync {
                                notice += catalogSync.ok
                                    ? "；" + catalogSync.message
                                    : "；模型目录刷新警告（不影响上面的客户端切换）：" + catalogSync.message
                            }
                            // 客户端配置写入与模型目录刷新是两条独立结果链。
                            // 目录刷新失败不能把已经成功写入的 4230 策略伪装成失败。
                            self.notify(notice, ok: result.ok)
                            self.refresh()
                        }
                    }
                }
            }
        }
    }

    /// 网关写入也必须遵守 Agent 清单里的 editable 标志。
    /// 每个 Agent 的授权独立生效，不能因为另一个客户端被授权就连坐。
    private func gatewayWriteTargets() -> [HubStrategySync.Target] {
        let allowed: Set<String> = Set(clientSpecs.compactMap { spec in
            guard spec.editable else { return nil }
            return HubStrategySync.client(id: spec.id, name: spec.name, path: spec.path)?.rawValue
        })
        return HubStrategySync.gatewayTargets().filter {
            allowed.contains($0.client.rawValue) && $0.isWritable
        }
    }

    private func clientConfigWritable(_ client: HubStrategySync.Client) -> Bool {
        clientSpecs.contains { spec in
            spec.editable
                && HubStrategySync.client(id: spec.id, name: spec.name, path: spec.path) == client
        }
    }

    private func gatewayWriteBlockedNotice() -> String {
        let candidates = HubStrategySync.gatewayTargets()
        guard !candidates.isEmpty else {
            return "没有检测到 4230 网关客户端配置；语音助手策略链仍使用 4202"
        }
        let allowed: Set<String> = Set(clientSpecs.compactMap { spec in
            guard spec.editable else { return nil }
            return HubStrategySync.client(id: spec.id, name: spec.name, path: spec.path)?.rawValue
        })
        let details = candidates.map { target -> String in
            if !allowed.contains(target.client.rawValue) { return "\(target.displayName)：清单未授权" }
            if !target.isWritable { return "\(target.displayName)：文件不可写" }
            return "\(target.displayName)：未通过写入检查"
        }
        return "没有可写的 4230 网关客户端：\(details.joined(separator: "、"))；语音助手策略链仍使用 4202"
    }

    /// 写入前的闸门：网关得真有东西在听，才谈得上改别人的客户端配置。
    ///
    /// 只有 `.ready` 放行，并且放行时把「已经验过的事实」一起交出来（探活打通的 endpoint +
    /// 脚本真读到的 base_url）；其余情况给「事实 + 下一步」。
    ///
    /// 为什么不能只看 `--gateway-info`：网关进程死了它照样返回 `enabled: true` 和一个拼好的
    /// `base_url`（那是按 host/port 拼字符串来的，与进程死活无关），照它写盘就会写出
    /// 一条指向死端口的「幽灵链路」——客户端显示已指向网关，实际上一个字节都送不到。
    enum GatewayGate {
        case ready(endpoint: HubStrategySync.Endpoint, baseURL: String)
        case blocked(String)
    }

    static func gatewayGate(baseURL: String?,
                            endpoint: HubStrategySync.Endpoint?,
                            reachable: Bool) -> GatewayGate {
        guard let endpoint else {
            return .blocked("统一网关还没配端口：请在本地路由高级面板里设置网关端口")
        }
        guard reachable else {
            return .blocked("网关 \(endpoint.label) 启动失败（端口没人监听）：请打开本地路由高级面板查看日志")
        }
        guard let address = normalizedAddress(baseURL) else {
            return .blocked("网关 \(endpoint.label) 通了，但没拿到 base_url：先在「本地路由」里把网关地址配完整，再切这个策略")
        }
        // 「拿到地址」和「放行」在这里是同一步：地址读不出来就只可能走 .blocked，
        // 而 WritePrompt 的 init 也只收非空地址 —— 确认框里写不出一个没读到的地址。
        return .ready(endpoint: endpoint, baseURL: address)
    }

    /// 网关地址的唯一口径：去掉首尾空白，剩下空的就当没有。
    ///
    /// 跟「状态」有关的三处判断（写入门闸、策略记录读/写、客户端配置指向谁）都走这一份，
    /// 免得各写一个「非空就算有」而互相打架。地址来自别处的脚本输出，一个只有空格或换行的值
    /// 同样是「没拿到」：要是它算数，就会被原样写进客户端配置，界面显示「已切到统一网关」，
    /// 而那条链路一个字节都送不出去（自检里 `base_url 只有空格` 那条就是这么抓出来的）。
    /// 确认框那边 `WritePrompt.init` 自己也会 trim 一次，只会更严，不会更松。
    static func normalizedAddress(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 写入结果压成一条消息：先报策略与网关地址，再报每个客户端的结果。
    ///
    /// 全 App 只有一份横幅，所以结果必须挤进同一条文本：成功合并成计数 + 真实备份文件名，
    /// 失败逐条带原因（脚本 stderr 首行）；任何一个客户端失败，整条就是失败态。
    static func gatewayWriteNotice(_ outcomes: [HubStrategySync.Outcome],
                                   baseURL: String?) -> (text: String, ok: Bool) {
        var parts = ["统一网关模式"]
        if let address = normalizedAddress(baseURL) {
            parts[0] += "：客户端统一指向 \(address)"
        }
        let succeeded = outcomes.filter(\.ok)
        let failed = outcomes.filter { !$0.ok }
        if !succeeded.isEmpty {
            let names = succeeded.map(\.client.displayName).joined(separator: "、")
            var line = "已按统一网关写入 \(succeeded.count) 个客户端（\(names)）"
            let backups = succeeded.compactMap(\.backupName)
            if !backups.isEmpty {
                line += "，备份 \(backups.joined(separator: "、"))"
            }
            parts.append(line)
        }
        if !failed.isEmpty {
            parts.append(failed.map(\.line).joined(separator: "；"))
        }
        return (parts.joined(separator: " · "), failed.isEmpty)
    }

    // MARK: 策略的来路（只记选择，事实每次重验）

    /// 磁盘上记着的、上次选的策略。
    ///
    /// 只记「选择」本身和当时的网关地址：连通性、客户端配置指向谁这类**事实**每次启动都重新
    /// 验一遍，写进文件只会变成一个会过期的好消息（网关进程死了，文件里还写着一切正常）。
    /// `.readOnly` / `.autoFallback` 是纯设置，读回就能用；`.gateway` 是「改过别的客户端
    /// 配置文件」这种外部事实，读回必须复核。
    struct StrategyRecord: Equatable {
        var strategy: HubAgentStrategy
        var baseURL: String?
        var savedAt: Date?

        var jsonObject: [String: Any] {
            var object: [String: Any] = ["version": 1, "strategy": strategy.rawValue]
            // 写的时候用跟读的时候同一个口径，否则「写进去的」和「读回来的」不是一份东西。
            if let address = HubModel.normalizedAddress(baseURL) { object["gateway_base_url"] = address }
            if let savedAt { object["saved_at"] = ISO8601DateFormatter().string(from: savedAt) }
            return object
        }

        /// 读不出来的情况一律返回 nil（文件没有 / 不是 JSON / strategy 是不认识的值）：
        /// 调用方按默认的只读走，绝不能凭空显示「已经切到网关」。
        static func read(from url: URL) -> StrategyRecord? {
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let raw = object["strategy"] as? String,
                  let strategy = HubAgentStrategy(rawValue: raw)
            else { return nil }
            let baseURL = HubModel.normalizedAddress(object["gateway_base_url"] as? String)
            let savedAt = (object["saved_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            return StrategyRecord(strategy: strategy, baseURL: baseURL, savedAt: savedAt)
        }
    }

    /// 记录文件跟 router.json 并排（都在本 App 自己的目录里）：不往 ~/.codex 这类别人的
    /// 目录里塞我们自己的状态，卸载 App 时一起走。
    static let strategyRecordName = "hub-strategy.json"

    static func strategyRecordURL(siblingOf configURL: URL) -> URL {
        configURL.deletingLastPathComponent().appendingPathComponent(strategyRecordName)
    }

    /// 复核结论：要么照旧用读回来的那个选择，要么退回只读并带上一条**真实理由**。
    /// 没有第三种「看起来像网关但没验过」的中间态。
    enum StrategyRestore: Equatable {
        case keep(HubAgentStrategy)
        case downgrade(reason: String)
    }

    /// 拿**现在**的事实重新核一遍「上次选的策略」还成不成立。
    ///
    /// 只有 `.gateway` 需要复核，因为它是这批策略里唯一在磁盘上留下过痕迹的那个：网关得还有人
    /// 在听（跟切换前同一道闸门），并且客户端配置里真能查到当时写进去的地址。两条有一条不成立，
    /// 就落到闸门给的真实理由上（没配端口 / 连不上 / 配置被改回去了），显示成只读 ——
    /// 界面显示什么，磁盘上就得是什么。
    static func restoreDecision(recorded: HubAgentStrategy,
                                recordedBaseURL: String?,
                                gate: GatewayGate,
                                clientsPointAtGateway: Bool) -> StrategyRestore {
        switch recorded {
        case .readOnly, .autoFallback:
            return .keep(recorded)
        case .gateway:
            switch gate {
            case .blocked(let problem):
                return .downgrade(reason: "上次选的「统一网关」没保住：" + problem)
            case .ready(let endpoint, _):
                guard clientsPointAtGateway else {
                    let detail = recordedBaseURL.map { "客户端配置里查不到 \($0)" } ?? "记不清当时指向哪个网关"
                    return .downgrade(reason: "上次选的「统一网关」没保住：网关 \(endpoint.label) 在听，"
                                      + "但 \(detail)：重新切一次「统一网关」把配置写回去")
                }
                return .keep(.gateway)
            }
        }
    }

    /// 「客户端配置真的指向这个网关」：在各客户端配置文件里按地址字面查一遍。
    ///
    /// 只做包含判断，不解析各家的配置格式 —— 判错的代价必须是显示得保守（退回只读、让人重切
    /// 一次），而不是显示成「已切到网关」而磁盘上其实没指向它。
    static func clientConfigsPointAt(baseURL: String?, targets: [HubStrategySync.Target]) -> Bool {
        guard let address = normalizedAddress(baseURL) else { return false }
        let needle = HubStrategySync.endpoint(inBaseURL: address)?.label ?? address
        for target in targets {
            guard let text = try? String(contentsOf: target.fileURL, encoding: .utf8) else { continue }
            if text.contains(needle) { return true }
        }
        return false
    }

    /// 复核 `.gateway` 记录用的闸门：跟真切换时走的是同一个 `gatewayGate`，只是入口不同。
    /// 两套口径会养出「切换时挡住、启动时放行」这种洞。
    static func gatewayGateForRestore(configURL: URL, port: Int,
                                     scriptURL: URL? = RouterStore.scriptURL) -> GatewayGate {
        guard let scriptURL else {
            return .blocked("找不到 unified_router.py：先运行 ./install.command 再试")
        }
        let runner = HubStrategySync.Runner(pythonURL: HubStrategySync.pythonURL,
                                            scriptURL: scriptURL,
                                            configURL: configURL)
        let info = HubStrategySync.gatewayInfo(runner)
        let endpoint = HubStrategySync.endpoint(info: info, fallbackPort: port)
        // 跟「切换」那条路对齐：给刚被拉起/重启的网关 3 秒宽限，别因为一次性探活
        // 恰好落在重启窗口里，就把「上次选了统一网关」误降级成只读。
        let reachable = endpoint.map { endpoint in
            let deadline = Date().addingTimeInterval(3)
            repeat {
                if HubStrategySync.isListening(host: endpoint.host, port: endpoint.port) { return true }
                Thread.sleep(forTimeInterval: 0.15)
            } while Date() < deadline
            return false
        } ?? false
        return gatewayGate(baseURL: info?.baseURL, endpoint: endpoint, reachable: reachable)
    }

    // MARK: 写别的 Agent 配置

    func planSync(agentID: String) -> Result<HubAgentSync.Plan, Error> {
        guard let agent = agents.first(where: { $0.id == agentID }) else {
            return .failure(HubAgentSync.Failure.missing(agentID))
        }
        guard let url = agent.configURL else {
            return .failure(HubAgentSync.Failure.missing("没有检测到 \(agent.name) 的配置文件"))
        }
        return Result { try HubAgentSync.plan(agentName: agent.name, fileURL: url) }
    }

    func applySync(plan: HubAgentSync.Plan, model: String) -> Result<HubAgentSync.Result, Error> {
        guard let client = HubStrategySync.client(id: plan.agentName, name: plan.agentName,
                                                  path: plan.fileURL.path),
              client != .codex,
              clientConfigWritable(client) else {
            let error = HubAgentSync.Failure.unsupported("当前是只读监测：未写入客户端配置")
            notify(error.localizedDescription, ok: false)
            return .failure(error)
        }
        let result = Result { try HubAgentSync.apply(plan, model: model) }
        if case .success(let outcome) = result {
            notify("已同步 \(plan.agentName) → \(model)，备份：\(outcome.backupURL.lastPathComponent)")
        } else if case .failure(let error) = result {
            notify("同步失败：\(error.localizedDescription)", ok: false)
        }
        refresh()
        return result
    }

    /// 只读模式下切换 Codex 的官方账号/API 登录方式；不改 router.json 或 4230。
    func applyReadOnlyCodexModel(fileURL: URL, model: String) {
        guard strategy == .readOnly else {
            notify("当前不是只读模式：不通过这条通道改 Codex 登录方式", ok: false)
            return
        }
        do {
            let result = try HubAgentSync.applyCodexReadOnlySelection(fileURL: fileURL, model: model)
            let label = HubAgentSync.codexReadOnlyAuthMode(for: model) == .official ? "官方账号" : "API 直连"
            notify("已写入 Codex：\(model) · \(label)。请手动重启 Codex 后生效；router.json/4230 未改。备份：\(result.backupURL.lastPathComponent)")
            refresh()
        } catch {
            notify("Codex 只读切换失败：\(error.localizedDescription)", ok: false)
        }
    }

    static func isOfficialCodexModel(_ model: String) -> Bool {
        codexReadOnlyModelKind(model) == .official
    }

    private enum CodexReadOnlyModelKind { case official, direct, unsupported }

    private static func codexReadOnlyModelKind(_ model: String) -> CodexReadOnlyModelKind {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("gpt-") || value == "codex-auto-review" { return .official }
        if value.hasPrefix("deepseek-") { return .direct }
        return .unsupported
    }

    // MARK: 把模型池里的模型加进客户端

    /// 网关现在是不是真的连得上：`--gateway-info` 只说明配置里写了什么，
    /// 连不上就是连不上（网关进程死了它照样返回一个拼好的 base_url）。
    /// 先请窗口把网关拉起来（`ensureRunning`），再给 3 秒宽限 ——
    /// 刚启动的网关会有短暂的不可用，这个秒数跟「统一网关」那条路用的是同一个。
    static func gatewayReachable(runner: HubStrategySync.Runner,
                                 configuredPort: Int,
                                 ensureRunning: (() -> Void)? = nil) -> Bool {
        let info = HubStrategySync.gatewayInfo(runner)
        guard let endpoint = HubStrategySync.endpoint(info: info, fallbackPort: configuredPort) else { return false }
        if HubStrategySync.isListening(host: endpoint.host, port: endpoint.port) { return true }
        guard let ensureRunning else { return false }
        // 拉起网关要碰窗口控制器，只能在主线程做。调用方都在后台队列上，
        // 主线程这一刻没有在等我们，所以同步跳一次是安全的。
        if Thread.isMainThread {
            ensureRunning()
        } else {
            DispatchQueue.main.sync(execute: ensureRunning)
        }
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if HubStrategySync.isListening(host: endpoint.host, port: endpoint.port) { return true }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return false
    }

    /// 把模型池里的一个模型加进某个客户端（改它的配置文件）。
    ///
    /// 这条路全程可查：干跑（`--plan-agent-model`）先算出真 diff 给人看，用户确认后
    /// 由脚本自己备份再写盘，写完用两次读回核实（脚本报的模型清单 + 重跑一次干跑）。
    /// 脚本明确不支持写入的客户端（Claude Code 之类）在这里一律拒绝：不猜着改别人的配置。
    func addModelToClient(clientID: String,
                          clientName: String,
                          clientPath: String,
                          providerID: String,
                          modelID: String) {
        guard let client = HubStrategySync.client(id: clientID, name: clientName, path: clientPath) else {
            notify("\(clientName) 不在脚本支持写入的清单里（只支持 Codex / ZCode）：没改它，也不假装改了", ok: false)
            return
        }
        // Codex 的适配器只写 router.json 的 client_assignments.codex，
        // 不改 ~/.codex/config.toml；其它客户端必须单独授予 clientWritable。
        guard client == .codex || clientConfigWritable(client) else {
            notify("当前是只读监测：未写入 \(clientName) 配置", ok: false)
            return
        }
        guard let target = HubStrategySync.targets().first(where: { $0.client == client }) else {
            notify("没找到 \(client.displayName) 的配置文件：先让它自己跑一次生成配置，再来加", ok: false)
            return
        }
        guard target.isWritable else {
            notify("\(target.displayPath) 现在不可写（权限或只读卷）：一个字都没改", ok: false)
            return
        }
        guard providerEnabled(providerID) else {
            notify("这条线路在模型池里是停用的：先在它的供应商卡片里启用，再往 \(client.displayName) 里加", ok: false)
            return
        }
        guard let scriptURL = RouterStore.scriptURL else {
            notify("找不到 unified_router.py：先运行 ./install.command 再试", ok: false)
            return
        }
        let key = "client-model:\(providerID)"
        guard !isBusy(key) else { return }
        let runner = HubStrategySync.Runner(pythonURL: HubStrategySync.pythonURL,
                                            scriptURL: scriptURL,
                                            configURL: store.configURL)
        let providerLabel = modelName(providerID: providerID)
        let fileURL = target.fileURL
        let displayPath = target.displayPath
        begin(key)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            func stop(_ text: String) {
                DispatchQueue.main.async {
                    self.end(key)
                    self.notify(text, ok: false)
                }
            }
            // 所有 Agent 客户端统一验证 4230；语音助手自己的调用链不经过这里。
            let reachable = HubModel.gatewayReachable(
                runner: runner,
                configuredPort: self.gatewayPort,
                ensureRunning: self.ensureGatewayRunning
            )
            let preview = HubStrategySync.previewAgentModel(runner,
                                                           client: client,
                                                           fileURL: fileURL,
                                                           displayPath: displayPath,
                                                           providerID: providerID,
                                                           model: modelID)
            if let reason = HubStrategySync.agentModelGate(preview, gatewayReachable: reachable) {
                return stop(reason)
            }
            guard preview.isWorthApplying else {
                DispatchQueue.main.async {
                    self.end(key)
                    let shownModel = client == .codex ? modelID : (preview.model ?? modelID)
                    self.notify("\(client.displayName) 已经在用 \(shownModel) 了：没改任何文件")
                }
                return
            }
            let prompt = HubStrategySync.AgentModelWritePrompt(preview: preview,
                                                              model: modelID,
                                                              providerLabel: providerLabel)
            DispatchQueue.main.async {
                // 取消 = 一个字都不改。这是设计内的结果，按惯例不弹提示。
                guard self.presentAgentModelConfirm?(prompt) == true else {
                    self.end(key)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    // 确认框开着的这段时间里 4230 可能掉线，任何 Agent 都不能写入死链路。
                    guard HubModel.gatewayReachable(
                        runner: runner,
                        configuredPort: self.gatewayPort,
                        ensureRunning: self.ensureGatewayRunning
                    ) else {
                        return stop("\(client.displayName) 没写入：确认期间网关掉线了，先重启网关再试")
                    }
                    let outcome = HubStrategySync.applyAgentModel(runner,
                                                                 client: client,
                                                                 fileURL: fileURL,
                                                                 displayPath: displayPath,
                                                                 providerID: providerID,
                                                                 model: modelID)
                    // 核实里那句「网关在跑」要是刚读出来的，不能拿确认之前的旧结论。
                    let stillReachable = client == .codex || HubModel.gatewayReachable(
                        runner: runner,
                        configuredPort: self.gatewayPort
                    )
                    let verdict = HubStrategySync.verifyAgentModelWrite(outcome,
                                                                       runner: runner,
                                                                       providerID: providerID,
                                                                       model: modelID,
                                                                       gatewayReachable: stillReachable)
                    let catalogSync = client == .codex && verdict.ok
                        ? HubCodexCatalogSync.sync(routerURL: self.store.configURL)
                        : nil
                    DispatchQueue.main.async {
                        self.end(key)
                        self.refresh()
                        let message: String
                        if let catalogSync {
                            message = verdict.line + (catalogSync.ok
                                ? "；\(catalogSync.message)"
                                : "；模型目录刷新警告（不影响模型写入）：\(catalogSync.message)")
                        } else {
                            message = verdict.line
                        }
                        self.notify(message, ok: verdict.ok)
                    }
                }
            }
        }
    }

    // MARK: Jev 档位

    func setTier(_ tier: String, providerID: String?) {
        store.setJevModel(tier: tier, providerID: providerID ?? "")
        try? store.save()
        refresh()
        if let providerID {
            notify("\(tier.uppercased()) → \(modelName(providerID: providerID))")
        } else {
            notify("\(tier.uppercased()) 已清空")
        }
    }

    var defaultTierMapping: [String: String] { initialTierMapping ?? tiers }

    var defaultTierCandidates: [String: [String]] {
        if !tierCandidates.isEmpty { return tierCandidates }
        return defaultTierMapping.reduce(into: [:]) { result, item in
            result[item.key] = item.value.isEmpty ? [] : [item.value]
        }
    }

    func saveTiers(_ mapping: [String: [String]]) {
        for tier in tierOrder {
            store.setJevModels(tier: tier, providerIDs: mapping[tier] ?? [])
        }
        try? store.save()
        refresh()
        notify("已保存 Jev 四档映射与故障转移顺序")
    }

    var tierNames: [String] { tierOrder }

    // MARK: - 无界面自检

    /// 无界面自检：上次选的策略「记哪三档、怎么读回、读回后拿什么事实重新核」。
    ///
    /// 只碰临时目录里的假 router.json / 假客户端配置，加一个真在监听的临时端口；用户真实的
    /// ~/.codex、~/.zcode 一个字节都不读不写。返回 0 表示全部通过，1 表示有断言失败。
    static func selfTest() -> Int32 {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hub-strategy-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("router.json")
        let recordURL = strategyRecordURL(siblingOf: configURL)
        let clientURL = directory.appendingPathComponent("fake-client-config.toml")
        let endpoint4230 = HubStrategySync.Endpoint(host: "127.0.0.1", port: 4230)
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }

        check(!agentWritesAllowed(for: .readOnly)
              && !agentWritesAllowed(for: .autoFallback)
              && agentWritesAllowed(for: .gateway),
              "只有统一网关策略允许写 Agent 配置")

        let arkCatalog = modelCatalogURLs(baseURL: "https://ark.cn-beijing.volces.com/api/plan/v3")?
            .map(\.absoluteString)
        check(arkCatalog == [
            "https://ark.cn-beijing.volces.com/api/plan/v3/models",
            "https://ark.cn-beijing.volces.com/api/v3/models",
        ], "Ark Plan 先探测 plan，再回退标准 /api/v3 模型清单")
        check(modelCatalogURLs(baseURL: "https://api.example.test/v1")?.map(\.absoluteString)
              == ["https://api.example.test/v1/models"],
              "标准 /v1 地址只请求一次 /models")
        check(modelCatalogURLs(baseURL: "not a URL") == nil,
              "模型清单地址拒绝非法 URL")

        // 列表探测失败后改走生成探测：地址要拼对，不合法就别猜端口。
        check(chatCompletionsURL(baseURL: "https://ark.cn-beijing.volces.com/api/plan/v3")?.absoluteString
              == "https://ark.cn-beijing.volces.com/api/plan/v3/chat/completions",
              "生成探测地址接在 base_url 后面")
        check(chatCompletionsURL(baseURL: "https://api.example.test/v1/")?.absoluteString
              == "https://api.example.test/v1/chat/completions",
              "生成探测地址容忍结尾斜杠")
        check(chatCompletionsURL(baseURL: "https://api.example.test/v1/chat/completions")?.absoluteString
              == "https://api.example.test/v1/chat/completions",
              "生成探测地址不重复接 /chat/completions")
        check(chatCompletionsURL(baseURL: "not a URL") == nil
              && chatCompletionsURL(baseURL: "ftp://api.example.test/v1") == nil
              && chatCompletionsURL(baseURL: "   ") == nil,
              "生成探测只认 http(s) 合法地址")
        check(probeModelID(from: "glm-5.3 (glm-latest)") == "glm-5.3"
              && probeModelID(from: "glm-4.6（界面上给人看的备注）") == "glm-4.6"
              && probeModelID(from: "  gpt-5.1  ") == "gpt-5.1",
              "生成探测剥掉模型名结尾的备注")
        check(needsGenerationProbe(error: NetError.catalogUnavailable, wireAPI: "chat_completions", modelID: "glm-5.3")
              && needsGenerationProbe(error: NetError.catalogUnavailable, wireAPI: "", modelID: "glm-5.3"),
              "接口说没有 /models 时改用生成探测")
        check(!needsGenerationProbe(error: NetError.catalogUnavailable, wireAPI: "chat_completions", modelID: "")
              && !needsGenerationProbe(error: NetError.catalogUnavailable, wireAPI: "responses", modelID: "glm-5.3")
              && !needsGenerationProbe(error: NetError.status(401, "unauthorized"), wireAPI: "chat_completions", modelID: "glm-5.3")
              && !needsGenerationProbe(error: NetError.status(500, "boom"), wireAPI: "chat_completions", modelID: "glm-5.3")
              && !needsGenerationProbe(error: NetError.badURL, wireAPI: "chat_completions", modelID: "glm-5.3")
              && !needsGenerationProbe(error: URLError(.timedOut), wireAPI: "chat_completions", modelID: "glm-5.3"),
              "没有模型名、凭据不对、超时、responses 协议都不拿生成探测去掩盖")

        check(isRouteProvider(["kind": "openai_compatible", "source": "manual"]),
              "OpenAI 兼容供应商进入本地路由模型池")
        check(!isRouteProvider(["kind": "command", "source": "dsh:codex"]),
              "Agent 命令客户端不进入本地路由模型池")
        check(!isRouteProvider(["kind": "openai_compatible", "source": "dsh:ark-agent"]),
              "Agent API 客户端不进入本地路由模型池")
        let jevInternal: [String: Any] = [
            "id": "codex-router-gpt-6-sol", "kind": "openai_compatible",
            "source": "dsh:codex-router", "model": "gpt-6-sol",
        ]
        let jevExternal: [String: Any] = [
            "id": jevProviderID, "kind": "openai_compatible",
            "source": "dsh:codex-router", "model": "jev/auto",
        ]
        check(!isExternallyVisiblePoolProvider(jevInternal)
              && isExternallyVisiblePoolProvider(jevExternal)
              && exposedModelName(providerID: jevProviderID, model: "jev/auto") == "jev-auto",
              "4202 内部模型隐藏，只暴露 Jev / 4202 的 jev-auto")
        check(isRouteConnection(["kind": "openai_compatible", "source": "dsh:teamorouter"]),
              "API 供应商连接进入本地路由页面")
        check(!isRouteConnection(["kind": "openai_compatible", "source": "dsh:agent"]),
              "Agent API 连接不进入本地路由页面")
        check(!isRouteConnection(["kind": "command", "name": "Codex CLI"]),
              "Agent 命令连接不进入本地路由页面")
        let legacyFlat: [String: Any] = [
            "id": "legacy-provider", "name": "旧供应商 · legacy-model",
            "kind": "openai_compatible", "base_url": "https://legacy.example/v1",
            "model": "legacy-model", "enabled": true,
        ]
        let projected = syntheticConnection(for: legacyFlat)
        check(projected?["flat_provider_id"] as? String == "legacy-provider"
              && (projected?["models"] as? [[String: Any]])?.first?["id"] as? String == "legacy-model",
              "已有 connections 时仍保留旧 flat provider 的供应商与模型")

        // 临时端口：一个真在监听（探活必须认出它）、一个刚关掉（探活必须不认）。
        // 少了「认得出」那一半，后面「没人听就挡住」会变成假通过。
        let probe = TempPorts.spawn()
        defer { probe?.stop() }
        if let probe {
            check(HubStrategySync.isListening(host: "127.0.0.1", port: probe.live),
                  "探活认得出真在监听的端口 \(probe.live)")
            check(!HubStrategySync.isListening(host: "127.0.0.1", port: probe.dead),
                  "探活不认刚关掉的端口 \(probe.dead)")
        } else {
            print("SKIP 起不到临时端口（\(TempPorts.failureReason)）：跳过探活相关的断言")
        }

        /// 假网关脚本：`--gateway-info` 的输出完全由端口决定（nil = 脚本直接报错）。
        func fakeScript(port: Int?) -> URL? {
            let url = directory.appendingPathComponent("fake-gateway-\(port.map(String.init) ?? "err").py")
            let body = port.map { """
            import json
            print(json.dumps({"enabled": True, "host": "127.0.0.1", "port": \($0),
                              "base_url": "http://127.0.0.1:\($0)/v1"}))
            """ } ?? "import sys\nsys.exit(1)\n"
            return (try? body.write(to: url, atomically: true, encoding: .utf8)) == nil ? nil : url
        }

        // MARK: 记录文件：写一份、读回来、坏文件当没有

        let record = StrategyRecord(strategy: .gateway,
                                    baseURL: "http://127.0.0.1:4230/v1",
                                    savedAt: Date(timeIntervalSince1970: 1_700_000_000))
        if let data = try? JSONSerialization.data(withJSONObject: record.jsonObject) {
            try? data.write(to: recordURL)
        }
        check(StrategyRecord.read(from: recordURL) == record, "策略记录写盘后能原样读回（含网关地址）")
        check(strategyRecordURL(siblingOf: configURL).deletingLastPathComponent().path == directory.path,
              "记录跟 router.json 并排放在本 App 自己的目录里（\(strategyRecordName)）")

        let unknownURL = directory.appendingPathComponent("unknown-strategy.json")
        _ = try? #"{"version": 1, "strategy": "gateway-legacy"}"#
            .write(to: unknownURL, atomically: true, encoding: .utf8)
        check(StrategyRecord.read(from: unknownURL) == nil, "不认识的策略名当没有，不猜成任何一档")

        let brokenURL = directory.appendingPathComponent("broken-strategy.json")
        _ = try? "{ not json".write(to: brokenURL, atomically: true, encoding: .utf8)
        check(StrategyRecord.read(from: brokenURL) == nil, "坏文件当没有记录（宁可按只读跑，也不能说已切网关）")
        check(StrategyRecord.read(from: directory.appendingPathComponent("nope.json")) == nil,
              "从没记过就读不出来，不凭空造一份")

        let bareURL = directory.appendingPathComponent("bare-strategy.json")
        _ = try? #"{"version": 1, "strategy": "autoFallback", "gateway_base_url": "   "}"#
            .write(to: bareURL, atomically: true, encoding: .utf8)
        let bare = StrategyRecord.read(from: bareURL)
        check(bare?.strategy == .autoFallback && bare?.baseURL == nil,
              "纯设置档没有地址也读得回来，空白地址不算地址")

        let keys = Set(record.jsonObject.keys)
        check(keys == Set(["version", "strategy", "gateway_base_url", "saved_at"]),
              "记录里只有选择本身和当时的地址，没有连通性这类会过期的好消息：\(keys.sorted())")

        // MARK: 复核：三档策略 ×（闸门结论、客户端配置指向谁）

        let readyGate = GatewayGate.ready(endpoint: endpoint4230, baseURL: "http://127.0.0.1:4230/v1")
        let deadGate = GatewayGate.blocked("网关 127.0.0.1:4230 连不上（端口没人监听）")

        check(restoreDecision(recorded: .readOnly, recordedBaseURL: nil,
                              gate: deadGate, clientsPointAtGateway: false) == .keep(.readOnly),
              "只读档不受外部事实影响：网关没了也还是只读")
        check(restoreDecision(recorded: .autoFallback, recordedBaseURL: nil,
                              gate: deadGate, clientsPointAtGateway: false) == .keep(.autoFallback),
              "自动故障转移是纯设置：网关死活与它无关")

        if case .downgrade(let reason) = restoreDecision(recorded: .gateway,
                                                         recordedBaseURL: "http://127.0.0.1:4230/v1",
                                                         gate: deadGate, clientsPointAtGateway: false) {
            check(reason.contains("连不上"), "网关没了：降级理由带的是闸门的真事实")
        } else {
            check(false, "网关没了：必须降级成只读，不能显示「已切到网关」")
        }

        if case .downgrade(let reason) = restoreDecision(recorded: .gateway,
                                                         recordedBaseURL: "http://127.0.0.1:4230/v1",
                                                         gate: readyGate, clientsPointAtGateway: false) {
            check(reason.contains("127.0.0.1:4230") && reason.contains("重新切一次"),
                  "网关在听但客户端配置里查不到那个地址：降级并说清下一步")
        } else {
            check(false, "网关在听但客户端配置被改回去了：也必须降级")
        }

        if case .downgrade(let reason) = restoreDecision(recorded: .gateway, recordedBaseURL: nil,
                                                         gate: readyGate, clientsPointAtGateway: false) {
            check(reason.contains("记不清"), "没留地址又查不到：说「记不清」，不假装核对过")
        } else {
            check(false, "没留地址又查不到：必须降级")
        }

        check(restoreDecision(recorded: .gateway,
                              recordedBaseURL: "http://127.0.0.1:4230/v1",
                              gate: readyGate, clientsPointAtGateway: true) == .keep(.gateway),
              "网关真在听 + 客户端配置真指向它：才回到统一网关")

        // 关键反例：客户端配置里还留着上次写进去的地址，但网关进程已经死了。
        // 只看文件就会显示「已切到网关」——那是一条一个字节都送不到的幽灵链路。
        if case .downgrade = restoreDecision(recorded: .gateway,
                                             recordedBaseURL: "http://127.0.0.1:4230/v1",
                                             gate: deadGate, clientsPointAtGateway: true) {
            check(true, "配置文件里还留着地址但网关已死：仍然降级（不认过期的好消息）")
        } else {
            check(false, "配置文件里还留着地址但网关已死：必须降级，不能被文件里的字面地址放行")
        }

        // MARK: 客户端配置到底指向谁
        //
        // 每条都带上一个真存在的目标文件：目标列表是空的时侯，函数无论如何都返回 false，
        // 那样「空地址不算指向」会因为「压根没找过」而通过 —— 看着过了，其实没验。

        let target = HubStrategySync.Target(client: .codex, fileURL: clientURL,
                                            isWritable: true, displayPath: clientURL.path)
        let missingTarget = HubStrategySync.Target(client: .zcode,
                                                   fileURL: directory.appendingPathComponent("missing.json"),
                                                   isWritable: false, displayPath: "missing.json")

        _ = try? "model_provider = \"gateway\"\nbase_url = \"http://127.0.0.1:4230/v1\"\n"
            .write(to: clientURL, atomically: true, encoding: .utf8)
        check(!clientConfigsPointAt(baseURL: nil, targets: [target]), "没有地址就是没指向")
        check(!clientConfigsPointAt(baseURL: "   ", targets: [target]),
              "只有空白的地址不算地址（否则会被原样写进客户端配置）")
        check(clientConfigsPointAt(baseURL: "http://127.0.0.1:4230/v1", targets: [target]),
              "客户端配置里查得到那串地址")
        check(!clientConfigsPointAt(baseURL: "http://127.0.0.1:4231/v1", targets: [target]),
              "换成别的端口就查不到了（不能把 4230 认成 4231）")
        check(!clientConfigsPointAt(baseURL: "http://127.0.0.1:4230/v1", targets: [missingTarget]),
              "读不到的目标跳过，不算指向")
        check(!clientConfigsPointAt(baseURL: "http://127.0.0.1:4230/v1", targets: []),
              "一个客户端配置都没找到 = 没指向")

        let blankURL = directory.appendingPathComponent("blank-client-config.toml")
        _ = try? "model_provider = \"gateway\"\nbase_url = \"   \"\n"
            .write(to: blankURL, atomically: true, encoding: .utf8)
        check(!clientConfigsPointAt(baseURL: "   ", targets: [
            HubStrategySync.Target(client: .zcode, fileURL: blankURL,
                                   isWritable: false, displayPath: blankURL.path)
        ]), "配置文件里只有一串空格：也不算指向这个网关")

        // MARK: 写入闸门（切换时走的就是这道）

        func readyBaseURL(_ gate: GatewayGate) -> String? {
            if case .ready(_, let baseURL) = gate { return baseURL }
            return nil
        }
        func blockedReason(_ gate: GatewayGate) -> String? {
            if case .blocked(let reason) = gate { return reason }
            return nil
        }

        if let reason = blockedReason(gatewayGate(baseURL: "http://127.0.0.1:4230/v1",
                                                  endpoint: nil, reachable: true)) {
            check(reason.contains("端口"), "没配端口：挡住，并说去高级面板设端口")
        } else {
            check(false, "没配端口时必须挡住")
        }
        if let reason = blockedReason(gatewayGate(baseURL: "http://127.0.0.1:4230/v1",
                                                  endpoint: endpoint4230, reachable: false)) {
            // 断言的是「事实 + 位置」：说清是哪个端口没人监听，只凭一句笼统的「连不上」
            // 用户在高级面板里还得自己猜端口。文案以后可以改，但这两件事必须在。
            check(reason.contains("没人监听") && reason.contains(endpoint4230.label),
                  "端口没人听：挡住，并指名是哪个端口没人监听")
        } else {
            check(false, "端口没人听时必须挡住")
        }
        check(blockedReason(gatewayGate(baseURL: nil, endpoint: endpoint4230, reachable: true)) != nil,
              "通了但没拿到 base_url：挡住，不能让确认框写出一个没读到的地址")
        check(blockedReason(gatewayGate(baseURL: "  ", endpoint: endpoint4230, reachable: true)) != nil,
              "base_url 只有空格：同样挡住（不是「非空就算有」）")
        check(readyBaseURL(gatewayGate(baseURL: "  http://127.0.0.1:4230/v1  ",
                                       endpoint: endpoint4230, reachable: true))
              == "http://127.0.0.1:4230/v1",
              "地址带首尾空白：放行的是去过空白的那个，写进配置的跟查得到的得是同一串")
        check(readyBaseURL(gatewayGate(baseURL: "http://127.0.0.1:4230/v1",
                                       endpoint: endpoint4230, reachable: true))
              == "http://127.0.0.1:4230/v1",
              "三条都成立才放行，且放行的就是验过的那串地址")

        // MARK: 复核入口：跟切换共用同一个闸门，事实不同则结论必须不同

        if let reason = blockedReason(gatewayGateForRestore(configURL: configURL, port: 4230,
                                                            scriptURL: nil)) {
            check(reason.contains("unified_router.py"), "找不到脚本：复核也挡住，不因为「启动时」就放行")
        } else {
            check(false, "找不到脚本时复核必须挡住")
        }

        // 探活相关的断言要有真端口才成立：起不到临时端口就报 SKIP，不报 FAIL ——
        // 把「没跑成」说成「跑失败了」，跟把失败说成通过一样是在骗人。
        if let probe {
            if let noInfoScript = fakeScript(port: nil),
               let reason = blockedReason(gatewayGateForRestore(configURL: configURL, port: probe.dead,
                                                                scriptURL: noInfoScript)) {
                // 复核入口走的是同一个闸门：回退到 router.json 的端口去探活，结论也得说清是哪个端口。
                check(reason.contains("没人监听") && reason.contains("\(probe.dead)"),
                      "网关信息读不出来：退到 router.json 的端口去探活，没人听就挡")
            } else {
                check(false, "网关信息读不出来又没人听时必须挡住")
            }

            if let liveScript = fakeScript(port: probe.live) {
                check(readyBaseURL(gatewayGateForRestore(configURL: configURL, port: probe.dead,
                                                         scriptURL: liveScript))
                      == "http://127.0.0.1:\(probe.live)/v1",
                      "脚本说在听、端口真在听：放行，并带回脚本给的那个地址")
            } else {
                check(false, "假网关脚本没写出来：探活正向断言没跑成")
            }

            if let deadScript = fakeScript(port: probe.dead) {
                check(blockedReason(gatewayGateForRestore(configURL: configURL, port: probe.dead,
                                                          scriptURL: deadScript)) != nil,
                      "脚本照样报 enabled/base_url，但端口没人听：必须挡住（幽灵链路）")
            } else {
                check(false, "假网关脚本没写出来：探活反向断言没跑成")
            }
        } else {
            print("SKIP 没拿到真端口：跳过复核入口的探活断言")
        }

        try? FileManager.default.removeItem(at: directory)
        print(failures == 0 ? "上次策略自检全部通过" : "上次策略自检失败 \(failures) 项")
        return failures == 0 ? 0 : 1
    }

    /// 自检用的临时端口：一个 bind 完立刻关掉（探活必须不认），一个是真在 listen（探活必须认）。
    /// 端口由内核分配，不写死，所以不会撞上用户真在跑的网关。
    private final class TempPorts {
        var dead = 0
        var live = 0
        static var failureReason = "没试过"
        private let process = Process()

        static func spawn() -> TempPorts? {
            let ports = TempPorts()
            ports.process.executableURL = HubStrategySync.pythonURL
            ports.process.arguments = ["-c", """
            import socket, time
            s1 = socket.socket(); s1.bind(("127.0.0.1", 0)); dead = s1.getsockname()[1]; s1.close()
            s2 = socket.socket(); s2.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s2.bind(("127.0.0.1", 0)); s2.listen(5); live = s2.getsockname()[1]
            print("%d %d" % (dead, live), flush=True)
            time.sleep(120)
            """]
            let pipe = Pipe()
            ports.process.standardOutput = pipe
            ports.process.standardError = FileHandle.nullDevice
            do {
                try ports.process.run()
            } catch {
                failureReason = "python3 起不来：\(error.localizedDescription)"
                return nil
            }
            let text = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
            // 按「数字」切，不按空格切：脚本每行末尾的换行会黏在最后一个端口上，
            // 让 Int("58100\n") 变成 nil —— 这样切出来的只有纯数字。
            let parts = text.split(whereSeparator: { !$0.isNumber })
            guard parts.count == 2, let dead = Int(parts[0]), let live = Int(parts[1]) else {
                failureReason = "python3 没报出端口，读到「\(text.prefix(200))」"
                ports.stop()
                return nil
            }
            ports.dead = dead
            ports.live = live
            return ports
        }

        func stop() {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: 模型池按来源分组（① 用）

    /// 行上没有 `source` 就跟随它归属的连接：同一批线路在 ① 里才会归成一组。
    static func effectiveSource(_ provider: [String: Any], connection: [String: Any]) -> String {
        let own = (provider["source"] as? String) ?? ""
        if !own.isEmpty { return own }
        return (connection["source"] as? String) ?? ""
    }

    /// `source` 是机器字段，界面不直接显示它，先翻译成人话。
    static func sourceLabel(_ source: String) -> String {
        let key = source.lowercased()
        if key.isEmpty || key == "manual" { return "手动添加" }
        if key == jevInternalSource { return "4202 内部线路" }
        if key == "jev:4202" { return "Jev / 4202" }
        if key == "dsh:teamorouter" { return "TeamoRouter" }
        return source
    }

    struct PoolSourceGroup: Identifiable {
        var id: String
        var label: String
        var source: String
        var models: [Model]
    }

    /// ① 同一个来源的线路合成一组，组内逐条列模型：同来源的 17 条线路不会刷 17 行。
    var poolSourceGroups: [PoolSourceGroup] {
        var order: [String] = []
        var buckets: [String: [Model]] = [:]
        for model in poolModels {
            let key = HubModel.sourceLabel(model.source)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(model)
        }
        return order.map { key in
            let models = buckets[key] ?? []
            return PoolSourceGroup(id: key, label: key, source: models.first?.source ?? "", models: models)
        }
    }

    /// ① 每行只回答两个问题：给谁用、通不通。
    func agentsUsing(providerID: String) -> [Agent] {
        agents.filter { $0.providerIDs.contains(providerID) }
    }

    func healthState(connectionID: String) -> Bool? {
        connections.first { $0.id == connectionID }?.healthOK
    }

    // MARK: 未归属线路（③ 用）

    /// 一条线路在 router.json 里的真实状态。页面照实显示，不重新猜一遍。
    enum RouteLineState: String {
        case pooled
        case adoptable
        case agentSide
        case internalLine
        case notModel
        case danglingReference
        case boundNotPooled

        var title: String {
            switch self {
            case .pooled: return "池内"
            case .adoptable: return "可收编"
            case .boundNotPooled: return "已归属未进池"
            case .agentSide: return "Agent 侧"
            case .internalLine: return "内部线路"
            case .notModel: return "非模型行"
            case .danglingReference: return "引用缺口"
            }
        }
    }

    struct RouteLine: Identifiable {
        var id: String
        var state: RouteLineState
        var name: String
        var model: String
        var baseURL: String
        var source: String
        var kind: String
        var connectionID: String
        /// 归属连接的名字（没有归属时是空）。
        var ownerName: String
        /// 归属连接自己写的地址（这行没写地址时，网关就用它）。
        var connectionAddress: String
        /// 一行原因：为什么它在这个状态里。界面直接显示这句话。
        var reason: String

        var displayName: String { name.isEmpty ? id : name }
        var sourceLabel: String { HubModel.sourceLabel(source) }
        /// 一行线路能不能收编：得真的是条模型线路（有模型名、有地址）。
        var isAdoptable: Bool { !model.isEmpty && !HubModel.isEmptyAddress(baseURL) }
        /// 收编时要额外确认的两类：Agent 侧的行、4202 内部线路。
        var needsOptIn: Bool { state == .agentSide || state == .internalLine }

        /// 这一行「等着收编」吗：它得是条真线路，而且盘上还没有归属。
        /// **只有它才收编得动**：已经有归属的行是用户（或别的程序）配好的，收编替它改指
        /// 轻则空转写盘，重则把用户自己的连接改坏。03-C 的「再点一次收编也改盘」就是踩在这一行上。
        var awaitsAdoption: Bool { isAdoptable && connectionID.isEmpty }
        /// 盘上已经有归属了（`connection_id` 非空）。收编对这类行一律不碰。
        var hasOwner: Bool { !connectionID.isEmpty }

        /// 这行真正会被用到的地址：行里写了就用行里的，行里没写才用归属连接上的。
        /// 界面以前只显示行自己的 `baseURL`，行里没写时就是一片空白，看着像「没有地址」。
        /// 网关自己的规则：行里的地址只要是空白（含「只打了几个空格」），就当没写，往下用连接的。
        /// 这里必须和 `addressFact` 同一把尺子，否则台账摆出来的地址不是真正发请求的那条。
        var effectiveAddress: String { HubModel.isEmptyAddress(baseURL) ? connectionAddress : baseURL }
        /// 地址是从哪儿来的，一句话说清。
        var addressOrigin: String {
            if !HubModel.isEmptyAddress(baseURL) {
                return HubModel.isEmptyAddress(connectionAddress)
                    ? "这一行自己写的"
                    : "这一行自己写的，覆盖了「\(ownerName.isEmpty ? connectionID : ownerName)」上的地址"
            }
            if !HubModel.isEmptyAddress(connectionAddress) {
                return "这一行没写，用归属连接「\(ownerName.isEmpty ? connectionID : ownerName)」上的地址"
            }
            return "这一行和它的连接都没写地址"
        }
        /// 地址有毛病时给一句「要修什么」。
        var addressDefect: String? {
            HubModel.addressDefect(baseURL) ?? HubModel.addressDefect(connectionAddress)
        }
    }

    @Published private(set) var routeLines: [RouteLine] = []

    var adoptableLines: [RouteLine] { routeLines.filter { $0.state == .adoptable } }
    var agentSideLines: [RouteLine] { routeLines.filter { $0.state == .agentSide } }
    var boundNotPooledLines: [RouteLine] { routeLines.filter { $0.state == .boundNotPooled } }
    var internalLines: [RouteLine] { routeLines.filter { $0.state == .internalLine } }
    var danglingLines: [RouteLine] { routeLines.filter { $0.state == .danglingReference } }
    /// 真正的模型线路里，行和归属连接都没写地址的行。这类行发不出请求，但值是「空」而不是「错」，
    /// 所以单独列出来（上面那几组按钮管的是状态，这一条管的是地址），界面上只说清缺什么、去哪儿补。
    /// DSH / command 这类桥接行没有 model，本来就不是 HTTP 模型线路，不能把它们算成「地址缺失」。
    var linesWithoutAddress: [RouteLine] {
        routeLines.filter {
            !$0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && HubModel.isEmptyAddress($0.effectiveAddress)
        }
    }
    /// ③ 默认折叠的一组：Agent 侧 + 内部线路 + 不是模型的行（桥接、命令、没地址的行等）。
    var collapsedRouteLines: [RouteLine] {
        routeLines.filter { [.agentSide, .internalLine, .notModel, .boundNotPooled].contains($0.state) }
    }
    /// 一键收编默认动的是「可收编」那组；Agent 侧和内部线路要另外确认。
    var canAdoptLines: Bool { !adoptableLines.isEmpty }

    /// 把 router.json 的 `providers` 逐行判一遍，给出状态和一行原因。
    static func auditRouteLines(providers: [[String: Any]],
                                connections: [[String: Any]],
                                pooledProviderIDs: Set<String>) -> [RouteLine] {
        var lines: [RouteLine] = []
        for provider in providers {
            guard let id = provider["id"] as? String, !id.isEmpty else { continue }
            let name = (provider["name"] as? String) ?? id
            let model = (provider["model"] as? String) ?? ""
            let source = (provider["source"] as? String) ?? ""
            let kind = (provider["kind"] as? String) ?? ""
            let connectionID = (provider["connection_id"] as? String) ?? ""
            let baseURL = (provider["base_url"] as? String) ?? ""
            let owner = connections.first { ($0["id"] as? String) == connectionID }
            let state: RouteLineState
            let reason: String
            if pooledProviderIDs.contains(id) {
                state = .pooled
                reason = "已经在模型池里"
            } else if !connectionID.isEmpty, owner == nil {
                state = .danglingReference
                reason = "connection_id 指向的「\(connectionID)」在 connections 里不存在"
            } else if !connectionID.isEmpty, let owner {
                // 有明确归属：归属说了算，不再拿「像不像 Agent 专用」去猜。
                let ownerName = (owner["name"] as? String) ?? connectionID
                if !isExternallyVisiblePoolProvider(provider) {
                    state = .internalLine
                    reason = "归属在「\(ownerName)」，是 4202 内部线路（默认只从「JEV 档位」进池）"
                } else if !isRouteConnection(owner) || !isRouteProvider(provider) {
                    let hits = agentSignatureMatch(owner) + agentSignatureMatch(provider)
                    state = .agentSide
                    reason = "归属在「\(ownerName)」，但这行/这个连接被判成 Agent 侧（命中 \(hits.joined(separator: "、"))）"
                } else if model.isEmpty {
                    state = .notModel
                    reason = "归属在「\(ownerName)」，但没有 model 字段，不是模型行"
                } else if HubModel.isEmptyAddress(baseURL),
                          HubModel.isEmptyAddress((owner["base_url"] as? String) ?? "") {
                    state = .notModel
                    reason = "归属在「\(ownerName)」，但这行和连接都没有 base_url，发不出去"
                } else {
                    state = .boundNotPooled
                    reason = "归属在「\(ownerName)」，但这行不在模型池里（检查这行自己的开关，或等模型池刷新）"
                }
            } else if !isRouteProvider(provider) {
                state = .agentSide
                reason = "没有归属，整行被判成 Agent 侧（命中 \(agentSignatureMatch(provider).joined(separator: "、"))，kind=\(kind.isEmpty ? "空" : kind)）"
            } else if model.isEmpty {
                state = .notModel
                reason = "没有 model 字段，不是模型行"
            } else if HubModel.isEmptyAddress(baseURL) {
                state = .notModel
                reason = baseURL.isEmpty ? "没有 base_url，发不出去"
                    : "base_url 是空白（只有空格或换行），等于没写，发不出去"
            } else if !isExternallyVisiblePoolProvider(provider) {
                state = .internalLine
                reason = "4202 内部线路：默认只从「JEV 档位」进模型池，没有单独当供应商露出来"
            } else if connectionID.isEmpty {
                state = .adoptable
                reason = "有模型和地址，只差一个连接归属"
            } else {
                state = .notModel
                reason = "连接在，但这一行不在池里（检查连接和这一行自己的开关）"
            }
            lines.append(RouteLine(id: id, state: state, name: name, model: model,
                                   baseURL: baseURL, source: source, kind: kind,
                                   connectionID: connectionID,
                                   ownerName: (owner?["name"] as? String) ?? "",
                                   connectionAddress: (owner?["base_url"] as? String) ?? "",
                                   reason: reason))
        }
        return lines
    }

    // MARK: 收编 / 还原（③ 的动作）

    /// 收编方案：建哪些连接、哪些线路行改归属。先算后写，自检打印的就是这一份。
    /// 新连接叫什么：来源标签够具体就用它（dsh:teamorouter → TeamoRouter），
    /// 太泛（Agent 侧/空）就用域名，免得出现「Agent 侧（App 收编）」这种说不出所以然的名字。
    static func adoptionName(sourceKey: String, baseURL: String, lines: [RouteLine]) -> String {
        let generic: Set<String> = ["Agent 侧", "(空)", "未知", ""]
        var stem = sourceKey
        if generic.contains(sourceKey) || sourceKey.contains(":") {
            let host = lines.compactMap { URL(string: $0.baseURL)?.host }.first ?? URL(string: baseURL)?.host ?? ""
            stem = host.isEmpty ? "第三方" : host
        }
        return "\(stem)（App 收编）"
    }

    struct AdoptionPlan {
        struct ConnectionPlan: Identifiable {
            var id: String
            var name: String
            var baseURL: String
            var apiKey: String
            var modelIDs: [String]
        }
        var connections: [ConnectionPlan]
        /// 方案里没列的行，原因照实记下来——不是「想省事跳过了」，是这两条硬理由。
        var receiptExcluded: [String] = []
        var duplicateLines: [String] = []
        var isEmpty: Bool { connections.isEmpty }
        var lineCount: Int { connections.reduce(0) { $0 + $1.modelIDs.count } }
        /// 跳过说明，给确认单用；空字符串表示一条都没跳。
        var notes: String {
            var parts: [String] = []
            if !duplicateLines.isEmpty {
                parts.append("同一个模型只收编一次，跳过重复 \(duplicateLines.count) 条（\(preview(duplicateLines))）")
            }
            if !receiptExcluded.isEmpty {
                parts.append("网关真实回执判过「重试也不会变」，跳过 \(receiptExcluded.count) 条（\(preview(receiptExcluded))）"
                    + "：这些行收进来只会让每次请求多等一轮")
            }
            return parts.joined(separator: "；")
        }

        private func preview(_ items: [String]) -> String {
            let head = items.prefix(3).joined(separator: "、")
            return items.count > 3 ? "\(head) 等" : head
        }

        var summary: String {
            connections.map { plan in
                let address = plan.baseURL.isEmpty ? "地址逐条自带" : plan.baseURL
                return "\(plan.name)（\(plan.modelIDs.count) 条线路，\(address)）"
            }.joined(separator: "、")
        }
    }

    /// 收编建出来的连接标记：`source` 字段写 `app-adopt`，一眼能看出这行是谁加的。
    static let adoptedConnectionSource = "app-adopt"
    /// 旧前缀：早期写法，保留兼容，还原时一起认。
    static let adoptedConnectionPrefix = "conn-adopted-"

    /// 收编台账：App 建过哪些连接、把哪些线路行挂到过连接上。
    /// `provider_ids` 是「借用的已有连接」唯一能还原的凭据——比如 Ark 那条：
    /// 收编时只把线路挂上去、连接本身一个字段都不动，还原时必须按这张表把线路解绑还回去。
    /// 写在 App 自己的目录里，不碰用户的配置文件；删掉它不影响配置，只影响「还原」的判断。
    private struct AdoptionLedger {
        var connectionIDs: [String] = []
        var providerIDs: [String] = []
        var isEmpty: Bool { connectionIDs.isEmpty && providerIDs.isEmpty }
    }

    private var adoptionLedgerURL: URL {
        store.configURL.deletingLastPathComponent().appendingPathComponent("router-adoptions.json")
    }

    /// 读台账的结果：表本身 + 「文件在、但读不动」的原因（没有这个文件不算原因）。
    /// 「读不到」和「没有」必须分开：两者要跟用户说的话正好相反（07-B 复现：混在一起就会
    /// 一边丢掉全部凭据、一边说「已还原」）。
    private struct AdoptionLedgerRead {
        var ledger = AdoptionLedger()
        var problem = ""
    }

    /// 台账负责证明“这一批连接是本次可还原对象”，source / 旧前缀负责证明
    /// “它确实像 App 建的连接”。两条证据要同时成立；不能因为历史连接还留着
    /// `source=app-adopt`，就把它自动当成下一次还原的目标。
    /// v1 的老台账只有 `connection_ids`，这里读出来照旧能用，`provider_ids` 只是空数组。
    /// 一半坏掉时，好的那一半照旧生效——只把坏掉的这一半说清楚。
    private func readAdoptionLedger() -> AdoptionLedgerRead {
        guard FileManager.default.fileExists(atPath: adoptionLedgerURL.path) else { return AdoptionLedgerRead() }
        guard let data = try? Data(contentsOf: adoptionLedgerURL) else {
            return AdoptionLedgerRead(problem: "台账文件读不了（\(adoptionLedgerURL.lastPathComponent) 打不开）")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AdoptionLedgerRead(problem: "台账文件读不了（\(adoptionLedgerURL.lastPathComponent) 不是合法 JSON，\(data.count) 字节），挂行凭据这次按没有算")
        }
        var read = AdoptionLedgerRead()
        if let rawConnections = object["connection_ids"] {
            if let ids = rawConnections as? [String] { read.ledger.connectionIDs = ids }
            else { read.problem = "台账里 connection_ids 的形状不对（不是字符串数组），这一半按读不到算" }
        }
        if let rawProviders = object["provider_ids"] {
            if let ids = rawProviders as? [String] { read.ledger.providerIDs = ids }
            else {
                read.problem += (read.problem.isEmpty ? "" : "；")
                    + "台账里 provider_ids 的形状不对（不是字符串数组），挂行凭据这一半按读不到算"
            }
        }
        return read
    }

    private func writeAdoptionLedger(_ ledger: AdoptionLedger) {
        if ledger.isEmpty {
            try? FileManager.default.removeItem(at: adoptionLedgerURL)
            return
        }
        var object: [String: Any] = [
            "note": "App「收编」建出来的连接、挂过的线路行；删掉这个文件不影响配置，只影响还原时的判断",
            "connection_ids": ledger.connectionIDs,
        ]
        if !ledger.providerIDs.isEmpty { object["provider_ids"] = ledger.providerIDs }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: adoptionLedgerURL, options: .atomic)
        }
    }

    /// 同组线路的值完全一致时共用一份，否则留空（写盘时一行都不会被改写）。
    private static func shared(_ values: [String]) -> String {
        guard let first = values.first, !first.isEmpty else { return "" }
        return values.allSatisfy { $0 == first } ? first : ""
    }

    private func apiKey(ofProvider providerID: String) -> String {
        let row = store.providers.first { ($0["id"] as? String) == providerID }
        return (row?["api_key"] as? String) ?? ""
    }

    /// 收编范围：默认只动「可收编」那组；
    /// Agent 侧 / 内部线路这两类要用户另外点头（它们本来就带着「别当普通供应商」的标记）。
    struct AdoptionSelection {
        var includeAgentSide = false
        var includeInternal = false

        var summary: String {
            var parts = ["可收编"]
            if includeAgentSide { parts.append("Agent 侧") }
            if includeInternal { parts.append("内部线路") }
            return parts.joined(separator: " + ")
        }
    }

    func planAdoption(_ selection: AdoptionSelection = AdoptionSelection()) -> AdoptionPlan {
        // 三组都按同一把尺子挑：**盘上还没有归属的行**（`awaitsAdoption`）。
        // 已经有归属的行不进方案——方案是「要动谁」的清单，不该把已经挂好的行再列一遍。
        var picked = adoptableLines.filter(\.awaitsAdoption)
        if selection.includeAgentSide { picked += agentSideLines.filter(\.awaitsAdoption) }
        if selection.includeInternal { picked += internalLines.filter(\.awaitsAdoption) }
        // 两道筛子，都是冲着同一件事：别把注定打不通的一行挂进池子。
        // ① 同一个模型只留第一条——同名挂两遍，翻车时等于每次请求多等一轮；
        //    唯一的例外：留下的那条自己就不可收编（比如 Agent 侧的行没写地址），
        //    后面又有同名且可收编的行，就把位置让给后者，不留一条空壳。
        // ② 有网关真实回执判过「重试也不会变」（比如 HTTP 401 密钥被拒）的行整条不要。
        // 「可收编」按 `line.isAdoptable`（模型名和地址都得在），与 ③ 页面上的分组同一把尺子。
        var duplicates: [String] = []
        var excluded: [String] = []
        var chosen: [RouteLine] = []
        var chosenIndexByModel: [String: Int] = [:]
        for line in picked {
            if HubReceiptLedger.shared.receipt(for: line.id)?.excludesFromAutoPick == true {
                excluded.append(line.displayName)
                continue
            }
            let key = line.model.lowercased()
            guard !key.isEmpty else {
                chosen.append(line)
                continue
            }
            guard let index = chosenIndexByModel[key] else {
                chosenIndexByModel[key] = chosen.count
                chosen.append(line)
                continue
            }
            if !chosen[index].isAdoptable && line.isAdoptable {
                duplicates.append(chosen[index].displayName)
                chosen[index] = line
            } else {
                duplicates.append(line.displayName)
            }
        }
        picked = chosen
        var order: [String] = []
        var buckets: [String: [RouteLine]] = [:]
        for line in picked {
            let key = line.sourceLabel
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(line)
        }
        var plans: [AdoptionPlan.ConnectionPlan] = []
        for key in order {
            let lines = buckets[key] ?? []
            let name = Self.adoptionName(sourceKey: key, baseURL: Self.shared(lines.map(\.baseURL)), lines: lines)
            plans.append(.init(id: "", name: name,
                               baseURL: Self.shared(lines.map(\.baseURL)),
                               apiKey: Self.shared(lines.map { apiKey(ofProvider: $0.id) }),
                               modelIDs: lines.map(\.id)))
        }
        return AdoptionPlan(connections: plans, receiptExcluded: excluded, duplicateLines: duplicates)
    }

    /// ③ 的一键动作：给所有「可收编」线路补上连接归属。
    /// 新建连接时只写 `name / base_url / api_key`，线路行只改自己的 `connection_id`；
    /// **已经有地址相同的连接就借它**（只挂线路，不改它的名字、密钥、模型表）——
    /// Ark 那种套餐端点本身就是用户配好的连接，合并写回等于把它的业务方名字和模型表清掉。
    @discardableResult
    func adoptUnassignedLines(_ selection: AdoptionSelection = AdoptionSelection()) -> String {
        let plan = planAdoption(selection)
        // 空方案 = 真的没得做：当场收手，不备份、不写盘、不记台账，回执也不许说「已收编」。
        // （线路都已经有归属时再点一次「收编」走的就是这条路——03-C 复现：旧版本会照样换一次备份、
        //  重写一遍 router.json、还往台账里记一笔。）
        guard !plan.isEmpty else {
            return "没有可收编的线路：没有哪一行等着归属，这次没写盘、没做备份、没记台账"
        }

        // 先逐组核对地址：整组都没有可用地址就跳过（写出来也是一条发不出去的连接）。
        // 密钥不算「缺」——线路自己带的密钥原样保留，不往连接上写。
        var linesByID: [String: RouteLine] = [:]
        for line in routeLines { linesByID[line.id] = line }
        var skipped: [String] = []
        var planned: [AdoptionPlan.ConnectionPlan] = []
        for item in plan.connections {
            // 第二道闸门（写盘前的兜底）：盘上已经有归属的行一律剔掉。方案按 `awaitsAdoption`
            // 本来就不会给出这类行，这里再挡一道——宁可少动一行，也不替用户改线路指向。
            let pending = item.modelIDs.filter { linesByID[$0]?.awaitsAdoption ?? false }
            let ownedCount = item.modelIDs.count - pending.count
            if ownedCount > 0 {
                skipped.append("\(item.name)（\(ownedCount) 条盘上已经有归属，没碰）")
            }
            guard !pending.isEmpty else { continue }
            let groupLines = pending.compactMap { linesByID[$0] }
            if Self.isEmptyAddress(item.baseURL), groupLines.allSatisfy({ Self.isEmptyAddress($0.baseURL) }) {
                skipped.append("\(item.name)（整组没有可用地址）")
                continue
            }
            var fresh = item
            fresh.modelIDs = pending
            planned.append(fresh)
        }
        guard !planned.isEmpty else {
            return "没有可收编的线路（跳过：\(skipped.joined(separator: "、"))）"
        }

        guard performBackup(tag: "adopt-lines") else { return "备份失败，已中止（router.json 没有改动）" }

        var created: [String] = []
        var createdIDs: [String] = []
        var reused: [String] = []
        var boundProviderIDs: [String] = []
        for item in planned {
            let identifier: String
            if let borrowed = existingConnectionID(baseURL: item.baseURL) {
                identifier = borrowed
                reused.append("\(item.name) → \(borrowed)（地址相同，只挂线路）")
            } else {
                identifier = store.addConnection(name: item.name, baseURL: item.baseURL,
                                                 apiKey: item.apiKey, wireAPI: "chat_completions",
                                                 catalog: [], selectedModelIDs: [],
                                                 source: Self.adoptedConnectionSource)
                createdIDs.append(identifier)
                created.append("\(item.name)（\(item.modelIDs.count) 条）")
            }
            for providerID in item.modelIDs {
                guard let index = store.providers.firstIndex(where: { ($0["id"] as? String) == providerID }) else { continue }
                store.updateProvider(at: index, with: ["connection_id": identifier])
                boundProviderIDs.append(providerID)
            }
        }
        do { try store.save() } catch { return "写盘失败：\(error.localizedDescription)" }
        let ledgerRead = readAdoptionLedger()
        // 台账是「这一次收编」的撤销凭据，不是把所有历史批次永久叠在一起的总表。
        // 旧实现把历史 connection_ids 与本次新建的连接合并，下一次点还原时会把
        // 之前已经存在的 app-adopt 连接也带进删除名单，导致同址复用无法逐字节回原。
        // 本次新建连接和本次挂过的线路足够完成撤销；历史连接留在 router.json，
        // 不再被下一次操作凭旧 source 标记自动删除。
        var ledger = AdoptionLedger()
        ledger.connectionIDs = Array(Set(createdIDs)).sorted()
        ledger.providerIDs = Array(Set(boundProviderIDs)).sorted()
        writeAdoptionLedger(ledger)
        refresh()
        var parts: [String] = ["已收编 \(planned.reduce(0) { $0 + $1.modelIDs.count }) 条线路"]
        if !created.isEmpty { parts.append("新建 " + created.joined(separator: "、")) }
        if !reused.isEmpty { parts.append("挂到已有连接：" + reused.joined(separator: "、")) }
        if !skipped.isEmpty { parts.append("跳过 " + skipped.joined(separator: "、")) }
        if !ledgerRead.problem.isEmpty {
            parts.append("注意：\(ledgerRead.problem)，旧的收编记录这次没读出来")
        }
        parts.append("模型池现在 \(poolModels.count) 个模型")
        return parts.joined(separator: "；") + "（连接带 source=app-adopt 标记，随时可还原）"
    }

    /// 收编要「借」哪条已有连接：地址规范化后相同、协议都是 chat_completions，
    /// 口径与 `RouterStore.addConnection` 的重复合并完全一致。只报告 id，不改任何字段。
    private func existingConnectionID(baseURL: String) -> String? {
        let wanted = RouterStore.normalizedAddress(baseURL)
        guard !wanted.isEmpty else { return nil }
        for connection in store.connections {
            let wire = (connection["wire_api"] as? String) ?? "chat_completions"
            guard wire == "chat_completions" else { continue }
            guard RouterStore.normalizedAddress((connection["base_url"] as? String) ?? "") == wanted else { continue }
            guard let identifier = connection["id"] as? String, !identifier.isEmpty else { continue }
            return identifier
        }
        return nil
    }

    /// 台账里点名、但自己不带 App 证据的连接：**不算收编连接**，只报给用户看。
    /// 台账是 App 自己写的，也可能被旧版本写坏、被手工编辑（07-B 复现：老版本会把「借来的那条
    /// 用户连接」记进 `connection_ids`）。单凭一张可能过期的名单去删连接，就是替用户删他自己的
    /// 连接——宁可少删、把话说清，也不许误删。
    private func ledgeredWithoutEvidence(_ ledger: AdoptionLedger) -> [String] {
        let trusted = Set(store.connections.filter { connection in
            (connection["source"] as? String) == Self.adoptedConnectionSource
                || ((connection["id"] as? String) ?? "").hasPrefix(Self.adoptedConnectionPrefix)
        }.compactMap { $0["id"] as? String })
        return ledger.connectionIDs.filter { !trusted.contains($0) }
    }

    /// App 收编出来的连接：当前台账点名 + `source=app-adopt` 标记，或旧 id 前缀。
    /// 只在「确实存在这个连接」时才认，避免拿台账去删已被用户手动删掉的 id。
    /// 关键是不能把所有 source=app-adopt 的历史连接自动纳入：source 本身不是
    /// 本次还原的时间证明，当前台账才是。旧的 conn-adopted-* 前缀继续兼容无台账的老数据。
    var adoptedConnectionIDs: [String] {
        let existing = store.connections
        let marked = Set(existing.filter { ($0["source"] as? String) == Self.adoptedConnectionSource }
            .compactMap { $0["id"] as? String })
        let prefixed = existing.compactMap { $0["id"] as? String }
            .filter { $0.hasPrefix(Self.adoptedConnectionPrefix) }
        let ledgered = readAdoptionLedger().ledger.connectionIDs.filter { id in
            existing.contains { ($0["id"] as? String) == id }
                && (marked.contains(id) || prefixed.contains(id))
        }
        return Array(Set(ledgered + prefixed)).sorted()
    }

    /// App 收编时「挂过」的线路行（台账里的 `provider_ids`，只认现在还在的行）。
    /// 借已有连接时只写线路行的 `connection_id`，连接本身不带任何标记——
    /// 所以「这条连接名下哪些行是收编挂上来的」只有台账知道，自检要报出来。
    var adoptedProviderIDs: Set<String> {
        let existing = Set(store.providers.compactMap { $0["id"] as? String })
        return Set(readAdoptionLedger().ledger.providerIDs.filter { existing.contains($0) })
    }

    /// 还原：删掉收编建出来的连接，线路行解绑保留（地址、密钥、模型名都还在）。
    /// 另外按台账把「借用的已有连接」上挂过的线路也解绑还回去——
    /// 那种连接不在删除名单里（它不是 App 建的），但它名下多出来的线路必须走。
    @discardableResult
    func restoreAdoptedLines() -> String {
        let ledgerRead = readAdoptionLedger()
        let ledger = ledgerRead.ledger
        let ids = adoptedConnectionIDs
        guard !ids.isEmpty || !ledger.providerIDs.isEmpty else {
            // 「凭据读不到」不许说成「没有收编过」：那等于把一次丢凭据说成已经还干净了。
            guard ledgerRead.problem.isEmpty else {
                return "还原没做：\(ledgerRead.problem)；这次没动 router.json，请先看看这个文件（删掉它不影响配置）"
            }
            let unproven = ledgeredWithoutEvidence(ledger)
            if !unproven.isEmpty {
                return "还原没做：台账里有 \(unproven.count) 条连接没有 App 证据（\(unproven.prefix(3).joined(separator: "、"))\(unproven.count > 3 ? "…" : "")），这次没动 router.json；请到「连接」里人工确认"
            }
            return "没有 App 收编出来的连接"
        }
        guard performBackup(tag: "restore-adopted") else { return "备份失败，已中止（router.json 没有改动）" }
        let detached = store.providers.filter { ids.contains(($0["connection_id"] as? String) ?? "") }.count
        for id in ids { store.removeConnectionKeepingProviders(id: id) }
        var unbound = 0
        for providerID in ledger.providerIDs where store.unbindProvider(providerID: providerID) { unbound += 1 }
        do { try store.save() } catch { return "写盘失败：\(error.localizedDescription)" }
        var remaining = ledger
        remaining.connectionIDs = ledger.connectionIDs.filter { !ids.contains($0) }
        remaining.providerIDs = []
        writeAdoptionLedger(remaining)
        refresh()
        var message = "已还原：删掉 \(ids.count) 个收编连接，共解绑 \(detached + unbound) 条挂上去的线路"
            + "（随被删连接解绑 \(detached) 条、挂在借来的连接上解绑 \(unbound) 条）；"
            + "模型池现在 \(poolModels.count) 个模型"
        if !ledgerRead.problem.isEmpty {
            message += "；注意：\(ledgerRead.problem)，这次只按 App 标记和旧前缀还原"
        }
        let unproven = ledgeredWithoutEvidence(ledger)
        if !unproven.isEmpty {
            message += "；台账里还有 \(unproven.count) 条没有 App 证据的连接（"
                + unproven.prefix(3).joined(separator: "、") + (unproven.count > 3 ? "…" : "")
                + "），这次没动它们——它们可能是你自己的连接，要删请到「连接」里自己确认"
        }
        return message
    }

    /// 写盘前的带时间戳备份：`router-backups/router-<时间>-<tag>.json`。
    /// 只复制，不改原文件；备份失败就不写配置（宁可什么都不做，也不做不能回退的修改）。
    private func performBackup(tag: String) -> Bool {
        let source = store.configURL
        guard FileManager.default.fileExists(atPath: source.path) else { lastBackupPath = ""; return true }
        let directory = source.deletingLastPathComponent().appendingPathComponent("router-backups", isDirectory: true)
        let stamp = HubModel.backupStampFormatter.string(from: Date())
        let target = directory.appendingPathComponent("router-\(stamp)-\(tag).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: source, to: target)
            lastBackupPath = target.path
            return true
        } catch {
            lastBackupPath = ""
            return false
        }
    }

    @Published private(set) var lastBackupPath = ""

    private static let backupStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    // MARK: 只读自检（--hub-audit）

    /// 把页面 ① ② ③ 和 Agent 引用一块算出来打印。默认只读；
    /// `adopt` / `restore` 为真时才真的写盘（写前先备份）。
    static func auditReport(adopt: Bool = false, restore: Bool = false) -> String {
        let model = HubModel()
        model.refresh()
        var out: [String] = []

        out.append("== ① 模型池：\(model.poolModels.count) 个模型 ==")
        for group in model.poolSourceGroups {
            out.append("[\(group.label)] source=\(group.source.isEmpty ? "(空)" : group.source) · \(group.models.count) 个模型")
            for item in group.models {
                let health = model.healthState(connectionID: item.connectionID)
                let healthText = health == nil ? "未检查" : (health == true ? "健康" : "不通")
                let used = model.agentsUsing(providerID: item.id)
                let users = used.isEmpty ? "没人用" : "\(used.count) 个 Agent：" + used.map(\.name).joined(separator: "、")
                out.append("  · \(item.model)  供应商=\(item.supplier ?? item.connectionID)  健康=\(healthText)  \(users)")
            }
        }

        out.append("")
        out.append("== ② 供应商：\(model.connections.count) 个连接 ==")
        for connection in model.connections {
            let health = connection.healthOK == nil ? "未检查" : (connection.healthOK == true ? "健康" : "不通")
            let users = model.agents.filter { agent in
                agent.providerIDs.contains { providerID in
                    connection.models.contains { $0.id == providerID }
                }
            }
            out.append("· \(connection.name)  source=\(connection.source.isEmpty ? "(空)" : connection.source)  "
                       + "\(connection.models.count) 个模型  \(health)  \(connection.statsLabel)  "
                       + (users.isEmpty ? "没人用" : "\(users.count) 个 Agent"))
            for item in connection.models {
                out.append("    - \(item.model)（\(item.id)）")
            }
        }

        out.append("")
        let dangling = model.danglingLines
        let adoptable = model.adoptableLines
        let collapsed = model.collapsedRouteLines
        out.append("== ③ 线路：可收编 \(adoptable.count) · 已归属未进池 \(model.boundNotPooledLines.count) "
                   + "· 内部线路 \(model.internalLines.count) "
                   + "· Agent 侧 \(model.agentSideLines.count) · 收起来 \(collapsed.count) · 引用缺口 \(dangling.count) ==")
        for line in model.routeLines where line.state != .pooled {
            out.append("[\(line.state.title)] \(line.id)  model=\(line.model.isEmpty ? "(无)" : line.model)  "
                       + "source=\(line.source.isEmpty ? "(空)" : line.source)  归属=\(line.connectionID.isEmpty ? "(无)" : line.connectionID)  "
                       + "原因：\(line.reason)")
        }

        out.append("")
        out.append("== ④ Agent 引用 ==")
        var missing: [String] = []
        let poolIDS = Set(model.poolModels.map(\.id))
        let lineByID = Dictionary(model.routeLines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for agent in model.agents {
            let references = agent.providerIDs
            let inPool = references.filter { poolIDS.contains($0) }
            let knownElsewhere = references.compactMap { poolIDS.contains($0) ? nil : lineByID[$0] }
            let unknown = references.filter { lineByID[$0] == nil && !poolIDS.contains($0) }
            missing.append(contentsOf: unknown)
            var detail: [String] = []
            if !knownElsewhere.isEmpty {
                let byState = Dictionary(grouping: knownElsewhere, by: { $0.state.title })
                    .map { "\($0.key) \($0.value.count) 条" }
                    .sorted()
                detail.append("有行但没进池：" + byState.joined(separator: "、"))
            }
            if !unknown.isEmpty { detail.append("找不到这一行：\(unknown.joined(separator: "、"))") }
            out.append("· \(agent.name)：引用 \(references.count) 条 · 池内 \(inPool.count) 条"
                       + (detail.isEmpty ? " · 其余都在池里" : " · 池外 " + detail.joined(separator: " · ")))
            if !knownElsewhere.isEmpty {
                let states = Set(knownElsewhere.map(\.state))
                if states == [.internalLine] {
                    out.append("    ↳ 全部指向 4202 内部线路：不影响它调用；想让它们在 ① 里单独出现，用「收编内部线路」")
                }
                if states.contains(.internalLine), states != [.internalLine] {
                    out.append("    ↳ 其中 \(knownElsewhere.filter { $0.state == .internalLine }.count) 条指向 4202 内部线路：不影响调用，"
                               + "想单独列出来用「收编内部线路」")
                }
                if states.contains(.agentSide) {
                    out.append("    ↳ 有行没归属、又被判成 Agent 侧：若它们其实是你自己配的供应商，"
                               + "用「收编」归到一起就会进 ①（新连接按来源或域名命名）")
                }
                if states.contains(.boundNotPooled) {
                    out.append("    ↳ 有行已归属但没进模型池：看看这行自己的开关，或等模型池刷新")
                }
            }
        }
        if !missing.isEmpty {
            out.append("  断链合计 \(missing.count) 条（provider_ids 指向不存在的行）：\(missing.joined(separator: "、"))")
        } else {
            out.append("  断链合计 0 条：每个 Agent 的 provider_ids 都能在 router.json 里找到对应的行")
        }

        out.append("")
        if restore {
            out.append("== 还原 ==")
            out.append(model.restoreAdoptedLines())
            out.append("")
        }
        if adopt {
            var scope = HubModel.AdoptionSelection()
            if (ProcessInfo.processInfo.environment["LOCAL_SIRI_AUDIT_SCOPE"] ?? "") == "all" {
                scope.includeAgentSide = true
                scope.includeInternal = true
            }
            out.append("== 收编（范围：\(scope.summary)）==")
            out.append(model.adoptUnassignedLines(scope))
            out.append("")
            out.append("== 收编后 ① 模型池：\(model.poolModels.count) 个模型 ==")
            for group in model.poolSourceGroups {
                out.append("[\(group.label)] \(group.models.count) 个模型")
            }
            out.append("== 收编后 ② 供应商：\(model.connections.count) 个连接 ==")
            for connection in model.connections {
                out.append("· \(connection.name)  \(connection.models.count) 个模型")
            }
            out.append("== 收编后 ③ 可收编 \(model.adoptableLines.count) · 引用缺口 \(model.danglingLines.count) ==")
        } else if !adoptable.isEmpty || !model.agentSideLines.isEmpty || !model.internalLines.isEmpty {
            out.append("== 收编演练（没有写盘）==")
            out.append("默认范围（\(HubModel.AdoptionSelection().summary)）：\(model.planAdoption().summary)")
            var wide = HubModel.AdoptionSelection()
            wide.includeAgentSide = true
            wide.includeInternal = true
            out.append("全部范围（\(wide.summary)）：\(model.planAdoption(wide).summary)")
        }
        if !model.lastBackupPath.isEmpty {
            out.append("备份：\(model.lastBackupPath)")
        }
        return out.joined(separator: "\n")
    }

    /// 验收断言：只打印结论，失败时返回非零退出码。
    static func auditVerify() -> (text: String, ok: Bool) {
        let model = HubModel()
        model.refresh()
        var failures: [String] = []
        var out: [String] = []
        func check(_ title: String, _ condition: Bool, _ detail: String) {
            out.append("\(condition ? "✅" : "❌") \(title) \(detail)")
            if !condition { failures.append(title) }
        }

        let poolIDS = Set(model.poolModels.map(\.id))
        check("模型池非空", model.poolModels.count >= 25, "池里 \(model.poolModels.count) 个模型（要求 ≥25）")
        let groups = model.poolSourceGroups
        let internal4202 = groups.first { $0.label == "4202 内部线路" }?.models.count ?? 0
        check("4202 内部线路已进池", internal4202 >= 17, "4202 组 \(internal4202) 个（要求 ≥17）")
        check("供应商连接数", model.connections.count >= 5, "\(model.connections.count) 个连接（要求 ≥5）")
        // 「Ark Agent Plan」这项按配置事实认人，不靠连接名字：
        // 名字正是这个 bug 会改写的东西——被盖成「xxx（App 收编）」时，按名字 filter 的断言会直接瞎掉、计数掉到 0。
        // 这里用连接 id「ark-agent-plan」定位（id 不会被收编流程改写），只数它名下、进了模型池的线路行；
        // 阈值仍是 ≥4，不放宽。另三条检查兜住「连接本身被动过」：名字被盖、api_key 被清空、被记进 App 收编台账。
        // 没归属的 ark 线路（source=dsh:ark-agent，按签名判成 Agent 侧）不在这个口径里，只有「全部范围」收编才动它。
        let arkFallbackID = model.routeLines.first { line in
            [line.id, line.name, line.baseURL].contains { $0.lowercased().contains("ark") }
        }?.connectionID ?? ""
        let arkConnection = model.connections.first { $0.id == "ark-agent-plan" }
            ?? model.connections.first { !arkFallbackID.isEmpty && $0.id == arkFallbackID }
        let arkConnectionID = arkConnection?.id ?? ""
        let arkLineCount = arkConnectionID.isEmpty
            ? 0 : model.routeLines.filter { $0.connectionID == arkConnectionID }.count
        let arkPooledCount = arkConnectionID.isEmpty
            ? 0 : model.poolModels.filter { $0.connectionID == arkConnectionID }.count
        var arkProblems: [String] = []
        // 提示桶：不该报红但必须让人看见的事实（如 Agent 侧「挂归属≠进池」）。
        var arkHints: [String] = []
        if arkConnection == nil { arkProblems.append("按连接 id 和线路归属都找不到这条连接") }
        if arkConnection != nil, arkPooledCount < 4 {
            arkProblems.append("进池的线路只有 \(arkPooledCount) 条（阈值 ≥4，不放宽）")
        }
        if arkPooledCount < arkLineCount {
            // 两种「不在池里」必须分开说，否则真损伤会被 Agent 侧的既定事实盖住：
            //   · 自有线路（本来就在这条连接下、不是 App 挂上来的）没进池 = 损伤，报红、点名；
            //   · 台账里挂过的行（`adoptedProviderIDs`）「挂归属≠进池」= 提示（黄），不报红。
            // 措辞：一条从没进过池的行被挂上来（如 source=dsh:ark-agent 被判 Agent 侧）不许说「掉出池」；
            // 「进池」看的是这行的分类（4202 内部线路不外泄，`isExternallyVisiblePoolProvider`），
            // 这行的开关不参与进池判定 —— 开关只在下面「自有线路没有被停用的」里被读。
            let unpooled = arkConnectionID.isEmpty ? [] : model.routeLines.filter {
                $0.connectionID == arkConnectionID && !poolIDS.contains($0.id)
            }
            let hungUnpooled = unpooled.filter { model.adoptedProviderIDs.contains($0.id) }.map(\.id)
            let ownUnpooled = unpooled.filter { !model.adoptedProviderIDs.contains($0.id) }.map(\.id)
            if !ownUnpooled.isEmpty {
                arkProblems.append("自有线路没进池：连接名下 \(arkLineCount) 条里有 \(ownUnpooled.count) 条"
                                   + "本来就在这条连接下却不在池里：\(ownUnpooled.joined(separator: "、"))")
            }
            if !hungUnpooled.isEmpty {
                arkHints.append("收编挂上来但没进池的 \(hungUnpooled.count) 条：\(hungUnpooled.joined(separator: "、"))"
                                + "（挂归属≠进池：进不进池看这行的分类，开关不参与判定；"
                                + "它本来就没进过池，不是「掉出池」）")
            }
        }
        if let connection = arkConnection {
            if connection.name.contains("（App 收编）") { arkProblems.append("名字被收编流程盖成了「\(connection.name)」") }
            if connection.apiKey.isEmpty { arkProblems.append("api_key 被清空了") }
            if model.adoptedConnectionIDs.contains(connection.id) { arkProblems.append("被记进了 App 收编台账") }
        }
        let arkHungCount = arkConnectionID.isEmpty ? 0
            : model.routeLines.filter { $0.connectionID == arkConnectionID && model.adoptedProviderIDs.contains($0.id) }.count
        let arkDetail: String
        if let connection = arkConnection {
            arkDetail = "依据连接 id=\(connection.id)「\(connection.name)」：\(arkPooledCount)/\(arkLineCount) 条线路在池里"
                + "（阈值 ≥4）；api_key \(connection.apiKey.isEmpty ? "空" : "在")、"
                + "收编台账 \(model.adoptedConnectionIDs.contains(connection.id) ? "有记录" : "无记录")"
                + "、收编挂过的线路 \(arkHungCount) 条"
                + (arkProblems.isEmpty ? "" : "；问题：" + arkProblems.joined(separator: "、"))
                + (arkHints.isEmpty ? "" : "；提示（不是故障）：" + arkHints.joined(separator: "、"))
        } else {
            arkDetail = "按连接 id「ark-agent-plan」和 Ark 线路归属都找不到这条连接"
        }
        check("Ark Agent Plan 线路在池里、连接原样", arkProblems.isEmpty, arkDetail)
        // 损伤检测（只读 `enabled` 和地址事实，不改池的定义：池仍是 `connections.flatMap { $0.models }`）。
        // 自有线路 = 不是 App 收编挂上来的行（`adoptedProviderIDs` 之外）；它们的开关是用户的意图，
        // 被停用（enabled=false）就是损伤：报红并点名到「行 id@连接」。
        let selfOwnedRows = model.connections.flatMap { connection in
            connection.models.filter { !model.adoptedProviderIDs.contains($0.id) }.map { (connection, $0) }
        }
        let disabledSelfOwned = selfOwnedRows.filter { !$0.1.enabled }
        check("自有线路没有被停用的", disabledSelfOwned.isEmpty,
              disabledSelfOwned.isEmpty
                ? "\(selfOwnedRows.count) 条自有线路都开着（enabled 全为 true）"
                : "损伤：\(disabledSelfOwned.count) 条自有线路被停用（enabled=false）："
                    + disabledSelfOwned.prefix(5).map { "\($0.1.id)@\($0.0.name)" }.joined(separator: "、"))
        // 成员行自己的 `base_url` 和归属连接的 `base_url` 不一致 = 损伤：网关按行里的走，
        // 这种不一致要么是换过地址没换干净，要么是行里还留着旧地址，必须点名到人。
        let addressMismatch = selfOwnedRows.filter { model.addressFact(of: $0.1).lineOverridesConnection }
        check("成员行地址与归属连接一致", addressMismatch.isEmpty,
              addressMismatch.isEmpty
                ? "\(selfOwnedRows.count) 条自有线路的行地址与归属连接一致"
                : "损伤：\(addressMismatch.count) 条行自己的 base_url 与归属连接不一致："
                    + addressMismatch.prefix(5).map { entry in
                        let fact = model.addressFact(of: entry.1)
                        return "\(entry.1.id)：\(fact.lineRaw) ≠ \(entry.0.baseURL)"
                    }.joined(separator: "、"))
        // 收编方案的两道筛子：这里断言「方案自己写的」和「方案里真有的」是一回事，不看外部文件。
        // 断言对象按「全部范围」算——范围只影响挑哪些组，不影响筛子。
        let plan = model.planAdoption(.init(includeAgentSide: true, includeInternal: true))
        let planLines = plan.connections.flatMap { group in
            group.modelIDs.compactMap { identifier in model.routeLines.first { $0.id == identifier } }
        }
        let planModelNames = planLines.map { $0.model.lowercased() }.filter { !$0.isEmpty }
        let repeatedNames = Dictionary(grouping: planModelNames, by: { $0 })
            .filter { $0.value.count > 1 }.keys.sorted()
        check("收编方案里没有同名模型", repeatedNames.isEmpty,
              repeatedNames.isEmpty
                ? "\(planModelNames.count) 个模型名各自只留了一条（丢弃 \(plan.duplicateLines.count) 条同名重复）"
                : "重复挂池：\(repeatedNames.prefix(5).joined(separator: "、"))")
        // 回执判过「重试也不会变」的行不许进方案：挂了也是每次请求白等一轮。
        let planReceiptExcluded = planLines.filter {
            HubReceiptLedger.shared.receipt(for: $0.id)?.excludesFromAutoPick == true
        }
        check("回执判死的行不在收编方案里", planReceiptExcluded.isEmpty,
              planReceiptExcluded.isEmpty
                ? "方案里 \(planLines.count) 条线路都没有「重试也不会变」的回执（方案自报跳过 \(plan.receiptExcluded.count) 条）"
                : "这些行带着判死的回执却还在方案里："
                    + planReceiptExcluded.prefix(5).map(\.id).joined(separator: "、"))
        // 数字对得上：方案自报的「跳过」条数 = 盘上真有多少条落在范围里、且回执判死。
        let scopePending = (model.adoptableLines + model.agentSideLines + model.internalLines)
            .filter(\.awaitsAdoption)
        let receiptDead = scopePending.filter {
            HubReceiptLedger.shared.receipt(for: $0.id)?.excludesFromAutoPick == true
        }
        check("方案自报的跳过条数对得上", plan.receiptExcluded.count == receiptDead.count,
              "方案自报 \(plan.receiptExcluded.count) 条，盘上按同一口径数是 \(receiptDead.count) 条")
        check("没有可收编的线路", model.adoptableLines.isEmpty, "还剩 \(model.adoptableLines.count) 条可收编")
        check("没有引用缺口", model.danglingLines.isEmpty, "还剩 \(model.danglingLines.count) 条引用缺口")
        var unresolved: [String] = []
        for agent in model.agents {
            unresolved.append(contentsOf: agent.providerIDs.filter { $0.hasPrefix("dsh:") && !poolIDS.contains($0) })
        }
        check("Agent 引用都在池里", unresolved.isEmpty, unresolved.isEmpty ? "0 条缺口" : "缺：" + unresolved.joined(separator: "、"))
        check("收编连接可识别", !model.adoptedConnectionIDs.isEmpty, model.adoptedConnectionIDs.joined(separator: "、"))
        // 灯下黑：当前台账认领的 App 收编连接如果名下一行线路都没有，盘上的线路行
        // 极可能已被别的程序覆盖过。「没有可收编的线路」这时仍可能是绿字，必须单独点出。
        // 这里与 adoptedConnectionIDs 共用同一口径：历史 source 标记但不在当前台账的连接，
        // 不能再次被当成“本次收编空壳”误报。
        let adoptedIDs = Set(model.adoptedConnectionIDs)
        let adoptedLooks = model.connections.filter { adoptedIDs.contains($0.id) }
        let adoptedEmpty = adoptedLooks.filter { $0.models.isEmpty }
        check("收编连接都挂着线路", adoptedEmpty.isEmpty,
              adoptedEmpty.isEmpty
                ? (adoptedLooks.isEmpty ? "没有 App 收编连接（正常）" : "\(adoptedLooks.count) 条 App 收编连接名下都有线路")
                : "损伤：\(adoptedEmpty.count) 条 App 收编连接名下一行线路都没有（线路行可能被别的程序覆盖）："
                    + adoptedEmpty.prefix(3).map { "\($0.name)@\($0.id)" }.joined(separator: "、")
                    + "——先去 ③ 逐行核对，别被「没有可收编的线路」这句绿字骗过去")
        let ledgerRead = model.readAdoptionLedger()
        check("收编台账可读", ledgerRead.problem.isEmpty,
              ledgerRead.problem.isEmpty
                ? (ledgerRead.ledger.isEmpty ? "没有台账文件（还没收编过，正常）"
                                             : "connection_ids \(ledgerRead.ledger.connectionIDs.count) 条、provider_ids \(ledgerRead.ledger.providerIDs.count) 条")
                : ledgerRead.problem)
        let unprovenLedgerIDs = model.ledgeredWithoutEvidence(ledgerRead.ledger)
        check("收编台账没有替用户背书的记录", unprovenLedgerIDs.isEmpty,
              unprovenLedgerIDs.isEmpty ? "台账点名的连接都自带 App 证据"
                                        : "台账里 \(unprovenLedgerIDs.count) 条连接没有 App 证据：\(unprovenLedgerIDs.prefix(3).joined(separator: "、"))（还原时不会动它们，要删请人工确认）")
        for group in groups {
            out.append("   · [\(group.label)] \(group.models.count) 个模型")
        }
        out.append(failures.isEmpty ? "hub-audit verify: PASS" : "hub-audit verify: FAIL（\(failures.joined(separator: "、"))）")
        return (out.joined(separator: "\n"), failures.isEmpty)
    }
}
