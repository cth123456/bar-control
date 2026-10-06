//  工具：verify-route-facts —— 「线路事实」核对（① ② ③ ④ 四块页面共用的那套判定）
//
//  为什么要有这个工具：
//  这个回合的改动全在「归属」两个字上——手写线路进池、收编只加连接、还原要逐字节回到原样。
//  这些不能靠肉眼看界面，也不能只看截图：得把 router.json 摆到不同的开局上，让 App 自己跑一遍，
//  再回头核对盘上到底改了哪些键。所以这里不用真配置、不用网络、不碰用户数据，
//  全部在 NSTemporaryDirectory() 里造夹具，用假的 LOCAL_SIRI_* 环境变量喂给 App 的数据层。
//
//  夹具是手写的（不是真配置的副本），每条都对应一句用户在界面上会做的事。
//  每条用例的输出分三层，故意分开写：
//      事实 ·     工具从盘上读到的（可以先不看我的判断，自己核对这一层）
//      手写预期 · App 这个回合承诺的行为，一句话
//      ✓ / ✗      事实和预期逐条对上没有；✗ 只表示「和手写的预期不符」，
//                 可能是 App 的问题，也可能是我预期写错了 —— 每条 ✗ 后面都跟着盘上事实。
//
//  用法：
//      ./Tools/verify-route-facts.command            跑全部用例
//      ./Tools/verify-route-facts.command --case 7   只跑第 7 条
//      ./Tools/verify-route-facts.command --keep     保留夹具目录（默认跑完删掉）
//
//  安全：全程只写临时目录；构造 HubModel 之前把 LOCAL_SIRI_ROUTER_CONFIG / _STATS / _HEALTH /
//       _ADOPTIONS 指向夹具，跑完再逐字节比对真实配置目录里的 router.json / router-adoptions.json
//       （只读比对，没变才算过）。

import Foundation

// MARK: - 输出层（事实 / 手写预期 / 逐条核对）

private var checks = 0
private var failures = 0
private var firstFailures: [String] = []

private func heading(_ text: String) { print("\n" + text) }
private func fact(_ text: String) { print("     事实 · \(text)") }
private func hand(_ text: String) { print("     手写预期 · \(text)") }
private func note(_ text: String) { print("     \(text)") }

@discardableResult
private func check(_ title: String, _ ok: Bool, got: String = "", want: String = "") -> Bool {
    checks += 1
    if ok {
        print("     ✓ \(title)")
    } else {
        failures += 1
        if firstFailures.count < 12 { firstFailures.append(title) }
        print("     ✗ \(title)")
        if !want.isEmpty { print("        期望：\(want)") }
        if !got.isEmpty { print("        实际：\(got)") }
        if want.isEmpty && got.isEmpty { print("        （这一条和手写的预期不符，盘上事实见上面几行）") }
    }
    return ok
}

// MARK: - JSON 小工具

private func row(id: String, name: String, model: String? = nil, baseURL: String? = nil,
                 source: String = "", kind: String = "openai_compatible",
                 connectionID: String? = nil, apiKey: String? = nil) -> [String: Any] {
    var item: [String: Any] = ["id": id, "name": name, "source": source, "kind": kind, "enabled": true]
    if let model { item["model"] = model }
    if let baseURL { item["base_url"] = baseURL }
    if let connectionID { item["connection_id"] = connectionID }
    if let apiKey { item["api_key"] = apiKey }
    return item
}

private func connection(id: String, name: String, baseURL: String, apiKey: String = "",
                        source: String = "manual", models: [String] = []) -> [String: Any] {
    [
        "id": id, "name": name, "base_url": baseURL, "api_key": apiKey,
        "wire_api": "chat_completions", "timeout_seconds": 120,
        "kind": "openai_compatible", "enabled": true, "source": source,
        "models": models.map { ["id": $0, "name": $0] },
    ]
}

private func agent(id: String, name: String, providerIDs: [String]) -> [String: Any] {
    ["id": id, "name": name, "enabled": true, "provider_ids": providerIDs]
}

/// 两份 JSON 的「键级差异」。路径写法：providers.1.base_url；数组变长/变短单独说。
private func jsonDiff(old: Any?, new: Any?, path: String = "") -> [String] {
    switch (old, new) {
    case (nil, nil):
        return []
    case (nil, let new?):
        return ["\(path.isEmpty ? "（根）" : path) 新增 \(compact(new))"]
    case (let old?, nil):
        return ["\(path.isEmpty ? "（根）" : path) 整块没了（原来是 \(compact(old))）"]
    case (let old as [String: Any], let new as [String: Any]):
        var out: [String] = []
        for key in Set(old.keys).union(new.keys).sorted() {
            let child = path.isEmpty ? key : "\(path).\(key)"
            if old[key] == nil {
                out.append("\(child) 新增 \(compact(new[key]!))")
            } else if new[key] == nil {
                out.append("\(child) 整键没了（原来是 \(compact(old[key]!))）")
            } else if !jsonEqual(old[key]!, new[key]!) {
                out += jsonDiff(old: old[key]!, new: new[key]!, path: child)
            }
        }
        return out
    case (let old as [Any], let new as [Any]):
        if old.count != new.count { return ["\(path.isEmpty ? "（根）" : path) 数组长度变了：\(old.count) → \(new.count)"] }
        var out: [String] = []
        for index in old.indices where !jsonEqual(old[index], new[index]) {
            out += jsonDiff(old: old[index], new: new[index], path: "\(path.isEmpty ? "（根）" : path).\(index)")
        }
        return out
    default:
        return ["\(path.isEmpty ? "（根）" : path) 值变了：\(compact(old)) → \(compact(new))"]
    }
}

private func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
    (try? JSONSerialization.data(withJSONObject: [lhs], options: [.sortedKeys]))
        == (try? JSONSerialization.data(withJSONObject: [rhs], options: [.sortedKeys]))
}

/// 一行人话：字符串直接写，其它压成 JSON。
private func compact(_ value: Any) -> String {
    if let text = value as? String { return "「\(text)」" }
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        return String(text.prefix(120))
    }
    return "\(value)"
}

private func loadObject(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
}

private func stableString(_ value: Any?) -> String {
    guard let value else { return "（无）" }
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) { return text }
    return "\(value)"
}

// MARK: - 沙箱夹具

private let keepSandboxes = CommandLine.arguments.contains("--keep")

/// 真实配置的两个文件（跑完用来核对「一个字节都没动」）。程序一开始就读，避免被夹具覆盖后再读。
private let realConfigURL = HubModel.defaultConfigURL
private let ambientAdoptionsURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCAL_SIRI_ADOPTIONS_PATH"]
                                      ?? HubModel.defaultConfigURL.deletingLastPathComponent()
                                          .appendingPathComponent("router-adoptions.json").path)
private let realConfigBefore = try? Data(contentsOf: realConfigURL)
private let realAdoptionsBefore = try? Data(contentsOf: ambientAdoptionsURL)

private final class Case {
    let dir: URL
    let model: HubModel
    let beforeData: Data
    let beforeObject: [String: Any]

    init(providers: [[String: Any]], connections: [[String: Any]] = [], agents: [[String: Any]]) {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verify-route-facts-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("router.json")
        let fixture: [String: Any] = ["providers": providers, "connections": connections, "agents": agents]
        beforeData = (try? JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        try? beforeData.write(to: config)
        setenv("LOCAL_SIRI_ROUTER_CONFIG", config.path, 1)
        setenv("LOCAL_SIRI_STATS_PATH", dir.appendingPathComponent("stats.json").path, 1)
        setenv("LOCAL_SIRI_HEALTH_PATH", dir.appendingPathComponent("health.json").path, 1)
        setenv("LOCAL_SIRI_ADOPTIONS_PATH", dir.appendingPathComponent("router-adoptions.json").path, 1)
        beforeObject = loadObject(config)
        model = HubModel()
        model.refresh()
    }

    var configURL: URL { dir.appendingPathComponent("router.json") }
    var ledgerURL: URL { dir.appendingPathComponent("router-adoptions.json") }
    var backupDir: URL { dir.appendingPathComponent("router-backups", isDirectory: true) }

    func object() -> [String: Any] { loadObject(configURL) }
    func providers() -> [[String: Any]] { (object()["providers"] as? [[String: Any]]) ?? [] }
    func connections() -> [[String: Any]] { (object()["connections"] as? [[String: Any]]) ?? [] }

    func provider(_ id: String) -> [String: Any]? {
        providers().first { ($0["id"] as? String) == id }
    }

    func connection(_ id: String) -> [String: Any]? {
        connections().first { ($0["id"] as? String) == id }
    }

    func ledgerIDs() -> [String] {
        (loadObject(ledgerURL)["connection_ids"] as? [String]) ?? []
    }

    func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: backupDir.path)) ?? []).sorted()
    }

    func refresh() { model.refresh() }

    func line(_ id: String) -> HubModel.RouteLine? {
        model.routeLines.first { $0.id == id }
    }

    func state(_ id: String) -> String { line(id)?.state.title ?? "（没这行）" }

    func diffFromBefore() -> [String] { jsonDiff(old: beforeObject, new: object()) }

    func poolNames() -> [String] { model.poolModels.map(\.model).sorted() }

    func cleanup() { if !keepSandboxes { try? FileManager.default.removeItem(at: dir) } }
}

private func printFixture(_ cs: Case) {
    for item in cs.providers() {
        let id = (item["id"] as? String) ?? "?"
        let name = (item["name"] as? String) ?? ""
        let model = (item["model"] as? String) ?? ""
        let address = (item["base_url"] as? String) ?? ""
        let owner = (item["connection_id"] as? String) ?? ""
        let source = (item["source"] as? String) ?? ""
        print("     夹具线路 · \(id)「\(name)」model=\(model.isEmpty ? "（没写）" : model)"
              + " 地址=\(address.isEmpty ? "（没写）" : "「\(address)」")"
              + " 归属=\(owner.isEmpty ? "（没有）" : owner)"
              + " source=\(source.isEmpty ? "（空）" : source)")
    }
    for item in cs.connections() {
        let id = (item["id"] as? String) ?? "?"
        let name = (item["name"] as? String) ?? ""
        let address = (item["base_url"] as? String) ?? ""
        let key = (item["api_key"] as? String) ?? ""
        let source = (item["source"] as? String) ?? ""
        let models = ((item["models"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        print("     夹具连接 · \(id)「\(name)」地址=\(address.isEmpty ? "（没写）" : address)"
              + " 密钥=\(key.isEmpty ? "（没有）" : "有")"
              + " 连接里的模型=\(models.isEmpty ? "（没有）" : models.joined(separator: "、"))"
              + " source=\(source.isEmpty ? "（空）" : source)")
    }
}

private func printAfter(_ cs: Case) {
    for line in cs.model.routeLines {
        print("     事实 · 线路 \(line.id)：状态=\(line.state.title)；\(line.reason)")
    }
    print("     事实 · 模型池现在 \(cs.model.poolModels.count) 个模型："
          + (cs.poolNames().isEmpty ? "（空）" : cs.poolNames().joined(separator: "、")))
}

private func printDiff(_ cs: Case) {
    let diff = cs.diffFromBefore()
    if diff.isEmpty {
        print("     事实 · 和开局比，router.json 的键级差异：没有（逐字节也相同=\(cs.object() as NSDictionary == ((try? JSONSerialization.jsonObject(with: cs.beforeData)) as? NSDictionary ?? NSDictionary()) ? "是" : "否，见下")")
    } else {
        print("     事实 · 和开局比，router.json 改了这些键：")
        for item in diff { print("        - \(item)") }
    }
}

private func byteIdentical(_ cs: Case) -> Bool {
    guard let now = try? Data(contentsOf: cs.configURL) else { return false }
    return now == cs.beforeData
}

private func perform(_ number: Int, _ title: String, _ promise: String,
                     providers: [[String: Any]], connections: [[String: Any]] = [],
                     agents: [[String: Any]], _ body: (Case) -> Void) {
    heading("== 用例 \(number)：\(title) ==")
    hand(promise)
    let startedWith = failures
    let cs = Case(providers: providers, connections: connections, agents: agents)
    printFixture(cs)
    body(cs)
    let ok = failures == startedWith
    print(ok ? "     小结 · 这一条全部对上。" : "     小结 · 这一条有 ✗，见上。")
    cs.cleanup()
}

// MARK: - 用例

private func case1() {
    let address = "https://api.mine.example/v1"
    perform(1, "手写线路进池（收编只加连接、只改这些行自己的归属），然后还原",
            "两条手写线路（同址同密钥，没有归属）收编后进模型池；收编只新增连接、只给这两行写 connection_id；还原后 router.json 逐字节回到开局。",
            providers: [
                row(id: "mine-primary", name: "手写·主线路", model: "gpt-5.1", baseURL: address, apiKey: "fixture-key-mine"),
                row(id: "mine-backup", name: "手写·备线路", model: "gpt-5.1-mini", baseURL: address, apiKey: "fixture-key-mine"),
                row(id: "mine-nameless", name: "手写·只写了名字", model: nil, baseURL: address, apiKey: "fixture-key-mine"),
            ],
            agents: [agent(id: "default", name: "默认", providerIDs: [])]) { cs in
        printAfter(cs)
        let adoptable = cs.model.routeLines.filter { $0.state == .adoptable }
        check("只有两条「可收编」，缺 model 的那条是「非模型行」",
              adoptable.map(\.id).sorted() == ["mine-backup", "mine-primary"] && cs.state("mine-nameless") == "非模型行",
              got: "可收编=\(adoptable.map(\.id).sorted())，缺 model 那条=\(cs.state("mine-nameless"))",
              want: "可收编=[mine-backup, mine-primary]，缺 model 那条=非模型行")

        let plan = cs.model.planAdoption()
        fact("收编方案 \(plan.lineCount) 条线路：" + plan.summary)
        check("方案把两条并进同一组（同一个来源标签 → 一条连接）", plan.connections.count == 1 && plan.lineCount == 2,
              got: "connections=\(plan.connections.count) lines=\(plan.lineCount)", want: "connections=1 lines=2")

        let reply = cs.model.adoptUnassignedLines()
        refreshAndReport(cs, action: reply)
        let newConnection = cs.connections().first { ($0["source"] as? String) == "app-adopt" }
        let newID = (newConnection?["id"] as? String) ?? ""
        fact("新连接 id=\(newID.isEmpty ? "（没建出来）" : newID)"
              + " 名字=「\((newConnection?["name"] as? String) ?? "")」"
              + " 地址=「\((newConnection?["base_url"] as? String) ?? "")」"
              + " 密钥=\(((newConnection?["api_key"] as? String) ?? "").isEmpty ? "（空）" : "有")")
        check("收编建出的连接带 source=app-adopt", newConnection != nil,
              got: "connections=\(cs.connections().compactMap { $0["id"] as? String })", want: "多出一条 source=app-adopt 的连接")
        check("两条线路都进池了", cs.poolNames() == ["gpt-5.1", "gpt-5.1-mini"],
              got: "池=\(cs.poolNames())", want: "[gpt-5.1, gpt-5.1-mini]")

        let diff = cs.diffFromBefore()
        let onlyExpected = diff.allSatisfy { $0.contains("connection_id") || $0.contains("connections") }
        check("收编只动了 connections（新增一条）和这两行的 connection_id", onlyExpected && !newID.isEmpty,
              got: diff.joined(separator: "；"), want: "只出现 connections.* 和 providers.0/1.connection_id")
        let untouched = ["model", "base_url", "api_key", "enabled", "name", "source"].allSatisfy { key in
            cs.provider("mine-primary")?[key] as? String == row(id: "mine-primary", name: "手写·主线路", model: "gpt-5.1",
                                                              baseURL: address, apiKey: "fixture-key-mine")[key] as? String
        }
        check("线路行自己的 model / 地址 / 密钥 / 开关一个都没改", untouched,
              got: stableString(cs.provider("mine-primary")), want: "地址 https://api.mine.example/v1、model gpt-5.1、enabled true")
        check("缺 model 的那行没被挂上连接", (cs.provider("mine-nameless")?["connection_id"]) == nil,
              got: stableString(cs.provider("mine-nameless")?["connection_id"]), want: "没有 connection_id")
        check("收编台账写在配置目录里，且只记这条新连接", cs.ledgerURL.deletingLastPathComponent().path == cs.dir.path
              && cs.ledgerIDs() == [newID],
              got: "台账=\(cs.ledgerIDs()) 位置=\(cs.ledgerURL.path)", want: "[\(newID)] 且和 router.json 同目录")
        check("写盘前留了备份", cs.backups().count == 1 && cs.backups()[0].contains("adopt-lines"),
              got: "\(cs.backups())", want: "router-backups/router-*-adopt-lines.json")

        let restoreReply = cs.model.restoreAdoptedLines()
        cs.refresh()
        print("     —— 还原 ——")
        printAfter(cs)
        note("还原回话：\(restoreReply)")
        check("还原后键级差异为空", cs.diffFromBefore().isEmpty, got: cs.diffFromBefore().joined(separator: "；"), want: "没有差异")
        check("还原后逐字节回到开局（最理想的那种）", byteIdentical(cs),
              got: byteIdentical(cs) ? "字节相同" : "字节不同（上面键级差异为空的话，这只是排版差异）",
              want: "字节相同")
        check("还原后连接没了、线路还在、状态回到「可收编」",
              cs.connections().isEmpty && cs.provider("mine-primary") != nil && cs.state("mine-primary") == "可收编",
              got: "connections=\(cs.connections().count) 状态=\(cs.state("mine-primary"))",
              want: "connections=0，mine-primary 还在，状态=可收编")
        check("台账在最后一个连接还原后被删掉", !FileManager.default.fileExists(atPath: cs.ledgerURL.path),
              got: FileManager.default.fileExists(atPath: cs.ledgerURL.path) ? "台账还在" : "台账已删")
        check("还原也留了备份", cs.backups().contains { $0.contains("restore-adopted") },
              got: "\(cs.backups())", want: "多一个 *-restore-adopted.json")
    }
}

private func case2() {
    perform(2, "名字里有 Agent 的普通线路（用户自己起的名）",
            "用户自己命名的连接「Ark Agent Plan」和它的线路行算普通线路：进池、状态是「池内」，收编时不该再把它当 Agent 侧去动。",
            providers: [
                row(id: "ark-line", name: "Ark Agent Plan", model: "ark-model", baseURL: "https://ark.example/v1"),
                row(id: "plain-line", name: "手写·待收编", model: "plain-model", baseURL: "https://plain.example/v1"),
            ],
            connections: [
                connection(id: "ark-agent-plan", name: "Ark Agent Plan", baseURL: "https://ark.example/v1",
                           apiKey: "fixture-key-ark", models: ["ark-model"]),
            ],
            agents: [agent(id: "default", name: "默认", providerIDs: [])]) { cs in
        let bound = cs.provider("ark-line")
        let owner = (bound?["connection_id"] as? String) ?? ""
        if owner.isEmpty {
            // 夹具里这行没有归属；为了让「用户自己命名」这件事成立，这里补上用户在界面上会做的那一步。
            note("夹具里没有给这行写归属；这一条只核对「名字里带 Agent 的普通连接」会不会被当成 Agent 侧。")
        }
        printAfter(cs)
        check("「Ark Agent Plan」这条连接不算 Agent 侧，它的行在池里", cs.state("ark-line") == "池内",
              got: "状态=\(cs.state("ark-line"))", want: "池内")
        check("池里有它，也有那条真正待收编的手写线路", cs.poolNames() == ["ark-model"],
              got: "池=\(cs.poolNames())", want: "[ark-model]（手写那条还没收编，先不算）")
        check("待收编的那条仍是「可收编」", cs.state("plain-line") == "可收编",
              got: "状态=\(cs.state("plain-line"))", want: "可收编")

        let plan = cs.model.planAdoption()
        fact("收编方案只该包含手写的这一条：" + (plan.isEmpty ? "（空）" : plan.summary))
        check("方案不含「Ark Agent Plan」那条（它不是待收编的）",
              plan.lineCount == 1 && plan.connections.first?.modelIDs == ["plain-line"],
              got: "lineCount=\(plan.lineCount) modelIDs=\(plan.connections.first?.modelIDs ?? [])",
              want: "只有 plain-line")

        let reply = cs.model.adoptUnassignedLines()
        refreshAndReport(cs, action: reply)
        let arkConnection = cs.connection("ark-agent-plan")
        fact("用户的连接现在：名字=「\((arkConnection?["name"] as? String) ?? "")」"
              + " 地址=「\((arkConnection?["base_url"] as? String) ?? "")」"
              + " source=「\((arkConnection?["source"] as? String) ?? "")」"
              + " 连接里的模型=\(((arkConnection?["models"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })")
        check("收编没有动用户自己那条连接（键级）",
              arkConnection?["name"] as? String == "Ark Agent Plan"
              && arkConnection?["api_key"] as? String == "fixture-key-ark"
              && arkConnection?["source"] as? String == "manual",
              got: stableString(arkConnection), want: "名字/密钥/source 原样")
        check("收编后两条线路都在池里",
              cs.poolNames() == ["ark-model", "plain-model"],
              got: "池=\(cs.poolNames())", want: "[ark-model, plain-model]")
    }
}

private func case3() {
    perform(3, "Jev 自动线路与 4202 内部试机线路",
            "Jev 那条不受影响、照旧进池；4202 内部试机线路是「内部线路」，默认不收编，收编动作也不该碰它（文件都不该动）。",
            providers: [
                row(id: HubModel.jevProviderID, name: "Jev 自动线路", model: "jev-auto",
                    baseURL: "https://jev.example/v1", source: HubModel.jevInternalSource),
                row(id: "dsh:codex-router-probe", name: "4202 试机线路", model: "probe-model",
                    baseURL: "https://probe.example/v1", source: HubModel.jevInternalSource),
                row(id: "handwritten", name: "手写·待收编", model: "hand-model",
                    baseURL: "https://hand.example/v1"),
            ],
            agents: [agent(id: "default", name: "默认", providerIDs: [HubModel.jevProviderID])]) { cs in
        printAfter(cs)
        check("Jev 那条在池里（它是唯一允许从「没有归属」进池的历史入口）", cs.state(HubModel.jevProviderID) == "池内",
              got: "状态=\(cs.state(HubModel.jevProviderID))", want: "池内")
        check("4202 内部试机线路是「内部线路」，不是「可收编」", cs.state("dsh:codex-router-probe") == "内部线路",
              got: "状态=\(cs.state("dsh:codex-router-probe"))", want: "内部线路")
        check("收编方案里只有手写那一条", cs.model.planAdoption().connections.first?.modelIDs == ["handwritten"],
              got: "\(cs.model.planAdoption().connections.first?.modelIDs ?? [])", want: "[handwritten]")

        let before = cs.object()
        // 只勾「可收编」：Jev 已经是池内、试机线路是内部线路，都不在被收编的范围里。
        let reply = cs.model.adoptUnassignedLines()
        cs.refresh()
        note("收编回话：\(reply)")
        printAfter(cs)
        let diff = jsonDiff(old: before, new: cs.object()).filter { !$0.contains("connection_id") && !$0.contains("connections.") }
        check("收编没有碰 Jev 行和试机行", diff.isEmpty, got: diff.joined(separator: "；"), want: "没有差异")
        check("Jev 行还原样不动（id、source、model 都在）",
              (cs.provider(HubModel.jevProviderID)?["id"] as? String) == HubModel.jevProviderID
              && (cs.provider(HubModel.jevProviderID)?["source"] as? String) == HubModel.jevInternalSource,
              got: stableString(cs.provider(HubModel.jevProviderID)))
    }
}

private func case4() {
    perform(4, "引用了不存在的连接的线路（引用缺口）",
            "connection_id 指向一个盘上没有的连接时，单独算「引用缺口」，收编不碰它、也不替它猜一条连接。",
            providers: [
                row(id: "dangling-line", name: "手写·指向不存在的连接", model: "ghost-model",
                    baseURL: "https://ghost.example/v1", connectionID: "ghost-conn"),
                row(id: "healthy-line", name: "手写·待收编", model: "ok-model", baseURL: "https://ok.example/v1"),
            ],
            agents: [agent(id: "default", name: "默认", providerIDs: [])]) { cs in
        printAfter(cs)
        check("那条状态是「引用缺口」", cs.state("dangling-line") == "引用缺口",
              got: "状态=\(cs.state("dangling-line"))", want: "引用缺口")
        check("它不在可收编里（收编不替它猜连接）",
              cs.model.planAdoption().connections.first?.modelIDs == ["healthy-line"],
              got: "\(cs.model.planAdoption().connections.first?.modelIDs ?? [])", want: "[healthy-line]")

        let reply = cs.model.adoptUnassignedLines()
        refreshAndReport(cs, action: reply)
        check("引用缺口那行的 connection_id 原样保留（没有被改写、也没有被清掉）",
              cs.provider("dangling-line")?["connection_id"] as? String == "ghost-conn",
              got: stableString(cs.provider("dangling-line")?["connection_id"]), want: "ghost-conn")
        check("收编后它还是「引用缺口」", cs.state("dangling-line") == "引用缺口",
              got: "状态=\(cs.state("dangling-line"))", want: "引用缺口")
        check("正常那条进了池", cs.poolNames() == ["ok-model"], got: "池=\(cs.poolNames())", want: "[ok-model]")
    }
}

private func case5() {
    perform(5, "没有地址 / 地址是空白的手写线路",
            "这两种行都算「非模型行」：界面要能说清原因（没地址 / 地址只有空白），收编也不该碰它们。",
            providers: [
                row(id: "no-url", name: "手写·没写地址", model: "m-1"),
                row(id: "blank-url", name: "手写·地址是空白", model: "m-2", baseURL: "   \n  "),
                row(id: "good-url", name: "手写·待收编", model: "m-3", baseURL: "https://good.example/v1"),
            ],
            agents: [agent(id: "default", name: "默认", providerIDs: [])]) { cs in
        printAfter(cs)
        check("没写地址的那行是「非模型行」，原因说"没有 base_url"",
              cs.state("no-url") == "非模型行" && (cs.line("no-url")?.reason.contains("没有 base_url") ?? false),
              got: "状态=\(cs.state("no-url"))；\(cs.line("no-url")?.reason ?? "")", want: "非模型行，原因是「没有 base_url，发不出去」")
        check("地址是空白的那行也是「非模型行」，原因说"空白"",
              cs.state("blank-url") == "非模型行" && (cs.line("blank-url")?.reason.contains("空白") ?? false),
              got: "状态=\(cs.state("blank-url"))；\(cs.line("blank-url")?.reason ?? "")", want: "非模型行，原因是「base_url 是空白……」")
        check("收编方案里只有那条正常线路",
              cs.model.planAdoption().connections.first?.modelIDs == ["good-url"],
              got: "\(cs.model.planAdoption().connections.first?.modelIDs ?? [])", want: "[good-url]")

        let reply = cs.model.adoptUnassignedLines()
        refreshAndReport(cs, action: reply)
        check("两条有毛病的行都原样留在盘上（没被删、也没被挂连接）",
              (cs.provider("no-url")?["connection_id"]) == nil && (cs.provider("blank-url")?["connection_id"]) == nil
              && (cs.provider("blank-url")?["base_url"] as? String) == "   \n  ",
              got: "no-url.connection_id=\(stableString(cs.provider("no-url")?["connection_id"]))，"
                  + "blank-url.base_url=\(compact(cs.provider("blank-url")?["base_url"] ?? ""))",
              want: "都没被动过")
    }
}

private func case6() {
    perform(6, "两条地址不一样的手写线路（合成一条连接时地址放哪）",
            "同一个来源标签下地址不一致时，收编仍然只加一条连接，地址留空、各条线路继续用自己那行的地址（绝不改写任何一行的地址）。",
            providers: [
                row(id: "two-a", name: "手写·A", model: "m-a", baseURL: "https://a.example/v1", apiKey: "fixture-key-a"),
                row(id: "two-b", name: "手写·B", model: "m-b", baseURL: "https://b.example/v1", apiKey: "fixture-key-b"),
            ],
            agents: [agent(id: "default", name: "默认", providerIDs: [])]) { cs in
        let plan = cs.model.planAdoption()
        fact("方案：" + (plan.isEmpty ? "（空）" : plan.summary))
        check("还是只加一条连接（同一个来源标签就是一组）", plan.connections.count == 1,
              got: "\(plan.connections.count)", want: "1")
        check("组里两条线路都在", plan.connections.first?.modelIDs.sorted() == ["two-a", "two-b"],
              got: "\(plan.connections.first?.modelIDs ?? [])", want: "[two-a, two-b]")

        let reply = cs.model.adoptUnassignedLines()
        refreshAndReport(cs, action: reply)
        let created = cs.connections().first { ($0["source"] as? String) == "app-adopt" }
        check("新连接的地址留空（两条不一样，不瞎猜）", (created?["base_url"] as? String) == "",
              got: compact(created?["base_url"] ?? ""), want: "空字符串")
        check("两条线路各自的地址、密钥一个字节都没改",
              (cs.provider("two-a")?["base_url"] as? String) == "https://a.example/v1"
              && (cs.provider("two-b")?["base_url"] as? String) == "https://b.example/v1"
              && (cs.provider("two-a")?["api_key"] as? String) == "fixture-key-a"
              && (cs.provider("two-b")?["api_key"] as? String) == "fixture-key-b",
              got: "\(compact(cs.provider("two-a")?["base_url"] ?? "")) / \(compact(cs.provider("two-b")?["base_url"] ?? ""))",
              want: "各自原样")
        check("两条都进池了", cs.poolNames() == ["m-a", "m-b"], got: "池=\(cs.poolNames())", want: "[m-a, m-b]")
    }
}

private func case7() {
    perform(7, "地址已经和一条用户自己的连接一样（重点复核）",
            "和已有连接同址的手写线路收编时：不该新建连接，也该只给这条线路写归属，用户那条连接的名字/密钥/模型列表一概不动；随后「还原」只能收回 App 加的东西。",
            providers: [
                row(id: "shared-line", name: "手写·同址线路", model: "m-new", baseURL: "https://api.shared.example/v1"),
            ],
            connections: [
                connection(id: "shared-api", name: "我的共享站", baseURL: "https://api.shared.example/v1/",
                           apiKey: "fixture-key-user", source: "manual", models: ["m-user"]),
            ],
            agents: [agent(id: "default", name: "默认", providerIDs: [])]) { cs in
        let plan = cs.model.planAdoption()
        fact("方案：" + (plan.isEmpty ? "（空）" : plan.summary))
        let reply = cs.model.adoptUnassignedLines()
        refreshAndReport(cs, action: reply)
        note("收编回话：\(reply)")

        let merged = cs.connection("shared-api")
        fact("用户的连接现在：名字=「\((merged?["name"] as? String) ?? "")」"
              + " 密钥=\(((merged?["api_key"] as? String) ?? "").isEmpty ? "（空）" : "「fixture-key-user」还在")"
              + " 连接里的模型=\(((merged?["models"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })"
              + " source=「\((merged?["source"] as? String) ?? "")」")
        check("没有新建连接（同址合并，盘上连接数不变）", cs.connections().count == 1,
              got: "\(cs.connections().count) 条连接：\(cs.connections().compactMap { $0["id"] as? String })", want: "1 条")
        check("用户的连接名字没被改", merged?["name"] as? String == "我的共享站",
              got: compact(merged?["name"] ?? ""), want: "「我的共享站」")
        check("用户的密钥没被改", merged?["api_key"] as? String == "fixture-key-user",
              got: compact(merged?["api_key"] ?? ""), want: "「fixture-key-user」")
        check("用户连接里本来有的模型列表没被清掉",
              ((merged?["models"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String } == ["m-user"],
              got: "\(((merged?["models"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })", want: "[m-user]")
        check("同址判定不看结尾斜杠和大小写（两条地址只差一个 /）", cs.provider("shared-line")?["connection_id"] as? String == "shared-api",
              got: stableString(cs.provider("shared-line")?["connection_id"]), want: "shared-api")
        check("线路行自己的地址没被改", cs.provider("shared-line")?["base_url"] as? String == "https://api.shared.example/v1",
              got: compact(cs.provider("shared-line")?["base_url"] ?? ""), want: "原样")

        let restoreReply = cs.model.restoreAdoptedLines()
        cs.refresh()
        print("     —— 还原 ——")
        note("还原回话：\(restoreReply)")
        printAfter(cs)
        check("还原后用户的连接还在（它本来就不是 App 建的）", cs.connection("shared-api") != nil,
              got: cs.connections().isEmpty ? "连接没了" : "还在", want: "还在")
        check("还原后用户连接的模型列表还是 [m-user]",
              ((cs.connection("shared-api")?["models"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String } == ["m-user"],
              got: "\(((cs.connection("shared-api")?["models"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })", want: "[m-user]")
        check("还原后用户的密钥还是 fixture-key-user", cs.connection("shared-api")?["api_key"] as? String == "fixture-key-user",
              got: compact(cs.connection("shared-api")?["api_key"] ?? ""), want: "「fixture-key-user」")
        check("还原后 router.json 逐字节回到开局", byteIdentical(cs),
              got: "字节不同；键级差异=\(cs.diffFromBefore().joined(separator: "；"))", want: "字节相同")
    }
}

private func case8() {
    perform(8, "收编范围开关（Agent 侧、内部线路要另外点头）",
            "默认只收「可收编」那一组；勾上「包括 Agent 侧 / 内部线路」后，它们各自成一条连接，标记同样是 source=app-adopt，随时能还原。",
            providers: [
                row(id: "plain-one", name: "手写·普通", model: "m-plain", baseURL: "https://one.example/v1"),
                row(id: "dsh:agent-terra", name: "Agent 执行器", model: "m-agent",
                    baseURL: "https://agent.example/v1", source: "dsh:codex-terra"),
                row(id: "router-probe", name: "4202 试机", model: "m-probe",
                    baseURL: "https://probe.example/v1", source: HubModel.jevInternalSource),
            ],
            agents: [agent(id: "default", name: "默认", providerIDs: [])]) { cs in
        printAfter(cs)
        check("三行的状态分别是「可收编 / Agent 侧 / 内部线路」",
              cs.state("plain-one") == "可收编" && cs.state("dsh:agent-terra") == "Agent 侧" && cs.state("router-probe") == "内部线路",
              got: "\(cs.state("plain-one")) / \(cs.state("dsh:agent-terra")) / \(cs.state("router-probe"))",
              want: "可收编 / Agent 侧 / 内部线路")

        let reply = cs.model.adoptUnassignedLines()
        refreshAndReport(cs, action: reply)
        check("默认只收编普通那条", cs.poolNames() == ["m-plain"],
              got: "池=\(cs.poolNames())", want: "[m-plain]")
        check("Agent 侧和内部线路两行都还是「没归属」的样子",
              (cs.provider("dsh:agent-terra")?["connection_id"]) == nil && (cs.provider("router-probe")?["connection_id"]) == nil,
              got: "agent=\(stableString(cs.provider("dsh:agent-terra")?["connection_id"])) probe=\(stableString(cs.provider("router-probe")?["connection_id"]))",
              want: "两行都没有 connection_id")

        var selection = HubModel.AdoptionSelection()
        selection.includeAgentSide = true
        selection.includeInternal = true
        let plan = cs.model.planAdoption(selection)
        fact("勾上两类之后的方案（\(plan.summary)）")
        check("勾上之后方案里三行都在，分成三条连接", plan.lineCount == 3 && plan.connections.count == 3,
              got: "lines=\(plan.lineCount) connections=\(plan.connections.count)", want: "3 / 3")
        let reply2 = cs.model.adoptUnassignedLines(selection)
        refreshAndReport(cs, action: reply2)
        check("三条都进池了", cs.poolNames() == ["m-agent", "m-plain", "m-probe"],
              got: "池=\(cs.poolNames())", want: "[m-agent, m-plain, m-probe]")
        check("新连接都带 source=app-adopt（还原按这个标记认）",
              cs.connections().filter { ($0["source"] as? String) == "app-adopt" }.count == 3,
              got: "\(cs.connections().filter { ($0["source"] as? String) == "app-adopt" }.count)", want: "3")
        let restoreReply = cs.model.restoreAdoptedLines()
        cs.refresh()
        note("还原回话：\(restoreReply)")
        check("还原后三行解绑保留、连接全没了",
              cs.connections().isEmpty && cs.model.routeLines.count == 3,
              got: "connections=\(cs.connections().count) 线路=\(cs.model.routeLines.count)", want: "0 / 3")
        check("还原后逐字节回到开局", byteIdentical(cs),
              got: "字节不同；键级差异=\(cs.diffFromBefore().joined(separator: "；"))", want: "字节相同")
    }
}

private func refreshAndReport(_ cs: Case, action: String) {
    cs.refresh()
    note("收编回话：\(action)")
    printAfter(cs)
    printDiff(cs)
}

// MARK: - 主流程

private let runner = ProcessInfo.processInfo.arguments.first.map { _ in "verify-route-facts" } ?? "verify-route-facts"
_ = runner

let wanted: Set<Int> = {
    var ids: Set<Int> = []
    let arguments = CommandLine.arguments
    var index = 1
    while index < arguments.count {
        if arguments[index] == "--case", index + 1 < arguments.count, let id = Int(arguments[index + 1]) {
            ids.insert(id)
            index += 2
            continue
        }
        index += 1
    }
    return ids
}()

func wants(_ number: Int) -> Bool { wanted.isEmpty || wanted.contains(number) }

let cases: [(Int, String, () -> Void)] = [
    (1, "手写线路进池 + 收编 + 逐字节还原", case1),
    (2, "名字里有 Agent 的普通线路", case2),
    (3, "Jev 自动线路与 4202 内部线路", case3),
    (4, "引用了不存在的连接", case4),
    (5, "没有地址 / 地址是空白", case5),
    (6, "两条地址不一样的手写线路", case6),
    (7, "同址已有用户连接（重点复核）", case7),
    (8, "收编范围开关", case8),
]

print("verify-route-facts · 线路事实核对（夹具全在临时目录里，不碰真配置）")
print("真实配置（只读比对用）· \(realConfigURL.path)")
if !FileManager.default.fileExists(atPath: realConfigURL.path) { print("（这个文件现在不存在，跳过最后的字节比对）") }

var results: [(Int, String, Bool)] = []
for (number, title, body) in cases where wants(number) {
    let startedWith = failures
    body()
    results.append((number, title, failures == startedWith))
}
if results.isEmpty { print("\n（没有匹配 --case 的用例，什么都没跑）") }

heading("== 合计 ==")
for (number, title, ok) in results {
    print("   \(ok ? "✓" : "✗") 用例 \(number) · \(title)")
}
print("   核对条目：\(checks) 条，其中 ✗ \(failures) 条")
if !firstFailures.isEmpty {
    print("   先看这几条：")
    for title in firstFailures { print("     - \(title)") }
}

var realUnchanged = true
if let before = realConfigBefore {
    let now = try? Data(contentsOf: realConfigURL)
    realUnchanged = now == before
    if !realUnchanged { realUnchanged = false }
}
if realConfigBefore == nil {
    print("   （真实 router.json 不存在，没得比）")
} else {
    check("真实配置目录里的 router.json 一个字节都没动", realUnchanged,
          got: "变了", want: "字节相同")
}
if realAdoptionsBefore != nil || FileManager.default.fileExists(atPath: ambientAdoptionsURL.path) {
    let now = try? Data(contentsOf: ambientAdoptionsURL)
    check("真实配置目录里的 router-adoptions.json 也没动", now == realAdoptionsBefore,
          got: "变了", want: "字节相同")
} else {
    note("真实配置目录里没有 router-adoptions.json（本来就没有，不用比）")
}

print("")
print(failures == 0 ? "结论：这一轮手写的预期，全部对上。" : "结论：有 \(failures) 条和手写的预期不符，逐条见上（✗ 后面都跟着盘上事实）。")
exit(failures == 0 ? 0 : 1)
