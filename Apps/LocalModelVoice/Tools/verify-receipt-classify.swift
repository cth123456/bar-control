//  verify-receipt-classify.swift
//  「拦截页不再判死」这一处改动的证据表：旧红在哪几条上变绿、有没有哪条真红被悄悄放行。
//
//  只读：本工具不写任何配置，也不碰网络。唯一的读取面是网关自己写的 router-stats.json
//        （解析走 App 里同一个 `HubLineReceipt.parse`，不是重写一份判据）。
//
//  背景（改动的一句话）：401 / 403 有两种长相 —— 服务方说「钥匙不对」（干净的 JSON 体），
//  和中间的盾 / 网关直接甩过来一张拦截页（HTML、challenge、captcha…）。后者跟 Key 没关系，
//  判死等于把一条好线路永久拉黑。改动后 `HubLineReceipt.classify(code:raw:)` 把这一种单独归为
//  `.gatewayBlocked`（会自己好，不排除出自动挑选）。
//
//  判据（每条都要能一眼看出「旧什么样、新什么样、谁改的、凭什么」）：
//    ① 等价性：除 401 / 403 外的所有码（400 / 402 / 404 / 422 / 429 / 5xx / 无码），
//       新判据逐条等于「只看 HTTP 码」的判据 —— 这次改动没有顺手碰别的码。
//       （源码自证：`looksLikeGatewayBlock` 只在 401 / 403 分支被调用。）
//    ② 翻转清单：旧红 → 新绿的样本逐条印出来，每条必须命中拦截页特征词，
//       并印出命中的是「硬特征」（HTML / challenge / captcha / cf-ray…）还是「软特征」
//       （access denied / 拦截 / 防护…）—— 软特征同样会放行，这是留给你的收紧开关。
//    ③ 不新增黑名单：不存在「旧绿 → 新红」的样本；本次改动不会让任何一条线更容易被判死。
//    ④ 真钥匙被拒仍判死：干净 JSON 的 401 / 403（不带拦截页特征）两边都红。
//    ⑤ 每条类别的 nextStep 都是人话（非空、不是「连接失败」这类猜出来的话），
//       9 个类别的 shortReason / nextStep 全表印出。
//    ⑥ 真实盘面扫描：router-stats.json 里每一条有 last_error 的线路，逐条算旧 / 新，
//       断言「旧红的每一条，要么新仍红，要么原文逐字命中拦截页特征」；命中的把特征词印出来。
//       （文件不存在 = 没有真实回执可扫，如实印出，不假装扫过。）
//
//  用法：
//    Tools/verify-receipt-classify.command              # 跑一遍
//    Tools/verify-receipt-classify.command --json       # 额外把结论打成一行 JSON

import Foundation

private var failures: [String] = []
private func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "✅" : "❌") \(what)")
    if !ok { failures.append(what) }
}

// MARK: - 旧判据：只看 HTTP 码

/// 改动前 classify 的信息源只有 HTTP 码本身。这里把那份映射如实复刻出来，
/// 用来给每个样本算「旧的结论」。401 / 403 一律「密钥被拒」（判死）——这正是被修掉的那一条。
private func codeOnlyKind(_ code: Int?) -> HubLineReceipt.Kind {
    switch code {
    case .some(401), .some(403): return .keyRejected
    case .some(402): return .quotaExhausted
    case .some(404): return .missingModel
    case .some(429): return .throttled
    case .some(400), .some(422): return .badRequest
    case .some(let value) where (500...599).contains(value): return .serverSide
    case .none: return .transport
    case .some: return .unknown
    }
}

/// 新旧共用同一套排除公式（额度类只看当天，这一条不是本次改动）。
private func excluded(_ kind: HubLineReceipt.Kind, isToday: Bool) -> Bool {
    kind.isPermanent || (kind == .quotaExhausted && isToday)
}

// MARK: - 硬 / 软特征词

/// 硬特征：一张页面 / 一道挑战才有的东西，干净的 JSON 体里基本不会出现。
private let hardMarkers = ["<!doctype html", "<html", "</html>", "<head", "cloudflare", "cf-ray",
                           "captcha", "challenge", "just a moment", "attention required", "人机验证"]
/// 软特征：通用短语，服务方自己的 JSON 里也可能正好这么写。
private let softMarkers = ["access denied", "request blocked", "web application firewall", "拦截", "防护"]

private func hitMarkers(_ raw: String) -> (hard: [String], soft: [String]) {
    let text = raw.lowercased()
    return (hardMarkers.filter { text.contains($0) }, softMarkers.filter { text.contains($0) })
}

// MARK: - 语料

struct Sample {
    let name: String
    let raw: String
    /// last_attempt_at；402 两条用 now 相对生成，好让「只看当天」这条规则可复现。
    let at: (Date) -> String
    /// 这条样本是干什么用的。
    let why: String
}

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private let cloudflarePage = """
HTTP 403: <!DOCTYPE html><html><head><title>Just a moment...</title></head><body>\
<div class="cf-challenge">Verifying you are human. Enable JavaScript and cookies to continue.</div>\
</body></html>
"""

private let cfRayPage = """
HTTP 401: <html><head><title>Access denied</title></head><body>Attention Required! | Cloudflare\
<br>Ray ID: 8f2c1a4b6c7d8e9f • cf-ray</body></html>
"""

private let chineseShieldPage = """
HTTP 403: <html><body><h1>人机验证</h1><p>请求被拦截，请完成验证后重试。</p></body></html>
"""

private let cleanJSON401 = #"HTTP 401: {"error":{"message":"invalid api key","type":"invalid_request_error"}}"#
private let cleanJSON403 = #"HTTP 403: {"error":{"message":"you do not have permission to use model deepseek-v4.1"}}"#
/// 边界样本：干净 JSON，但服务方的话里正好写着 access denied（软特征）。
private let cleanJSONAccessDenied = #"HTTP 403: {"message":"access denied"}"#
/// 边界样本：干净 JSON，但话里写着「拦截」（软特征）。
private let cleanJSONChineseBlock = #"HTTP 403: {"message":"该请求已被拦截：账号未实名"}"#

// 下面两条不是编的：逐字抄自本机 router-stats.json 里 `dead` 和 `dsh` 两条线路的 last_error。
// 「某台机器连不上」这一类，界面要说得清是哪台、为什么、下一步怎么办。
private let refusedRaw = "网络错误：[Errno 61] Connection refused"
private let dshTimeoutRaw = "DSH 桥超时（请确认 DSH 客户端正在运行）"

let samples: [Sample] = [
    Sample(name: "干净 401 JSON·钥匙被拒", raw: cleanJSON401, at: { iso($0.addingTimeInterval(-3600)) },
           why: "真的钥匙不对：必须两边都判死，不许因为改动放行"),
    Sample(name: "干净 403 JSON·真没权限", raw: cleanJSON403, at: { iso($0.addingTimeInterval(-3600)) },
           why: "服务方自己的 JSON：必须两边都判死"),
    Sample(name: "Cloudflare 拦截页 403", raw: cloudflarePage, at: { iso($0.addingTimeInterval(-1800)) },
           why: "被修掉的那一条：旧判死 → 新放行（硬特征）"),
    Sample(name: "Cloudflare 拦截页 401（cf-ray）", raw: cfRayPage, at: { iso($0.addingTimeInterval(-1800)) },
           why: "401 长着拦截页的样子：不许当成钥匙被拒（硬特征）"),
    Sample(name: "中文盾拦截页 403", raw: chineseShieldPage, at: { iso($0.addingTimeInterval(-1800)) },
           why: "人机验证 / 拦截页：旧判死 → 新放行（硬特征）"),
    Sample(name: "边界·干净 JSON 里写着 access denied", raw: cleanJSONAccessDenied, at: { iso($0.addingTimeInterval(-1800)) },
           why: "软特征也会放行 —— 代价与收益如实摆出来，收紧开关在这里"),
    Sample(name: "边界·干净 JSON 里写着「拦截」", raw: cleanJSONChineseBlock, at: { iso($0.addingTimeInterval(-1800)) },
           why: "同上，中文软特征"),
    Sample(name: "402 额度用尽·今天的回执", raw: #"HTTP 402: {"message":"今日额度已耗尽，明日恢复"}"#,
           at: { iso($0.addingTimeInterval(-600)) }, why: "额度类只看当天：今天的不放行"),
    Sample(name: "402 额度用尽·九天前的回执", raw: #"HTTP 402: {"message":"今日额度已耗尽，明日恢复"}"#,
           at: { iso($0.addingTimeInterval(-9 * 86_400)) }, why: "九天前的「今日额度」说的是九天前那天：两边都放行"),
    Sample(name: "404 模型不存在", raw: #"HTTP 404: {"message":"model not found"}"#,
           at: { iso($0.addingTimeInterval(-7200)) }, why: "重试也不会变：两边都判死"),
    Sample(name: "400 请求被拒", raw: #"HTTP 400: {"message":"invalid request: unsupported parameter temperature"}"#,
           at: { iso($0.addingTimeInterval(-7200)) }, why: "会自己好（换个请求就好）：两边都放行"),
    Sample(name: "429 被限流", raw: #"HTTP 429: {"message":"rate limit reached"}"#,
           at: { iso($0.addingTimeInterval(-300)) }, why: "过一会儿能再试：两边都放行"),
    Sample(name: "503 服务方出错", raw: #"HTTP 503: {"message":"upstream connect error"}"#,
           at: { iso($0.addingTimeInterval(-300)) }, why: "稍后重试：两边都放行"),
    Sample(name: "无 HTTP 码·连不上", raw: "error sending request for url (https://ark.cn-beijing.volces.com/api/v3): connection refused",
           at: { iso($0.addingTimeInterval(-120)) }, why: "网络 / 本地服务没跑：两边都放行"),
    Sample(name: "本机真实回执·dead 线路连不上", raw: refusedRaw,
           at: { iso($0.addingTimeInterval(-120)) }, why: "连不上时也得看见「哪台、为什么、怎么办」；这句话是本机记的，不能挂在服务方名下"),
    Sample(name: "本机真实回执·dsh 桥超时", raw: dshTimeoutRaw,
           at: { iso($0.addingTimeInterval(-120)) }, why: "同上：本机的话照实署名，操作提示要留在脸上"),
]

// MARK: - 一句一字都不编的收尾

private func sha256Prefix(_ path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path) else { return "读不到" }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("receipt-classify-\(UUID().uuidString.prefix(8)).bin")
    guard (try? data.write(to: tmp)) != nil else { return "写入失败" }
    defer { try? FileManager.default.removeItem(at: tmp) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", tmp.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return "shasum 启动失败" }
    process.waitUntilExit()
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return text.split(separator: " ").first.map { String($0.prefix(12)) } ?? "解析失败"
}

private func mtimeText(_ path: String) -> String {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    guard let date = attributes?[.modificationDate] as? Date else { return "时间未知" }
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm:ss"
    return formatter.string(from: date)
}

// MARK: - 真实盘面

private func statsURL() -> URL {
    if let override = ProcessInfo.processInfo.environment["LOCAL_SIRI_ROUTER_CONFIG"], !override.isEmpty {
        return URL(fileURLWithPath: override).deletingLastPathComponent()
            .appendingPathComponent("router-stats.json")
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalSiriLLM", isDirectory: true)
        .appendingPathComponent("router-stats.json")
}

// MARK: - 主流程

private let now = Date()

print("== 回执判据证据表：401 / 403 拦截页不再判死 ==")
print("现在：\(ISO8601DateFormatter().string(from: now))")
for relative in ["Sources/RouterManager.swift", "Sources/HubPages.swift", "Sources/HubReceiptViews.swift"] {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(relative).path
    let exists = FileManager.default.fileExists(atPath: path)
    print("源码 \(path) · \(exists ? "mtime \(mtimeText(path)) · sha256:\(sha256Prefix(path))" : "不存在")")
}
print("")

// ── ① 9 个类别的人话全表
print("-- ① 类别全表（shortReason / 会不会自己好 / 下一步） --")
let allKinds: [HubLineReceipt.Kind] = [.keyRejected, .gatewayBlocked, .missingModel, .quotaExhausted,
                                       .throttled, .badRequest, .serverSide, .transport, .unknown]
for kind in allKinds {
    let reason = kind.shortReason
    let step = kind.nextStep
    let ok = !reason.isEmpty && !step.isEmpty && !step.contains("连接失败")
    print("\(ok ? "✅" : "❌") \(kind.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0)) · \(reason) · \(kind.isPermanent ? "不会自己好（判死）" : "会自己好（不排除）") · 下一步：\(step)")
    if !ok { failures.append("类别 \(kind.rawValue) 的人话不完整") }
}
print("")

// ── ② 语料逐条：旧 / 新 / 差集
print("-- ② 语料逐条：旧判据（只看 HTTP 码） vs 新判据（HubLineReceipt.parse） --")
var freed: [Sample] = []
var tightened: [Sample] = []
var softOnlyFreed: [Sample] = []
for sample in samples {
    let atText = sample.at(now)
    let code = HubLineReceipt.httpStatus(in: sample.raw)
    let entry: [String: Any] = ["last_error": sample.raw, "last_attempt_at": atText,
                                "attempts": 3, "successes": 0, "failures": 3]
    guard let receipt = HubLineReceipt.parse(providerID: sample.name, entry: entry, now: now) else {
        failures.append("样本 \(sample.name) 解析不出回执")
        print("❌ \(sample.name)：解析不出回执")
        continue
    }
    let oldKind = codeOnlyKind(code)
    let isToday = receipt.isFromToday
    let oldExcluded = excluded(oldKind, isToday: isToday)
    let newExcluded = receipt.excludesFromAutoPick
    let marks = hitMarkers(sample.raw)
    let flip = oldExcluded != newExcluded
        ? (oldExcluded ? "旧红 → 新绿（放行）" : "旧绿 → 新红（判死）")
        : "两边一致（\(oldExcluded ? "红" : "绿")）"
    print("· \(sample.name)：\(flip)")
    print("    为什么摆这条：\(sample.why)")
    print("    旧：\(oldKind.rawValue)\(oldExcluded ? " · 排除" : " · 不排除")  →  新：\(receipt.kind.rawValue)\(newExcluded ? " · 排除" : " · 不排除")")
    print("    \(receipt.messageAttribution)：\(receipt.providerMessage.isEmpty ? "（没有）" : receipt.providerMessage)")
    print("    界面这一行：\(receipt.receiptLine)")
    print("    给人看的补充：\(receipt.exclusionNote)")
    if let basis = receipt.evidenceNote {
        print("    \(basis)")   // 字符串自带「判定依据：」前缀，界面这一行就是它
    }
    if !marks.hard.isEmpty || !marks.soft.isEmpty {
        print("    拦截页特征：硬 \(marks.hard.isEmpty ? "无" : marks.hard.joined(separator: "、")) · 软 \(marks.soft.isEmpty ? "无" : marks.soft.joined(separator: "、"))")
    }
    if code == 401 || code == 403 {
        let expectedGateway = HubLineReceipt.looksLikeGatewayBlock(sample.raw)
        check(receipt.kind == (expectedGateway ? .gatewayBlocked : .keyRejected),
              "样本「\(sample.name)」的类别按特征表推得 \(expectedGateway ? "gatewayBlocked" : "keyRejected")，实际 \(receipt.kind.rawValue)")
    }
    if oldExcluded && !newExcluded {
        freed.append(sample)
        if marks.hard.isEmpty && !marks.soft.isEmpty { softOnlyFreed.append(sample) }
    }
    if !oldExcluded && newExcluded { tightened.append(sample) }
}
print("")

// ── ③ 断言
print("-- ③ 断言 --")
check(tightened.isEmpty, "不新增黑名单：没有「旧绿 → 新红」的样本（收紧只会来自别的改动，不会来自这一处）")
let freedAllAre401403 = freed.allSatisfy { ["401", "403"].contains(HubLineReceipt.httpStatus(in: $0.raw).map(String.init) ?? "") }
check(freedAllAre401403, "放行只发生在 401 / 403 上（共 \(freed.count) 条放行：\(freed.map(\.name).joined(separator: "、"))）")
let freedAllHitMarkers = freed.allSatisfy { !(hitMarkers($0.raw).hard.isEmpty && hitMarkers($0.raw).soft.isEmpty) }
check(freedAllHitMarkers, "每条放行都逐字命中拦截页特征词（没有靠「猜」放行的）")
let cleanOnesStillRed = samples.filter { ["401", "403"].contains(HubLineReceipt.httpStatus(in: $0.raw).map(String.init) ?? "") }
    .filter { hitMarkers($0.raw).hard.isEmpty && hitMarkers($0.raw).soft.isEmpty }
let cleanStillExcluded = cleanOnesStillRed.allSatisfy { sample in
    let entry: [String: Any] = ["last_error": sample.raw, "last_attempt_at": sample.at(now),
                                "attempts": 3, "successes": 0, "failures": 3]
    return HubLineReceipt.parse(providerID: sample.name, entry: entry, now: now)?.excludesFromAutoPick == true
}
check(cleanStillExcluded, "真钥匙被拒 / 真没权限（干净 JSON 的 401 / 403）仍然判死：\(cleanOnesStillRed.map(\.name).joined(separator: "、"))")
let otherCodesUnchanged = samples.filter { code in
    guard let codeNumber = HubLineReceipt.httpStatus(in: code.raw) else { return true }
    return !(codeNumber == 401 || codeNumber == 403)
}.allSatisfy { sample in
    let entry: [String: Any] = ["last_error": sample.raw, "last_attempt_at": sample.at(now),
                                "attempts": 3, "successes": 0, "failures": 3]
    guard let receipt = HubLineReceipt.parse(providerID: sample.name, entry: entry, now: now) else { return false }
    return receipt.kind == codeOnlyKind(HubLineReceipt.httpStatus(in: sample.raw))
}
check(otherCodesUnchanged, "除 401 / 403 外的码一条没变：新判据逐条等于「只看 HTTP 码」")
print("")

// ── ④ 明细要能自证，口吻要跟着依据走：只有真拦截页才配用「换网络就能解决」这句
print("-- ④ 明细自证与口吻（「被网关挡下」这一类） --")
let tableAgrees = samples.allSatisfy { sample in
    let app = HubLineReceipt.gatewayBlockEvidence(in: sample.raw)
    let mine = hitMarkers(sample.raw)
    return app.hard == mine.hard && app.soft == mine.soft
}
check(tableAgrees, "工具里的硬 / 软特征表与 App 里 `gatewayBlockEvidence` 逐条一致（不是两套判据各说各话）")
let gatewayReceipts = samples.compactMap { sample -> HubLineReceipt? in
    let entry: [String: Any] = ["last_error": sample.raw, "last_attempt_at": sample.at(now),
                                "attempts": 3, "successes": 0, "failures": 3]
    guard let receipt = HubLineReceipt.parse(providerID: sample.name, entry: entry, now: now),
          receipt.kind == .gatewayBlocked else { return nil }
    return receipt
}
check(gatewayReceipts.count == freed.count,
      "每一条放行都归到了「被网关挡下」（放行 \(freed.count) 条 / 该类 \(gatewayReceipts.count) 条），明细里有地方写依据")
let allGatewaysShowBasis = gatewayReceipts.allSatisfy { ($0.evidenceNote ?? "").contains("判定依据") }
check(allGatewaysShowBasis, "每一条「被网关挡下」的明细都写出了判定依据（是拦截页 / 只有一句通用短语）")
let softToneOnes = gatewayReceipts.filter {
    hitMarkers($0.rawText).hard.isEmpty && !hitMarkers($0.rawText).soft.isEmpty
}
let softToneHonest = softToneOnes.allSatisfy { receipt in
    !receipt.exclusionNote.contains("换网络") && receipt.exclusionNote.contains("不能确定")
        && (receipt.evidenceNote ?? "").contains("看不出是不是网关挡的")
}
check(softToneHonest, "只命中软特征的 \(softToneOnes.count) 条不再用确定口吻：补充说「不能确定」，依据说「看不出是不是网关挡的」")
let hardToneOnes = gatewayReceipts.filter { !hitMarkers($0.rawText).hard.isEmpty }
check(hardToneOnes.allSatisfy { $0.exclusionNote.contains("不是 Key 的问题") },
      "命中硬特征的 \(hardToneOnes.count) 条文案没被顺手改掉（仍说「不是 Key 的问题」）")

// 界面只说人话：依据那一行里不许出现 HTML / JSON / 响应头这类技术细节。
// 特征词、原始正文留在本工具的日志里当证据，不往界面上甩。
let techTokens = ["<", ">", "{", "}", "\\", "HTTP", "JSON", "DOCTYPE", "HTML",
                  "cloudflare", "cf-ray", "captcha", "challenge", "server:", "content-type"]
let basisIsPlainWords = gatewayReceipts.allSatisfy { receipt in
    let text = receipt.evidenceNote ?? ""
    let upper = text.uppercased()
    if text.isEmpty || !text.hasSuffix("。") { return false }
    return !techTokens.contains { upper.contains($0.uppercased()) }
}
check(basisIsPlainWords, "明细里只有人话：\(gatewayReceipts.count) 条依据都不含 HTML / JSON / 响应头字样（技术细节只出现在本工具日志里）")

// 「某台机器连不上」这一类：哪台、为什么、下一步都得看得见，而且署名不能挂错 ——
// 连不上时网关根本没收到服务方的回话，那句错是本机自己记的，不能写成「服务方原话」。
func receiptOf(_ sample: Sample) -> HubLineReceipt? {
    let entry: [String: Any] = ["last_error": sample.raw, "last_attempt_at": sample.at(now),
                                "attempts": 3, "successes": 0, "failures": 3]
    return HubLineReceipt.parse(providerID: sample.name, entry: entry, now: now)
}
let attributionRight = samples.allSatisfy { sample in
    guard let receipt = receiptOf(sample) else { return false }
    let expected = HubLineReceipt.httpStatus(in: sample.raw) == nil ? "本机记下的错" : "服务方原话"
    return receipt.messageAttribution == expected
}
check(attributionRight, "每一句都署名到说话的人：有 HTTP 响应才是「服务方原话」，连不上 / 超时写成「本机记下的错」")
let transportReceipts = samples.compactMap { sample -> HubLineReceipt? in
    guard let receipt = receiptOf(sample), receipt.kind == .transport else { return nil }
    return receipt
}
let transportPlainTrio = transportReceipts.allSatisfy { receipt in
    let upper = receipt.receiptLine.uppercased()
    let note = receipt.exclusionNote
    let plain = !techTokens.contains { upper.contains($0.uppercased()) }
    return plain
        && receipt.receiptLine.contains(receipt.kind.shortReason)
        && note.contains("检查地址、网络")
        && note.hasSuffix("。")
        && !receipt.providerMessage.isEmpty          // 具体原因留在脸上，不藏进悬停
}
check(!transportReceipts.isEmpty && transportPlainTrio,
      "连不上的 \(transportReceipts.count) 条：结论行只说人话（「\(transportReceipts.first?.kind.shortReason ?? "")」），补充给出下一步，具体原因照原样摆出来")
let bridgeHintVisible = samples
    .filter { $0.raw == dshTimeoutRaw }
    .allSatisfy { (receiptOf($0)?.providerMessage ?? "").contains("请确认 DSH 客户端正在运行") }
check(bridgeHintVisible, "「DSH 桥超时」这条最有用的一句（请确认 DSH 客户端正在运行）留在脸上，没被藏进悬停")
// 连不上时那句「本机记下的错」里可能带机器字样（URL / errno / 英文错误名）。
// 不替用户翻译：这几样正是最具体的「为什么」，翻译要靠猜。照原样摆着，但把清单亮出来。
let machineTokens = ["http", "://", "errno", "connection", "refused", "timeout", "socket"]
let transportVisibleTokens = transportReceipts.filter { receipt in
    let lower = receipt.providerMessage.lowercased()
    return machineTokens.contains { lower.contains($0) }
}
if !transportVisibleTokens.isEmpty {
    print("⚠️ 连不上的回执里还剩机器字样，照原样摆着（没有替你翻译）：")
    for receipt in transportVisibleTokens {
        print("   · \(receipt.providerMessage)")
    }
    print("   留着它的理由：这是本机原样记下的「为什么」，翻译要靠猜；具体原因摆出来比藏起来有用。")
    print("   要彻底只留人话，就把 `HubReceiptViews` 里那句 `receipt.providerMessage` 改成只在悬停里显示。")
}
print("")

if !softOnlyFreed.isEmpty {
    print("-- ⑤ 留给你的收紧开关（只有软特征命中的放行） --")
    for sample in softOnlyFreed {
        let marks = hitMarkers(sample.raw)
        print("⚠️ \(sample.name)：只命中软特征 \(marks.soft.joined(separator: "、")) → 现在会放行。")
    }
    print("   现在不收紧的理由：这一类「多试几次」的代价，小于把一条好线路永久拉黑。")
    print("   要收紧就把 `HubLineReceipt.gatewayBlockSoftMarkers` 删空：硬特征足够盖住真拦截页。")
    print("")
}

// ── ⑥ 真实盘面
print("-- ⑥ 真实盘面：\(statsURL().path) --")
let stats = statsURL()
if let data = FileManager.default.contents(atPath: stats.path),
   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    print("读到 \(stats.path) · mtime \(mtimeText(stats.path)) · \(data.count) 字节")
    // 真实盘面是平的：顶层键就是线路 id。也兼容将来包一层 "providers" 的写法。
    let providers: [String: Any]
    if let nested = object["providers"] as? [String: Any] {
        providers = nested
    } else {
        providers = object.filter { $0.value is [String: Any] }
    }
    var scanned = 0
    var realFreed: [String] = []
    var stillExcluded: [String] = []
    var mismatched: [String] = []
    for (id, value) in providers.sorted(by: { $0.key < $1.key }) {
        guard let entry = value as? [String: Any] else { continue }
        let raw = ((entry["last_error"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { continue }
        scanned += 1
        guard let receipt = HubLineReceipt.parse(providerID: id, entry: entry, now: now) else { continue }
        let code = HubLineReceipt.httpStatus(in: raw)
        let oldExcluded = excluded(codeOnlyKind(code), isToday: receipt.isFromToday)
        let rawText = raw.count > 100 ? String(raw.prefix(100)) + "…" : raw
        if oldExcluded && receipt.excludesFromAutoPick { stillExcluded.append(id) }
        if oldExcluded && receipt.excludesFromAutoPick {
            print("   仍排除：\(id) · 旧 \(codeOnlyKind(code).rawValue) → 新 \(receipt.kind.rawValue) · \(receipt.kind.shortReason) · 原文：\(rawText)")
        }
        if !oldExcluded && !receipt.excludesFromAutoPick {
            print("   不排除：\(id) · 旧 \(codeOnlyKind(code).rawValue) → 新 \(receipt.kind.rawValue) · 原文：\(rawText)")
        }
        if oldExcluded && !receipt.excludesFromAutoPick {
            let marks = hitMarkers(raw)
            let why = (marks.hard + marks.soft).joined(separator: "、")
            print("   放行：\(id) · \(receipt.kind.rawValue) · 命中特征 \(why.isEmpty ? "无" : why)")
            print("        原文：\(raw.count > 160 ? String(raw.prefix(160)) + "…" : raw)")
            realFreed.append(id)
            if marks.hard.isEmpty { mismatched.append(id) }
        } else if !oldExcluded && receipt.excludesFromAutoPick {
            print("   收紧：\(id) · \(receipt.kind.rawValue) · 原文：\(raw.prefix(120))")
            mismatched.append(id)
        }
    }
    print("有 last_error 的线路：\(scanned) 条；其中旧红仍红 \(stillExcluded.count) 条\(stillExcluded.isEmpty ? "" : "（\(stillExcluded.joined(separator: "、"))）")；旧红被放行 \(realFreed.count) 条\(realFreed.isEmpty ? "" : "（\(realFreed.joined(separator: "、"))）")")
    check(mismatched.isEmpty, realFreed.isEmpty
          ? "真实盘面上本次改动什么都没有放行（\(scanned) 条回执逐条看过），也没有一条被莫名收紧"
          : "真实盘面里每一条放行（\(realFreed.count) 条）都命中了拦截页硬特征，且没有一条被莫名收紧")
} else {
    print("没有 router-stats.json（或读不动）：没有真实回执可扫，本项按「无数据」记录，不假装扫过。")
}
print("")

if failures.isEmpty {
    print("回执判据证据表通过：放行只发生在命中拦截页特征的 401 / 403 上，真判死的线一条没松。")
} else {
    print("回执判据证据表不通过，共 \(failures.count) 项：")
    for failure in failures { print("  ❌ \(failure)") }
}

if CommandLine.arguments.contains("--json") {
    let payload: [String: Any] = ["ok": failures.isEmpty,
                                  "failures": failures,
                                  "freed": freed.map(\.name),
                                  "softOnlyFreed": softOnlyFreed.map(\.name),
                                  "tightened": tightened.map(\.name)]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print("JSON \(text)")
    }
}

exit(failures.isEmpty ? 0 : 1)
