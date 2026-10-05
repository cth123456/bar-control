//  verify-reentry-paths.swift
//  03-C 定向复现：第二次点「收编」必须一个字都不写。
//
//  立场：真目录只读。把真配置复制进 $TMPDIR 的沙箱，用 LOCAL_SIRI_ROUTER_CONFIG 指过去 →
//        收编写盘只会落在 sandbox 里的三件套：router.json / router-adoptions.json / router-backups
//        （后两者的位置都由 configURL 的父目录推出来：HubModel.swift:2745 / :3030）。
//        真目录的前后差异逐项比对，连 config-backups / backups / router-backups 三个子目录里的
//        文件清单也一起比（只看顶层文件哈希会漏掉子目录里的新文件）。
//
//  判据（每条都要印绝对路径 + mtime + sha256）：
//    ① 第一次点击：确实收编了（方案非空 → 允许写盘）
//    ② 第二次点击：config / router-adoptions.json / router-backups 三者的 mtime + sha 全不变
//    ③ 第二次点击的回执不许出现「已收编」（空方案一个字都不许说已收编）
//    ④ 换一个「全部范围」的第二次点击，同样一个字都不许写
//    ⑤ 收尾：真目录逐项与开工时相同
//
//  用法：
//    Tools/verify-reentry-paths.command              # 跑一遍
//    Tools/verify-reentry-paths.command --keep       # 留沙箱自己翻

import Foundation

private var sandboxRoot: URL?

// MARK: - 小工具

private func home() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
}

/// 真目录：LOCAL_SIRI_CONFIG_DIR 是给别的工具用的；真配置目录固定是支持目录。
private func realDirectory() -> URL {
    home().appendingPathComponent("Library/Application Support/LocalSiriLLM", isDirectory: true)
}

private func sha256(of data: Data) -> String {
    let file = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("reentry-sha-\(UUID().uuidString.prefix(8)).bin")
    guard (try? data.write(to: file)) != nil else { return "写入失败" }
    defer { try? FileManager.default.removeItem(at: file) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", file.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return "shasum 启动失败" }
    process.waitUntilExit()
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return text.split(separator: " ").first.map { String($0.prefix(12)) } ?? "解析失败"
}

/// 顶层文件名符合 drill 护栏口径（router* 或 *.json）的合并哈希：FNV-1a 64。
private func directoryFingerprint(_ dir: URL) -> String {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix("router") || $0.hasSuffix(".json") }
        .sorted()
    var hash: UInt64 = 0xcbf29ce484222325
    for name in names {
        let path = dir.appendingPathComponent(name).path
        guard let data = FileManager.default.contents(atPath: path) else { continue }
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    }
    return String(format: "%016llx", hash)
}

private func mtimeText(_ url: URL) -> String {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let date = attributes[.modificationDate] as? Date else { return "（无）" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
    return formatter.string(from: date)
}

/// 单个文件的「mtime + 大小 + sha」。
struct Stamp: Equatable {
    let label: String
    let url: URL
    let exists: Bool
    let bytes: Int
    let sha: String
    let mtime: String

    init(_ label: String, _ url: URL) {
        self.label = label
        self.url = url
        let data = FileManager.default.contents(atPath: url.path)
        exists = data != nil
        bytes = data?.count ?? 0
        sha = data.map(sha256(of:)) ?? "—"
        mtime = data == nil ? "—" : mtimeText(url)
    }

    var text: String {
        exists
            ? "\(bytes) 字节 · sha256 \(sha) · mtime \(mtime)"
            : "不存在（本来就没有）"
    }
}

/// 一个目录：自身 mtime + 里面每个文件的名字 / mtime / sha（排序后逐行）。
private func directoryListing(_ url: URL) -> (mtime: String, files: [Stamp], combined: String) {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return ("不存在", [], "不存在")
    }
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    let stamps = names.map { Stamp($0, url.appendingPathComponent($0)) }
    let combined = stamps.map { "\($0.label) \($0.bytes) \($0.sha) \($0.mtime)" }.joined(separator: " ｜ ")
    return (mtimeText(url), stamps, combined.isEmpty ? "（空目录）" : combined)
}

/// 收编三件套：配置文件 / 台账 / 备份目录（都在 configURL 的父目录下）。
private struct Trio {
    let config: Stamp
    let ledger: Stamp
    let backups: (mtime: String, files: [Stamp], combined: String)

    init(_ dir: URL) {
        config = Stamp("router.json", dir.appendingPathComponent("router.json"))
        ledger = Stamp("router-adoptions.json", dir.appendingPathComponent("router-adoptions.json"))
        backups = directoryListing(dir.appendingPathComponent("router-backups", isDirectory: true))
    }

    /// 三件套是否一字未动（mtime 与 sha 都要相同）。
    func unchanged(comparedTo other: Trio) -> Bool {
        config == other.config
            && ledger == other.ledger
            && backups.mtime == other.backups.mtime
            && backups.combined == other.backups.combined
    }

    func report(_ title: String) {
        print("  \(title)")
        print("    config            \(config.url.path)")
        print("      \(config.text)")
        print("    ledger            \(ledger.url.path)")
        print("      \(ledger.text)")
        print("    backups 目录      \(config.url.deletingLastPathComponent().appendingPathComponent("router-backups").path)")
        print("      dir mtime \(backups.mtime) · \(backups.files.count) 个文件")
        if backups.files.isEmpty {
            print("      （空）")
        } else {
            for file in backups.files {
                print("      · \(file.label)  \(file.bytes) 字节 · sha256 \(file.sha) · mtime \(file.mtime)")
            }
        }
    }
}

/// 真目录全貌：顶层指纹 + 三件套 + 两个「App 支持目录里其它会写盘的地方」。
private struct RealSnapshot {
    let fingerprint: String
    let topLevelCount: Int
    let trio: Trio
    let configBackups: (mtime: String, files: [Stamp], combined: String)
    let backups: (mtime: String, files: [Stamp], combined: String)

    init(_ dir: URL) {
        fingerprint = directoryFingerprint(dir)
        topLevelCount = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).count
        trio = Trio(dir)
        configBackups = directoryListing(dir.appendingPathComponent("config-backups", isDirectory: true))
        backups = directoryListing(dir.appendingPathComponent("backups", isDirectory: true))
    }

    func equal(to other: RealSnapshot) -> Bool {
        fingerprint == other.fingerprint && topLevelCount == other.topLevelCount
            && trio.unchanged(comparedTo: other.trio)
            && configBackups.combined == other.configBackups.combined
            && backups.combined == other.backups.combined
    }

    func report(_ title: String) {
        print("  \(title)")
        trio.report("收编三件套")
        print("    config-backups/   dir mtime \(configBackups.mtime) · \(configBackups.files.count) 个文件（最新：\(configBackups.files.last?.label ?? "无")）")
        print("    backups/          dir mtime \(backups.mtime) · \(backups.files.count) 个文件（最新：\(backups.files.last?.label ?? "无")）")
        print("    顶层指纹          \(fingerprint) · \(topLevelCount) 个文件")
    }
}

// MARK: - 沙箱

private func makeSandbox(seed: URL) throws -> URL {
    let name = "verify-reentry-\(UUID().uuidString.prefix(8))"
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for file in ["router.json", "router-stats.json", "router-health.json",
                 "clients.json", "router-adoptions.json"] {
        let from = seed.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: from.path) else { continue }
        try FileManager.default.copyItem(at: from, to: dir.appendingPathComponent(file))
    }
    guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("router.json").path) else {
        throw NSError(domain: "verify-reentry", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "真配置目录里没有 router.json：\(seed.path)"])
    }
    sandboxRoot = dir
    setenv("LOCAL_SIRI_ROUTER_CONFIG", dir.appendingPathComponent("router.json").path, 1)
    setenv("LOCAL_SIRI_ROUTER_STATS", dir.appendingPathComponent("router-stats.json").path, 1)
    setenv("LOCAL_SIRI_ROUTER_HEALTH", dir.appendingPathComponent("router-health.json").path, 1)
    return dir
}

private func writeJSON(_ object: [String: Any], to url: URL) {
    // 护栏：本工具的一切写盘只允许落在本次沙箱里。
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

private func freshModel() -> HubModel {
    let model = HubModel()
    model.refresh()
    return model
}

// MARK: - 夹具

private func rows(_ object: [String: Any], _ key: String) -> [[String: Any]] {
    (object[key] as? [[String: Any]]) ?? []
}

/// 夹具里本来没有「等收编」的行时，往沙箱副本里合成一条未归属线路（只动副本）。
/// 复制一条已有线路并摘掉 connection_id：地址与已有连接相同 → 走「借已有连接」那条路。
@discardableResult
private func injectUnassignedLine(into sandbox: URL) -> String? {
    let url = sandbox.appendingPathComponent("router.json")
    guard let data = FileManager.default.contents(atPath: url.path),
          var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    var providers = rows(object, "providers")
    guard let donor = providers.first(where: {
        ($0["connection_id"] as? String)?.isEmpty == false
    }) else { return nil }
    var clone = donor
    clone["id"] = "reentry-repro-line"
    clone["connection_id"] = nil
    if let name = clone["name"] as? String { clone["name"] = name + "（复现合成行）" }
    providers.append(clone)
    object["providers"] = providers
    writeJSON(object, to: url)
    return "\(clone["id"] as? String ?? "?")（复制自 \(donor["id"] as? String ?? "?")，地址与它相同）"
}

/// 合成一条「看着待归属、其实一条都写不出去」的行：摘掉 connection_id、地址留空。
/// 这类行按口径 `isAdoptable`（模型名 + 地址都得在）本来就不该进方案；万一哪天有人把
/// 「待归属」简化成「connection_id 为空」，这一行就会被拿去建一条**没有地址的连接**并写盘——
/// 这一步就是给那种写法留的哨兵。
@discardableResult
private func injectPendingLookingLine(into sandbox: URL) -> String? {
    let url = sandbox.appendingPathComponent("router.json")
    guard let data = FileManager.default.contents(atPath: url.path),
          var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    var providers = rows(object, "providers")
    guard let donor = providers.first else { return nil }
    var clone = donor
    clone["id"] = "reentry-empty-address-line"
    clone["connection_id"] = nil
    clone["base_url"] = ""
    if let name = clone["name"] as? String { clone["name"] = name + "（复现合成行·无地址）" }
    providers.append(clone)
    object["providers"] = providers
    writeJSON(object, to: url)
    return "\(clone["id"] as? String ?? "?")（未归属 + 地址留空：照口径就不可收编）"
}

// MARK: - 跑

private var keep = false
if CommandLine.arguments.contains("--keep") { keep = true }

let real = realDirectory()
private let realBefore = RealSnapshot(real)

print("verify-reentry-paths · 03-C 定向复现（第二次点「收编」不许写盘）")
print("  真目录    \(real.path)")
print("  沙箱      \(NSTemporaryDirectory())verify-reentry-*（默认跑完删掉，--keep 保留）")
print("")
print("【0】开工时：真目录账目（只读）")
realBefore.report("真目录")
print("")

private var failures: [String] = []

do {
    let sandbox = try makeSandbox(seed: real)
    defer { if !keep { try? FileManager.default.removeItem(at: sandbox) } }

    print("【1】沙箱副本")
    print("  沙箱目录  \(sandbox.path)")
    print("  router.json（副本）\(Stamp("", sandbox.appendingPathComponent("router.json")).text)")
    print("")

    var model = freshModel()
    var plan = model.planAdoption()
    var pending = model.adoptableLines.filter(\.awaitsAdoption).count
    if plan.isEmpty {
        let injected = injectUnassignedLine(into: sandbox)
        print("【2】夹具里没有「等收编」的行 → 只往沙箱副本合成一条未归属线路：\(injected ?? "合成失败")")
        model = freshModel()
        plan = model.planAdoption()
        pending = model.adoptableLines.filter(\.awaitsAdoption).count
    } else {
        print("【2】夹具（真实数据）里本来就有等收编的行")
    }
    print("  方案：\(plan.connections.count) 组连接 · \(plan.lineCount) 条线路 · 待归属 \(pending) 条")
    print("")

    func drive(_ title: String, _ model: HubModel, _ selection: HubModel.AdoptionSelection) {
        print("【\(title)】")
        let before = Trio(sandbox)
        let message = model.adoptUnassignedLines(selection)
        let after = Trio(sandbox)
        let same = after.unchanged(comparedTo: before)
        print("  回执：\(message)")
        after.report("点击后沙箱三件套")
        print("  对照（点击前）：")
        print("    config  \(before.config.text)")
        print("    ledger  \(before.ledger.text)")
        print("    backups dir mtime \(before.backups.mtime) · \(before.backups.files.count) 个文件")
        if same {
            print("  ✅ 三件套 mtime + sha 全不变")
        } else {
            print("  ❌ 三件套被动过")
            failures.append("\(title)：三件套被动过")
        }
        if message.contains("已收编") && same {
            print("  ❌ 回执说了「已收编」，但盘上一个字节都没写")
            failures.append("\(title)：空回执说「已收编」")
        }
        print("")
    }

    // ② 第一次点击：允许写盘，这时方案非空。
    print("【3】第一次点击（默认范围）：应当收编并写盘")
    let firstBefore = Trio(sandbox)
    let firstMessage = model.adoptUnassignedLines()
    let firstAfter = Trio(sandbox)
    print("  回执：\(firstMessage)")
    firstAfter.report("点击后沙箱三件套")
    if firstAfter.unchanged(comparedTo: firstBefore) {
        print("  ⚠️ 第一次点击没写盘（方案非空却不写 = 收编没生效，后面的「第二次」就不算数）")
        failures.append("第一次点击没有生效")
    } else {
        print("  ✅ 第一次点击确实动过盘（收编生效），下面看第二次")
    }
    print("")

    // ④ 第二次点击：必须一个字都不写。
    drive("4a 第二次点击（默认范围，同一个模型实例）", model, HubModel.AdoptionSelection())

    drive("4b 第二次点击（默认范围，重新从盘上读的新实例）", freshModel(), HubModel.AdoptionSelection())


    // ④ 全部范围的第二次点击：同样一个字都不许写。
    var allScope = HubModel.AdoptionSelection()
    allScope.includeAgentSide = true
    allScope.includeInternal = true
    let model5 = freshModel()
    let plan5 = model5.planAdoption(allScope)
    print("【5】全部范围的第二次点击：方案 \(plan5.connections.count) 组 · \(plan5.lineCount) 条线路")
    if plan5.isEmpty {
        drive("5 第二次点击（全部范围）", model5, allScope)
    } else {
        // 方案非空 → 允许写一次；写完之后再点，才是不许写的那一次。
        _ = model5.adoptUnassignedLines(allScope)
        drive("5 第二次点击（全部范围，写完之后再点）", model5, allScope)
    }

    print("【5b 再点一次（盘上多出一条「未归属 + 没地址」的行）】")
    if let note = injectPendingLookingLine(into: sandbox) {
        let model = freshModel()
        let plan = model.planAdoption(allScope)
        let pending = model.adoptableLines.filter(\.awaitsAdoption).count
        print("  夹具：\(note)")
        print("  方案：\(plan.connections.count) 组连接 · \(plan.lineCount) 条线路 · 待归属 \(pending) 条\(plan.isEmpty ? "（空方案：这类行按口径不可收编）" : "")")
        drive("5b 再点一次（有未归属行，但一条也写不出去）", model, allScope)
    } else {
        print("  ⚠️ 夹具没造出来，这一步跳过")
    }

    print("【6】收工：真目录账目（只读）")
    let realAfter = RealSnapshot(real)
    realAfter.report("真目录")
    if realAfter.equal(to: realBefore) {
        print("  ✅ 真目录逐项与开工时相同（含 config-backups / backups / router-backups 子目录清单）")
        print("     指纹 \(realBefore.fingerprint) → \(realAfter.fingerprint) · 顶层 \(realBefore.topLevelCount) → \(realAfter.topLevelCount) 个文件")
    } else {
        print("  ❌ 真目录被动了：指纹 \(realBefore.fingerprint) → \(realAfter.fingerprint) · 顶层 \(realBefore.topLevelCount) → \(realAfter.topLevelCount)")
        failures.append("真目录被动了")
    }
    print("")
} catch {
    failures.append("用例执行失败：\(error.localizedDescription)")
    print("❌ 用例执行失败：\(error.localizedDescription)")
}

print("—— 结论 ——")
if failures.isEmpty {
    print("✅ 全部通过：第二次点「收编」不动 config / router-adoptions.json / router-backups 的 mtime+sha，回执也不说「已收编」，真目录逐项未变。")
    exit(0)
} else {
    for failure in failures { print("❌ \(failure)") }
    exit(1)
}
