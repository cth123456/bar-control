//  verify-adopt-safety.swift
//  独立验收器：把「收编线路不许动用户已有连接」落成 FAIL → PASS 判据。
//
//  立场：这是第三方验收工具。只读真实配置，把真实配置复制进沙箱再动手；
//        从不修改 App 源码，也不替 App 解释自己的行为——每一条结论都从
//        「盘上文件的前后差异」和「App 自己的 planAdoption/adopt/restore」里取。
//
//  与官方 verify-router-pool.swift 的分工：官方管整体演练（四块页面 · 数字自洽 · 全部范围），
//  这里专管它没形成判据的几条合同：
//    ① 同一地址的线路必须复用「用户已有那条连接」，不许改名/改地址/改口径/吞模型/吞密钥；
//    ② 复用别人的连接，不许把别人的 id 记进台账（否则还原会删掉用户的连接）；
//    ③ 被改指的行必须记进台账 provider_ids；还原要逐键回到原样（该行原本没这个键就删掉键，不是写 ""）；
//    ④ 写盘前先备份；⑤ 再点一次收编不许重复建连接；⑥ 只读动作不许写盘；
//    ⑦ 台账 v1（只有 connection_ids）仍要能读；⑧ 验收项不许靠改阈值/改名字哄过去。
//    ⑨ 台账漂移（文件写坏 / 形状变了 / 老版本混进用户的连接）不许让「还原」悄悄少做事或做错事。
//
//  用法：
//    swiftc -swift-version 5 -framework AppKit -framework AVFoundation -framework SwiftUI \
//           Sources/*.swift Tools/verify-adopt-safety.swift -o /tmp/verify-adopt-safety
//    /tmp/verify-adopt-safety              # 全部
//    /tmp/verify-adopt-safety --case A     # 单跑一条
//    /tmp/verify-adopt-safety --keep       # 保留沙箱目录

import Foundation

// MARK: - 小工具

/// 新建一个模型层实例并刷新（和页面一样先 load 再看，否则读到的是空）。
private func freshModel() -> HubModel {
    let model = HubModel()
    model.refresh()
    return model
}

private func canonical(_ any: Any) -> String {
    if any is NSNull { return "null" }
    if let s = any as? String { return "\"\(s)\"" }
    if let n = any as? NSNumber { return n.stringValue }
    if let a = any as? [Any] {
        return "[" + a.map(canonical).joined(separator: ",") + "]"
    }
    if let d = any as? [String: Any] {
        return "{" + d.keys.sorted().map { "\"\($0)\":\(canonical(d[$0] as Any))" }.joined(separator: ",") + "}"
    }
    return String(describing: any)
}

private func loadJSON(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
    return object
}

private func rows(_ object: [String: Any], _ key: String) -> [[String: Any]] {
    (object[key] as? [[String: Any]]) ?? []
}

private func hash12(_ data: Data) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    return String(format: "%012llx", hash)
}

/// 完整 sha256（走系统 shasum，与官方 drill 同一口径）：报告里要给「冻结基线」钉一个别人能复算的值。
private func sha256Full(_ data: Data) -> String {
    let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sha256-\(UUID().uuidString.prefix(8)).bin")
    guard (try? data.write(to: file)) != nil else { return "写入临时文件失败" }
    defer { try? FileManager.default.removeItem(at: file) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", file.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return "shasum 启动失败" }
    process.waitUntilExit()
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return text.split(separator: " ").first.map(String.init) ?? "解析失败"
}

/// 密钥只看尾号：报告里说明「还是原来那把」，又不把密钥打进日志。
private func keyTail(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "（空）" }
    return "…" + String(value.suffix(5))
}

/// 沙箱根。本工具只允许往它底下写：任何一次写盘若不在这里，直接拒绝并退出（退出码 3 = 护栏拦截）。
private var sandboxRoot: URL?

private func appConfigDirectory() -> URL {
    if let raw = ProcessInfo.processInfo.environment["LOCAL_SIRI_CONFIG_DIR"], !raw.isEmpty {
        return URL(fileURLWithPath: raw, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalSiriLLM", isDirectory: true)
}

// MARK: - 沙箱

private struct Sandbox {
    let dir: URL
    let sourceDir: URL
    /// 沙箱里依次用到的文件名；真实配置里缺哪个就不复制哪个。
    static let files = ["router.json", "router-stats.json", "router-health.json",
                        "clients.json", "router-adoptions.json"]

    init(seed: URL) throws {
        sourceDir = seed
        let name = "verify-adopt-safety-\(UUID().uuidString.prefix(8))"
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in Sandbox.files {
            let from = seed.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try FileManager.default.copyItem(at: from, to: dir.appendingPathComponent(file))
        }
        // 夹具至少要有 router.json，否则后面所有结论都没有意义。
        guard FileManager.default.fileExists(atPath: routerJSON.path) else {
            throw NSError(domain: "verify-adopt-safety", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "真实配置目录里没有 router.json：\(seed.path)"])
        }
        pointStoreAt(dir)
    }

    var routerJSON: URL { dir.appendingPathComponent("router.json") }
    var ledger: URL { dir.appendingPathComponent("router-adoptions.json") }
    var backups: URL { dir.appendingPathComponent("router-backups", isDirectory: true) }

    func copy(_ name: String, to url: URL) throws {
        let from = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        try FileManager.default.copyItem(at: from, to: url)
    }

    func cleanUp(keep: Bool) {
        guard !keep else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}

private func pointStoreAt(_ directory: URL) {
    setenv("LOCAL_SIRI_ROUTER_CONFIG", directory.appendingPathComponent("router.json").path, 1)
    setenv("LOCAL_SIRI_ROUTER_STATS", directory.appendingPathComponent("router-stats.json").path, 1)
    setenv("LOCAL_SIRI_ROUTER_HEALTH", directory.appendingPathComponent("router-health.json").path, 1)
}

// MARK: - 逐行 / 逐键比对

private struct RowDiff {
    var id: String
    var missing = false          // 快照里有、现在没了
    var appeared = false         // 快照里没有、现在多了
    var changedKeys: [String] = []
    var addedKeys: [String] = []
    var removedKeys: [String] = []
    var byteEqual = false
    var keyNotes: [String] = []   // 键级证据：「键: 旧 → 新」，方便一眼看出到底改了哪几个字

    var clean: Bool { !missing && !appeared && changedKeys.isEmpty && addedKeys.isEmpty && removedKeys.isEmpty }
    var summary: String {
        if missing { return "整行不见了" }
        if appeared { return "整行是多出来的" }
        var parts: [String] = []
        if !changedKeys.isEmpty { parts.append("改了 " + changedKeys.joined(separator: "/")) }
        if !addedKeys.isEmpty { parts.append("多了 " + addedKeys.joined(separator: "/")) }
        if !removedKeys.isEmpty { parts.append("少了 " + removedKeys.joined(separator: "/")) }
        return parts.isEmpty ? "一字没改" : parts.joined(separator: "；")
    }
}

/// 把一个值压成一行短摘要（打印证据用：数字/列表给条数与 id 前几个，字符串给前 64 字）。
private func brief(_ value: Any?) -> String {
    guard let value else { return "（没有这个键）" }
    if let text = value as? String { return text.count <= 64 ? "\"\(text)\"" : "\"\(text.prefix(61))…\"" }
    if let list = value as? [Any] {
        let ids = list.compactMap { ($0 as? [String: Any])?["id"] as? String }
        if !ids.isEmpty { return "\(list.count) 项（\(ids.prefix(5).joined(separator: "、"))\(ids.count > 5 ? "…" : "")）" }
        return "\(list.count) 项"
    }
    return canonical(value)
}

/// 差异 + 键级证据，合成一条给人看的说明。
private func evidence(_ diff: RowDiff, _ limit: Int = 2) -> String {
    let notes = diff.keyNotes.prefix(limit).joined(separator: " · ")
    return notes.isEmpty ? diff.summary : "\(diff.summary)（\(notes)）"
}

private func diffRows(before: [[String: Any]], after: [[String: Any]]) -> [RowDiff] {
    var beforeByID: [String: [String: Any]] = [:]
    var order: [String] = []
    for (index, row) in before.enumerated() {
        let id = (row["id"] as? String) ?? "#\(index)"
        beforeByID[id] = row
        order.append(id)
    }
    var afterByID: [String: [String: Any]] = [:]
    for (index, row) in after.enumerated() {
        let id = (row["id"] as? String) ?? "#\(index)"
        afterByID[id] = row
        if beforeByID[id] == nil { order.append(id) }
    }
    return order.map { id in
        var diff = RowDiff(id: id)
        switch (beforeByID[id], afterByID[id]) {
        case (.some, .none):
            diff.missing = true
        case (.none, .some):
            diff.appeared = true
        case (.some(let old), .some(let new)):
            diff.byteEqual = canonical(old) == canonical(new)
            for key in Set(old.keys).union(new.keys) {
                let oldValue = old[key]
                let newValue = new[key]
                if oldValue == nil { diff.addedKeys.append(key); continue }
                if newValue == nil { diff.removedKeys.append(key); continue }
                if canonical(oldValue as Any) != canonical(newValue as Any) { diff.changedKeys.append(key) }
            }
            diff.changedKeys.sort(); diff.addedKeys.sort(); diff.removedKeys.sort()
            diff.keyNotes = diff.changedKeys.map { key in
                "\(key): \(brief(old[key])) → \(brief(new[key]))"
            }
        default:
            diff.missing = true
        }
        return diff
    }
}

private func lineIDs(_ rows: [[String: Any]]) -> Set<String> {
    Set(rows.compactMap { $0["id"] as? String })
}

private func connectionID(_ row: [String: Any]) -> String? {
    guard let value = row["connection_id"] as? String, !value.isEmpty else { return nil }
    return value
}

private func normalizedAddress(_ value: String?) -> String {
    var text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while text.hasSuffix("/") { text.removeLast() }
    return text
}

private func writeJSON(_ object: [String: Any], to url: URL) {
    // 护栏：本工具的一切写盘只允许落在本次沙箱里。真实配置目录（seed）永远够不着。
    guard let root = sandboxRoot else {
        FileHandle.standardError.write("拒绝写盘：沙箱根未设置（\(url.path)）\n".data(using: .utf8)!)
        exit(3)
    }
    let target = url.standardizedFileURL.path
    guard target.hasPrefix(root.standardizedFileURL.path + "/") else {
        FileHandle.standardError.write("拒绝写盘：目标在沙箱之外 \(target)（沙箱 \(root.path)）\n".data(using: .utf8)!)
        exit(3)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? data.write(to: url)
}

/// 指向不存在的连接的 connection_id（「悬空归属」）。
private func danglingConnectionIDs(_ object: [String: Any]) -> Set<String> {
    let known = lineIDs(rows(object, "connections"))
    return Set(rows(object, "providers")
        .compactMap { $0["connection_id"] as? String }
        .filter { !$0.isEmpty && !known.contains($0) })
}

/// App 自己的断言清单（`HubModel.auditVerify`）逐条解析：标题 / 绿红 / 附带数字。
private struct AuditItem {
    var title: String
    var ok: Bool
    var detail: String
    var numbers: [Int] { detail.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
}

/// 清单自己的 16 条标题（顺序即 `HubModel.auditVerify` 的顺序）。标题里带空格
/// （「Ark Agent Plan 线路在池里、连接原样」），所以不能按第一个空格切成「标题 + 明细」——
/// 那是把标题截成第一个词。这里按标题表做最长前缀匹配，标题才与页面原文逐字一致。
private let expectedAuditTitles = [
    "模型池非空",
    "4202 内部线路已进池",
    "供应商连接数",
    "Ark Agent Plan 线路在池里、连接原样",
    "自有线路没有被停用的",
    "成员行地址与归属连接一致",
    "收编方案里没有同名模型",
    "回执判死的行不在收编方案里",
    "方案自报的跳过条数对得上",
    "没有可收编的线路",
    "没有引用缺口",
    "Agent 引用都在池里",
    "收编连接可识别",
    "收编连接都挂着线路",
    "收编台账可读",
    "收编台账没有替用户背书的记录",
]

private func auditItems() -> [AuditItem] {
    HubModel.auditVerify().text.split(separator: "\n").compactMap { line in
        let text = String(line)
        guard text.hasPrefix("✅") || text.hasPrefix("❌") else { return nil }
        let body = text.dropFirst().trimmingCharacters(in: .whitespaces)
        let title = expectedAuditTitles.filter { body.hasPrefix($0) }.max { $0.count < $1.count }
            ?? body.split(separator: " ").first.map(String.init) ?? body
        return AuditItem(title: title, ok: text.hasPrefix("✅"),
                         detail: String(body.dropFirst(title.count)).trimmingCharacters(in: .whitespaces))
    }
}

private func auditLine(_ items: [AuditItem], containing needle: String) -> AuditItem? {
    items.first { $0.title.contains(needle) }
}

private func auditState(_ items: [AuditItem]) -> String {
    items.map { "\($0.ok ? "✅" : "❌")\($0.title)" }.joined(separator: " ")
}

/// 盘上「名字里带 ark」的连接（App 那条验收项的判据就是按名字含 Ark 数模型）。
private func arkNamedConnections(_ object: [String: Any]) -> [[String: Any]] {
    rows(object, "connections").filter { (($0["name"] as? String) ?? "").lowercased().contains("ark") }
}

private func modelIDs(_ connection: [String: Any]) -> Set<String> {
    Set((connection["models"] as? [Any])?.compactMap { ($0 as? [String: Any])?["id"] as? String } ?? [])
}

// MARK: - 判据收集

struct Verdict {
    var group: String
    var title: String
    var ok: Bool
    var detail: String
    var isNote = false        // 事实/前提：不算判据，不进通过率（避免「拿环境事实冒充合同」）
}

var verdicts: [Verdict] = []

func check(_ group: String, _ title: String, _ ok: Bool, _ detail: String = "") {
    verdicts.append(Verdict(group: group, title: title, ok: ok, detail: detail, isNote: false))
}

/// 记录一条事实（不算判据）：夹具形状、被改指的行数、App 自己的清单原文……都走这里。
func note(_ group: String, _ title: String, _ detail: String = "") {
    verdicts.append(Verdict(group: group, title: title, ok: true, detail: detail, isNote: true))
}

// MARK: - 表 A：四块页面（数字全部取自 HubModel 的页面 API，与页面同源）

/// 四块页面的数字：模型池 / 供应商 / 线路 / Agent 引用。
/// 这里刻意不另写一套读盘逻辑 —— 用的就是页面自己那套属性，避免「工具口径 vs 页面口径」两套数。
private struct PageBlocks {
    var pool = 0
    var connections = 0
    var connectionModels = 0
    var lines = 0
    var pooled = 0
    var adoptable = 0
    var boundNotPooled = 0
    var internalLines = 0
    var agentSide = 0
    var references = 0

    init(_ model: HubModel) {
        pool = model.poolModels.count
        connections = model.connections.count
        connectionModels = model.connections.reduce(0) { $0 + $1.models.count }
        lines = model.routeLines.count
        pooled = model.routeLines.filter { $0.state == .pooled }.count
        adoptable = model.adoptableLines.count
        boundNotPooled = model.boundNotPooledLines.count
        internalLines = model.internalLines.count
        agentSide = model.agentSideLines.count
        references = model.agents.reduce(0) { $0 + $1.providerIDs.count }
    }

    var report: String {
        "① 模型池 \(pool) · ② 供应商 \(connections) 个连接（\(connectionModels) 个模型）· "
        + "③ 线路 \(lines)：已进池 \(pooled)、可收编 \(adoptable)、已归属未进池 \(boundNotPooled)、内部线路 \(internalLines)、Agent 侧 \(agentSide) · "
        + "④ Agent 引用 \(references) 条"
    }

    /// 收编前 → 收编后，逐项对照。
    func compare(_ after: PageBlocks) -> String {
        "① \(pool)→\(after.pool) · ② \(connections) 个连接→\(after.connections) 个（\(connectionModels)→\(after.connectionModels) 个模型）· "
        + "③ 合计 \(lines)→\(after.lines)｜已进池 \(pooled)→\(after.pooled)｜可收编 \(adoptable)→\(after.adoptable)"
        + "｜已归属未进池 \(boundNotPooled)→\(after.boundNotPooled)｜4202 内部 \(internalLines)→\(after.internalLines)｜Agent 侧 \(agentSide)→\(after.agentSide) · "
        + "④ 引用 \(references)→\(after.references)"
    }
}

// MARK: - 用例

/// A/B/C/D/E/F/I/K/L：真实配置当夹具，默认范围收编一次，回答「用户已有连接有没有被碰」。
private func caseDefaultScope(sandbox: Sandbox) {
    let group = "A 默认范围收编"
    let beforeObject = loadJSON(sandbox.routerJSON)
    let beforeData = (try? Data(contentsOf: sandbox.routerJSON)) ?? Data()
    let beforeConnections = rows(beforeObject, "connections")
    let beforeProviders = rows(beforeObject, "providers")
    let beforeConnectionIDs = lineIDs(beforeConnections)
    let beforeProvidersByID = Dictionary(uniqueKeysWithValues: beforeProviders.compactMap { row -> (String, [String: Any])? in
        guard let id = row["id"] as? String else { return nil }
        return (id, row)
    })

    // 夹具形状：这是事实，不是判据（判据是「不许动用户的连接」，同址复用场景由 R 用例专测）。
    let model = freshModel()
    let poolBefore = model.poolModels.count
    let plan = model.planAdoption()
    let auditBefore = auditItems()
    let arkNamedBefore = Set(arkNamedConnections(beforeObject).compactMap { $0["id"] as? String })
    let sameAddressExisting = beforeConnections.filter { existing in
        plan.connections.contains { normalizedAddress($0.baseURL) == normalizedAddress(existing["base_url"] as? String) }
    }
    note(group, "事实：夹具与本次方案",
         "方案 \(plan.connections.count) 个连接/\(plan.lineCount) 条线路 · 地址 "
         + plan.connections.map { "\($0.baseURL)（\($0.modelIDs.count) 条）" }.joined(separator: "、")
         + " · 已有连接 " + beforeConnections.map { "\($0["name"] as? String ?? "?") @ \(normalizedAddress($0["base_url"] as? String))（\(modelIDs($0).count) 个模型）" }.joined(separator: "、")
         + " · 同址已有连接 \(sameAddressExisting.count) 个"
         + (sameAddressExisting.isEmpty ? "（真实配置里没有同址复用场景 → ① 的复用三条合同由 R 用例的同址合成夹具专测）" : ""))

    let pageBefore = PageBlocks(model)              // 收编前的四块数字（这一刻盘还没动）
    let adoptLog = model.adoptUnassignedLines()
    note(group, "表 A 收编前后四块页面对比（口径与页面一致：数字都取 HubModel 的页面 API）",
         pageBefore.compare(PageBlocks(freshModel())))   // 收编后从沙箱盘上重读
    let afterObject = loadJSON(sandbox.routerJSON)
    let afterConnections = rows(afterObject, "connections")
    let afterProviders = rows(afterObject, "providers")
    let connectionDiffs = diffRows(before: beforeConnections, after: afterConnections)

    // ① 用户已有连接：一字不改、一条不删。
    let touchedExisting = connectionDiffs.filter { beforeConnectionIDs.contains($0.id) && !$0.clean }
    let removedExisting = connectionDiffs.filter { beforeConnectionIDs.contains($0.id) && $0.missing }
    check(group, "① 序号不变：已有连接一条都没被删", removedExisting.isEmpty,
          removedExisting.isEmpty ? "\(beforeConnections.count) 条都在" : "被删：" + removedExisting.map(\.id).joined(separator: "、"))
    check(group, "① 内容不变：已有连接逐键一字不改", touchedExisting.isEmpty,
          touchedExisting.isEmpty
            ? beforeConnections.map { "\($0["id"] as? String ?? "?")（\((($0["models"] as? [Any])?.count) ?? 0) 个模型）" }.joined(separator: "、")
            : touchedExisting.map { "\($0.id)：\($0.summary)" }.joined(separator: "；"))
    let leakedKey = afterConnections.first { row in
        beforeConnectionIDs.contains((row["id"] as? String) ?? "") && (row["api_key"] as? String ?? "").isEmpty
    }
    check(group, "① 密钥没被吞掉", leakedKey == nil,
          leakedKey == nil ? "已有连接的 api_key 都还在" : "「\(leakedKey!["name"] as? String ?? "?")」的 api_key 变空了")

    // ①（A2）逐键点名：已有连接的这几个键，收编后必须与「收编前快照」逐字一致。
    // 基准只取本次快照现场算出来的值（这条命令不引用任何历史值）：当前真实形态里 api_key 非空、尾号 …da950。
    let watchedConnectionKeys = ["id", "name", "base_url", "wire_api", "api_key", "source", "enabled"]
    let existingWithKey = beforeConnections.filter { !(($0["api_key"] as? String) ?? "").isEmpty }
    check(group, "① 前提：快照里已有连接带非空密钥（否则「密钥没被改写」是空转）",
          existingWithKey.count == beforeConnections.count,
          "\(existingWithKey.count)/\(beforeConnections.count) 条已有连接带非空 api_key："
          + beforeConnections.map { "\($0["name"] as? String ?? "?")（尾号 \(keyTail($0["api_key"] as? String))）" }.joined(separator: "、"))
    var connectionKeyProblems: [String] = []
    for before in beforeConnections {
        guard let id = before["id"] as? String,
              let after = afterConnections.first(where: { ($0["id"] as? String) == id }) else { continue }
        for key in watchedConnectionKeys where canonical(before[key] ?? NSNull()) != canonical(after[key] ?? NSNull()) {
            connectionKeyProblems.append("\(id).\(key)：\(brief(before[key])) → \(brief(after[key]))")
        }
    }
    check(group, "① 逐键点名：id/name/base_url/wire_api/api_key/source/enabled 都与快照一致",
          connectionKeyProblems.isEmpty,
          connectionKeyProblems.isEmpty
            ? "\(beforeConnections.count) 条已有连接 × \(watchedConnectionKeys.count) 个键逐字一致（api_key 尾号 "
              + beforeConnections.map { keyTail($0["api_key"] as? String) }.joined(separator: "、") + "）"
            : connectionKeyProblems.joined(separator: "；"))
    note(group, "事实：已有连接的收编前基准（本次快照，报告以此为准）",
         beforeConnections.map { "\($0["name"] as? String ?? "?") · key 尾号 \(keyTail($0["api_key"] as? String)) · \(modelIDs($0).count) 个模型 · \(normalizedAddress($0["base_url"] as? String))" }.joined(separator: " ｜ "))

    // ② 复用：同址的组必须落到「用户已有那条连接」上，而不是又建一条同地址连接。
    var addressCountBefore: [String: Int] = [:]
    for connection in beforeConnections { addressCountBefore[normalizedAddress(connection["base_url"] as? String), default: 0] += 1 }
    var addressCountAfter: [String: Int] = [:]
    for connection in afterConnections { addressCountAfter[normalizedAddress(connection["base_url"] as? String), default: 0] += 1 }
    let reused = afterConnections.filter { beforeConnectionIDs.contains(($0["id"] as? String) ?? "") }
    let newConnections = afterConnections.filter { !beforeConnectionIDs.contains(($0["id"] as? String) ?? "") }
    // 合同一：用户已经有连接的地址，收编后不许出现第二条（必须复用用户那条）。
    let duplicatedAtUserAddress = afterConnections.filter { connection in
        let address = normalizedAddress(connection["base_url"] as? String)
        return (addressCountBefore[address] ?? 0) > 0 && (addressCountAfter[address] ?? 0) > 1
    }
    // 合同二：任何地址收编后至多一条连接（收编前没有的地址，允许多出恰好一条）。
    let overCrowded = (addressCountAfter.filter { address, count in count > max(1, addressCountBefore[address] ?? 0) }).keys.sorted()
    check(group, "① 同址不重复建连接（用户已有的那条被复用）", duplicatedAtUserAddress.isEmpty && overCrowded.isEmpty,
          duplicatedAtUserAddress.isEmpty && overCrowded.isEmpty
            ? "新增 \(newConnections.count) 条连接、复用 \(reused.count) 条；每个地址至多一条"
              + (newConnections.isEmpty ? "" : "（新建：" + newConnections.map { "\($0["id"] as? String ?? "?") @ \(normalizedAddress($0["base_url"] as? String))" }.joined(separator: "、") + "）")
            : "用户已有地址上又建了：" + duplicatedAtUserAddress.map { "\($0["id"] as? String ?? "?") @ \($0["base_url"] as? String ?? "?")" }.joined(separator: "、")
              + (overCrowded.isEmpty ? "" : "｜同址堆叠：" + overCrowded.joined(separator: "、")))

    // ③ 台账：复用来的连接 id 不许进台账，否则还原会删掉用户的连接。
    let ledger = loadJSON(sandbox.ledger)
    let recorded = Set((ledger["connection_ids"] as? [String]) ?? [])
    let recordedExisting = recorded.intersection(beforeConnectionIDs)
    check(group, "② 台账只记 App 自己新建的连接", recordedExisting.isEmpty,
          recordedExisting.isEmpty
            ? "台账 \(recorded.count) 条，全部是新建连接" + (adoptLog.isEmpty ? "" : "（\(adoptLog.prefix(60))）")
            : "台账里混进了已有连接：" + recordedExisting.joined(separator: "、"))
    check(group, "② 台账只记真的新建出来的连接", recorded.isSubset(of: Set(newConnections.compactMap { $0["id"] as? String })),
          "台账 \(recorded.count) 条 ⊂ 新建 \(newConnections.count) 条")
    let claimed = Set(model.adoptedConnectionIDs)
    check(group, "② 页面识别的「App 收编连接」不含用户的连接", claimed.intersection(beforeConnectionIDs).isEmpty,
          claimed.isEmpty ? "识别集合为空" : "识别：" + claimed.sorted().joined(separator: "、"))

    // ④ 写盘前先备份：备份内容必须逐字节等于收编前。
    let backupFiles = (try? FileManager.default.contentsOfDirectory(at: sandbox.backups,
                                                                   includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    let backupsAfter = backupFiles.filter { $0.lastPathComponent.contains("adopt") }
    if let newest = backupsAfter.max(by: { ($0.lastPathComponent) < ($1.lastPathComponent) }) {
        let backupData = (try? Data(contentsOf: newest)) ?? Data()
        check(group, "④ 写盘前有带时间戳的备份，且等于收编前", backupData == beforeData,
              "\(newest.lastPathComponent) · \(backupData.count) 字节 vs 收编前 \(beforeData.count) 字节")
    } else {
        check(group, "④ 写盘前有带时间戳的备份，且等于收编前", false,
              "router-backups 里没有 adopt 备份（现有 \(backupFiles.count) 个文件）")
    }

    // ⑤ 只动该动的：没被收编的线路行必须逐键不变。
    let touchedLineIDs = Set(afterProviders.filter { row in
        guard let id = row["id"] as? String, let old = beforeProvidersByID[id] else { return false }
        return connectionID(old) != connectionID(row)
    }.compactMap { $0["id"] as? String })
    let providerDiffs = diffRows(before: beforeProviders, after: afterProviders)
    let collateral = providerDiffs.filter { diff in
        guard diff.id.hasPrefix("#") == false else { return true }
        if touchedLineIDs.contains(diff.id) {
            // 收编组自己：唯一允许的差异就是 connection_id 这一键（收编=新增该键；还原=删掉该键；改指其他连接=改写）。
            let onlyConnectionID = !diff.missing
                && diff.changedKeys.allSatisfy { $0 == "connection_id" }
                && diff.addedKeys.allSatisfy { $0 == "connection_id" }
                && diff.removedKeys.allSatisfy { $0 == "connection_id" }
                && (diff.changedKeys.count + diff.addedKeys.count + diff.removedKeys.count) > 0
            return !onlyConnectionID
        }
        return !diff.clean
    }
    check(group, "⑤ 只动被收编的线路行（其余逐键不变）", collateral.isEmpty,
          collateral.isEmpty
            ? "被改指 \(touchedLineIDs.count) 行，其余 \(beforeProviders.count - touchedLineIDs.count) 行一字没动"
            : collateral.prefix(4).map { "\($0.id)：\(evidence($0))" }.joined(separator: "；"))
    if !collateral.isEmpty {
        note(group, "⑤ 证据：不该动的行到底改了什么",
             collateral.prefix(3).map { "\($0.id) [\($0.summary)] " + ($0.keyNotes.isEmpty ? "（整行不见/整行多出）" : $0.keyNotes.joined(separator: " · ")) }.joined(separator: " ｜ "))
    }

    // ⑥ 数字自洽：池子真的变大，且增量与被改指的行数对得上。
    let pooled = freshModel()
    let poolAfter = pooled.poolModels.count
    check(group, "⑥ 收编后池真的变大", poolAfter > poolBefore,
          "池 \(poolBefore) → \(poolAfter) 个模型 · 改指 \(touchedLineIDs.count) 行")
    check(group, "⑥ 池增量与被改指的行数对得上（多则疑重复计、少则疑漏计）",
          poolAfter - poolBefore == touchedLineIDs.count,
          "增量 \(poolAfter - poolBefore) · 改指 \(touchedLineIDs.count) 行")

    // ⑦ 验收项不许放水：判据取 App 自己的断言清单（HubModel.auditVerify），且「绿」必须与盘上一致。
    let auditAfter = auditItems()
    check(group, "⑦ 验收清单标题与原文逐字一致、16 条不漏不多（防止把标题截成第一个词）",
          Set(auditAfter.map(\.title)) == Set(expectedAuditTitles) && auditAfter.count == expectedAuditTitles.count,
          "解析到 \(auditAfter.count) 条：\(auditAfter.map(\.title).joined(separator: "、"))")
    let arkNamedAfter = Set(arkNamedConnections(afterObject).compactMap { $0["id"] as? String })
    let flippedRed = auditBefore.filter { item in
        item.ok && auditAfter.first { $0.title == item.title }?.ok == false
    }
    check(group, "⑦ 收编没有把 App 自己的任何一条验收项压红", flippedRed.isEmpty,
          flippedRed.isEmpty
            ? "收编前 \(auditBefore.filter(\.ok).count)/\(auditBefore.count) 条绿 → 收编后 \(auditAfter.filter(\.ok).count)/\(auditAfter.count) 条绿"
            : "被压红的：" + flippedRed.map(\.title).joined(separator: "、"))
    check(group, "⑦ 「Ark 的模型回到池里」这条不许靠改名字凑数（数到的连接必须还是原来那批）",
          arkNamedAfter == arkNamedBefore,
          arkNamedAfter == arkNamedBefore
            ? "名字含 Ark 的连接仍是 \(arkNamedAfter.sorted().joined(separator: "、"))（收编前后同一批）"
            : "收编前 \(arkNamedBefore.sorted().joined(separator: "、")) → 收编后 \(arkNamedAfter.sorted().joined(separator: "、"))")
    let arkItem = auditLine(auditAfter, containing: "Ark")
    let diskArk = arkNamedConnections(afterObject)
    let diskArkModels = diskArk.reduce(0) { $0 + modelIDs($1).count }
    // App 那条验收项的口径是「连接 id=ark-agent-plan 名下、进了模型池的线路行 / 它名下的线路行总数」，
    // 不是「连接数 / 连接上的模型数」——分母按 id 锚定后必须等于盘上真条数，否则绿是假的。
    let arkDiskID = (arkNamedAfter.contains("ark-agent-plan") ? "ark-agent-plan" : (diskArk.first?["id"] as? String)) ?? ""
    let diskArkLines = arkDiskID.isEmpty ? 0 : afterProviders.filter { connectionID($0) == arkDiskID }.count
    let claimedNumbers = arkItem.map { ($0.detail.isEmpty ? $0.numbers : $0.numbers) } ?? []
    let numbersMatch: Bool
    if let item = arkItem, claimedNumbers.count >= 2 {
        if item.ok {
            numbersMatch = claimedNumbers[1] == diskArkLines && diskArkLines > 0
                && claimedNumbers[0] == claimedNumbers[1] && claimedNumbers[0] >= 4
        } else {
            numbersMatch = claimedNumbers[0] <= claimedNumbers[1] && claimedNumbers[1] == diskArkLines
        }
    } else {
        numbersMatch = false
    }
    check(group, "⑦ 清单里的数字与盘上一致（绿是真绿）", numbersMatch,
          (arkItem.map { "\($0.ok ? "✅" : "❌")\($0.title) \($0.detail)" } ?? "清单里没有 Ark 项")
          + " ｜ 盘上名字含 Ark 的连接 \(diskArk.count) 条 / \(diskArkModels) 个模型"
          + " ｜ 按 id 锚定 \(arkDiskID.isEmpty ? "（找不到）" : arkDiskID) 的线路行 \(diskArkLines) 条（App 报的分母必须等于这个数）"
          + (arkItem.map { $0.ok ? "（注意：这条按连接名字计数，与收编无关）" : "" } ?? ""))
    note(group, "表 B 收编前后页面验收清单（App 自己 audit 的原文）",
         auditState(auditBefore) + " → " + auditState(auditAfter))

    // ⑧ 幂等：再点一次，不许重复建连接、不许再改盘。
    let bytesBeforeSecond = (try? Data(contentsOf: sandbox.routerJSON)) ?? Data()
    let connectionsBeforeSecond = Set(rows(loadJSON(sandbox.routerJSON), "connections").compactMap { $0["id"] as? String })
    let ledgerBeforeSecond = (try? Data(contentsOf: sandbox.ledger)) ?? Data()
    let secondLog = freshModel().adoptUnassignedLines()
    let connectionsAfterSecond = Set(rows(loadJSON(sandbox.routerJSON), "connections").compactMap { $0["id"] as? String })
    let bytesAfterSecond = (try? Data(contentsOf: sandbox.routerJSON)) ?? Data()
    let ledgerAfterSecond = (try? Data(contentsOf: sandbox.ledger)) ?? Data()
    check(group, "⑤ 再点一次收编：不重复建连接", connectionsAfterSecond == connectionsBeforeSecond,
          connectionsAfterSecond == connectionsBeforeSecond
            ? "\(connectionsAfterSecond.count) 条连接没变（第二次返回「\(secondLog.prefix(40))」）"
            : "连接集合变了：新增 " + connectionsAfterSecond.subtracting(connectionsBeforeSecond).sorted().joined(separator: "、"))
    check(group, "⑤ 再点一次收编：盘上一个字节都没重写", bytesAfterSecond == bytesBeforeSecond && ledgerAfterSecond == ledgerBeforeSecond,
          bytesAfterSecond == bytesBeforeSecond
            ? "router.json 与台账都逐字节不变"
            : "router.json \(bytesBeforeSecond.count) → \(bytesAfterSecond.count) 字节（台账\(ledgerAfterSecond == ledgerBeforeSecond ? "未动" : "也动了")）")

    // ⑨ 只读动作不许写盘。
    let frozenRouter = (try? Data(contentsOf: sandbox.routerJSON)) ?? Data()
    let frozenLedger = (try? Data(contentsOf: sandbox.ledger)) ?? Data()
    _ = freshModel().planAdoption()
    _ = freshModel().planAdoption(HubModel.AdoptionSelection(includeAgentSide: true, includeInternal: true))
    _ = HubModel.auditReport()
    let routerAfterReadOnly = (try? Data(contentsOf: sandbox.routerJSON)) ?? Data()
    let ledgerAfterReadOnly = (try? Data(contentsOf: sandbox.ledger)) ?? Data()
    check(group, "⑥ 只读动作（看方案/看验收）不写盘",
          frozenRouter == routerAfterReadOnly && frozenLedger == ledgerAfterReadOnly,
          frozenRouter == routerAfterReadOnly ? "router.json 与台账一字未动" : "router.json 被改了")

    // ⑩ 归还：还原之后必须逐字节等于收编前（用户的连接要能回来）。
    let restoreLog = freshModel().restoreAdoptedLines()
    let restoredData = (try? Data(contentsOf: sandbox.routerJSON)) ?? Data()
    let restoredObject = loadJSON(sandbox.routerJSON)
    let restoredConnectionDiffs = diffRows(before: beforeConnections, after: rows(restoredObject, "connections"))
    let restoredProviderDiffs = diffRows(before: beforeProviders, after: rows(restoredObject, "providers"))
    let emptyConnectionID = rows(restoredObject, "providers").filter { ($0["connection_id"] as? String) == "" }
    check(group, "⑩ 还原：连接块逐键回到收编前（用户的连接还在）",
          restoredConnectionDiffs.allSatisfy(\.clean),
          restoredConnectionDiffs.filter { !$0.clean }.prefix(4).map { "\($0.id)：\($0.summary)" }.joined(separator: "；").isEmpty
            ? "\(beforeConnections.count) 条连接全部回到原样（\(restoreLog.prefix(40))）"
            : restoredConnectionDiffs.filter { !$0.clean }.prefix(4).map { "\($0.id)：\($0.summary)" }.joined(separator: "；"))
    check(group, "⑩ 还原：线路块逐键回到收编前（不许留 connection_id 空串）",
          restoredProviderDiffs.allSatisfy(\.clean) && emptyConnectionID.isEmpty,
          restoredProviderDiffs.filter { !$0.clean }.prefix(4).map { "\($0.id)：\($0.summary)" }.joined(separator: "；").isEmpty
            ? "\(beforeProviders.count) 行全部回到原样，空串 \(emptyConnectionID.count) 个"
            : restoredProviderDiffs.filter { !$0.clean }.prefix(4).map { "\($0.id)：\($0.summary)" }.joined(separator: "；"))
    check(group, "⑩ 还原：router.json 逐字节回到收编前", restoredData == beforeData,
          "\(hash12(beforeData))（\(beforeData.count) 字节）→ \(hash12(restoredData))（\(restoredData.count) 字节）")
    let auditRestored = auditItems()
    check(group, "⑩ 还原：App 自己的验收清单逐条回到收编前（不许留收编痕迹）",
          auditState(auditRestored) == auditState(auditBefore),
          auditState(auditRestored) == auditState(auditBefore)
            ? "\(auditRestored.count) 条逐条一致"
            : "收编前：\(auditState(auditBefore))｜还原后：\(auditState(auditRestored))")
    let danglingRestored = danglingConnectionIDs(restoredObject)
    check(group, "⑩ 还原后不许留悬空归属", danglingRestored.isEmpty,
          danglingRestored.isEmpty ? "没有指向已删连接的 connection_id" : "悬空：\(danglingRestored.sorted().prefix(4).joined(separator: "、"))")
}

/// G：宽范围收编——本来就有 connection_id、只是被改指的行，必须记进台账 provider_ids；还原逐键回原样。
private func caseRepointedLines(sandbox: Sandbox) {
    let group = "G 宽范围（被改指的行）"
    let beforeData = (try? Data(contentsOf: sandbox.routerJSON)) ?? Data()
    let beforeObject = loadJSON(sandbox.routerJSON)
    let beforeProviders = rows(beforeObject, "providers")
    let beforeConnections = rows(beforeObject, "connections")
    let wide = HubModel.AdoptionSelection(includeAgentSide: true, includeInternal: true)
    let model = freshModel()
    let plan = model.planAdoption(wide)
    // 事实：这次会「改指」的行 = 方案里选中、且盘上本来就有 connection_id 的行。
    let plannedIDs = Set(plan.connections.flatMap(\.modelIDs))
    let expectedRepointed = Set(beforeProviders.compactMap { row -> String? in
        guard let id = row["id"] as? String, plannedIDs.contains(id), connectionID(row) != nil else { return nil }
        return id
    })
    note(group, "事实：宽范围的方案",
         "被改指 \(expectedRepointed.count) 行 / 方案 \(plannedIDs.count) 行 · 已有连接 \(beforeConnections.count) 条 · 可收编 \(model.adoptableLines.count) 条")

    // 方案之外被两道筛子拦下的行，必须让方案自己报出来：
    // 「已收编 21 条」和「池子里 25 个」之间差的就是这些行，页面上的「要求 ≥25」够不够得着全看它们。
    let receiptExcluded = plan.receiptExcluded
    let excludedDetail = model.routeLines.filter { receiptExcluded.contains($0.displayName) }.map { line -> String in
        let receipt = HubReceiptLedger.shared.receipt(for: line.id)
        return "\(line.displayName)〔\(receipt?.receiptLine ?? "无回执") · \(receipt?.exclusionNote ?? "无说明") · 成功 \(receipt?.successRateText ?? "?")〕"
    }
    note(group, "事实：被「回执判死」筛子拦下的行",
         receiptExcluded.isEmpty
            ? "无（方案没有行被回执拦下）"
            : "\(receiptExcluded.count) 行：" + (excludedDetail.isEmpty ? receiptExcluded.joined(separator: "、") : excludedDetail.joined(separator: "；")))
    note(group, "事实：被「同模型只留一条」筛掉的行",
         plan.duplicateLines.isEmpty ? "无" : "\(plan.duplicateLines.count) 行：" + plan.duplicateLines.joined(separator: "、"))

    func census(_ name: String, _ lines: [HubModel.RouteLine]) -> String {
        let dead = lines.filter { HubReceiptLedger.shared.receipt(for: $0.id)?.excludesFromAutoPick == true }.count
        let notAdoptable = lines.filter { !$0.isAdoptable }.count
        let bound = lines.filter { !$0.awaitsAdoption }.count
        let usable = lines.filter { $0.isAdoptable && $0.awaitsAdoption }.count
        return "\(name) \(lines.count)：本轮能收 \(usable)｜不可收编 \(notAdoptable)｜已有归属 \(bound)｜回执判死 \(dead)"
    }
    note(group, "事实：三个桶的构成（数字与页面上 ③ 的括号一致）",
         [census("可收编", model.adoptableLines), census("Agent 侧", model.agentSideLines), census("4202 内部", model.internalLines)]
            .joined(separator: " · "))

    let widePageBefore = PageBlocks(model)
    _ = model.adoptUnassignedLines(wide)
    note(group, "表 A（全部范围）收编前后四块页面对比",
         widePageBefore.compare(PageBlocks(freshModel())))
    let afterProviders = rows(loadJSON(sandbox.routerJSON), "providers")
    let ledger = loadJSON(sandbox.ledger)
    let recordedProviders = Set((ledger["provider_ids"] as? [String]) ?? [])
    check(group, "③ 台账记了被改指的行（provider_ids）", recordedProviders.isSuperset(of: expectedRepointed),
          recordedProviders.isEmpty
            ? "台账里没有 provider_ids 键（被改指 \(expectedRepointed.count) 行）"
            : "台账 provider_ids \(recordedProviders.count) 条，应含 \(expectedRepointed.count) 条")

    // 台账不许把「复用来的连接」记成新建（宽范围下更容易踩）。
    let beforeConnectionIDs = lineIDs(beforeConnections)
    let recorded = Set((ledger["connection_ids"] as? [String]) ?? [])
    check(group, "② 宽范围：台账里的连接 id 全是新建的", recorded.intersection(beforeConnectionIDs).isEmpty,
          recorded.intersection(beforeConnectionIDs).isEmpty ? "台账 \(recorded.count) 条全是新建" : "混进已有连接：" + recorded.intersection(beforeConnectionIDs).joined(separator: "、"))
    let afterConnectionRows = rows(loadJSON(sandbox.routerJSON), "connections")
    let wideConnectionDiffs = diffRows(before: beforeConnections, after: afterConnectionRows)
    let wideExistingDiffs = wideConnectionDiffs.filter { beforeConnectionIDs.contains($0.id) && !$0.clean }
    let wideRemoved = wideConnectionDiffs.filter { beforeConnectionIDs.contains($0.id) && $0.missing }
    check(group, "① 宽范围：已有连接一条都没被删", wideRemoved.isEmpty,
          wideRemoved.isEmpty
            ? "\(beforeConnections.count) 条已有连接都在（收编后共 \(afterConnectionRows.count) 条）"
            : "被删：" + wideRemoved.map(\.id).joined(separator: "、"))
    check(group, "① 宽范围：已有连接仍逐键不变", wideExistingDiffs.isEmpty,
          wideExistingDiffs.isEmpty ? "\(beforeConnections.count) 条已有连接一字没动" : wideExistingDiffs.prefix(4).map { "\($0.id)：\(evidence($0))" }.joined(separator: "；"))

    _ = freshModel().restoreAdoptedLines()
    let restoredProviders = rows(loadJSON(sandbox.routerJSON), "providers")
    let restoredDiffs = diffRows(before: beforeProviders, after: restoredProviders)
    let dirty = restoredDiffs.filter { !$0.clean }
    let emptyKeys = restoredProviders.filter { $0.keys.contains("connection_id") && (($0["connection_id"] as? String) ?? "") == "" }
    let restoredObject = loadJSON(sandbox.routerJSON)
    let restoredConnectionDiffs = diffRows(before: beforeConnections, after: rows(restoredObject, "connections"))
    let dirtyConnections = restoredConnectionDiffs.filter { !$0.clean }
    check(group, "③ 还原：连接块逐键回到收编前（被改指时可能整条被删，这一步要它回来）", dirtyConnections.isEmpty,
          dirtyConnections.isEmpty
            ? "\(beforeConnections.count) 条连接全部回到原样"
            : dirtyConnections.prefix(4).map { "\($0.id)：\(evidence($0))" }.joined(separator: "；"))
    check(group, "③ 还原：被改指的行逐键回到原样", dirty.isEmpty,
          dirty.isEmpty ? "\(beforeProviders.count) 行全部回到原样" : dirty.prefix(5).map { "\($0.id)：\(evidence($0))" }.joined(separator: "；"))
    let restoredData = (try? Data(contentsOf: sandbox.routerJSON)) ?? Data()
    check(group, "④ 还原：router.json 逐字节回到收编前", restoredData == beforeData,
          "\(hash12(beforeData))（\(beforeData.count) 字节）→ \(hash12(restoredData))（\(restoredData.count) 字节）")
    let wideDangling = danglingConnectionIDs(restoredObject)
    check(group, "④ 还原后不许留悬空归属", wideDangling.isEmpty,
          wideDangling.isEmpty ? "没有指向已删连接的 connection_id" : "悬空：\(wideDangling.sorted().prefix(4).joined(separator: "、"))")
    check(group, "③ 还原：原本没有 connection_id 的行，键要被删掉（不是写 \"\"）", emptyKeys.isEmpty,
          emptyKeys.isEmpty ? "没有留下 connection_id 空串" : "\(emptyKeys.count) 行留了空串：" + emptyKeys.prefix(3).compactMap { $0["id"] as? String }.joined(separator: "、"))
    _ = afterProviders
}

/// G2：同一份盘、同一份源码，方案的规模不该取决于「用户之前点过什么」。
/// 起因：官方裁判是「先跑默认收编+还原，再算全部范围」→ 19 条；G 用例是干净模型直接算 → 21 条。
/// 这里把两条到达路径并排跑一遍：数字不一致，用户就会看到 23 而不是 25。
private func caseStalePlanAfterAdoption(sandbox: Sandbox) {
    let group = "G2 收编过的盘再来算方案"
    _ = sandbox
    let wide = HubModel.AdoptionSelection(includeAgentSide: true, includeInternal: true)

    // 路径①：App 里最常见的走法 —— 先收一次默认范围，再还原（还原会在台账里留残迹），然后算全部范围方案。
    let used = freshModel()
    _ = used.adoptUnassignedLines()
    _ = used.restoreAdoptedLines()
    used.refresh()
    let usedPlan = used.planAdoption(wide)

    // 路径②：同一份盘，新模型直接算全部范围方案。
    let cleanPlan = freshModel().planAdoption(wide)

    let usedLines = usedPlan.connections.reduce(0) { $0 + $1.modelIDs.count }
    let cleanLines = cleanPlan.connections.reduce(0) { $0 + $1.modelIDs.count }
    let usedNames = usedPlan.connections.map { "\($0.name)(\($0.modelIDs.count))" }.joined(separator: "、")
    let cleanNames = cleanPlan.connections.map { "\($0.name)(\($0.modelIDs.count))" }.joined(separator: "、")
    note(group, "路径① 先默认收编+还原再算", "\(usedLines) 条 · \(usedNames)")
    note(group, "路径② 新模型直接算", "\(cleanLines) 条 · \(cleanNames)")
    check(group, "同一份盘：两条到达路径给出同一份方案", usedLines == cleanLines && usedNames == cleanNames,
          "① 先收编+还原 \(usedLines) 条 vs ② 干净 \(cleanLines) 条")
}

/// H：台账 v1（只有 connection_ids）仍要能读，且删干净、不多删。
/// R：真·同址复用。用的不是合成夹具，而是真实配置里本来就存在的那条同址线路
/// （未归属行 ↔ 已有连接同址），且它只在「全部范围」下才被收编。
/// 专测 ① 的复用四条：复用不许动用户的连接、不许建同址第二条、台账不许记别人的连接、还原要能退回原样。
private func caseRealAddressReuse(sandbox: Sandbox) {
    let group = "R 真·同址复用（真实配置里同址的那条）"
    let beforeData = (try? Data(contentsOf: sandbox.routerJSON)) ?? Data()
    let beforeObject = loadJSON(sandbox.routerJSON)
    let beforeConnections = rows(beforeObject, "connections")
    let beforeProviders = rows(beforeObject, "providers")
    let beforeConnectionIDs = lineIDs(beforeConnections)
    let auditBefore = auditItems()
    let watchedKeys = ["id", "name", "base_url", "wire_api", "api_key", "source", "enabled"]

    let selection = HubModel.AdoptionSelection(includeAgentSide: true, includeInternal: true)
    let model = freshModel()
    let plan = model.planAdoption(selection)

    // 前提全部从真实数据现场算出来（不写死任何 id）：未归属线路里，地址与某条已有连接相同的那些。
    let unboundLines = beforeProviders.filter { connectionID($0) == nil }
    let sameAddress = unboundLines.compactMap { line -> (line: [String: Any], existing: [String: Any], address: String)? in
        let address = normalizedAddress(line["base_url"] as? String)
        guard !address.isEmpty,
              let existing = beforeConnections.first(where: { normalizedAddress($0["base_url"] as? String) == address }) else { return nil }
        return (line, existing, address)
    }
    note(group, "事实：真实配置里的同址复用场景",
         "未归属线路 \(unboundLines.count) 条，其中与已有连接同址 \(sameAddress.count) 条"
         + sameAddress.map { item in
             " ｜ \(item.line["id"] as? String ?? "?")（source \(item.line["source"] as? String ?? "无")）↔「\(item.existing["name"] as? String ?? "?")」@ \(item.address)"
           }.joined())
    guard let scenario = sameAddress.first else {
        check(group, "前提：真实配置里存在同址可复用场景", false,
              "未归属线路里没有与已有连接同址的行，这条合同在真实夹具上判不了")
        return
    }
    if sameAddress.count > 1 {
        note(group, "事实：同址场景不止一条", "这里只跟第一条走（\(sameAddress.count) 条），其余由 A/G 用例覆盖")
    }
    let lineID = scenario.line["id"] as? String ?? "?"
    let existingID = scenario.existing["id"] as? String ?? "?"
    let address = scenario.address
    let modelsBefore = modelIDs(scenario.existing)

    let plannedModels = Set(plan.connections.flatMap { $0.modelIDs })
    let lineInPlan = plan.connections.contains { $0.modelIDs.contains(lineID) }
    check(group, "前提：这条同址线路确实进了「全部范围」的收编方案", lineInPlan,
          lineInPlan ? "\(lineID) 在方案里（全部范围共 \(plannedModels.count) 个模型）"
                     : "\(lineID) 不在方案里：全部范围只收了 \(plannedModels.count) 个模型（分类口径可能变了）")
    guard lineInPlan else { return }

    let adoptLog = model.adoptUnassignedLines(selection)
    let afterObject = loadJSON(sandbox.routerJSON)
    let afterConnections = rows(afterObject, "connections")
    let afterLine = rows(afterObject, "providers").first { ($0["id"] as? String) == lineID }
    let afterExisting = afterConnections.first { ($0["id"] as? String) == existingID }
    let sameAddressAfter = afterConnections.filter { normalizedAddress($0["base_url"] as? String) == address }

    // R1 这行真被收编了（否则后面的复用结论都是空转）。
    check(group, "R1 该行被收编、拿到归属",
          (afterLine.map { !HubModel.isEmptyAddress(connectionID($0) ?? "") } ?? false),
          afterLine.map { "\(lineID) → connection_id \(connectionID($0) ?? "无")（\(adoptLog.prefix(48))）" } ?? "\(lineID) 收编后不见了")

    // R2 指到「用户已有那条」。
    let lineConnection = connectionID(afterLine ?? [:])
    check(group, "R2 指到用户已有那条连接（不是新建同址连接）", lineConnection == existingID,
          "收编后 \(lineID).connection_id = \(lineConnection ?? "无") · 用户那条 = \(existingID)")

    // R3 同址不许出现第二条连接。
    let sameAddressIDs = sameAddressAfter.map { $0["id"] as? String ?? "?" }.joined(separator: "、")
    check(group, "R3 同址连接没有变成两条",
          sameAddressAfter.count == 1 && (sameAddressAfter.first?["id"] as? String) == existingID,
          "地址 \(address) 上的连接：\(sameAddressIDs)（收编前 1 条：\(existingID)）")

    // R4 用户的连接逐键一字未改、模型口径不变。
    var keyProblems: [String] = []
    if let afterExisting {
        for key in watchedKeys where canonical(scenario.existing[key] ?? NSNull()) != canonical(afterExisting[key] ?? NSNull()) {
            keyProblems.append("\(key)：\(brief(scenario.existing[key])) → \(brief(afterExisting[key]))")
        }
    } else {
        keyProblems.append("用户的连接在收编后不见了")
    }
    check(group, "R4 复用后用户的连接逐键未改（含 api_key，尾号与快照同）", keyProblems.isEmpty,
          keyProblems.isEmpty
            ? "「\(scenario.existing["name"] as? String ?? "?")」\(watchedKeys.count) 个键与快照一致 · api_key 尾号 \(keyTail(scenario.existing["api_key"] as? String))"
            : keyProblems.joined(separator: "；"))
    let modelsAfter = modelIDs(afterExisting ?? [:])
    let extraModels = modelsAfter.subtracting(modelsBefore).sorted().joined(separator: "、")
    check(group, "R4 用户的连接没被吞模型也没被改口径",
          modelsAfter == modelsBefore,
          "模型 \(modelsBefore.count) → \(modelsAfter.count) 个（多出来的：\(extraModels.isEmpty ? "无" : extraModels)）")

    // R5 台账只记 App 自己新建的：用户的连接进了台账，还原就会把它删掉。
    let recorded = Set((loadJSON(sandbox.ledger)["connection_ids"] as? [String]) ?? [])
    check(group, "R5 台账里没有用户的连接", !recorded.contains(existingID),
          "台账 \(recorded.count) 条 · 命中已有连接 \(recorded.intersection(beforeConnectionIDs).count) 条 · 用户的 \(existingID) \(recorded.contains(existingID) ? "被记进去了" : "没被记")")

    // R6 还原：逐字节回到收编前，这行退回「本来没有 connection_id」（是删键，不是留空串）。
    let restoreLog = freshModel().restoreAdoptedLines()
    let restoredData = (try? Data(contentsOf: sandbox.routerJSON)) ?? Data()
    let restoredObject = loadJSON(sandbox.routerJSON)
    let restoredLine = rows(restoredObject, "providers").first { ($0["id"] as? String) == lineID }
    let emptyIDLines = rows(restoredObject, "providers").filter { ($0["connection_id"] as? String) == "" }
    check(group, "R6 还原：router.json 逐字节回到收编前", restoredData == beforeData,
          "\(hash12(beforeData))（\(beforeData.count) 字节）→ \(hash12(restoredData))（\(restoredData.count) 字节）· \(restoreLog.prefix(40))")
    let lineBackToNone = (restoredLine.map { $0["connection_id"] == nil } ?? false)
    let restoredState: String = restoredLine.map { row -> String in
        guard let value = row["connection_id"] else { return "\(lineID).connection_id = （键已删除）" }
        return "\(lineID).connection_id = \(value)"
    } ?? "\(lineID) 还原后不见了"
    check(group, "R6 还原：这行回到「本来没有归属」（键已删除）",
          lineBackToNone && emptyIDLines.isEmpty,
          restoredState + " · 空串残留 \(emptyIDLines.count) 个")
    let dangling = danglingConnectionIDs(restoredObject)
    check(group, "R6 还原后不许留悬空归属", dangling.isEmpty,
          dangling.isEmpty ? "没有指向不存在连接的线路" : "悬空：" + dangling.joined(separator: "、"))
    let auditRestored = auditItems()
    check(group, "R6 还原：App 自己的验收清单逐条回到基准",
          auditState(auditRestored) == auditState(auditBefore),
          "\(auditState(auditBefore)) → \(auditState(auditRestored))")
}

private func caseLedgerV1(sandbox: Sandbox) {
    let group = "H 台账 v1 兼容"
    let beforeConnections = rows(loadJSON(sandbox.routerJSON), "connections")
    let beforeConnectionIDs = lineIDs(beforeConnections)
    let model = freshModel()
    _ = model.adoptUnassignedLines()
    let afterAdoptConnections = rows(loadJSON(sandbox.routerJSON), "connections")
    let adoptedIDs = Set(afterAdoptConnections.compactMap { $0["id"] as? String }).subtracting(beforeConnectionIDs)
    check(group, "前提：先收编出可被 v1 台账认领的连接", !adoptedIDs.isEmpty, "新增连接 \(adoptedIDs.count) 条")

    // 把台账改写成 v1 的样子：只有 connection_ids。
    let v1 = ["version": 1, "connection_ids": Array(adoptedIDs).sorted()] as [String: Any]
    if let data = try? JSONSerialization.data(withJSONObject: v1, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: sandbox.ledger)
    }
    let restoreLog = freshModel().restoreAdoptedLines()
    let restored = loadJSON(sandbox.routerJSON)
    let restoredConnections = rows(restored, "connections")
    let restoredDiffs = diffRows(before: beforeConnections, after: restoredConnections)
    let dirty = restoredDiffs.filter { !$0.clean }
    check(group, "⑦ v1 台账能读：列出的连接被删掉", restoredConnections.count == beforeConnections.count,
          "还原前 \(afterAdoptConnections.count) 条 → 还原后 \(restoredConnections.count) 条（收编前 \(beforeConnections.count) 条）· \(restoreLog.prefix(40))")
    check(group, "⑦ v1 台账：不多删、不改别的连接", dirty.isEmpty,
          dirty.isEmpty ? "收编前的 \(beforeConnections.count) 条连接全部原样回来" : dirty.prefix(4).map { "\($0.id)：\($0.summary)" }.joined(separator: "；"))
    let dangling = rows(restored, "providers").compactMap { row -> String? in
        guard let value = row["connection_id"] as? String, !value.isEmpty else { return nil }
        return value
    }.filter { !lineIDs(restoredConnections).contains($0) }
    check(group, "④ v1 台账：还原后不许留悬空归属", dangling.isEmpty,
          dangling.isEmpty ? "没有指向已删连接的 connection_id" : "悬空 \(Set(dangling).count) 个：\(Set(dangling).sorted().prefix(3).joined(separator: "、"))")
}

/// D：台账漂移——文件写坏、形状变了、老版本写坏的表混进用户的连接，
/// 都不许让「还原」悄悄少做事、做错事，或把没读出来的凭据说成「已经还干净了」。
private func caseLedgerDrift(sandbox: Sandbox) {
    let group = "D 台账漂移"
    let seedDir = sandbox.sourceDir
    let beforeAll = rows(loadJSON(sandbox.routerJSON), "connections")
    let unreadable = ["读不了", "损坏", "无法解析", "不可读", "形状"]

    // D2 台账文件被截断（上一次写入中断 / 手工编辑）：凭据读不出来时，必须点名台账，不许默不作声。
    if let box = try? Sandbox(seed: seedDir) {
        _ = freshModel().adoptUnassignedLines()
        try? Data("{\"connection_ids\": [\"conn-adopted-x".utf8).write(to: box.ledger)
        let log = freshModel().restoreAdoptedLines()
        check(group, "⑦ 坏台账：必须点名「台账读不了」",
              log.contains("台账") && unreadable.contains { log.contains($0) },
              "还原日志：\(log.prefix(90))")
        check(group, "⑦ 坏台账：不许把「凭据没读出来」说成一次成功还原",
              !(log.hasPrefix("已还原") && !log.contains("台账")),
              "还原日志：\(log.prefix(90))")
        box.cleanUp(keep: keep)
    } else {
        check(group, "⑦ 坏台账：必须点名「台账读不了」", false, "沙箱建不出来")
    }

    // D3 形状漂移：provider_ids 被写成字符串（外部工具 / 老版本），connection_ids 还是好的。
    if let box = try? Sandbox(seed: seedDir) {
        _ = freshModel().adoptUnassignedLines()
        let adopted = rows(loadJSON(box.routerJSON), "connections")
        let appIDs = Set(adopted.compactMap { $0["id"] as? String }).subtracting(lineIDs(beforeAll))
        let drifted: [String: Any] = ["version": 2, "connection_ids": Array(appIDs).sorted(),
                                      "provider_ids": "不是数组"]
        if let data = try? JSONSerialization.data(withJSONObject: drifted, options: [.sortedKeys]) {
            try? data.write(to: box.ledger)
        }
        let log = freshModel().restoreAdoptedLines()
        let restored = rows(loadJSON(box.routerJSON), "connections")
        let dirty = diffRows(before: beforeAll, after: restored).filter { !$0.clean }
        check(group, "⑦ 形状漂移：好的那一半要认（该删的删、该留的留）",
              restored.count == beforeAll.count && dirty.isEmpty,
              "连接 \(adopted.count) → \(restored.count)（基准 \(beforeAll.count)）· 差异 \(dirty.count) 处")
        check(group, "⑦ 形状漂移：读不了的那一半必须说出来",
              log.contains("台账") && unreadable.contains { log.contains($0) },
              "还原日志：\(log.prefix(90))")
        box.cleanUp(keep: keep)
    } else {
        check(group, "⑦ 形状漂移：好的那一半要认（该删的删、该留的留）", false, "沙箱建不出来")
    }

    // D4 老版本写坏的表：把「复用到的用户连接」也记进了 connection_ids。
    // 还原时凭证据说话——用户的连接必须原样留下，App 自己建的照删。
    if let box = try? Sandbox(seed: seedDir) {
        let userRow = beforeAll.first { row in
            guard let id = row["id"] as? String else { return false }
            return !id.hasPrefix("conn-adopted-") && (row["source"] as? String) != "app-adopt"
        }
        if let userRow, let userID = userRow["id"] as? String {
            let linesOnUserBefore = rows(loadJSON(box.routerJSON), "providers")
                .filter { ($0["connection_id"] as? String) == userID }.count
            _ = freshModel().adoptUnassignedLines()
            let adopted = rows(loadJSON(box.routerJSON), "connections")
            let appIDs = Set(adopted.compactMap { $0["id"] as? String }).subtracting(lineIDs(beforeAll))
            let poisoned: [String: Any] = ["version": 2, "connection_ids": (Array(appIDs) + [userID]).sorted(),
                                           "provider_ids": []]
            if let data = try? JSONSerialization.data(withJSONObject: poisoned, options: [.sortedKeys]) {
                try? data.write(to: box.ledger)
            }
            let log = freshModel().restoreAdoptedLines()
            let after = loadJSON(box.routerJSON)
            let afterConnections = rows(after, "connections")
            let userAfter = afterConnections.first { ($0["id"] as? String) == userID }
            check(group, "① 老版本台账混进用户的连接：用户的连接必须原样留下",
                  userAfter.map(canonical) == Optional(canonical(userRow)),
                  userAfter == nil ? "用户的连接 \(userID) 被删了（台账说它是 App 建的）"
                                   : "用户的连接 \(userID) 还在\(userAfter.map(canonical) == Optional(canonical(userRow)) ? "且逐键未改" : "但内容被改了")")
            let linesOnUserAfter = rows(after, "providers")
                .filter { ($0["connection_id"] as? String) == userID }.count
            check(group, "① 用户连接名下的线路仍指着它（没被解绑）",
                  linesOnUserAfter == linesOnUserBefore, "\(linesOnUserBefore) → \(linesOnUserAfter) 条")
            check(group, "⑦ 台账里没证据的那条要留痕（点名 id 或说明跳过）",
                  log.contains(userID) || (log.contains("台账") && ["跳过", "没动", "证据", "人工"].contains { log.contains($0) }),
                  "还原日志：\(log.prefix(90))")
            let appLeft = afterConnections.filter { appIDs.contains(($0["id"] as? String) ?? "") }.count
            check(group, "⑦ 有 App 证据的那条照删不误", appLeft == 0,
                  "App 建的 \(appIDs.count) 条，还原后剩 \(appLeft) 条")
        } else {
            check(group, "① 老版本台账混进用户的连接：用户的连接必须原样留下", false, "夹具里找不到用户自己的连接")
        }
        box.cleanUp(keep: keep)
    } else {
        check(group, "① 老版本台账混进用户的连接：用户的连接必须原样留下", false, "沙箱建不出来")
    }

    // D5 漂移收尾：还原后台账不许留空壳；再点一次还原不许写盘、也不许说成又还了一遍。
    if let box = try? Sandbox(seed: seedDir) {
        _ = freshModel().adoptUnassignedLines()
        _ = freshModel().restoreAdoptedLines()
        let left = (try? Data(contentsOf: box.ledger)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let noFile = !FileManager.default.fileExists(atPath: box.ledger.path)
        let empty = ((left?["connection_ids"] as? [String]) ?? []).isEmpty && ((left?["provider_ids"] as? [String]) ?? []).isEmpty
        check(group, "④ 还原后台账不许留空壳（文件删掉或表清空）", noFile || empty,
              noFile ? "台账文件已删除" : (empty ? "台账已清空" : "台账还剩 \(left?.keys.sorted().joined(separator: "、") ?? "?")"))
        let frozen = (try? Data(contentsOf: box.routerJSON)) ?? Data()
        let log2 = freshModel().restoreAdoptedLines()
        let frozenAfter = (try? Data(contentsOf: box.routerJSON)) ?? Data()
        check(group, "⑤ 再点一次还原：不写盘、也不说成又还了一遍",
              frozen == frozenAfter && !log2.hasPrefix("已还原"),
              "日志：\(log2.prefix(60)) · 盘上\(frozen == frozenAfter ? "未变" : "被改了")")
        box.cleanUp(keep: keep)
    } else {
        check(group, "④ 还原后台账不许留空壳（文件删掉或表清空）", false, "沙箱建不出来")
    }
}

/// I：确认工具自己没动真实目录（护栏）。
private func caseRealDirectoryUntouched(before: (hash: String, count: Int), after: (hash: String, count: Int)) {
    let group = "护栏"
    check(group, "真实配置目录逐字节未变", before.hash == after.hash,
          "\(before.hash) → \(after.hash)")
    check(group, "真实配置目录没有多出文件", before.count == after.count,
          "文件数 \(before.count) → \(after.count)")
}

// MARK: - 主流程

private func runSelected(_ name: String, _ body: (Sandbox) throws -> Void, seed: URL, keep: Bool) {
    do {
        let sandbox = try Sandbox(seed: seed)
        sandboxRoot = sandbox.dir
        defer { sandbox.cleanUp(keep: keep) }
        try body(sandbox)
    } catch {
        check(name, "用例执行失败", false, "\(error.localizedDescription)")
    }
}

private let arguments = CommandLine.arguments
private let keep = arguments.contains("--keep")
private let only: String? = {
    guard let index = arguments.firstIndex(of: "--case"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1].uppercased()
}()

private let seed = appConfigDirectory()
private func directoryFingerprint(_ dir: URL) -> (hash: String, count: Int) {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    let relevant = files.filter { $0.lastPathComponent.hasPrefix("router") || $0.lastPathComponent.hasSuffix(".json") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var combined = Data()
    for file in relevant { combined.append((try? Data(contentsOf: file)) ?? Data()) }
    return (hash12(combined), files.count)
}

let realBefore = directoryFingerprint(seed)
let seedRouter = seed.appendingPathComponent("router.json")
let seedRouterData = (try? Data(contentsOf: seedRouter)) ?? Data()
let seedRouterObject = loadJSON(seedRouter)
let seedModified: String = {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: seedRouter.path),
          let date = attributes[.modificationDate] as? Date else { return "未知" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
    return formatter.string(from: date)
}()
let seedLedgerExists = FileManager.default.fileExists(atPath: seed.appendingPathComponent("router-adoptions.json").path)
let seedConnectionCount = rows(seedRouterObject, "connections").count
let seedProviderCount = rows(seedRouterObject, "providers").count
let seedLedgerText = seedLedgerExists ? "存在" : "不存在"
print("verify-adopt-safety · 独立验收（只读真实配置，所有动作都在沙箱副本里做；写盘护栏只放行沙箱）")
print("  真实配置目录  \(seed.path)")
print("  冻结基线      router.json sha256 \(sha256Full(seedRouterData))")
print("  基线内容      \(seedRouterData.count) 字节 · mtime \(seedModified) · \(seedConnectionCount) 个连接 · \(seedProviderCount) 条线路 · 收编台账\(seedLedgerText)")
print("  目录指纹      \(realBefore.hash) · \(realBefore.count) 个文件")
print("  沙箱          \(NSTemporaryDirectory())verify-adopt-safety-*（默认跑完删掉，--keep 保留）")
print("")

if only == nil || only == "A" {
    runSelected("A", caseDefaultScope, seed: seed, keep: keep)
}
if only == nil || only == "G" {
    runSelected("G", caseRepointedLines, seed: seed, keep: keep)
}
if only == nil || only == "G2" {
    runSelected("G2", caseStalePlanAfterAdoption, seed: seed, keep: keep)
}
if only == nil || only == "R" {
    runSelected("R", caseRealAddressReuse, seed: seed, keep: keep)
}
if only == nil || only == "H" {
    runSelected("H", caseLedgerV1, seed: seed, keep: keep)
}
if only == nil || only == "D" {
    runSelected("D", caseLedgerDrift, seed: seed, keep: keep)
}
let realAfter = directoryFingerprint(seed)
caseRealDirectoryUntouched(before: realBefore, after: realAfter)

// MARK: - 结论

var currentGroup = ""
for verdict in verdicts {
    guard !verdict.isNote else { continue }
    if verdict.group != currentGroup {
        currentGroup = verdict.group
        print("== \(currentGroup) ==")
    }
    let mark = verdict.ok ? "✅" : "❌"
    let detail = verdict.detail.isEmpty ? "" : "  \(verdict.detail)"
    print("\(mark) \(verdict.title)\(detail)")
}
let checks = verdicts.filter { !$0.isNote }
let facts = verdicts.filter(\.isNote)
let failures = checks.filter { !$0.ok }
print("")
if !facts.isEmpty {
    print("== ℹ️ 事实（不是判据，不计入通过率）==")
    for fact in facts {
        let detail = fact.detail.isEmpty ? "" : "  \(fact.detail)"
        print("ℹ️ [\(fact.group)] \(fact.title)\(detail)")
    }
    print("")
}
let tables = verdicts.filter { $0.isNote && ($0.title.hasPrefix("表 A") || $0.title.hasPrefix("表 B")) }
if !tables.isEmpty {
    print("== 表 A / 表 B（收编前后对照，页面同源口径）==")
    for table in tables {
        print(table.title)
        print("   \(table.detail)")
    }
    print("")
}
print("判据 \(checks.count - failures.count)/\(checks.count) 通过（另有 \(facts.count) 条事实）")
if failures.isEmpty {
    print("verify-adopt-safety: PASS")
    exit(0)
}
print("verify-adopt-safety: FAIL（\(failures.count) 条红）")
for failure in failures { print("   ❌ [\(failure.group)] \(failure.title)") }
exit(1)
