//
//  verify-router-pool.swift — 「① 模型池 / ② 供应商 / ③ 线路 / ④ Agent 引用」四块页面的免窗口验收工具
//
//  为什么要有它：这四块页面的数据全来自 HubModel，而 HubModel 又能在没有窗口、没有网关进程的
//  情况下跑起来。于是「页面显示的到底对不对、会不会误伤配置」这件事，可以完全脱离 App 来验证 ——
//  这对一个改配置的界面尤其重要：说「我只动该动的」不算数，得拿出来看。
//
//  三个模式：
//    （不加参数）     只读：把配置复制成临时副本，打印四块页面 + 收编方案 + 页面自带验收清单
//    --choose        交互：给每个组一个编号，打印选中后四块页面会变成什么样（只算，不写盘）
//    --sandbox       演练：在临时副本上真的走一遍「收编 → 逐键比对 → 还原 → 逐字节比对」
//
//  安全边界：所有模式都只读真实配置、只写临时副本。真实配置目录（~/Library/Application Support/
//  LocalSiriLLM）一个字节都不会被碰；演练里的收编与还原走的都是 App 自己的代码路径
//  （HubModel.adoptUnassignedLines / restoreAdoptedLines），不是另写一套。
//
//  怎么跑：Tools/verify-router-pool.command（编译时要带上 Sources/，还要 SwiftUI 宏插件路径，
//  这两件事都不能少，所以别直接 swift 这个文件）。
//

import Foundation

/// 报告抬头会打印这一行：用来确认「这次输出到底是不是这份源码编译出来的」。
private let toolStamp = "verify-router-pool（router.json 模型池核对，源码版本 2）"

// MARK: - 配置路径与沙箱

private let tempRoot = "verify-router-pool"

/// 真实配置目录。
private func realConfigDirectory() -> URL {
    let override = ProcessInfo.processInfo.environment["LOCAL_SIRI_CONFIG_DIR"] ?? ""
    if !override.isEmpty {
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalSiriLLM", isDirectory: true)
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("用完不还：\(message)\n").data(using: .utf8)!)
    FileHandle.standardError.write("用法：verify-router-pool [--choose | --sandbox | --help]\n".data(using: .utf8)!)
    exit(2)
}

/// 把真实配置目录里的文件复制成一份临时副本，并把三个路径环境变量都指过去。
///
/// 三个都指的必要性：RouterStore 的 config / stats / health 各读一个环境变量，只重定向 config 的话，
/// 「健康探测」这类顺手写盘的动作仍会落到真实目录里。三个一起指，就是「重定向到别处也写不进真目录」。
private func makeSandbox() -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(tempRoot)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let real = realConfigDirectory()
    let names = ["router.json", "router-adoptions.json",
                 "router-stats.json", "router-health.json", "clients.json"]
    for name in names {
        let source = real.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: source.path) else { continue }
        try? FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
    }
    return directory
}

private func pointStoreAt(_ directory: URL) {
    setenv("LOCAL_SIRI_ROUTER_CONFIG", directory.appendingPathComponent("router.json").path, 1)
    setenv("LOCAL_SIRI_ROUTER_STATS", directory.appendingPathComponent("router-stats.json").path, 1)
    setenv("LOCAL_SIRI_ROUTER_HEALTH", directory.appendingPathComponent("router-health.json").path, 1)
}

private func sandboxHeadline(_ directory: URL) -> String {
    let files = ["router.json", "router-stats.json", "router-health.json",
                 "clients.json", "router-adoptions.json"]
    let copied = files.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    return """
    == 沙箱 ==
       沙箱目录     \(directory.path)
       真实配置目录 \(realConfigDirectory().path)（本次一个字节都没动）
       复制进来的   \(copied.joined(separator: "、"))
       三个路径环境变量（config / stats / health）都指向沙箱，写盘也落不到真实目录
    """
}

// MARK: - 配置原件（不经 App 解析，用来做逐字节 / 逐键比对）

private func parseConfig(_ url: URL) -> (data: Data, object: [String: Any])? {
    guard let data = try? Data(contentsOf: url),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    return (data, object)
}

private func describeConfig(_ url: URL, parsed: (data: Data, object: [String: Any])) -> String {
    let providerCount = (parsed.object["providers"] as? [[String: Any]])?.count ?? 0
    let connectionCount = (parsed.object["connections"] as? [[String: Any]])?.count ?? 0
    let agentCount = (parsed.object["agents"] as? [[String: Any]])?.count ?? 0
    let keys = parsed.object.keys.sorted().joined(separator: "、")
    return """
       配置 \(parsed.data.count) 字节 · providers \(providerCount) 条 · connections 文件里 \(connectionCount) 条 · agents \(agentCount) 条
       顶层键：\(keys)
       注：② 页面上的连接数可能比这里多 —— 单行形式的供应商会被页面当成一条连接显示，但不写回配置。
    """
}

/// 走系统自带的 shasum，避免给工具加任何依赖。
private func sha256(_ data: Data) -> String {
    let file = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(tempRoot)-\(UUID().uuidString.prefix(8)).bin")
    guard (try? data.write(to: file)) != nil else { return "" }
    defer { try? FileManager.default.removeItem(at: file) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", file.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return "" }
    process.waitUntilExit()
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return text.split(separator: " ").first.map(String.init) ?? ""
}

// MARK: - 四块页面的数字（与页面同一个来源）

private struct Metrics {
    let pool: Int
    let connections: Int
    let connectionModels: Int
    let agents: Int
    let totalLines: Int
    let pooledLines: Int
    let adoptable: Int
    let boundNotPooled: Int
    let internalLines: Int
    let agentSide: Int
    let references: Int

    var note: String {
        "① \(pool) 个模型 · ② \(connections) 个连接（\(connectionModels) 个模型）· "
        + "③ 线路 \(totalLines)：已进池 \(pooledLines)、可收编 \(adoptable)、已归属未进池 \(boundNotPooled)、"
        + "内部线路 \(internalLines)、Agent 侧 \(agentSide) · ④ \(references) 条引用"
    }
}

private func metrics(_ model: HubModel) -> Metrics {
    Metrics(pool: model.poolModels.count,
            connections: model.connections.count,
            connectionModels: model.connections.reduce(0) { $0 + $1.models.count },
            agents: model.agents.count,
            totalLines: model.routeLines.count,
            pooledLines: model.routeLines.filter { $0.state == .pooled }.count,
            adoptable: model.adoptableLines.count,
            boundNotPooled: model.boundNotPooledLines.count,
            internalLines: model.internalLines.count,
            agentSide: model.agentSideLines.count,
            references: model.agents.reduce(0) { $0 + $1.providerIDs.count })
}

private func printLedger(_ model: HubModel) {
    _ = model
    // 台账是 HubModel 上的静态方法：它直接读本机配置文件，跟哪个实例无关。
    print(HubModel.auditReport())
    print("")
}

/// 收编方案：一组线路会共用一条连接，所以只有地址相同、又确实是自己配的线路才会被归到一起。
/// （用的是 App 自己的 planAdoption()，不是另写一套分组逻辑。）
private func printPlan(_ plan: HubModel.AdoptionPlan, title: String) {
    print("== \(title)（\(plan.lineCount) 条线路 → \(plan.connections.count) 个新连接）==")
    if plan.isEmpty {
        print("   没有要收编的线路。")
    }
    for connection in plan.connections {
        let address = connection.baseURL.isEmpty ? "地址逐条自带" : connection.baseURL
        let key = connection.apiKey.isEmpty ? "密钥逐条自带" : "共用同一把密钥"
        print("   · \(connection.name)   \(connection.modelIDs.count) 条线路   \(key)")
        print("     地址 \(address)")
        print("     线路 \(connection.modelIDs.joined(separator: "、"))")
    }
    print("")
}

/// 只列数字，不打印长台账 —— 收编前后的对照看这一块就够。
private func printSummary(_ title: String, _ metrics: Metrics) {
    print("== \(title) ==")
    print("""
    ① 模型池            数量
    ──────────────────────────
    已进池模型               \(metrics.pool)
    ② 供应商            数量
    ──────────────────────────
    连接                     \(metrics.connections)
    连接里带的模型           \(metrics.connectionModels)
    Agent                    \(metrics.agents)
    ③ 线路              数量
    ──────────────────────────
    合计                     \(metrics.totalLines)
    已进池                   \(metrics.pooledLines)
    可收编                   \(metrics.adoptable)
    已归属未进池             \(metrics.boundNotPooled)
    4202 内部线路            \(metrics.internalLines)
    Agent 侧                 \(metrics.agentSide)
    ④ Agent 引用        数量
    ──────────────────────────
    Agent                    \(metrics.agents)
    引用条目                 \(metrics.references)
    """)
    print("")
}

// MARK: - 逐键比对

private func fieldDiff(_ before: [String: Any], _ after: [String: Any],
                       ignoring ignored: Set<String>) -> [String] {
    var changed: [String] = []
    for key in Set(before.keys).union(after.keys).subtracting(ignored).sorted() {
        let left = (before[key] ?? NSNull()) as AnyObject
        let right = (after[key] ?? NSNull()) as AnyObject
        if !left.isEqual(right) { changed.append(key) }
    }
    return changed
}

/// 逐键（再逐字段）比对本机上的两份 router.json。任何一项不合格都会被单独列出来。
private func printComparison(beforeP: (data: Data, object: [String: Any]),
                             afterP: (data: Data, object: [String: Any]),
                             expectedConnections: Int) -> [String] {
    var problems: [String] = []
    var rows: [(String, String, Bool)] = []
    func row(_ item: String, _ detail: String, _ ok: Bool) {
        rows.append((item, detail, ok))
    }

    let after = afterP.object
    let before = beforeP.object

    let beforeProviders = before["providers"] as? [[String: Any]] ?? []
    let afterProviders = after["providers"] as? [[String: Any]] ?? []
    func byID(_ list: [[String: Any]]) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for item in list where item["id"] as? String != nil { result[item["id"] as! String] = item }
        return result
    }
    let beforeByID = byID(beforeProviders)
    let afterByID = byID(afterProviders)

    row("providers 行数", "\(beforeProviders.count) → \(afterProviders.count)（只增不减）",
        afterProviders.count >= beforeProviders.count)
    let removed = Set(beforeByID.keys).subtracting(afterByID.keys)
    row("线路行一条没少", removed.isEmpty ? "原有 \(beforeByID.count) 行都在" : "丢了 \(removed.count) 行",
        removed.isEmpty)

    var boundIDs: [String] = []
    var touchedFieldProblems: [String] = []
    for (id, old) in beforeByID {
        guard let new = afterByID[id] else { continue }
        let oldBound = (old["connection_id"] as? String) ?? ""
        let newBound = (new["connection_id"] as? String) ?? ""
        if oldBound != newBound {
            boundIDs.append(id)
            if !oldBound.isEmpty { touchedFieldProblems.append("\(id)：原本已有归属，被改写了") }
            let changed = fieldDiff(old, new, ignoring: ["connection_id"])
            if !changed.isEmpty { touchedFieldProblems.append("\(id)：connection_id 之外也被改了（\(changed.joined(separator: "、"))）") }
        } else {
            let changed = fieldDiff(old, new, ignoring: [])
            if !changed.isEmpty { touchedFieldProblems.append("\(id)：本不该动，却被改了（\(changed.joined(separator: "、"))）") }
        }
    }
    row("被写 connection_id 的行", "\(boundIDs.count) 条", true)
    row("这些行的其它字段 / 其余行", touchedFieldProblems.isEmpty ? "逐字段一字未动" : touchedFieldProblems.joined(separator: "；"),
        touchedFieldProblems.isEmpty)
    if !touchedFieldProblems.isEmpty { problems.append("改动了不该动的字段") }

    let beforeConnections = before["connections"] as? [[String: Any]] ?? []
    let afterConnections = after["connections"] as? [[String: Any]] ?? []
    let beforeConnectionByID = byID(beforeConnections)
    let afterConnectionByID = byID(afterConnections)
    var connectionProblems: [String] = []
    for (id, old) in beforeConnectionByID {
        guard let new = afterConnectionByID[id] else { connectionProblems.append("\(id)：原有连接被删了"); continue }
        let changed = fieldDiff(old, new, ignoring: [])
        if !changed.isEmpty { connectionProblems.append("\(id)：\(changed.joined(separator: "、"))") }
    }
    let addedConnections = Set(afterConnectionByID.keys).subtracting(beforeConnectionByID.keys)
    row("原有连接", connectionProblems.isEmpty ? "一个没少、逐字段没变（\(beforeConnectionByID.count) 个）" : connectionProblems.joined(separator: "；"),
        connectionProblems.isEmpty)
    row("新增连接", "\(addedConnections.count) 个：\(addedConnections.sorted().joined(separator: "、"))",
        addedConnections.count == expectedConnections)
    if !connectionProblems.isEmpty { problems.append("原有连接被动了") }
    if addedConnections.count != expectedConnections { problems.append("新增连接数与方案不符") }

    var dangling: [String] = []
    for provider in afterProviders {
        guard let id = provider["connection_id"] as? String, !id.isEmpty else { continue }
        if afterConnectionByID[id] == nil { dangling.append(id) }
    }
    row("connection_id 指向的连接", dangling.isEmpty ? "都在" : "悬空：\(dangling.joined(separator: "、"))", dangling.isEmpty)
    if !dangling.isEmpty { problems.append("有悬空归属") }

    let beforeAgents = byID(before["agents"] as? [[String: Any]] ?? [])
    let afterAgents = byID(after["agents"] as? [[String: Any]] ?? [])
    let agentProblems = beforeAgents.compactMap { id, old -> String? in
        guard let new = afterAgents[id] else { return "\(id)：Agent 被删了" }
        let changed = fieldDiff(old, new, ignoring: [])
        return changed.isEmpty ? nil : "\(id)：\(changed.joined(separator: "、"))"
    }
    row("agents 定义", agentProblems.isEmpty ? "\(afterAgents.count) 个，逐字段一字未动" : agentProblems.joined(separator: "；"),
        agentProblems.isEmpty)
    if !agentProblems.isEmpty { problems.append("Agent 定义被动了") }

    let topKeys = Set(before.keys).subtracting(["providers", "connections"])
    let topProblems = topKeys.compactMap { key -> String? in
        let left = (before[key] ?? NSNull()) as AnyObject
        let right = (after[key] ?? NSNull()) as AnyObject
        return left.isEqual(right) ? nil : key
    }
    row("其余顶层键", topProblems.isEmpty ? "原样" : "被改了：\(topProblems.joined(separator: "、"))", topProblems.isEmpty)
    if !topProblems.isEmpty { problems.append("其余顶层键被改了") }

    print("== 逐键比对（原件 vs 收编后）==")
    let widths = (item: max(22, rows.map(\.0.count).max() ?? 22),
                  detail: max(40, rows.map(\.1.count).max() ?? 40))
    print("\(pad("项目", widths.item))\(pad("结果", widths.detail))结论")
    print(String(repeating: "─", count: widths.item + widths.detail + 6))
    for (item, detail, ok) in rows {
        print("\(pad(item, widths.item))\(pad(detail, widths.detail))\(ok ? "✓" : "✗")")
    }
    print("")
    return problems
}

/// 按「显示宽度」补齐（中文占两格），每格后面再留 6 格空隙。
private func pad(_ text: String, _ width: Int) -> String {
    var result = text
    var displayWidth = 0
    for scalar in text.unicodeScalars {
        displayWidth += scalar.value > 0x2000 && scalar.value < 0xFF61 ? 2 : 1
    }
    while displayWidth < width + 6 { result += " "; displayWidth += 1 }
    return result
}

// MARK: - 页面自带的验收清单

/// 页面里那份验收清单是按「已经收编过」的目标口径写的：池子够大、没有剩余可收编、
/// 每条引用都指得到线路。所以它在收编前本来就该是红的 —— 红的那些正是差距清单。
private func verifyLines(_ title: String, _ result: (text: String, ok: Bool)) -> String {
    let reds = redLines(result)
    var out = "== \(title) ==\n"
    if result.ok {
        out += "全绿（\(result.text.split(separator: "\n").filter { $0.hasPrefix("✅") }.count) 项）\n"
    } else {
        out += "\(reds.count) 项红：\n"
        // 细节为空时（例如还没收编、没有可报的 id），原样打出来会是一条半截话，补个说明。
        for line in reds {
            out += line.hasSuffix(" ") || line == "❌" ? "   \(line)（暂时没有可报的）\n" : "   \(line)\n"
        }
    }
    return out
}

/// 清单里的红项原文。
private func redLines(_ result: (text: String, ok: Bool)) -> [String] {
    result.text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("❌") }
}

/// 四项带「要求 ≥N」的红项就是「目标口径」——它们要的是全部范围收编：
/// 3（TeamoRouter）+ 1（Ark）+ 4（Agent 侧）+ 17（4202 内部线路）= 25。
/// 其余红项跟这些硬指标无关，默认范围收编就该能弄绿，所以演练里专门盯它们。
private func thresholdReds(_ result: (text: String, ok: Bool)) -> [String] {
    redLines(result).filter { $0.contains("要求 ≥") }
}

private func nonThresholdReds(_ result: (text: String, ok: Bool)) -> [String] {
    redLines(result).filter { !$0.contains("要求 ≥") }
}

/// 方案里某个组（按名字前缀认，例如「4202」）有多少条线路。
private func wideLinesFor(_ prefix: String, _ plan: HubModel.AdoptionPlan) -> Int {
    plan.connections.filter { $0.name.hasPrefix(prefix) }.reduce(0) { $0 + $1.modelIDs.count }
}

// MARK: - 动作：只读 / 选组 / 演练

/// 只读：沙箱副本上的四块页面 + 收编方案 + 页面验收清单现状。
private func runReadOnly(directory: URL, parsed: (data: Data, object: [String: Any])) {
    print("== 读的是沙箱副本（真文件没碰）==")
    print(describeConfig(directory.appendingPathComponent("router.json"), parsed: parsed))
    print("")
    pointStoreAt(directory)
    let model = HubModel()
    model.refresh()
    printSummary("① ② ③ ④", metrics(model))
    print(model.planAdoption().summary)
    printPlan(model.planAdoption(), title: "收编方案（默认范围：只动「可收编」）")
    var wide = HubModel.AdoptionSelection()
    wide.includeAgentSide = true
    wide.includeInternal = true
    printPlan(model.planAdoption(wide), title: "收编方案（全部范围：可收编 + Agent 侧 + 内部线路）")
    print("")
    print("== ③ 页面台账原文（HubModel.auditReport()，只读）==")
    printLedger(model)
    let before = HubModel.auditVerify()
    print(verifyLines("页面自带验收清单（目标口径 = 已收编）", before))
    print("   红的就是差距清单，分两种：")
    print("     · 带「要求 ≥N」的 \(thresholdReds(before).count) 项要的是「全部范围」：3（TeamoRouter）+ 1（Ark）+ 4（Agent 侧）+ 17（4202 内部线路）= 25；")
    print("     · 其余 \(nonThresholdReds(before).count) 项（没有可收编的线路、收编连接可识别）走「默认范围」就会变绿。")
    print("")
    print("只读：没有写盘。要看真写一遍的效果：Tools/verify-router-pool.command --sandbox")
}

/// 交互：给每个组编号，看选中后四块页面会变成什么样。只算，不写盘。
private func runChoose(directory: URL) {
    pointStoreAt(directory)
    let model = HubModel()
    model.refresh()
    let plan = model.planAdoption()
    var wide = HubModel.AdoptionSelection()
    wide.includeAgentSide = true
    wide.includeInternal = true
    let widePlan = model.planAdoption(wide)
    guard !plan.isEmpty || !widePlan.isEmpty else {
        print("这份配置里没有可收编的线路、Agent 侧线路或 4202 内部线路 —— 没什么可挑的。")
        print("现状：连接 \(model.connections.count) 个 · 线路 \(model.routeLines.count) 条 · 模型池 \(model.poolModels.count) 个模型。")
        return
    }

    print("== 可收编的组（编号只供你在 App 里对照，这个工具不走输入）==")
    print("")
    var index = 0
    func list(_ plan: HubModel.AdoptionPlan, _ scope: String) {
        for connection in plan.connections {
            index += 1
            let address = connection.baseURL.isEmpty ? "地址逐条自带" : connection.baseURL
            print("  [\(index)] \(connection.name)     \(connection.modelIDs.count) 条线路")
            print("       范围 \(scope) · 地址 \(address) · \(connection.apiKey.isEmpty ? "密钥逐条自带" : "共用同一把密钥")")
            print("       线路：\(connection.modelIDs.joined(separator: "、"))")
        }
    }
    let already = Set(plan.connections.map(\.name))
    var wideExtra = widePlan
    wideExtra.connections = widePlan.connections.filter { !already.contains($0.name) }
    list(plan, "默认")
    list(wideExtra, "要另外点头")
    print("")
    print("上面每一行就是一组：一起收编的线路会共用同一个地址和密钥，所以只有地址相同、")
    print("又确实是你自己配的线路才会被归到一起。要改分组就用 App 里的按钮；")
    print("想先看收编以后四块页面变成什么样，跑 --sandbox（在临时副本上真做一遍再还原）。")
}

/// 演练：在沙箱副本上真的收编一次、逐键比对、再用 App 自己的「还原」退回去并逐字节比对。
private func runExercise(directory: URL, parsed: (data: Data, object: [String: Any])) -> Int32 {
    print(sandboxHeadline(directory))
    print(describeConfig(directory.appendingPathComponent("router.json"), parsed: parsed))
    print("")

    pointStoreAt(directory)
    let model = HubModel()
    model.refresh()
    let before = metrics(model)
    printSummary("收编前 ①②③④", before)

    let plan = model.planAdoption()
    printPlan(plan, title: "收编方案（只算，不写盘）")
    let verifyBefore = HubModel.auditVerify()

    let beforeData = (try? Data(contentsOf: directory.appendingPathComponent("router.json"))) ?? Data()
    let beforeHash = sha256(beforeData)

    print("== 真的写一遍（只写沙箱）==")
    let adoption = model.adoptUnassignedLines()
    print("   结果：\(adoption)")
    let afterData = (try? Data(contentsOf: directory.appendingPathComponent("router.json"))) ?? Data()
    print("   改动后配置 \(afterData.count) 字节（原 \(beforeData.count) 字节）")
    if !model.lastBackupPath.isEmpty {
        let backupExists = FileManager.default.fileExists(atPath: model.lastBackupPath)
        print("   写盘前备份：\(model.lastBackupPath)（\(backupExists ? "在" : "没落盘"))")
    }
    print("")

    model.refresh()
    printSummary("收编后 ①②③④", metrics(model))
    let verifyAfter = HubModel.auditVerify()
    // 还原会把状态退回去，所以这两件事现在就得记下来（它们各有自己的验收项）。
    let adoptedLeftover = model.adoptableLines.count
    let adoptedRecognizable = model.adoptedConnectionIDs.count

    guard let afterParsed = parseConfig(directory.appendingPathComponent("router.json")) else {
        print("读不回改动后的配置，演练中止。")
        return 1
    }
    let expectedConnections = plan.connections.count
    let compareProblems = printComparison(beforeP: parsed, afterP: afterParsed,
                                         expectedConnections: expectedConnections)

    let after = metrics(model)

    print("== 收编后的四块页面台账（HubModel.auditReport() 原样输出）==")
    printLedger(model)
    print(verifyLines("页面自带验收清单（收编后）", verifyAfter))
    print("   剩下这 \(thresholdReds(verifyAfter).count) 项都带「要求 ≥N」，靠这一次默认范围收编到不了；")
    print("   走「全部范围」把 4202 内部线路 17 条和 Agent 侧 4 条也收进来才够 25。")
    print("")

    // 用 App 自己的「还原」退回去 —— 这才是用户在 ③ 页面上点的那个动作。
    print("== 还原（HubModel.restoreAdoptedLines()）==")
    let restoreMessage = model.restoreAdoptedLines()
    print("   结果：\(restoreMessage)")
    let restoredData = (try? Data(contentsOf: directory.appendingPathComponent("router.json"))) ?? Data()
    let restoredHash = sha256(restoredData)
    model.refresh()
    let restored = metrics(model)
    let verifyRestored = HubModel.auditVerify()
    let restoredParsed = parseConfig(directory.appendingPathComponent("router.json"))?.object ?? [:]

    var checks: [(String, Bool)] = []
    checks.append(("逐字节还原：\(beforeHash) → \(restoredHash)", beforeHash == restoredHash && !beforeHash.isEmpty))
    checks.append(("还原后连接回到 \(before.connections) 个", restored.connections == before.connections))
    checks.append(("还原后模型池回到收编前的 \(before.pool) 个", restored.pool == before.pool))
    checks.append(("还原后可收编回到 \(before.adoptable) 条", restored.adoptable == before.adoptable))
    checks.append(("还原后没有悬空归属",
                   !((restoredParsed["providers"] as? [[String: Any]]) ?? []).contains { provider in
                       guard let id = provider["connection_id"] as? String, !id.isEmpty else { return false }
                       let ids = Set(((restoredParsed["connections"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })
                       return !ids.contains(id)
                   }))
    checks.append(("老口径没被牵连：线路行 \(before.totalLines) · 内部线路 \(before.internalLines) · Agent 侧 \(before.agentSide)",
                   restored.totalLines == before.totalLines
                   && restored.internalLines == before.internalLines
                   && restored.agentSide == before.agentSide
                   && compareProblems.isEmpty))
    checks.append(("净效果 = 可收编那组整体进池：模型池 \(before.pool) → \(after.pool)（+\(plan.lineCount)）",
                   after.pool == before.pool + plan.lineCount))
    checks.append(("Agent 引用没被牵连：\(before.references) → \(after.references)",
                   after.references == before.references))
    // 「全绿」不是这次演练的标准：目标清单要的是全部范围（3+1+4+17=25），
    // 默认范围只该把跟硬指标无关的那两项弄绿，并且不许牵连出新的红。
    let thresholdAfter = thresholdReds(verifyAfter).count
    let thresholdBefore = thresholdReds(verifyBefore).count
    checks.append(("验收清单：该绿的绿了（没有可收编的线路剩 \(adoptedLeftover) 条 · 收编连接可识别 \(adoptedRecognizable) 个）",
                   adoptedLeftover == 0 && adoptedRecognizable > 0))
    checks.append(("验收清单：没牵连出新的红（带「要求 ≥N」的 \(thresholdBefore) → \(thresholdAfter) 项，其余 \(nonThresholdReds(verifyAfter).count) 项已清）",
                   thresholdAfter == thresholdBefore && nonThresholdReds(verifyAfter).isEmpty))
    checks.append(("验收清单：收编前确实有红项可看（\(redLines(verifyBefore).count) 项）",
                   !redLines(verifyBefore).isEmpty && !verifyBefore.ok))
    checks.append(("验收清单：还原后回到原样（和不写盘时一致）", verifyRestored.ok == verifyBefore.ok))

    // ── 第二段：全部范围（用户给的验收口径：3 + 1 + 4 + 17 = 25）──
    // 第一段只动「可收编」，够不到「≥25 / 4202 ≥17」这些硬指标，所以这里把
    // Agent 侧和 4202 内部线路也收一遍，看目标清单能不能全绿，再逐字节还原。
    print("")
    print("== 第二段：全部范围收编（可收编 + Agent 侧 + 内部线路）==")
    var wide = HubModel.AdoptionSelection()
    wide.includeAgentSide = true
    wide.includeInternal = true
    let widePlan = model.planAdoption(wide)
    let wideConnections = widePlan.connections.count
    let wideLines = widePlan.connections.reduce(0) { $0 + $1.modelIDs.count }
    print("   方案：\(wideConnections) 个新连接 · \(wideLines) 条线路")
    for connection in widePlan.connections {
        print("     · \(connection.name)  \(connection.modelIDs.count) 条")
    }
    let wideAdoption = model.adoptUnassignedLines(wide)
    print("   结果：\(wideAdoption)")
    model.refresh()
    printSummary("全部范围收编后 ①②③④", metrics(model))
    let afterWide = metrics(model)
    let verifyWide = HubModel.auditVerify()
    print(verifyLines("页面自带验收清单（全部范围收编后）", verifyWide))
    if !verifyWide.ok {
        print("   还红的这几项，括号里是收编后的实际数字：")
        for line in redLines(verifyWide) { print("     \(line)") }
    }

    let wideData = (try? Data(contentsOf: directory.appendingPathComponent("router.json"))) ?? Data()
    print("== 第二段还原（HubModel.restoreAdoptedLines()）==")
    print("   结果：\(model.restoreAdoptedLines())")
    let wideRestoredData = (try? Data(contentsOf: directory.appendingPathComponent("router.json"))) ?? Data()
    print("   配置 \(wideData.count) 字节 → \(wideRestoredData.count) 字节")
    model.refresh()
    let restoredWide = metrics(model)
    let verifyRestoredWide = HubModel.auditVerify()

    checks.append(("全部范围：4202 内部线路整组进池 \(wideLinesFor("4202", widePlan)) 条（要求 ≥17）",
                   wideLinesFor("4202", widePlan) >= 17))
    checks.append(("全部范围：模型池 \(afterWide.pool) 个（要求 ≥25）", afterWide.pool >= 25))
    checks.append(("全部范围：供应商连接 \(afterWide.connections) 个（要求 ≥5）", afterWide.connections >= 5))
    checks.append(("全部范围：页面目标清单全绿（8 项）", verifyWide.ok))
    checks.append(("全部范围：还原逐字节回到原样（\(sha256(beforeData).prefix(12))…）",
                   sha256(wideRestoredData) == sha256(beforeData)))
    checks.append(("全部范围：还原后四块页面回到收编前（池 \(restoredWide.pool) · 连接 \(restoredWide.connections) · 可收编 \(restoredWide.adoptable)）",
                   restoredWide.pool == before.pool
                   && restoredWide.connections == before.connections
                   && restoredWide.adoptable == before.adoptable
                   && verifyRestoredWide.ok == verifyBefore.ok))

    print("")
    print("== 结论 ==")
    for (title, ok) in checks { print("\(ok ? "✅" : "❌") \(title)") }

    print("""
    这次动过的文件                      内容
    ────────────────────────────────────────────────────────────────────────────
    router.json                         \(plan.lineCount) 行的 connection_id + \(expectedConnections) 个新连接
    router-backups/                     写盘前的带时间戳备份（只复制，不改原文件）
    router-adoptions.json               App 自己的收编台账，用来支持「还原」
    沙箱目录里的其它文件                原样复制，未被修改
    """)

    let failed = checks.filter { !$0.1 }.map(\.0)
    if failed.isEmpty {
        print("")
        print("演练通过：默认范围只动该动的 \(plan.lineCount) 行、全部范围把 \(wideLines) 条线路收进来，两次都逐字节还原回原样。")
        return 0
    }
    print("")
    print("演练有 \(failed.count) 项没过：\(failed.joined(separator: "；"))")
    return 1
}

// MARK: - 入口

let arguments = CommandLine.arguments.dropFirst()
let known: Set<String> = ["--choose", "--sandbox", "--help", "-h"]
if let bad = arguments.first(where: { !known.contains($0) }) { fail("不认识的参数 \(bad)") }

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    verify-router-pool —— 四块页面的免窗口验收

      （不加参数）  只读：打印 ①②③④ + 收编方案 + 页面验收清单现状
      --choose      列出可收编的组（只算，不写盘）
      --sandbox     沙箱演练：默认范围收一遍、全部范围再收一遍，各自逐键比对 + 逐字节还原
                    KEEP_SANDBOX=1 可保留沙箱目录（用来 diff 还原残留）

    所有模式都只读真实配置、只写临时副本。环境变量 LOCAL_SIRI_CONFIG_DIR 可换配置目录。
    """)
    exit(0)
}

let sandbox = makeSandbox()
// 想看还原后到底剩了什么，就 KEEP_SANDBOX=1 跑一次：目录会留下来，路径也打印出来。
let keepSandbox = ProcessInfo.processInfo.environment["KEEP_SANDBOX"] == "1"
defer { if !keepSandbox { try? FileManager.default.removeItem(at: sandbox) } }
if keepSandbox { print("沙箱保留在：\(sandbox.path)") }
print(toolStamp)
print("")
guard let parsed = parseConfig(sandbox.appendingPathComponent("router.json")) else {
    fail("沙箱里没有 router.json（真实目录：\(realConfigDirectory().path)）")
}

if arguments.contains("--sandbox") {
    exit(runExercise(directory: sandbox, parsed: parsed))
} else if arguments.contains("--choose") {
    runChoose(directory: sandbox)
    exit(0)
} else {
    runReadOnly(directory: sandbox, parsed: parsed)
    exit(0)
}
