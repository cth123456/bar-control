import AppKit
import AVFoundation
import CoreAudio
import Darwin
import SwiftUI

private var applicationController: VoiceController?

private let automaticStopSilence: TimeInterval = 2.0
private let minimumRecordingDuration: TimeInterval = 0.8
private let voicePowerThreshold: Float = -50

private func touchBarStage(for text: String) -> String? {
    switch text {
    case "🔴 说话中": return "recording"
    case "📝 识别中": return "recognizing"
    case "🧭 本地判断中": return "thinking"
    case "🔊 准备播放": return "preparing_speech"
    case "🔊 播放中": return "speaking"
    default:
        // 回答阶段的状态条现在指向真在跑的东西（本机 Codex CLI，可能带真实版本号），
        // 所以按前缀判定，不写整串相等——否则带上版本号就掉出映射，状态被当成「无状态」清掉。
        // 「☁️ 云端思考中」这类话不再映射到任何 stage：宁可不显示，也不显示一句假话。
        return text.hasPrefix(VoiceController.runningPillPrefix) ? "thinking" : nil
    }
}

private func speechReadyText(_ raw: String) -> String {
    var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
    text = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "代码内容已省略。", options: .regularExpression)
    text = text.replacingOccurrences(of: #"https?://\S+"#, with: "链接", options: .regularExpression)
    text = text.replacingOccurrences(of: #"(?m)^\s*[-*•]\s+"#, with: "。", options: .regularExpression)
    text = text.replacingOccurrences(of: #"[#*_`>|]"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\s*\n+\s*"#, with: "。", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: #"[。]{2,}"#, with: "。", options: .regularExpression)
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let last = text.last, !"。！？".contains(last) {
        text += "。"
    }
    return text
}

private struct CodexUsage {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
}

private enum CodexEventUpdate {
    case threadStarted(String)
    case turnStarted
    case command(String)
    case answer(String)
    case warning(String)
    case failed(String)
    case completed(CodexUsage)
}

/// Parser for the actual `codex exec --json` JSONL events captured from codex-cli 0.155.1.
private struct CodexEventParser {
    var threadID: String?
    var answer = ""
    /// 事件流里 agent_message 的到达段数。多段按到达顺序拼接，不覆盖、不丢弃中间段。
    var answerSegments = 0
    var usage: CodexUsage?
    var fatalError: String?
    var lastError: String?
    var eventModel: String?
    /// 事件流里真实出现过的 provider 值；没有这个键时保持 nil，不猜、不编。
    var eventProvider: String?
    var invalidLineCount = 0
    var eventCount = 0

    mutating func consume(_ line: String) -> CodexEventUpdate? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            invalidLineCount += 1
            return nil
        }
        eventCount += 1
        // provider 是数据驱动的：事件里任何一层出现就取真值，没有才在文案里说「未带」。
        if let provider = Self.provider(in: object) { eventProvider = provider }
        switch type {
        case "thread.started":
            guard let threadID = object["thread_id"] as? String else { return nil }
            self.threadID = threadID
            return .threadStarted(threadID)
        case "turn.started":
            return .turnStarted
        case "item.started":
            guard let item = object["item"] as? [String: Any],
                  item["type"] as? String == "command_execution",
                  let command = item["command"] as? String else { return nil }
            return .command(command)
        case "item.completed":
            guard let item = object["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return nil }
            if itemType == "agent_message", let text = item["text"] as? String {
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return nil }
                answerSegments += 1
                answer = answer.isEmpty ? cleaned : answer + "\n\n" + cleaned
                return .answer(answer)
            }
            if itemType == "error", let message = item["message"] as? String {
                lastError = message
                if let model = Self.modelMentioned(in: message) { eventModel = model }
                return .warning(message)
            }
            if itemType == "command_execution", let command = item["command"] as? String {
                return .command(command)
            }
            return nil
        case "turn.completed":
            guard let usage = object["usage"] as? [String: Any] else { return nil }
            let parsed = CodexUsage(
                inputTokens: Self.int(usage["input_tokens"]),
                cachedInputTokens: Self.int(usage["cached_input_tokens"]),
                outputTokens: Self.int(usage["output_tokens"]),
                reasoningOutputTokens: Self.int(usage["reasoning_output_tokens"])
            )
            self.usage = parsed
            return .completed(parsed)
        case "turn.failed":
            let message = Self.message(from: object["error"]) ?? "Codex turn failed"
            fatalError = message
            lastError = message
            return .failed(message)
        case "error":
            let message = object["message"] as? String ?? "Codex returned an error"
            lastError = Self.message(from: message) ?? message
            return .warning(lastError ?? message)
        default:
            return nil
        }
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    /// 在事件 JSON 里找 provider 键（含 item 等嵌套层）。找不到返回 nil，绝不返回占位串。
    private static func provider(in object: [String: Any], depth: Int = 0) -> String? {
        if let value = object["provider"] as? String, !value.isEmpty { return value }
        guard depth < 3 else { return nil }
        for value in object.values {
            if let nested = value as? [String: Any], let found = provider(in: nested, depth: depth + 1) {
                return found
            }
            if let list = value as? [Any] {
                for element in list {
                    if let nested = element as? [String: Any],
                       let found = provider(in: nested, depth: depth + 1) {
                        return found
                    }
                }
            }
        }
        return nil
    }

    private static func modelMentioned(in text: String) -> String? {
        guard let range = text.range(of: "for model `") else { return nil }
        let suffix = text[range.upperBound...]
        guard let end = suffix.firstIndex(of: "`") else { return nil }
        return String(suffix[..<end])
    }

    private static func message(from value: Any?) -> String? {
        if let text = value as? String {
            if let data = text.data(using: .utf8),
               let nested = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = nested["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            return text
        }
        if let dictionary = value as? [String: Any], let message = dictionary["message"] as? String {
            return message
        }
        return nil
    }
}

/// 用真实抓到的 `codex exec --json` 事件流形状做断言（codex-cli 0.155.1）：
/// 多段回答按到达顺序拼接、命令回显和 error 事件不进正文、坏行只计数不崩、线路文案里的版本号与网关来自真实探测。
private enum CodexStreamSelfTest {
    static func run() -> Int32 {
        var failures: [String] = []

        func feed(_ lines: [String]) -> CodexEventParser {
            var parser = CodexEventParser()
            for line in lines { _ = parser.consume(line) }
            return parser
        }

        // 1) 真实形状：thread.started → error 项 → turn.started → 命令项 → 两段 agent_message → turn.completed。
        let twoSegments = feed([
            #"{"type":"thread.started","thread_id":"01999a1f-0f2b-7c31-8f21-2b1e5d0a9c44"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Configured service tier `priority` is not advertised as supported for model `jev/auto` and will be omitted from requests."}}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc \"date\""}}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc \"date\"","aggregated_output":"Sat Sep 26 19:53:54 CST 2026\n","exit_code":0,"status":"completed"}}"#,
            #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"现在是晚上7点53分。"}}"#,
            #"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"需要我提醒你吗？"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":38241,"cached_input_tokens":22016,"cache_write_input_tokens":0,"output_tokens":95,"reasoning_output_tokens":26}}"#,
        ])
        if twoSegments.answer != "现在是晚上7点53分。\n\n需要我提醒你吗？" {
            failures.append("多段回答必须按到达顺序拼接，实际：\(twoSegments.answer)")
        }
        if !twoSegments.answer.contains("现在是晚上7点53分。") {
            failures.append("拼接丢掉了先到的那一段，只剩最后一段：\(twoSegments.answer)")
        }
        if twoSegments.answerSegments != 2 {
            failures.append("两段 agent_message 应记 2 段，实际 \(twoSegments.answerSegments)")
        }
        if twoSegments.answer.contains("date") || twoSegments.answer.contains("service tier") {
            failures.append("命令回显和 error 事件不能混进正文：\(twoSegments.answer)")
        }
        if twoSegments.threadID != "01999a1f-0f2b-7c31-8f21-2b1e5d0a9c44" {
            failures.append("thread_id 没读出来：\(String(describing: twoSegments.threadID))")
        }
        if twoSegments.usage?.outputTokens != 95 {
            failures.append("turn.completed 的 output_tokens 没读出来：\(String(describing: twoSegments.usage?.outputTokens))")
        }
        if twoSegments.eventModel != "jev/auto" {
            failures.append("error 事件里提到的模型名要读出来（用于核对线路文案）：\(String(describing: twoSegments.eventModel))")
        }
        if twoSegments.invalidLineCount != 0 || twoSegments.eventCount != 8 {
            failures.append("事件计数不对：invalid=\(twoSegments.invalidLineCount) events=\(twoSegments.eventCount)")
        }

        // 2) 单段回答保持原样，不加多余换行。
        let single = feed([#"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"你好。"}}"#])
        if single.answer != "你好。" || single.answerSegments != 1 {
            failures.append("单段回答被改动：\(single.answer) 段数 \(single.answerSegments)")
        }

        // 3) 空白 agent_message 不算一段；坏行只计数，不炸。
        let noisy = feed([
            "这不是 JSON",
            #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"   "}}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"正文。"}}"#,
        ])
        if noisy.answer != "正文。" || noisy.answerSegments != 1 {
            failures.append("空白段被算进正文：\(noisy.answer) 段数 \(noisy.answerSegments)")
        }
        if noisy.invalidLineCount != 1 {
            failures.append("坏行应记 1 行，实际 \(noisy.invalidLineCount)")
        }

        // 4) 线路文案：模型名、版本号、网关必须来自真实探测，缺项直说原因，不写死也不写「未知」。
        //    前缀只准写能指到出处的事实：本次是本机 Codex CLI 打到本机网关，写「云端」就是拿类别名冒充事实。
        let thread = "01999a1f-0f2b-7c31-8f21-2b1e5d0a9c44"
        let route = VoiceController.cloudRouteText(
            version: "0.155.1", endpoint: "127.0.0.1:4202", eventModel: "jev/auto", provider: nil,
            threadID: thread, outputTokens: 95, answerChars: 24, segments: 2
        )
        let expectedRoute = "线路：本机 Codex CLI 0.155.1 → 网关 127.0.0.1:4202 · 请求模型 jev/auto · 事件模型 jev/auto · 响应未带 provider 字段 · 线程 01999a1f-0f2 · 输出 95 tokens · 正文 24 字/2 段"
        if route != expectedRoute {
            failures.append("线路文案与期望不一致：\n  实际：\(route)\n  期望：\(expectedRoute)")
        }
        for expected in ["本机 Codex CLI 0.155.1", "网关 127.0.0.1:4202", "请求模型 jev/auto", "正文 24 字/2 段"]
        where !route.contains(expected) {
            failures.append("线路文案少了「\(expected)」：\(route)")
        }
        if route.contains("未知") {
            failures.append("线路文案用「未知」冒充真实数据：\(route)")
        }
        if route.contains("云端") {
            failures.append("这次是本机 CLI 打本机网关，没有任何字段能证明上游是云：\(route)")
        }
        if !route.contains("01999a1f-0f2") || route.contains(thread) {
            failures.append("线程号只显示前 12 位：\(route)")
        }

        // 4b) provider 数据驱动：事件里有 provider 键就打印真值（顶层 / item 内两种形状都要认）。
        let topLevelProvider = feed([#"{"type":"thread.started","thread_id":"01999a1f-0f2b-7c31-8f21-2b1e5d0a9c44","provider":"anthropic"}"#])
        if topLevelProvider.eventProvider != "anthropic" {
            failures.append("事件顶层的 provider 没读出来：\(String(describing: topLevelProvider.eventProvider))")
        }
        let itemProvider = feed([#"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"好。","provider":"openai"}}"#])
        if itemProvider.eventProvider != "openai" {
            failures.append("item 里的 provider 没读出来：\(String(describing: itemProvider.eventProvider))")
        }
        let providerRoute = VoiceController.cloudRouteText(
            version: "0.155.1", endpoint: "127.0.0.1:4202", eventModel: nil, provider: itemProvider.eventProvider,
            threadID: nil, outputTokens: nil, answerChars: 1, segments: 1
        )
        if !providerRoute.contains("响应 provider openai") || providerRoute.contains("未带 provider") {
            failures.append("有 provider 时必须打印真值，实际：\(providerRoute)")
        }
        if providerRoute.contains("云端") {
            failures.append("有 provider 时前缀也不许写「云端」：\(providerRoute)")
        }

        // 4c) 读不到的项：直说原因，不留半截、不编号码。
        let missing = VoiceController.cloudRouteText(
            version: nil, endpoint: nil, eventModel: nil, provider: nil,
            threadID: nil, outputTokens: nil, answerChars: 4, segments: 1
        )
        if !missing.hasPrefix("线路：本机 Codex CLI → ") {
            failures.append("没有版本号时不能在 CLI 后面留半截：\(missing)")
        }
        if !missing.contains("配置里没有 base_url") {
            failures.append("读不到网关时要直说，实际：\(missing)")
        }
        for absent in ["0.155.1", "版本", "事件模型", "线程", "输出 ", "provider openai", "云端"]
        where missing.contains(absent) {
            failures.append("读不到的项不能编：出现了「\(absent)」\(missing)")
        }
        if !missing.contains("响应未带 provider 字段") {
            failures.append("没读到 provider 键时才说「未带」，实际：\(missing)")
        }

        // 5) 探测结果本身要像真的（读不到就跳过，不假装失败也不假装成功）。
        if let version = CodexCLI.versionText() {
            if version.isEmpty || version.rangeOfCharacter(from: .decimalDigits) == nil {
                failures.append("codex --version 读出来的版本号不合理：\(version)")
            }
        }
        if let endpoint = CodexCLI.endpoint(), endpoint.isEmpty || endpoint.contains("http") {
            failures.append("网关要显示真实 host:port，实际：\(endpoint)")
        }

        // 4d) 回答阶段的状态条：说的是真在跑的东西，且机器能按前缀反查回 stage。
        let pillWithVersion = VoiceController.runningPillText(version: "0.155.1")
        if pillWithVersion != "💻 本机 Codex CLI 0.155.1 执行中" {
            failures.append("带版本号的状态条文案不对：\(pillWithVersion)")
        }
        if pillWithVersion.contains("云端") {
            failures.append("状态条不能再说「云端」：\(pillWithVersion)")
        }
        if !pillWithVersion.hasPrefix(VoiceController.runningPillPrefix) {
            failures.append("状态条必须能被前缀反查回 stage：\(pillWithVersion)")
        }
        let pillNoVersion = VoiceController.runningPillText(version: nil)
        if pillNoVersion != "💻 本机 Codex CLI 执行中" {
            failures.append("没有版本号时不留半截、不编号：\(pillNoVersion)")
        }
        if pillNoVersion.contains("版本") {
            failures.append("没有版本号时不能写「版本」字样：\(pillNoVersion)")
        }

        guard failures.isEmpty else {
            for failure in failures { print("codex stream self-test failed: \(failure)") }
            return 1
        }
        // 把状态条和「线路：」两行真输出打出来：这两串是自测唯一能看见真实值的地方。
        print("pill: \(VoiceController.runningPillText(version: CodexCLI.versionText()))")
        print("route: \(VoiceController.cloudRouteText(version: CodexCLI.versionText(), endpoint: CodexCLI.endpoint(), eventModel: nil, provider: nil, threadID: nil, outputTokens: nil, answerChars: 42, segments: 2))")
        print("codex stream self-test passed")
        return 0
    }
}

private struct CodexInvocationResult {
    let answer: String
    let answerSegments: Int
    let threadID: String?
    let usage: CodexUsage?
    let eventModel: String?
    let eventProvider: String?
    let eventCount: Int
    let invalidLineCount: Int
    let elapsed: TimeInterval
}

private enum CodexCLIError: LocalizedError {
    case missing(String)
    case timeout(Int)
    case cancelled
    case failed(Int32, String)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .missing(let detail): return "Codex CLI 不可用：\(detail)"
        case .timeout(let seconds): return "Codex CLI 超时（\(seconds) 秒），没有等到模型完成。"
        case .cancelled: return "Codex 请求已取消。"
        case .failed(let code, let detail): return "Codex CLI 退出码 \(code)：\(detail)"
        case .empty(let detail): return "Codex 没有返回模型回复：\(detail)"
        }
    }
}

private enum CodexCLI {
    static let model = "jev/auto"
    /// 语音助手的策略链固定走 4202；Codex 客户端本身可以独立接入 4230，
    /// 不能再从 ~/.codex/config.toml 借用客户端出口。
    static let voiceBaseURL = "http://127.0.0.1:4202/v1"
    static let defaultTimeout: TimeInterval = 240
    static let reasoningEffort = "low"

    static func candidates() -> [String] {
        var values: [String] = []
        if let override = ProcessInfo.processInfo.environment["LOCALMODELVOICE_CODEX_PATH"], !override.isEmpty {
            values.append(override)
        }
        values += [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
        ]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        values += path.split(separator: ":").map { String($0) + "/codex" }
        var unique: [String] = []
        for value in values where !unique.contains(value) { unique.append(value) }
        return unique
    }

    static func executable() -> String? {
        candidates().first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private static let versionLock = NSLock()
    private static var cachedVersion: String?

    /// 线路文案里的版本号：真实读 `codex --version`，形如 "0.155.1"。
    /// 读不到就返回 nil —— 宁可不写版本，也不编一个。
    static func versionText() -> String? {
        versionLock.lock()
        defer { versionLock.unlock() }
        if let cachedVersion { return cachedVersion }
        guard let executable = executable() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        process.environment = environment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        // 真实输出形如 "codex-cli 0.155.1"：只取版本号那一段，产品名不进文案。
        let version = raw.split(separator: " ").last.map(String.init) ?? raw
        cachedVersion = version
        return version
    }

    /// 线路文案里的网关地址：语音助手固定使用自己的 4202 策略链。
    static func endpoint() -> String? {
        shortenEndpoint(voiceBaseURL)
    }

    /// "http://127.0.0.1:4202/v1" → "127.0.0.1:4202"，只留真实的主机与端口。
    private static func shortenEndpoint(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["http://", "https://"] where value.hasPrefix(scheme) {
            value.removeFirst(scheme.count)
        }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        return value
    }

    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let current = environment["PATH"] ?? ""
        let preferred = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var paths: [String] = []
        for value in preferred + current.split(separator: ":").map(String.init) where !paths.contains(value) {
            paths.append(value)
        }
        environment["PATH"] = paths.joined(separator: ":")
        return environment
    }
}

final class VoiceController: NSObject, NSApplicationDelegate, AVAudioRecorderDelegate {
    private struct LocalDecision: Decodable {
        let route: String
        let answer: String?
        let reason: String?
    }

    /// 一次语音交互的状态。中枢常驻，所以 .finished 是「待机」而不是「退出」。
    enum State: Equatable {
        case preparing
        case recording
        case processing
        case speaking
        case finished
    }

    private let processLock = NSLock()
    private let runtimeLogLock = NSLock()
    private lazy var runtimePIDURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalSiriLLM/voice.pid")
    private lazy var stopRequestURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalSiriLLM/stop.request")
    private lazy var touchBarStateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalSiriLLM/touchbar-state.tsv")
    private lazy var runtimeLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalSiriLLM/last-run.log")
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var stopRequestTimer: Timer?
    private var detectedVoice = false
    private var voiceFrameCount = 0
    private var recordingStartedAt = Date.distantPast
    private var lastVoiceAt = Date.distantPast
    private var audioURL: URL?
    private var state = State.finished
    private var activeProcess: Process?
    private var warmupProcess: Process?
    private var speakingAudioURL: URL?
    private var spokenAnswer = ""
    private var speechWasError = false
    private var cancellationRequested = false
    private var hub: HubWindowController?
    private var statusItem: NSStatusItem?
    /// 左键点状态栏图标弹出的快捷面板；右键（或 ⌥ 点击）仍然给原来的命令菜单。
    private var popover: NSPopover?
    /// 系统会因为「点到面板外面」先替我们关掉面板；记个时间戳，别让同一次点击又把它弹回来。
    private var popoverClosedAt = Date.distantPast
    private var statusMenu: NSMenu?
    /// 最近一次麦克风电平，菜单栏面板的电平条用它，不进日志。
    private var meterLevel = 0.0
    private var singleInstanceLockDescriptor: Int32 = -1
    private var isDuplicateInstance = false
    private var lastStatusText = "待机"
    private var lastDetailText = "点「开始说话」开麦；说完停约 2 秒自动结束，文字只在本机转写。"
    /// 上一次真正走通的线路，只展示后端给过的事实。
    private var lastRoute = ""
    /// 首页「最近一次」用的真实问答记录，不编造。
    private var lastQuestion = ""
    private var lastAnswerText = ""

    private func logStage(_ stage: String) {
        runtimeLogLock.lock()
        defer { runtimeLogLock.unlock() }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp)\t\(stage)\n"
        if !FileManager.default.fileExists(atPath: runtimeLogURL.path) {
            try? line.write(to: runtimeLogURL, atomically: true, encoding: .utf8)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: runtimeLogURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--router-self-test") {
            // |= 而不是 ||：三份自检都要跑完，一次就能看到全部失败项。
            exit(RouterStore.selfTest() | HubModel.selfTest() | HubClientRegistry.runSelfTest())
        }
        guard claimSingleInstance() else {
            isDuplicateInstance = true
            NSApp.terminate(nil)
            return
        }
        try? FileManager.default.removeItem(at: runtimeLogURL)
        let mode = LaunchMode(arguments: CommandLine.arguments)
        logStage("launch version=2.3.0 build=26 mode=\(mode.rawValue) activation=\(NSApp.activationPolicy().rawValue)")
        try? FileManager.default.removeItem(at: stopRequestURL)
        try? String(ProcessInfo.processInfo.processIdentifier)
            .write(to: runtimePIDURL, atomically: true, encoding: .utf8)
        installMainMenu()
        buildHub()
        installStatusMenu()
        restartStopRequestTimer()

        // 中枢是默认状态：打开软件 = 中枢首页（说明这个 App 能做什么 + 打字入口），不碰麦克风。
        // 只有显式要求（--voice / localmodelvoice://voice / 点「开始说话」）才进入语音流程。
        hub?.present(mode.landingPage)
        if mode != .voice {
            updateStatus(lastStatusText, detail: lastDetailText)
        }

        if let query = debugQuery() {
            runDebugQuery(query)
            return
        }

        if mode == .voice {
            beginVoiceFlow()
        }
    }

    /// Prevent duplicate app copies; flock also closes the race between near-simultaneous launches.
    ///
    /// 顺序很重要：**先抢锁**（进程一死 flock 立刻释放），抢不到才去激活现役实例。
    /// 反过来先看运行列表会踩到「兄弟进程正在退出」的几百毫秒空窗：它还在
    /// NSRunningApplication 清单里，激活落空后本进程又 terminate 自己，
    /// 用户看到的就是「点了图标，App 还是没出来」。
    private func claimSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.local.LocalModelVoice"
        let currentPID = ProcessInfo.processInfo.processIdentifier

        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalSiriLLM", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        } catch {
            fputs("AI助手: 无法创建单实例锁目录：\(error.localizedDescription)\n", stderr)
            return false
        }
        let lockURL = support.appendingPathComponent("ai-assistant-instance.lock")

        var descriptor: Int32 = -1
        for attempt in 0...3 {
            descriptor = Darwin.open(
                lockURL.path,
                O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK,
                mode_t(S_IRUSR | S_IWUSR)
            )
            if descriptor >= 0 { break }
            // 锁在别人手里：多半是现役实例，把它请到前台就够了；也可能它刚退出、
            // flock 还差几毫秒才释放，那就等一下再抢，别把自己的启动白扔掉。
            if activateRunningInstance(bundleID: bundleID, excluding: currentPID) { return false }
            if attempt < 3 { usleep(200_000) }
        }
        guard descriptor >= 0 else {
            fputs("AI助手: 无法创建单实例锁文件。\n", stderr)
            return false
        }

        // 抢到锁了，但还要排掉「不用锁的老版本实例」：它活着就让位，保持旧行为。
        // 正在退出的残留进程不算数（activateRunningInstance 已经把它们过滤掉）。
        if activateRunningInstance(bundleID: bundleID, excluding: currentPID) {
            Darwin.close(descriptor)
            return false
        }
        singleInstanceLockDescriptor = descriptor
        return true
    }

    /// 把真正活着、没在退出的同 bundle 实例激活到前台；有就返回 true（调用方应当让位）。
    /// - Parameter waitsForExit: 额外等几次（每次 150ms），给正在退出的兄弟进程让干净的机会。
    @discardableResult
    private func activateRunningInstance(
        bundleID: String,
        excluding currentPID: pid_t,
        waitsForExit waits: Int = 0
    ) -> Bool {
        for attempt in 0...max(0, waits) {
            let sibling = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first { $0.processIdentifier != currentPID && !$0.isTerminated }
            if let sibling = sibling {
                _ = sibling.activate(options: [.activateAllWindows])
                return true
            }
            if attempt < waits { usleep(150_000) }
        }
        return false
    }

    /// 真正开始一次语音交互。每次交互前重置取消标记，否则一次取消会永久卡死后续交互。
    private func beginVoiceFlow() {
        guard state == .finished else {
            hub?.present(.voice)
            return
        }
        processLock.lock()
        cancellationRequested = false
        processLock.unlock()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            prepareRecording()
        case .notDetermined:
            updateStatus("需要麦克风权限", detail: "录音留在本机；复杂问题只发送转写文字")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                DispatchQueue.main.async {
                    if allowed {
                        self?.prepareRecording()
                    } else {
                        self?.finishWithError("麦克风权限未开启")
                    }
                }
            }
        default:
            finishWithError("请在“隐私与安全性 → 麦克风”中允许“AI助手”")
        }
    }

    private func debugQuery() -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--debug-query"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "AI助手")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "AI助手 · 中枢"
        item.button?.target = self
        item.button?.action = #selector(statusButtonClicked(_:))
        // 只在 mouseUp 上收事件：菜单一旦常挂按钮就会吞掉左键，所以菜单按需挂、弹完就摘。
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusMenu = buildStatusMenu()
        statusItem = item
    }

    /// 面板里放不下的命令仍然留在右键菜单里，原来习惯的用法不用改。
    func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let voiceItem = NSMenuItem(title: "打开中枢（语音）", action: #selector(showVoiceWindow), keyEquivalent: "1")
        voiceItem.target = self
        menu.addItem(voiceItem)

        let managerItem = NSMenuItem(title: "Agent 与线路", action: #selector(openRouterManager), keyEquivalent: "2")
        managerItem.target = self
        menu.addItem(managerItem)

        let statusItemMenu = NSMenuItem(title: "运行状态", action: #selector(showStatusWindow), keyEquivalent: "3")
        statusItemMenu.target = self
        menu.addItem(statusItemMenu)

        let talkItem = NSMenuItem(title: "开始说话", action: #selector(startTalking), keyEquivalent: "d")
        talkItem.target = self
        menu.addItem(talkItem)

        menu.addItem(.separator())
        let revealItem = NSMenuItem(title: "打开配置目录", action: #selector(revealSupportDirectory), keyEquivalent: "")
        revealItem.target = self
        menu.addItem(revealItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true
        if wantsMenu, let menu = statusMenu {
            // 菜单得挂在按钮上才会贴在光标位置弹出；弹完立刻摘掉，左键才留得住。
            statusItem?.menu = menu
            sender.performClick(nil)
            statusItem?.menu = nil
            return
        }
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else if Date().timeIntervalSince(popoverClosedAt) > 0.2 {
            showPopover(relativeTo: sender)
        }
    }

    /// 快捷面板：上面是「现在在做什么」，中间是语音 / 打字两个入口，下面留最近一次问答。
    private func showPopover(relativeTo button: NSStatusBarButton) {
        guard let bridge = hub?.homeBridge else { return }
        let popover = self.popover ?? makePopover(bridge: bridge)
        // 面板里要打字，所以先把 App 激活，再把焦点交给弹出的窗口。
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func makePopover(bridge: HubHomeBridge) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(rootView: VoicePopoverView(bridge: bridge))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 380, height: 460)
        self.popover = popover
        return popover
    }

    /// 自检：菜单栏快捷面板必须建得出来，而且用的是中枢首页那份状态桥。
    func popoverSelfTestFailure() -> String? {
        if statusItem == nil { installStatusMenu() }
        if statusMenu == nil || statusMenu?.items.isEmpty == true {
            return "右键菜单没有建出来：快捷面板会顺手把老入口弄丢"
        }
        if statusItem?.menu != nil {
            return "状态栏按钮不该常挂菜单，否则左键永远开不出快捷面板"
        }
        if statusItem?.button?.action != #selector(statusButtonClicked(_:)) {
            return "状态栏左键没有接到快捷面板"
        }
        guard let bridge = hub?.homeBridge else {
            return "快捷面板没有拿到状态桥，点开只会停在初始文案"
        }
        if bridge.onAsk == nil || bridge.onToggleVoice == nil {
            return "快捷面板的语音 / 打字入口没有接到语音控制器"
        }
        let popover = self.popover ?? makePopover(bridge: bridge)
        if popover.contentViewController is NSHostingController<VoicePopoverView> == false {
            return "快捷面板装的不是 VoicePopoverView"
        }
        if popover.behavior != .transient {
            return "快捷面板必须点外面就收，否则会一直压着别的窗口"
        }
        return nil
    }

    @objc private func openRouterManager() {
        hub?.present(.router)
    }

    @objc private func showStatusWindow() {
        hub?.present(.status)
    }

    /// 「运行状态」页：把语音链路上的依赖逐项摊开，缺什么、要装什么一目了然。
    private func refreshStatusPage() {
        guard let panel = hub?.statusPanel else { return }
        panel.setChecks(environmentChecks())
        panel.setLogPath("日志文件：\(runtimeLogURL.path)")
        panel.setLog((try? String(contentsOf: runtimeLogURL, encoding: .utf8)) ?? "")
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    private func environmentChecks() -> [EnvironmentCheck] {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalSiriLLM")
        var checks: [EnvironmentCheck] = []

        // 1. 麦克风权限：整条语音链路的入口。
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            checks.append(EnvironmentCheck(name: "麦克风权限", level: .ok, detail: "已允许"))
        case .notDetermined:
            checks.append(EnvironmentCheck(
                name: "麦克风权限",
                level: .ok,
                detail: "尚未申请；首次点「开始说话」时才会询问（不影响打字和路由）"
            ))
        default:
            checks.append(EnvironmentCheck(
                name: "麦克风权限",
                level: .fail,
                detail: "去「系统设置 → 隐私与安全性 → 麦克风」勾选「AI助手」"
            ))
        }

        // 2. 转写器：缺了就会一直停在"识别中"。
        let whisper = "/opt/homebrew/bin/whisper-cli"
        if FileManager.default.isExecutableFile(atPath: whisper) {
            checks.append(EnvironmentCheck(name: "本机转写 whisper-cli", level: .ok, detail: whisper))
        } else {
            checks.append(EnvironmentCheck(
                name: "本机转写 whisper-cli",
                level: .fail,
                detail: "缺少 \(whisper)，安装：brew install whisper-cpp"
            ))
        }

        // 3. 转写模型文件。
        let model = support.appendingPathComponent("models/ggml-small.bin")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: model.path),
           let size = attributes[.size] as? Int {
            checks.append(EnvironmentCheck(
                name: "转写模型 ggml-small",
                level: .ok,
                detail: String(format: "%.0f MB · %@", Double(size) / 1_048_576, model.path)
            ))
        } else {
            checks.append(EnvironmentCheck(
                name: "转写模型 ggml-small",
                level: .fail,
                detail: "缺少 \(model.path)，需要先放好模型文件"
            ))
        }

        // 4. 本地分流脚本：决定"本机答"还是"上云"。
        let helper = support.appendingPathComponent("local_assistant.py")
        if FileManager.default.fileExists(atPath: helper.path) {
            checks.append(EnvironmentCheck(name: "本地分流脚本", level: .ok, detail: helper.path))
        } else {
            checks.append(EnvironmentCheck(
                name: "本地分流脚本",
                level: .fail,
                detail: "缺少 \(helper.path)：本机分流不可用，提问将直接交本机 Codex CLI（\(CodexCLI.model)）回答，不经本机小模型"
            ))
        }

        // 5. 云端线路：真实调用 codex exec --json，不再经过旧的 Python 云端包装器。
        if let codex = CodexCLI.executable() {
            checks.append(EnvironmentCheck(
                name: "用户提出问题 → Codex CLI 问答",
                level: .ok,
                detail: "\(codex) · 模型 \(CodexCLI.model) · JSONL · read-only · ephemeral"
            ))
        } else {
            checks.append(EnvironmentCheck(
                name: "用户提出问题 → Codex CLI 问答",
                level: .fail,
                detail: "未找到 Codex CLI；已检查：\(CodexCLI.candidates().joined(separator: ", "))"
            ))
        }
        checks.append(EnvironmentCheck(
            name: "最近一次真实线路",
            level: lastRoute.isEmpty ? .warn : .ok,
            detail: lastRoute.isEmpty ? "尚未完成一次问答，不能编造线路" : lastRoute
        ))

        // 6. 语音播报：系统自带，基本不会缺。
        let say = "/usr/bin/say"
        checks.append(EnvironmentCheck(
            name: "语音播报 say",
            level: FileManager.default.isExecutableFile(atPath: say) ? .ok : .warn,
            detail: say
        ))

        return checks
    }

    @objc private func revealSupportDirectory() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalSiriLLM")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func showHubHome() {
        hub?.present(.home)
    }

    @objc private func showVoiceWindow() {
        hub?.present(.voice)
    }

    @objc private func startTalking() {
        hub?.present(.voice)
        beginVoiceFlow()
    }

    private func runDebugQuery(_ query: String) {
        state = .processing
        lastQuestion = query
        lastAnswerText = ""
        hub?.chatPanel.setTranscript(query)
        hub?.chatPanel.setAnswer("")
        hub?.chatPanel.setReplayEnabled(false)
        updateStatus("正在诊断模型与语音…", detail: "跳过录音和 Whisper")
        logStage("debug-query start characters=\(query.count)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let answer = try self?.askModel(query) ?? ""
                guard let self, !self.isCancellationRequested() else { return }
                self.logStage("model-answer characters=\(answer.count)")
                self.logStage("speech-dispatch")
                DispatchQueue.main.async {
                    self.lastAnswerText = answer
                    self.hub?.chatPanel.setAnswer(answer)
                    self.hub?.chatPanel.setReplayEnabled(true)
                    self.renderVoicePanel()
                    self.logStage("speech-closure")
                    self.prepareSiriSpeech(
                        answer,
                        audioURL: FileManager.default.temporaryDirectory.appendingPathComponent("local-siri-debug.wav")
                    )
                }
            } catch {
                self?.logStage("debug-query error=\(error.localizedDescription.prefix(120))")
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.showConversationError(error.localizedDescription)
                    self.finishWithError(error.localizedDescription)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isDuplicateInstance else { return }
        stopRequestTimer?.invalidate()
        terminateChildProcesses()
        hub?.shutdown()
        try? FileManager.default.removeItem(at: runtimePIDURL)
        try? FileManager.default.removeItem(at: stopRequestURL)
        try? FileManager.default.removeItem(at: touchBarStateURL)
        if singleInstanceLockDescriptor >= 0 {
            Darwin.close(singleInstanceLockDescriptor)
            singleInstanceLockDescriptor = -1
        }
    }

    /// 点 Dock 图标 / 再次「打开」App = 回到中枢，不会偷偷开麦，也不会取消正在进行的事。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        logStage("reopen")
        // 空闲时回中枢首页；正在录音/回答时留在对话页，否则会看不到自己在说什么。
        hub?.present(state == .finished ? .home : .voice)
        return true
    }

    /// 外部触发：localmodelvoice://voice 说话、localmodelvoice://router 打开线路页。
    /// 中枢常驻后这是 Touch Bar / 脚本最可靠的入口（冷启动和已运行都生效）。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "localmodelvoice" {
            switch url.host {
            case "voice":
                logStage("url-voice")
                hub?.present(.voice)
                beginVoiceFlow()
            case "home":
                logStage("url-home")
                hub?.present(.home)
            case "router":
                logStage("url-router")
                hub?.present(.router)
            default:
                break
            }
        }
    }

    private func restartStopRequestTimer() {
        stopRequestTimer?.invalidate()
        stopRequestTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.checkStopRequest()
        }
    }

    private func handleToggle() {
        switch state {
        case .preparing, .recording, .processing, .speaking:
            cancelCurrentWork()
        case .finished:
            beginVoiceFlow()
        }
    }

    private func cancelCurrentWork() {
        logStage("cancel")
        processLock.lock()
        cancellationRequested = true
        let process = activeProcess
        let warmup = warmupProcess
        processLock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
        if warmup?.isRunning == true {
            warmup?.terminate()
        }
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        audioURL = nil
        try? FileManager.default.removeItem(at: stopRequestURL)
        state = .finished
        setReadyTouchBar()
        // 中枢常驻：取消只回到待机，退出请用 ⌘Q 或状态栏「退出」。
        updateStatus("已取消", detail: "回到待机；点「开始说话」可以再说一次。")
    }

    private func isCancellationRequested() -> Bool {
        processLock.lock()
        defer { processLock.unlock() }
        return cancellationRequested
    }

    private func terminateChildProcesses() {
        processLock.lock()
        let process = activeProcess
        let warmup = warmupProcess
        processLock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
        if warmup?.isRunning == true {
            warmup?.terminate()
        }
    }

    private func checkStopRequest() {
        guard state != .finished,
              FileManager.default.fileExists(atPath: stopRequestURL.path) else { return }
        try? FileManager.default.removeItem(at: stopRequestURL)
        cancelCurrentWork()
    }

    /// 中枢窗口：语音助手 + Agent 与线路 + 运行状态。App 的内存中只保留这一个窗口。
    private func buildHub() {
        let controller = HubWindowController()
        let panel = controller.chatPanel
        panel.onPrimary = { [weak self] in self?.handleToggle() }
        panel.onCancel = { [weak self] in self?.cancelCurrentWork() }
        panel.onSendText = { [weak self] text in self?.submitTypedQuery(text) }
        panel.onCopyAnswer = { [weak self] in self?.copyAnswerToPasteboard() }
        panel.onReplayAnswer = { [weak self] in self?.replayAnswer() }
        panel.onRevealSupportDirectory = { [weak self] in self?.revealSupportDirectory() }
        panel.setFooter(Self.footerText(lastRoute: lastRoute))

        let home = controller.homePanel
        home.onAsk = { [weak self] text in self?.submitTypedQuery(text) }
        home.onToggleVoice = { [weak self] in self?.handleToggle() }
        home.onOpenPage = { [weak self] page in self?.hub?.present(page) }

        // 总览页是 SwiftUI 的，状态机必须同时喂它，否则新首页永远停在「待机」。
        let bridge = controller.homeBridge
        bridge.onAsk = { [weak self] text in self?.submitTypedQuery(text) }
        bridge.onToggleVoice = { [weak self] in self?.handleToggle() }
        // 菜单栏快捷面板共用这份状态桥：跳页和开目录前先收起面板，否则面板会盖着刚开的窗口。
        bridge.onOpenPage = { [weak self] page in
            self?.popover?.performClose(nil)
            self?.hub?.present(page)
        }
        bridge.onCancelVoice = { [weak self] in self?.cancelCurrentWork() }
        bridge.onCopyAnswer = { [weak self] in self?.copyAnswerToPasteboard() }
        bridge.onReplayAnswer = { [weak self] in self?.replayAnswer() }
        bridge.onRevealSupportDirectory = { [weak self] in
            self?.popover?.performClose(nil)
            self?.revealSupportDirectory()
        }
        bridge.onQuit = { NSApp.terminate(nil) }

        let status = controller.statusPanel
        status.onRefresh = { [weak self] in self?.refreshStatusPage() }
        status.onRevealSupportDirectory = { [weak self] in self?.revealSupportDirectory() }
        status.onOpenMicrophoneSettings = { [weak self] in self?.openMicrophoneSettings() }
        controller.onPageChange = { [weak self] page in
            if page == .status {
                self?.refreshStatusPage()
            }
        }
        hub = controller
        renderVoicePanel()
    }

    /// 一次性菜单栏，让 App 像正常 Mac 应用（⌘Q 退出、⌘W 藏窗口、⌘1/⌘2 切页签）。
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 AI助手", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 AI助手", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 AI助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let hubItem = NSMenuItem()
        let hubMenu = NSMenu(title: "中枢")
        let homeItem = NSMenuItem(title: "中枢首页", action: #selector(showHubHome), keyEquivalent: "0")
        homeItem.target = self
        hubMenu.addItem(homeItem)
        let voiceItem = NSMenuItem(title: "对话（语音 / 打字）", action: #selector(showVoiceWindow), keyEquivalent: "1")
        voiceItem.target = self
        hubMenu.addItem(voiceItem)
        let routerItem = NSMenuItem(title: "Agent 与线路", action: #selector(openRouterManager), keyEquivalent: "2")
        routerItem.target = self
        hubMenu.addItem(routerItem)
        let statusEntry = NSMenuItem(title: "运行状态", action: #selector(showStatusWindow), keyEquivalent: "3")
        statusEntry.target = self
        hubMenu.addItem(statusEntry)
        let talkItem = NSMenuItem(title: "开始说话", action: #selector(startTalking), keyEquivalent: "d")
        talkItem.target = self
        hubMenu.addItem(talkItem)
        hubMenu.addItem(.separator())
        let revealItem = NSMenuItem(title: "打开配置目录", action: #selector(revealSupportDirectory), keyEquivalent: "")
        revealItem.target = self
        hubMenu.addItem(revealItem)
        hubItem.submenu = hubMenu
        main.addItem(hubItem)

        // SwiftUI 文本框的右键菜单自带编辑动作，但 ⌘V 等快捷键仍由 AppKit
        // 主菜单分发；没有标准「编辑」菜单时，快捷键不会进入 first responder。
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: #selector(UndoManager.undo), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "隐藏窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    private func updateStatus(_ status: String, detail: String) {
        lastStatusText = status
        lastDetailText = detail
        logStage("ui status=\(status)")
        renderVoicePanel()
        statusItem?.button?.toolTip = "AI助手 · \(status)"
    }

    /// 把状态机映射成界面：待机给按钮、录音给红色状态点和取消、处理中不给重复开麦。
    private func renderVoicePanel() {
        guard let panel = hub?.chatPanel else { return }
        let presentation = Self.presentation(for: state, status: lastStatusText, detail: lastDetailText)
        panel.apply(presentation)
        panel.setReplayEnabled(state == .finished && !spokenAnswer.isEmpty)
        panel.setSendEnabled(state == .finished)
        panel.setFooter(Self.footerText(lastRoute: lastRoute))
        // 菜单栏面板画的是同一张流水线地图：阶段高亮 + 只有录音时才有意义的电平。
        if state != .recording { meterLevel = 0 }
        hub?.homeBridge.stageIndex = presentation.stage.rawValue
        hub?.homeBridge.level = meterLevel
        renderHomePanel()
    }

    /// 首页那张状态卡：跟对话页同一个状态机，只是话更少。
    private func renderHomePanel() {
        let presentation = Self.homePresentation(for: state, status: lastStatusText, detail: lastDetailText)
        if let home = hub?.homePanel {
            home.apply(presentation)
            home.setLastExchange(question: lastQuestion, answer: lastAnswerText, route: lastRoute)
        }
        guard let bridge = hub?.homeBridge else { return }
        bridge.apply(
            status: presentation.status,
            detail: presentation.detail,
            tint: Color(nsColor: presentation.tint),
            busy: presentation.busy
        )
        bridge.setLastExchange(question: lastQuestion, answer: lastAnswerText, route: lastRoute)
    }

    /// 首页只回答两个问题：现在在做什么、下一步按哪里。
    static func homePresentation(for state: State, status: String, detail: String) -> HomePanelView.Presentation {
        switch state {
        case .finished:
            return HomePanelView.Presentation(
                status: status,
                detail: detail.isEmpty ? "还没有开始对话：打字问一句，或者点「开始说话」。" : detail,
                tint: .secondaryLabelColor,
                busy: false
            )
        case .preparing:
            return HomePanelView.Presentation(status: status, detail: detail, tint: .systemOrange, busy: true)
        case .recording:
            return HomePanelView.Presentation(status: status, detail: detail, tint: .systemRed, busy: true)
        case .processing:
            return HomePanelView.Presentation(status: status, detail: detail, tint: .systemOrange, busy: true)
        case .speaking:
            return HomePanelView.Presentation(status: status, detail: detail, tint: .systemGreen, busy: true)
        }
    }

    /// 页脚只写后端真实给过的信息：上一次实际走了哪条线路。
    static func footerText(lastRoute: String) -> String {
        let route = lastRoute.isEmpty ? "还没有提问过" : lastRoute
        return "上次线路：\(route) · 配置目录 ~/Library/Application Support/LocalSiriLLM"
    }

    /// 线路文案的唯一出处：每个词都要能在真实输出或配置里指到出处，指不到就省略；
    /// 既不编造，也不用「未知」冒充「已经读到但读不出」。
    /// 前缀不写「云端」：本次执行是本机 Codex CLI 打到本机网关，事件流里没有任何字段能证明上游是云。
    static func cloudRouteText(version: String?, endpoint: String?, eventModel: String?,
                               provider: String?, threadID: String?, outputTokens: Int?,
                               answerChars: Int, segments: Int) -> String {
        var head = "本机 Codex CLI"
        if let version, !version.isEmpty { head += " \(version)" }
        var parts: [String] = []
        parts.append("网关 \(endpoint ?? "配置里没有 base_url")")
        parts.append("请求模型 \(CodexCLI.model)")
        if let eventModel { parts.append("事件模型 \(eventModel)") }
        if let provider, !provider.isEmpty {
            parts.append("响应 provider \(provider)")
        } else {
            parts.append("响应未带 provider 字段")
        }
        if let threadID { parts.append("线程 \(String(threadID.prefix(12)))") }
        if let outputTokens { parts.append("输出 \(outputTokens) tokens") }
        parts.append("正文 \(answerChars) 字/\(segments) 段")
        return "线路：\(head) → " + parts.joined(separator: " · ")
    }

    /// 回答阶段状态条的固定前缀：跑的是本机 codex CLI 打到本机网关，
    /// 事件流里没有任何字段能证明上游是云，所以不写「云端」。
    static let runningPillPrefix = "💻 本机 Codex CLI"

    /// 状态条文案：真读到版本号就带上，读不到就不写这一项（不用「未知」兜）。
    static func runningPillText(version: String?) -> String {
        runningPillPrefix + (version.map { " \($0)" } ?? "") + " 执行中"
    }

    static func presentation(for state: State, status: String, detail: String) -> ChatPanelView.Presentation {
        let stage = pipelineStage(for: state, status: status)
        switch state {
        case .finished:
            return ChatPanelView.Presentation(
                headline: status,
                hint: detail,
                stage: stage,
                primaryTitle: "开始说话",
                tint: .secondaryLabelColor
            )
        case .preparing:
            return ChatPanelView.Presentation(
                headline: status,
                hint: detail,
                stage: stage,
                primaryTitle: "先不说了",
                tint: .systemOrange,
                showsCancel: true
            )
        case .recording:
            return ChatPanelView.Presentation(
                headline: status,
                hint: detail,
                stage: stage,
                primaryTitle: "说完了",
                tint: .systemRed,
                showsMeter: true,
                showsCancel: true
            )
        case .processing:
            return ChatPanelView.Presentation(
                headline: status,
                hint: detail,
                stage: stage,
                primaryTitle: "处理中…",
                primaryEnabled: false,
                tint: .systemBlue,
                showsCancel: true
            )
        case .speaking:
            return ChatPanelView.Presentation(
                headline: status,
                hint: detail,
                stage: stage,
                primaryTitle: "播报中…",
                primaryEnabled: false,
                tint: .systemGreen,
                showsCancel: true
            )
        }
    }

    /// 状态机 + 当前文案 → 流程条阶段（识别与思考共用 .processing，靠文案区分）。
    static func pipelineStage(for state: State, status: String) -> ChatPanelView.Stage {
        switch state {
        case .recording:
            return .listening
        case .speaking:
            return .speaking
        case .processing:
            return status.contains("识别") || status.contains("转写") ? .transcribing : .thinking
        case .preparing, .finished:
            return .idle
        }
    }

    private func copyAnswerToPasteboard() {
        guard !spokenAnswer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(spokenAnswer, forType: .string)
    }

    private func replayAnswer() {
        guard state == .finished, !spokenAnswer.isEmpty else { return }
        logStage("replay")
        startSpeech(spokenAnswer, isError: speechWasError, audioURL: nil)
    }

    private func updateTouchBar(text: String, symbol _: String, color _: String) {
        guard let stage = touchBarStage(for: text) else {
            try? FileManager.default.removeItem(at: touchBarStateURL)
            return
        }
        let label = text.replacingOccurrences(of: #"^[^\p{L}]+"#, with: "", options: .regularExpression)
        try? "\(stage)\t\(label)\n".write(to: touchBarStateURL, atomically: true, encoding: .utf8)
    }

    private func setReadyTouchBar() {
        updateTouchBar(
            text: "🎙 点击说话",
            symbol: "waveform.circle.fill",
            color: "58,58,58,255"
        )
    }

    private func prepareRecording() {
        state = .preparing
        updateStatus("准备聆听…", detail: "提示音后开始说话；停顿约 2 秒执行，再按一次取消")
        updateTouchBar(
            text: "🔴 说话中",
            symbol: "stop.circle.fill",
            color: "185,38,38,255"
        )
        prewarmLocalModel()
        NSSound.beep()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.startRecording()
        }
    }

    /// 把系统默认输入设备固定到内置麦克风。
    ///
    /// 蓝牙耳机（AirPods）会在音频配置变化时抢回默认输入，而它的麦克风在未佩戴或
    /// 设备切换过程中只会给出静音；下面的语音检测用 -42dB 能量判据，信号是 -120dB
    /// 时永远不触发 —— 现象就是「点了说话、什么也没识别到」。内置麦克风始终可用。
    private func pinBuiltInMicrophone() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &size) == noErr else { return }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &devicesAddress, 0, nil, &size, &devices) == noErr else { return }

        for device in devices {
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var name: CFString?
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            let nameStatus = withUnsafeMutablePointer(to: &name) { pointer in
                AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, pointer)
            }
            guard nameStatus == noErr, let resolved = name else { continue }
            let label = resolved as String
            guard label.contains("MacBook") || label.contains("内置") || label.contains("BuiltIn") else { continue }

            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var target = device
            AudioObjectSetPropertyData(system, &inputAddress, 0, nil,
                                       UInt32(MemoryLayout<AudioDeviceID>.size), &target)
            return
        }
    }

    private func startRecording() {
        guard state == .preparing else { return }
        pinBuiltInMicrophone()
        do {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("local-model-\(UUID().uuidString).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let newRecorder = try AVAudioRecorder(url: tempURL, settings: settings)
            newRecorder.delegate = self
            newRecorder.isMeteringEnabled = true
            guard newRecorder.prepareToRecord(), newRecorder.record() else {
                throw NSError(domain: "LocalModelVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法开始录音"])
            }
            recorder = newRecorder
            audioURL = tempURL
            detectedVoice = false
            voiceFrameCount = 0
            recordingStartedAt = Date()
            lastVoiceAt = recordingStartedAt
            state = .recording
            updateStatus("正在聆听…", detail: "说完停顿约 2 秒执行，再按一次取消")
            updateTouchBar(
                text: "🔴 说话中",
                symbol: "stop.circle.fill",
                color: "185,38,38,255"
            )
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.updateAudioLevel()
            }
        } catch {
            finishWithError("录音失败：\(error.localizedDescription)")
        }
    }

    private func updateAudioLevel() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        // -50dB…0dB 映射成 0…1，界面上能看到麦克风到底有没有收到声音。
        let level = Double(max(0, min(1, (power - voicePowerThreshold) / -voicePowerThreshold)))
        meterLevel = level
        hub?.chatPanel.setLevel(level)
        hub?.homeBridge.level = level
        let now = Date()
        if power > voicePowerThreshold {
            voiceFrameCount += 1
            if voiceFrameCount >= 2 {
                detectedVoice = true
                lastVoiceAt = now
            }
        } else if !detectedVoice {
            voiceFrameCount = 0
        }
        if now.timeIntervalSince(recordingStartedAt) >= minimumRecordingDuration,
           now.timeIntervalSince(lastVoiceAt) >= automaticStopSilence {
            stopAndProcess()
        } else if now.timeIntervalSince(recordingStartedAt) >= 60 {
            detectedVoice = true
            stopAndProcess()
        }
    }

    private func stopAndProcess() {
        guard state == .recording else { return }
        state = .processing
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        guard let audioURL else {
            finishWithError("没有取得录音")
            return
        }
        updateStatus("正在本机识别…", detail: "Whisper 正在把语音转换为文字")
        updateTouchBar(
            text: "📝 识别中",
            symbol: "text.bubble.fill",
            color: "116,82,40,255"
        )
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let transcript = try self?.transcribe(audioURL) ?? ""
                self?.logStage("transcript characters=\(transcript.count)")
                guard self?.isCancellationRequested() == false else { return }
                guard !transcript.isEmpty else {
                    throw NSError(domain: "LocalModelVoice", code: 2, userInfo: [NSLocalizedDescriptionKey: "没有识别到文字"])
                }
                DispatchQueue.main.async {
                    self?.hub?.chatPanel.setTranscript(transcript)
                    self?.updateStatus("正在本地判断…", detail: transcript)
                    self?.updateTouchBar(
                        text: "🧭 本地判断中",
                        symbol: "brain.head.profile",
                        color: "74,72,160,255"
                    )
                }
                let answer = try self?.askModel(transcript) ?? ""
                self?.logStage("model-answer characters=\(answer.count)")
                guard self?.isCancellationRequested() == false else { return }
                guard !answer.isEmpty else {
                    throw NSError(domain: "LocalModelVoice", code: 3, userInfo: [NSLocalizedDescriptionKey: "模型没有返回内容"])
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.lastAnswerText = answer
                    self.hub?.chatPanel.setAnswer(answer)
                    self.hub?.chatPanel.setReplayEnabled(true)
                    self.renderVoicePanel()
                    self.prepareSiriSpeech(answer, audioURL: audioURL)
                }
            } catch {
                try? FileManager.default.removeItem(at: audioURL)
                guard self?.isCancellationRequested() == false else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.showConversationError(error.localizedDescription)
                    self.finishWithError(error.localizedDescription)
                }
            }
        }
    }

    private func transcribe(_ audioURL: URL) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let model = home
            .appendingPathComponent("Library/Application Support/LocalSiriLLM/models/ggml-small.bin")
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw NSError(domain: "LocalModelVoice", code: 4, userInfo: [NSLocalizedDescriptionKey: "Whisper 模型文件不存在"])
        }
        let output = try runProcess(
            "/opt/homebrew/bin/whisper-cli",
            arguments: [
                "-m", model.path,
                "-f", audioURL.path,
                "-l", "zh",
                "-t", "4",
                "-np",
                "-nt",
            ],
            timeout: 45
        )
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func askModel(_ query: String) throws -> String {
        let decision: LocalDecision
        do {
            decision = try askLocalModel(query)
        } catch {
            guard !isCancellationRequested() else { throw error }
            return try askCloudModel(query, reason: "本地判断不可用，自动使用 Codex CLI")
        }
        if decision.route == "local", let answer = decision.answer, !answer.isEmpty {
            noteRoute("本机模型")
            return answer
        }
        if decision.route == "cloud" {
            return try askCloudModel(query, reason: decision.reason ?? "本地模型请求升级")
        }
        return try askCloudModel(query, reason: "本地模型返回了无效分流结果")
    }

    private func noteRoute(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastRoute = text
            self?.renderVoicePanel()
            self?.refreshStatusPage()
        }
    }

    /// 打字提问：跳过录音和转写，其余（分流、回答、播报按钮）和语音完全同一条链路。
    private func submitTypedQuery(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard state == .finished else {
            updateStatus("正在处理上一条…", detail: "等这次结束再发下一条，或先点「取消」。")
            return
        }

        processLock.lock()
        cancellationRequested = false
        processLock.unlock()

        spokenAnswer = ""
        lastQuestion = query
        lastAnswerText = ""
        hub?.chatPanel.clearTypedInput()
        hub?.chatPanel.setTranscript(query)
        hub?.chatPanel.setAnswer("")
        hub?.chatPanel.setReplayEnabled(false)
        state = .processing
        updateStatus("正在判断走哪条线路…", detail: query)
        updateTouchBar(text: "🧭 本地判断中", symbol: "brain.head.profile", color: "74,72,160,255")
        logStage("typed query characters=\(query.count)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                guard let self else { return }
                let answer = try self.askModel(query)
                guard !self.isCancellationRequested() else { return }
                guard !answer.isEmpty else {
                    throw NSError(
                        domain: "LocalModelVoice",
                        code: 9,
                        userInfo: [NSLocalizedDescriptionKey: "模型没有返回内容"]
                    )
                }
                DispatchQueue.main.async {
                    self.state = .finished
                    self.setReadyTouchBar()
                    self.spokenAnswer = answer
                    self.lastAnswerText = answer
                    self.hub?.chatPanel.setAnswer(answer)
                    self.updateStatus("已回答（没有自动播报）", detail: answer)
                    self.renderVoicePanel()
                }
            } catch {
                guard let self, !self.isCancellationRequested() else { return }
                DispatchQueue.main.async {
                    self.state = .finished
                    self.showConversationError(error.localizedDescription)
                    self.finishWithError(error.localizedDescription)
                }
            }
        }
    }

    private func askLocalModel(_ query: String) throws -> LocalDecision {
        let helper = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalSiriLLM/local_assistant.py")
        let output = try runProcess(
            "/usr/bin/python3",
            arguments: [helper.path, "--query", query],
            timeout: 130
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = output.data(using: .utf8) else {
            throw NSError(
                domain: "LocalModelVoice",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "无法读取本地分流结果"]
            )
        }
        return try JSONDecoder().decode(LocalDecision.self, from: data)
    }

    private func askCloudModel(_ query: String, reason: String) throws -> String {
        let timeout = CodexCLI.defaultTimeout
        // 状态条只说真在跑的东西。版本号在当前（后台）线程先读好，
        // 不让 main 线程去等 `codex --version` 这个子进程。
        let pill = Self.runningPillText(version: CodexCLI.versionText())
        DispatchQueue.main.async { [weak self] in
            self?.updateStatus(
                "正在通过 Codex CLI 回答…",
                detail: "模型 \(CodexCLI.model) · 只读沙箱 · \(reason)"
            )
            self?.updateTouchBar(
                text: pill,
                symbol: "cloud.fill",
                color: "40,92,150,255"
            )
        }

        let result = try runCodexModel(query, timeout: timeout) { [weak self] update in
            guard let self else { return }
            switch update {
            case .threadStarted(let threadID):
                self.logStage("codex event thread.started thread=\(threadID)")
                DispatchQueue.main.async {
                    self.updateStatus("Codex 已接收提问…", detail: "线程 \(String(threadID.prefix(12))) · 模型 \(CodexCLI.model)")
                }
            case .turnStarted:
                self.logStage("codex event turn.started")
            case .command(let command):
                self.logStage("codex event command=\(String(command.prefix(240)))")
                DispatchQueue.main.async {
                    self.updateStatus("Codex 正在执行只读步骤…", detail: String(command.prefix(240)))
                }
            case .answer(let answer):
                self.logStage("codex event item.completed agent_message characters=\(answer.count)")
                DispatchQueue.main.async {
                    self.updateStatus("Codex 已给出回答…", detail: String(answer.prefix(240)))
                }
            case .warning(let warning):
                self.logStage("codex event warning=\(String(warning.prefix(300)))")
            case .failed(let message):
                self.logStage("codex event turn.failed=\(String(message.prefix(400)))")
                DispatchQueue.main.async {
                    self.updateStatus("Codex 请求失败", detail: String(message.prefix(400)))
                }
            case .completed(let usage):
                self.logStage("codex event turn.completed input=\(usage.inputTokens) cached=\(usage.cachedInputTokens) output=\(usage.outputTokens) reasoning=\(usage.reasoningOutputTokens)")
            }
        }

        let rawAnswer = result.answer
        let cleaned = rawAnswer
            .replacingOccurrences(of: "```.*?```", with: "代码内容已省略。", options: [.regularExpression])
            .replacingOccurrences(of: "[*_#`>|]", with: "", options: [.regularExpression])
            // 只压空格与制表符，段落之间的换行要留着，句末的句号也不能删。
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: [.regularExpression])
            .replacingOccurrences(of: " *\\n *", with: "\n", options: [.regularExpression])
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw CodexCLIError.empty("事件流没有可显示的 agent_message")
        }

        logStage("codex answer raw=\(rawAnswer.count)字 cleaned=\(cleaned.count)字 segments=\(result.answerSegments)")
        // 线路文案只写真实发生过的事：配置里读不到网关就省略那一项，事件流里没有 provider 字段就直说，
        // 不再用「未知」冒充「已经读到但读不出」。
        let route = Self.cloudRouteText(
            version: CodexCLI.versionText(),
            endpoint: CodexCLI.endpoint(),
            eventModel: result.eventModel,
            provider: result.eventProvider,
            threadID: result.threadID,
            outputTokens: result.usage?.outputTokens,
            answerChars: cleaned.count,
            segments: result.answerSegments
        )
        logStage("codex success route=\(route) elapsed=\(String(format: "%.1f", result.elapsed))s events=\(result.eventCount) invalid=\(result.invalidLineCount)")
        noteRoute(route)
        // 全文交给上层显示，这里不再截断。
        return cleaned
    }

    private func runCodexModel(
        _ query: String,
        timeout: TimeInterval,
        onUpdate: @escaping (CodexEventUpdate) -> Void
    ) throws -> CodexInvocationResult {
        guard let executable = CodexCLI.executable() else {
            throw CodexCLIError.missing("已检查：\(CodexCLI.candidates().joined(separator: ", "))")
        }
        let prompt = """
        你是本地语音助手按需调用的上级云端模型。请直接回答用户，不讨论分流过程。
        默认使用简体中文，先给结论，使用自然口语，不用 Markdown；通常控制在 180 个汉字内，确有必要最多 500 个汉字，以便语音播报。
        需要当前事实时主动联网核实。当前为只读问答：不要修改本机文件、发送消息、付款或执行会改变外部状态的操作；若用户要求实际操作，说明需要在有确认机制的任务中执行。

        用户原话：\(query)
        """
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let arguments = [
            "exec", "--json", "--ephemeral", "--skip-git-repo-check",
            "-s", "read-only", "-m", CodexCLI.model,
            "-c", "openai_base_url=\"\(CodexCLI.voiceBaseURL)\"",
            "-c", "model_reasoning_effort=\"\(CodexCLI.reasoningEffort)\"",
            "--color", "never", "-C", home, "-",
        ]
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = CodexCLI.environment()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let parserQueue = DispatchQueue(label: "LocalModelVoice.codex-parser")
        var parser = CodexEventParser()
        let emitLine: (String) -> Void = { line in
            let update = parserQueue.sync { parser.consume(line) }
            if let update { onUpdate(update) }
        }
        let outputGroup = DispatchGroup()
        outputGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            while true {
                let data = outputPipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(data: buffer.subdata(in: 0..<newline), encoding: .utf8) ?? ""
                    buffer.removeSubrange(0...newline)
                    emitLine(line)
                }
            }
            if !buffer.isEmpty {
                emitLine(String(data: buffer, encoding: .utf8) ?? "")
            }
            outputGroup.leave()
        }

        let stderrLock = NSLock()
        var stderrData = Data()
        let errorGroup = DispatchGroup()
        errorGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = errorPipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                stderrLock.lock()
                stderrData.append(data)
                stderrLock.unlock()
            }
            errorGroup.leave()
        }

        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSemaphore.signal() }
        let startedAt = Date()
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
            throw CodexCLIError.missing("无法启动 \(executable)：\(error.localizedDescription)")
        }
        processLock.lock()
        activeProcess = process
        processLock.unlock()
        inputPipe.fileHandleForWriting.write(Data(prompt.utf8))
        try? inputPipe.fileHandleForWriting.close()

        var timedOut = false
        var cancelled = false
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if isCancellationRequested() {
                cancelled = true
                process.terminate()
                break
            }
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            _ = exitSemaphore.wait(timeout: .now() + 0.1)
        }
        if process.isRunning {
            let graceDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < graceDeadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        _ = exitSemaphore.wait(timeout: .now() + 2)
        outputGroup.wait()
        errorGroup.wait()
        parserQueue.sync { }
        processLock.lock()
        if activeProcess === process { activeProcess = nil }
        processLock.unlock()

        if cancelled { throw CodexCLIError.cancelled }
        if timedOut { throw CodexCLIError.timeout(Int(timeout)) }

        let snapshot = parserQueue.sync { parser }
        stderrLock.lock()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        stderrLock.unlock()
        let stderrDetail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = Date().timeIntervalSince(startedAt)
        guard !snapshot.answer.isEmpty else {
            var details = [snapshot.fatalError, snapshot.lastError, stderrDetail.isEmpty ? nil : String(stderrDetail.suffix(500))]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if snapshot.invalidLineCount > 0 {
                details.append("JSONL 无法解析 \(snapshot.invalidLineCount) 行")
            }
            let detail = details.first ?? "事件流里没有 agent_message（事件 \(snapshot.eventCount) 个）"
            if process.terminationStatus != 0 {
                throw CodexCLIError.failed(process.terminationStatus, detail)
            }
            throw CodexCLIError.empty(detail)
        }
        if process.terminationStatus != 0 {
            throw CodexCLIError.failed(process.terminationStatus, "已收到回答，但进程仍以非零退出；stderr：\(stderrDetail.suffix(400))")
        }
        return CodexInvocationResult(
            answer: snapshot.answer,
            answerSegments: snapshot.answerSegments,
            threadID: snapshot.threadID,
            usage: snapshot.usage,
            eventModel: snapshot.eventModel,
            eventProvider: snapshot.eventProvider,
            eventCount: snapshot.eventCount,
            invalidLineCount: snapshot.invalidLineCount,
            elapsed: elapsed
        )
    }

    private func prewarmLocalModel() {
        let helper = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalSiriLLM/local_assistant.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper.path, "--warmup"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self, weak process] _ in
            guard let self, let process else { return }
            self.processLock.lock()
            if self.warmupProcess === process {
                self.warmupProcess = nil
            }
            self.processLock.unlock()
        }

        processLock.lock()
        guard !cancellationRequested else {
            processLock.unlock()
            return
        }
        warmupProcess = process
        processLock.unlock()
        do {
            try process.run()
            if isCancellationRequested(), process.isRunning {
                process.terminate()
            }
        } catch {
            processLock.lock()
            if warmupProcess === process {
                warmupProcess = nil
            }
            processLock.unlock()
        }
    }

    private func prepareSiriSpeech(_ answer: String, audioURL: URL) {
        guard !isCancellationRequested() else {
            logStage("speech-skipped-cancelled")
            return
        }
        let speechText = speechReadyText(answer)
        guard !speechText.isEmpty else {
            finishWithError("没有可播报的内容")
            return
        }
        startSpeech(speechText, isError: false, audioURL: audioURL)
    }

    private func startSpeech(_ speechText: String, isError: Bool, audioURL: URL?) {
        let helper = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalSiriLLM/SiriSpeechHelper.swift")
        guard FileManager.default.fileExists(atPath: helper.path) else {
            state = .finished
                setReadyTouchBar()
            updateStatus("无法完成", detail: "Linfei 语音组件不可用")
            logStage("speech-helper-unavailable")
            return
        }
        state = .speaking
        speakingAudioURL = audioURL
        spokenAnswer = speechText
        speechWasError = isError
        hub?.chatPanel.setSpokenText(speechText)
        logStage("speech-helper-prepare characters=\(speechText.count)")
        updateStatus("正在准备 Siri 语音…", detail: speechText)
        updateTouchBar(
            text: "🔊 准备播放",
            symbol: "speaker.wave.2.fill",
            color: "35,111,96,255"
        )
        updateStatus(isError ? "正在播报错误…" : "正在播放回复…", detail: speechText)
        updateTouchBar(text: "🔊 播放中", symbol: "speaker.wave.2.fill", color: "35,111,96,255")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let voiceIdentifier = try self?.runProcess(
                    "/usr/bin/swift",
                    arguments: [helper.path],
                    input: speechText,
                    timeout: max(30, min(180, Double(speechText.count) * 0.4))
                ).trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let self, !self.isCancellationRequested() else { return }
                self.logStage("speech-helper-finish voice=\(voiceIdentifier)")
                DispatchQueue.main.async { self.completeSpeech() }
            } catch {
                guard let self, !self.isCancellationRequested() else { return }
                self.logStage("speech-helper-error=\(error.localizedDescription.prefix(120))")
                DispatchQueue.main.async {
                    self.state = .finished
                    self.setReadyTouchBar()
                    self.updateStatus("无法完成", detail: "Linfei 语音播放失败")
                }
            }
        }
    }

    private func completeSpeech() {
        guard state == .speaking, !isCancellationRequested() else { return }
        if let speakingAudioURL {
            try? FileManager.default.removeItem(at: speakingAudioURL)
        }
        speakingAudioURL = nil
        state = .finished
        setReadyTouchBar()
        // 中枢常驻：播报结束只回到待机，不退出、不关窗。
        updateStatus(speechWasError ? "无法完成" : "已完成", detail: spokenAnswer)
    }

    private func runProcess(
        _ executable: String,
        arguments: [String],
        input: String? = nil,
        timeout: TimeInterval
    ) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = input == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        if let inputPipe {
            process.standardInput = inputPipe
        }
        try process.run()
        processLock.lock()
        activeProcess = process
        processLock.unlock()
        if isCancellationRequested(), process.isRunning {
            process.terminate()
        }
        if let input, let inputPipe, process.isRunning {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }
        defer {
            processLock.lock()
            if activeProcess === process {
                activeProcess = nil
            }
            processLock.unlock()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw NSError(domain: "LocalModelVoice", code: 5, userInfo: [NSLocalizedDescriptionKey: "处理超时"])
        }
        let stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: stdout, encoding: .utf8) ?? ""
        let errorOutput = String(data: stderr, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "LocalModelVoice",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "子进程执行失败" : String(detail.suffix(400))]
            )
        }
        return output
    }

    private func showConversationError(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = trimmed.isEmpty ? "未知错误（没有错误详情）" : trimmed
        lastAnswerText = "错误：\(visible)"
        hub?.chatPanel.setAnswer(lastAnswerText)
        hub?.chatPanel.setReplayEnabled(false)
        updateStatus("无法完成", detail: visible)
        renderVoicePanel()
        logStage("visible-error=\(String(visible.prefix(500)))")
    }

    private func finishWithError(_ message: String) {
        meterTimer?.invalidate()
        recorder?.stop()
        setReadyTouchBar()
        startSpeech(speechReadyText(message), isError: true, audioURL: audioURL)
    }
}

/// 启动模式：默认只开中枢（不碰麦克风），显式要求才进语音流程。
enum LaunchMode: String {
    case hub
    case voice

    init(arguments: [String]) {
        self = arguments.contains("--voice") ? .voice : .hub
    }

    /// 打开软件落在哪一页。普通启动 = 中枢首页（不碰麦克风）；
    /// 只有 `--voice` 才直接进对话页并开始聆听，避免"一开软件就在录音"的错觉。
    var landingPage: HubWindowController.Page {
        self == .voice ? .voice : .home
    }
}

extension VoiceController {
    /// 验收自检：把「打开就录音」「关掉就退出」「界面看不懂」三个问题变成可重复执行的断言。
    static func hubSelfTest() -> Int32 {
        var failures: [String] = []
        _ = NSApplication.shared

        // 1) 打开软件默认是中枢，绝不自动开麦；只有显式要求才进语音流程。
        if LaunchMode(arguments: []) != .hub {
            failures.append("默认启动必须是中枢模式")
        }
        if LaunchMode(arguments: ["--voice"]) != .voice {
            failures.append("--voice 必须进入语音模式")
        }
        if LaunchMode(arguments: ["--manage"]) != .hub {
            failures.append("--manage 不应进入语音模式")
        }
        if LaunchMode(arguments: []).landingPage != .home {
            failures.append("普通启动必须落在中枢首页，不能一开就停在录音页")
        }
        if LaunchMode(arguments: ["--voice"]).landingPage != .voice {
            failures.append("--voice 必须直接落在对话页")
        }

        // 2) 每个状态都要有能读懂的文案，并且说明下一步能做什么。
        let samples: [(State, String)] = [
            (.finished, "待机"),
            (.preparing, "准备聆听…"),
            (.recording, "正在聆听…"),
            (.processing, "正在本机识别…"),
            (.speaking, "正在播放回复…")
        ]
        for (state, text) in samples {
            let presentation = VoiceController.presentation(for: state, status: text, detail: "说明文字")
            if presentation.headline != text {
                failures.append("状态 \(state) 标题没有跟随状态文案")
            }
            if presentation.primaryTitle.isEmpty || presentation.hint.isEmpty {
                failures.append("状态 \(state) 缺少按钮或说明文字")
            }
        }

        // 3) 录音中必须给红色状态点 + 电平 + 取消；处理中不能让人以为还能再说话。
        let recording = VoiceController.presentation(for: .recording, status: "正在聆听…", detail: "停顿约 2 秒执行")
        if !recording.showsCancel {
            failures.append("录音中必须能取消")
        }
        if !recording.showsMeter {
            failures.append("录音中必须显示麦克风电平")
        }
        if recording.primaryTitle == "开始说话" {
            failures.append("录音中主按钮不能还是「开始说话」")
        }
        let processing = VoiceController.presentation(for: .processing, status: "正在本机识别…", detail: "")
        if processing.primaryEnabled {
            failures.append("处理中不能重复开麦")
        }
        let idle = VoiceController.presentation(for: .finished, status: "已取消", detail: "回到待机")
        if idle.primaryTitle != "开始说话" {
            failures.append("待机主按钮必须是「开始说话」")
        }
        if idle.showsCancel || idle.showsMeter {
            failures.append("待机不应显示取消或电平")
        }

        // 4) 关窗口只是藏起来：返回 false + 窗口不随关闭释放，App 继续待机。
        let hub = HubWindowController()
        guard let window = hub.window else {
            print("hub self-test failed: 中枢窗口未创建")
            return 1
        }
        if hub.windowShouldClose(window) != false {
            failures.append("关窗口必须返回 false（只隐藏，不退出）")
        }
        if window.isVisible {
            failures.append("关窗口后不应仍然可见")
        }
        if window.isReleasedWhenClosed {
            failures.append("中枢窗口不能在关闭时释放，否则打不开第二次")
        }

        // 5) 中枢首页：默认不在录音、有打字入口、说清麦克风策略、能直达其他页。
        let home = HomePanelView()
        if home.introText.isEmpty {
            failures.append("中枢首页顶部必须有一句话说明这个 App 是干什么的")
        }
        if !home.hasTypedInput {
            failures.append("中枢首页必须有打字提问入口，否则看起来只支持语音")
        }
        if !home.canAskTyped {
            failures.append("中枢首页一打开就应该能打字提问")
        }
        if home.voiceButtonTitle.contains("取消") {
            failures.append("空闲时首页按钮必须是「开始说话」，不能默认就在录音")
        }
        if home.capabilityTitles.count < 3 {
            failures.append("中枢首页要列出中枢能做什么，不能只讲语音")
        }
        if !home.micNoteText.contains("麦克风默认关闭") {
            failures.append("首页要写明麦克风默认关闭、关窗口不等于退出")
        }
        home.apply(HomePanelView.Presentation(status: "录音中", detail: "说话", tint: .systemRed, busy: true))
        if home.canAskTyped {
            failures.append("录音中首页不能重复发送")
        }
        if !home.voiceButtonTitle.contains("取消") {
            failures.append("录音中首页按钮要变成「取消本次对话」")
        }
        home.setLastExchange(question: "", answer: "", route: "")
        if !home.introText.contains("中枢") {
            failures.append("首页标题区必须自称「中枢」，别让人以为只会语音")
        }

        // 6) 对话页：要有说明、打字入口、你说的→中枢答的顺序、真实线路回显。
        let panel = ChatPanelView()
        if panel.introText.isEmpty {
            failures.append("对话页顶部必须有一句话说明这个 App 是干什么的")
        }
        if !panel.hasTypedInput {
            failures.append("对话页必须有打字提问入口，否则看起来只支持语音")
        }
        panel.setSendEnabled(false)
        if panel.canSendTypedInput {
            failures.append("处理中不能重复发送打字提问")
        }
        panel.setSendEnabled(true)
        if !panel.canSendTypedInput {
            failures.append("待机时打字提问入口必须可用")
        }
        panel.setTranscript("帮我看看今天该先做什么")
        panel.setAnswer("先做最紧的那件。")
        let sections = panel.sectionTitles
        guard let askIndex = sections.firstIndex(where: { $0 == "你" }),
              let answerIndex = sections.firstIndex(where: { $0 == "中枢" }) else {
            failures.append("对话页必须按「你 → 中枢」分区")
            print(failures.map { "hub self-test failed: \($0)" }.joined(separator: "\n"))
            return 1
        }
        if askIndex >= answerIndex {
            failures.append("「你」必须排在「中枢」前面")
        }
        if !VoiceController.footerText(lastRoute: "").contains("还没有提问过") {
            failures.append("没提问过时页脚不能编造线路")
        }
        // 样例输入也用产品里真会出现的线路名；「云端线路」这个分类名已经从产品里去掉了。
        if !VoiceController.footerText(lastRoute: "本机模型").contains("本机模型") {
            failures.append("页脚必须回显真实走过的线路")
        }

        // 7) 设计稿分页：侧栏顺序、二级页归属、每一页真的建得出来、总览页接上状态机。
        if HubWindowController.Page.sidebarOrder != [.home, .voice, .router, .agents, .jev, .status] {
            failures.append("侧栏顺序必须跟设计稿一致：总览 / 语音助手 / 本地路由 / Agent 管理 / Jev 档位 / 设置与状态")
        }
        if HubWindowController.Page.sidebarOrder.contains(.routerDetail) {
            failures.append("「供应商详情」是本地路由的二级页，不能占侧栏位置")
        }
        for page in HubWindowController.Page.allCases where page != .routerDetail {
            if page.title.isEmpty || page.subtitle.isEmpty || page.symbol.isEmpty {
                failures.append("侧栏项「\(page.title)」缺标题、副标题或图标")
            }
        }
        let routed = HubWindowController()
        for page in HubWindowController.Page.allCases {
            routed.select(page)
            if !routed.isPageBuilt(page) {
                failures.append("切到「\(page.title)」时页面没有建出来（点进去会是空白）")
            }
        }
        if routed.currentPage != HubWindowController.Page.routerDetail {
            failures.append("二级页「供应商详情」必须能真正选中")
        }

        // 8) 总览页（swiftUI）的状态桥：状态机和最近一次对话都要推得进去。
        let overview = HubHomeBridge()
        if overview.introText.isEmpty {
            failures.append("总览页顶部必须有一句话说明这个 App 是干什么的")
        }
        overview.apply(status: "正在聆听…", detail: "说完停约 2 秒自动结束", tint: .red, busy: true)
        if overview.status != "正在聆听…" || !overview.busy || overview.tint != .red {
            failures.append("总览页状态桥没接上：状态/忙碌/颜色没有写进去")
        }
        overview.setLastExchange(question: "帮我看看今天该先做什么", answer: "先做最紧的那件。", route: "本机线路")
        if overview.lastQuestion.isEmpty || overview.lastAnswer.isEmpty || overview.lastRoute != "本机线路" {
            failures.append("总览页没有拿到最近一次对话和真实线路")
        }

        let controller = VoiceController()
        controller.buildHub()
        guard let wiredHub = controller.hub else {
            failures.append("语音控制器没有建出中枢窗口")
            print(failures.map { "hub self-test failed: \($0)" }.joined(separator: "\n"))
            return 1
        }
        if wiredHub.homeBridge.onAsk == nil {
            failures.append("总览页的打字提问入口没有接到语音控制器")
        }
        if wiredHub.homeBridge.onToggleVoice == nil {
            failures.append("总览页的说话入口没有接到语音控制器")
        }
        if wiredHub.homeBridge.onOpenPage == nil {
            failures.append("总览页的跳页入口没有接到语音控制器")
        }
        // 菜单栏快捷面板共用这同一份状态桥，所以它的动作也必须接全。
        if wiredHub.homeBridge.onCancelVoice == nil || wiredHub.homeBridge.onCopyAnswer == nil
            || wiredHub.homeBridge.onReplayAnswer == nil || wiredHub.homeBridge.onRevealSupportDirectory == nil
            || wiredHub.homeBridge.onQuit == nil {
            failures.append("菜单栏快捷面板的动作没有接全（取消 / 复制 / 重播 / 配置目录 / 退出）")
        }
        if let failure = controller.popoverSelfTestFailure() {
            failures.append(failure)
        }
        controller.updateStatus("待机", detail: "自检")
        if wiredHub.homeBridge.status != "待机" || wiredHub.homeBridge.busy {
            failures.append("状态变化没有推进到总览页：新首页会一直停在初始文案")
        }

        // 9) 本地路由按供应商分组：同一供应商的多条线路必须合并成一行，点开才看模型。
        let sameSupplier = [
            HubModel.Connection(id: "a", name: "Codex Router · DeepSeek V4 Flash (API)", baseURL: "http://x",
                                apiKey: "", wireAPI: "chat_completions", timeout: 120, kind: "",
                                models: [HubModel.Model(id: "m1", model: "deepseek/flash", rank: nil)],
                                catalog: [], enabled: true, healthOK: true, latencyMS: 60,
                                healthError: "", statsLabel: "", isLocal: false, source: "dsh:codex-router"),
            HubModel.Connection(id: "b", name: "Codex Router · GPT-6 Sol", baseURL: "http://x",
                                apiKey: "", wireAPI: "chat_completions", timeout: 120, kind: "",
                                models: [HubModel.Model(id: "m2", model: "gpt-6-sol", rank: nil)],
                                catalog: [], enabled: true, healthOK: true, latencyMS: 90,
                                healthError: "", statsLabel: "", isLocal: false, source: "dsh:codex-router"),
            HubModel.Connection(id: "c", name: "DSH", baseURL: "http://y",
                                apiKey: "", wireAPI: "chat_completions", timeout: 120, kind: "",
                                models: [], catalog: [], enabled: true, healthOK: false, latencyMS: 0,
                                healthError: "连不上", statsLabel: "", isLocal: true, source: ""),
        ]
        if HubModel.supplierName(for: sameSupplier[0]) != "Codex Router" {
            failures.append("「Codex Router · X」必须归到供应商「Codex Router」，否则同一家会被拆成很多行")
        }
        if HubModel.supplierName(for: sameSupplier[2]) != "DSH" {
            failures.append("没有中点的名字要原样作为供应商名")
        }
        let grouped = HubModel.supplierGroups(of: sameSupplier)
        if grouped.count != 2 {
            failures.append("3 条线路应归成 2 个供应商，实际 \(grouped.count) 个")
        }
        if let router = grouped.first(where: { $0.name == "Codex Router" }) {
            if router.connections.count != 2 {
                failures.append("Codex Router 下应挂 2 条线路，实际 \(router.connections.count) 条")
            }
            if router.modelCount != 2 {
                failures.append("Codex Router 展开后应有 2 个模型，实际 \(router.modelCount) 个")
            }
            if router.latencyMS != 90 {
                failures.append("供应商延迟应取组内最慢线路 90ms，实际 \(router.latencyMS.map(String.init) ?? "nil")")
            }
        } else {
            failures.append("分组结果里找不到 Codex Router")
        }
        if let dsh = grouped.first(where: { $0.name == "DSH" }), !dsh.isLocal {
            failures.append("DSH 必须被标记成本地线路")
        }

        // 10) Agent 页：客户端要从本地路由模型池里取模型，不能凭空编。
        let assignments = HubModel.assignedModelIDs(
            agentID: "codex",
            agentName: "Codex",
            currentModel: "gpt-6-sol",
            agentProviderIDs: ["m1"],
            pool: sameSupplier.flatMap { $0.models }
        )
        if !assignments.contains("m1") {
            failures.append("Agent 已绑定的线路必须算作「已添加」")
        }
        if !assignments.contains("m2") {
            failures.append("客户端配置里当前写着的模型也要算作「已添加」")
        }
        if assignments.contains("m9") {
            failures.append("没有绑定的模型不能算作已添加")
        }
        let emptyPool = HubModel.assignedModelIDs(
            agentID: "codex", agentName: "Codex", currentModel: nil,
            agentProviderIDs: [], pool: []
        )
        if !emptyPool.isEmpty {
            failures.append("模型池为空时不能凭空给出已添加模型")
        }

        // 11) 全局提示只有一份，且不许遮住任何内容：默认收起（高度 0）、展开把页面推下去、关掉收回 0 高。
        let noticeHub = HubWindowController()
        if !noticeHub.isNoticeWired {
            failures.append("数据层的通知没接到窗口横幅：提示将无处显示（或页面各画一份，同一句话出现两次）")
        }
        noticeHub.window?.contentView?.layoutSubtreeIfNeeded()
        let restingNotice = noticeHub.noticeBannerState()
        if !restingNotice.text.isEmpty {
            failures.append("刚打开窗口时横幅不该已经有内容")
        }
        if restingNotice.height != 0 {
            failures.append("没有提示时横幅必须收起成 0 高，否则内容列顶部会空出一条带（实际 \(restingNotice.height)pt）")
        }
        noticeHub.showNotice(text: "已取消：客户端配置一个字都没改", ok: false)
        noticeHub.window?.contentView?.layoutSubtreeIfNeeded()
        let shownNotice = noticeHub.noticeBannerState()
        if shownNotice.text.isEmpty || shownNotice.height <= 0 {
            failures.append("提示没有真的展出来（高度 \(shownNotice.height)pt），用户看不到刚才发生了什么")
        }
        if let inset = noticeHub.currentPageTopInset(), inset < shownNotice.height {
            failures.append("横幅展开时页面要被推下去，不能压在页面上（页面顶边只让出 \(inset)pt）")
        }
        noticeHub.showNotice(text: nil, ok: true)
        noticeHub.window?.contentView?.layoutSubtreeIfNeeded()
        if noticeHub.noticeBannerState().height != 0 {
            failures.append("关掉提示后横幅要收回 0 高，让页面重新占满")
        }
        // 没人点「关闭」的时候，横幅必须自己走掉：否则它会一直把每页顶部顶下去一截。
        noticeHub.showNotice(text: "已保存 Jev 四档映射", ok: true)
        noticeHub.window?.contentView?.layoutSubtreeIfNeeded()
        if noticeHub.noticeBannerState().height <= 0 {
            failures.append("提示没展出来，后面的自动收起就无从验证")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(hubNoticeLifetime + 0.5))
        noticeHub.window?.contentView?.layoutSubtreeIfNeeded()
        if noticeHub.noticeBannerState().height != 0 {
            failures.append("横幅没有自己收起：没人点「关闭」时它会一直挂在页面上面")
        }

        // 12) 「统一网关」写入前必须过确认：拒绝就等于一个字都不改，策略也不许变成网关。
        if !noticeHub.hasGatewayConfirmWired {
            failures.append("统一网关写入前必须有确认钩子，否则会不经同意就改别人的客户端配置")
        }
        let refusing = HubModel()
        refusing.presentGatewayConfirm = { _ in false }
        refusing.applyStrategy(.gateway)
        let refusingHasWritableTarget = HubStrategySync.gatewayTargets().contains { target in
            target.isWritable && refusing.clientSpecs.contains {
                $0.editable
                    && HubStrategySync.client(id: $0.id, name: $0.name, path: $0.path) == target.client
            }
        }
        if refusingHasWritableTarget {
            if refusing.strategy == .gateway {
                failures.append("确认被拒绝时策略不能显示成「统一网关」——那表示配置没改却报成改了")
            }
        } else if refusing.strategy != .gateway {
            failures.append("没有可写 4230 Agent 时应进入空目标接管态，而不是报切换失败")
        }
        let mixed = HubModel.gatewayWriteNotice(
            [
                HubStrategySync.Outcome(client: .codex, fileURL: URL(fileURLWithPath: "/tmp/a"),
                                        ok: true, baseURL: "http://127.0.0.1:8317",
                                        backupName: "config.toml.bak", message: ""),
                HubStrategySync.Outcome(client: .zcode, fileURL: URL(fileURLWithPath: "/tmp/b"),
                                        ok: false, baseURL: nil, backupName: nil, message: "脚本退出码 1"),
            ],
            baseURL: "http://127.0.0.1:8317"
        )
        if mixed.text.contains("\n") {
            failures.append("统一网关的结果必须是横幅里的一条文本，不能带换行（横幅只有一行）")
        }
        if !mixed.text.contains("http://127.0.0.1:8317") {
            failures.append("统一网关的结果要回显真实网关地址")
        }
        if !mixed.text.contains("config.toml.bak") {
            failures.append("写入成功要报出真实备份文件名，否则用户没法回滚")
        }
        if mixed.ok {
            failures.append("有客户端没写成功时整条提示必须是失败态，不能报成成功")
        }

        // 13) 「统一网关」这道闸门：只有网关真在监听，才谈得上改别人的客户端配置。
        //     两个方向都要验——
        //       · 有人在听：闸门不许误杀，得一路走到确认框；这里用「拒绝确认」收尾，保证自检自己一个字都不写；
        //       · 没人听：预览和确认框都不该出现，还要说清「连不上 + 下一步」，且绝不写盘。
        //     做法 = 用临时 router.json 把端口分别指向「刚开出来的监听」和「刚关掉的端口」，
        //     期间真实客户端配置只读比对；presentGatewayConfirm 一律回 false 兜底。
        func openListener() -> (fd: Int32, port: Int)? {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0                       // 0 = 让内核挑一个空闲端口
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafePointer(to: &address) { pointer in
                // 必须写全 `Darwin.bind`：视图层里同名的 bind 会把裸名字抢走。
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
            }
            // backlog 必须给足：这道自检里的监听口没人 accept，全靠内核的 accept 队列接着探活。
            // 实测 backlog=1 时，同一个 socket 上的第 2、3 次探活会直接吃到 ECONNREFUSED，
            // 于是一个真在听的端口会被判成「没人听」——自检自己把自己搞红。
            guard bound == 0, listen(fd, 128) == 0 else { close(fd); return nil }
            var actual = sockaddr_in()
            var actualSize = size
            let named = withUnsafeMutablePointer(to: &actual) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &actualSize) }
            }
            guard named == 0 else { close(fd); return nil }
            return (fd, Int(UInt16(bigEndian: actual.sin_port)))
        }

        /// 探活是「连一下就关」，这条自检里没人主动 accept 它；光把 backlog 调大只是抬高上限，
        /// 真网关是会把连接收下的。所以起一个后台线程收一个关一个，让探活次数不再有上限。
        func drainIncoming(fd: Int32) {
            Thread.detachNewThread {
                while true {
                    let connection = accept(fd, nil, nil)
                    if connection < 0 { return }     // 监听口关掉后 accept 会报错，线程就此退出
                    close(connection)
                }
            }
        }

        /// 自检里的流程是异步的，只能在自己的 runloop 上等它落地。
        func pump(_ finished: () -> Bool, seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while !finished(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }

        /// 造一份只属于这次自检的 router.json（网关端口指到 port），再让 HubModel 从它读设置。
        /// 端口必须写进文件、不能只靠环境：HubModel 的端口是 refresh() 从 router.json 里读出来的。
        func probeModel(port: Int) -> HubModel? {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("hub-gateway-probe-\(UUID().uuidString)", isDirectory: true)
            let config = directory.appendingPathComponent("router.json")
            let payload: [String: Any] = [
                "version": 1, "connections": [], "providers": [], "agents": [],
                "gateway": ["enabled": true, "host": "127.0.0.1", "port": port, "agent_id": "omni"],
            ]
            guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
                  let data = try? JSONSerialization.data(withJSONObject: payload),
                  (try? data.write(to: config)) != nil
            else { return nil }
            // 必须在 HubModel() 之前设：RouterStore 在 init 时就定下了 router.json 的路径。
            setenv("LOCAL_SIRI_ROUTER_CONFIG", config.path, 1)
            let model = HubModel()
            model.refresh()
            return model
        }

        /// 方向一：有人在听 → 闸门必须放行到确认框。用「拒绝确认」收尾，所以自检全程不写盘。
        func gatewayLiveCase(port: Int) {
            guard let model = probeModel(port: port) else {
                failures.append("写不出临时 router.json：网关在听时「必须走到确认框」没被验证")
                return
            }
            var offered: HubStrategySync.WritePrompt?
            var notice: String?
            model.onNotice = { text, _ in notice = text }
            model.presentGatewayConfirm = { prompt in offered = prompt; return false }
            model.applyStrategy(.gateway)
            pump({ offered != nil || notice != nil }, seconds: 30)

            let hasWritableTarget = HubStrategySync.gatewayTargets().contains { target in
                target.isWritable && model.clientSpecs.contains {
                    $0.editable
                        && HubStrategySync.client(id: $0.id, name: $0.name, path: $0.path) == target.client
                }
            }
            if !hasWritableTarget {
                if offered != nil || model.strategy != .gateway
                    || !(notice ?? "").contains("当前没有已授权的 4230 Agent") {
                    failures.append("没有可写 4230 Agent 时不应弹写入确认或报错")
                }
                return
            }

            if let text = notice, text.contains("连不上") {
                failures.append("\(port) 上明明有人监听却被判成连不上：这道闸门会把能用的网关挡在外面（说：\(text)）")
            }
            guard let prompt = offered else {
                failures.append(
                    "网关 \(port) 在听，确认框却没弹出来（提示：\(notice ?? "什么都没说")）："
                        + "正常流程被误杀，后面「拒绝就不写」也无从验证"
                )
                return
            }
            let present = HubStrategySync.gatewayTargets()
            if prompt.targets.count != present.count {
                failures.append(
                    "确认框要如实列出将被写入的客户端配置，实际列了 \(prompt.targets.count) 份，本机有 \(present.count) 份"
                )
            }
            if let base = prompt.baseURL, !base.contains(":\(port)") {
                failures.append("确认框要说清指向哪个网关，实际写的是 \(base)")
            }
            if notice != "已取消：客户端配置一个字都没改" {
                failures.append("拒绝确认后要明确报「一个字都没改」，实际说：\(notice ?? "什么都没说")")
            }
            if model.strategy == .gateway {
                failures.append("确认被拒绝时策略不能显示成「统一网关」：配置没改却报成改了")
            }
            if model.isBusy("strategy") {
                failures.append("拒绝确认后还卡在「进行中」：按钮会一直转圈，像还在配置")
            }
        }

        /// 方向二：没人听 → 一个字都不写，还要说清「连不上 + 下一步」。
        func gatewayDeadCase(port: Int) {
            guard let model = probeModel(port: port) else {
                failures.append("写不出临时 router.json：网关没人听时「一个字都不写」没被验证")
                return
            }
            var confirmShown = false
            var notice: String?
            model.onNotice = { text, _ in notice = text }
            // 万一闸门漏了，这个钩子也只回 false：自检期间绝不允许真的改客户端配置。
            model.presentGatewayConfirm = { _ in confirmShown = true; return false }
            model.applyStrategy(.gateway)
            pump({ notice != nil }, seconds: 20)

            let hasWritableTarget = HubStrategySync.gatewayTargets().contains { target in
                target.isWritable && model.clientSpecs.contains {
                    $0.editable
                        && HubStrategySync.client(id: $0.id, name: $0.name, path: $0.path) == target.client
                }
            }
            if !hasWritableTarget {
                if confirmShown || model.strategy != .gateway
                    || !(notice ?? "").contains("当前没有已授权的 4230 Agent") {
                    failures.append("没有可写 4230 Agent 时死网关也应保持空目标接管态")
                }
                return
            }

            if confirmShown {
                failures.append("网关 \(port) 上没人监听却弹了确认框：等于邀请用户切向一条不存在的链路")
            }
            if model.strategy == .gateway {
                failures.append("网关连不上却把策略显示成「统一网关」：配置没改却报成改了")
            }
            if model.isBusy("strategy") {
                failures.append("被闸门挡住后还卡在「进行中」：按钮会一直转圈，像还在配置")
            }
            guard let text = notice else {
                failures.append("网关连不上时静悄悄地什么都没说：用户只看到按钮弹回来，不知道链路是死的")
                return
            }
            if text.contains("\n") {
                failures.append("网关连不上的原因要能进横幅，不能带换行")
            }
            if !text.contains("127.0.0.1:\(port)") {
                failures.append("被闸门挡住时要报出真实网关地址，实际说：\(text)")
            }
            if !text.contains("启动") {
                failures.append("光说连不上没用，得给出下一步（启动网关），实际说：\(text)")
            }
        }

        // 探活得两个方向都对：认得出「有人在听」，也认得出「没人听」。
        var livePort = 0
        if let live = openListener() {
            livePort = live.port
            drainIncoming(fd: live.fd)         // 留着不关：方向一需要一个真有人听的端口
            if !HubStrategySync.isListening(host: "127.0.0.1", port: livePort) {
                failures.append("探活没认出本机正在监听的端口 \(livePort)：它大概只会一律报「不通」")
            }
        } else {
            failures.append("开不出本地监听端口：没法验证「有人在听」和「没人听」这两个方向")
        }
        var deadPort = 0
        if let spare = openListener() {
            deadPort = spare.port              // 刚被内核判为空闲，随即关掉 = 确定没人听
            close(spare.fd)
            if HubStrategySync.isListening(host: "127.0.0.1", port: deadPort) {
                failures.append("刚关掉的端口 \(deadPort) 还有人应答：这条用例的前提不成立")
            }
        }
        // 这个监听口故意不关：drainIncoming 的线程正阻塞在 accept 上，关掉它会让线程去 accept
        // 一个可能已被复用的 fd 号。自检跑完就 exit()，不会把端口带进常驻态。

        var clientBytes: [URL: Data?] = [:]
        for target in HubStrategySync.targets() { clientBytes[target.fileURL] = try? Data(contentsOf: target.fileURL) }

        var missing: [String] = []
        if livePort <= 0 { missing.append("开不出一个正在监听的本地端口") }
        if deadPort <= 0 { missing.append("造不出一个确定没人监听的本地端口") }
        if RouterStore.scriptURL == nil { missing.append("找不到 unified_router.py") }
        if clientBytes.isEmpty { missing.append("本机没有 Codex / ZCode 的配置可写") }
        if !missing.isEmpty {
            failures.append("网关闸门的前提凑不齐（" + missing.joined(separator: "；") + "）：这道闸门没被验证")
        } else {
            let previousEnv = ProcessInfo.processInfo.environment["LOCAL_SIRI_ROUTER_CONFIG"]
            gatewayLiveCase(port: livePort)
            gatewayDeadCase(port: deadPort)
            if let previousEnv {
                setenv("LOCAL_SIRI_ROUTER_CONFIG", previousEnv, 1)
            } else {
                unsetenv("LOCAL_SIRI_ROUTER_CONFIG")
            }
            for (url, before) in clientBytes where (try? Data(contentsOf: url)) != before {
                failures.append("客户端配置 \(url.lastPathComponent) 被动了：这道闸门没挡住写入")
            }
        }
        // 13) ③ 线路台账：页面上那几个数字和按钮真正会做的事必须同源；默认那一下也不能顺手把
        //     Agent 侧 / 内部线路收进来（这两类要先问过用户）。这一段只读 router.json，
        //     真正写盘的演练留给 --router-self-test。
        let ledger = HubModel()
        ledger.refresh()
        let pooledCount = ledger.routeLines.filter { $0.state == .pooled }.count
        print("③ 台账 \(ledger.routeLines.count) 行：池内 \(pooledCount) · 可收编 \(ledger.adoptableLines.count)"
              + " · 已归属未进池 \(ledger.boundNotPooledLines.count) · 内部线路 \(ledger.internalLines.count)"
              + " · Agent 侧 \(ledger.agentSideLines.count) · 引用缺口 \(ledger.danglingLines.count)")
        if ledger.routeLines.isEmpty {
            failures.append("③ 台账一行都没读到：router.json 的线路没被审计出来")
        }
        for line in ledger.routeLines where line.reason.isEmpty {
            failures.append("③ 线路「\(line.displayName)」被归成「\(line.state.title)」却没说为什么，用户没法判断")
        }
        for line in ledger.adoptableLines where line.model.isEmpty || HubModel.isEmptyAddress(line.baseURL) {
            failures.append("③ 把没有模型名或没有地址的行（\(line.id)）标成了「可收编」，收编会造出走不通的连接")
        }

        // 方案里有两道合法的筛子（网关回执判死、同一个模型只留一条），所以它会比「可动行数」少收几行。
        // 判据因此不是「条数相等」，而是**每一行都有交代**：要么在方案里，要么被点名跳过，且跳过的理由站得住。
        func auditPlanCoverage(_ plan: HubModel.AdoptionPlan, scope: [HubModel.RouteLine], label: String) {
            let rows = scope.filter(\.awaitsAdoption)
            let plannedIDs = Set(plan.connections.flatMap(\.modelIDs))
            let dropped = rows.filter { !plannedIDs.contains($0.id) }
            let explained = plan.receiptExcluded.count + plan.duplicateLines.count
            if dropped.count != explained {
                failures.append("\(label) 有 \(dropped.count) 行没进方案，方案只交代了 \(explained) 行：多半是静悄悄丢了一行")
            }
            for row in dropped {
                let named = plan.receiptExcluded.contains(row.displayName)
                    || plan.duplicateLines.contains(row.displayName)
                if !named {
                    failures.append("\(label) 把「\(row.displayName)」放到方案外，却没说为什么")
                    continue
                }
                // 两条能站住的理由，二选一：网关真有判死的回执，或同模型的另一条已经进了方案。
                let receiptDead = HubReceiptLedger.shared.receipt(for: row.id)?.excludesFromAutoPick == true
                let twinInPlan = !row.model.isEmpty && rows.contains {
                    $0.id != row.id && plannedIDs.contains($0.id)
                        && $0.model.lowercased() == row.model.lowercased()
                }
                if !receiptDead && !twinInPlan {
                    failures.append("\(label) 跳过「\(row.displayName)」，理由站不住："
                        + "网关没说它不会好，也没有同名行进了方案")
                }
            }
        }

        let defaultPlan = ledger.planAdoption()
        auditPlanCoverage(defaultPlan, scope: ledger.adoptableLines, label: "③ 一键收编")
        if defaultPlan.connections.reduce(0, { $0 + $1.modelIDs.count }) != defaultPlan.lineCount {
            failures.append("③ 收编方案里连接覆盖的行数和总条数对不上，会有线路收不进去或被重复改")
        }
        for item in defaultPlan.connections where item.name.isEmpty {
            failures.append("③ 收编会造出没名字的连接")
        }
        // 收编新建的连接，地址要么空着（一批线路各有各的地址，写盘时逐条自带），
        // 要么是条真能用的地址；只打了空格 / 换行等于没写，不能当成「有地址」。
        for item in defaultPlan.connections where !item.baseURL.isEmpty && HubModel.isEmptyAddress(item.baseURL) {
            failures.append("③ 收编会把「只打了空白」的地址写进连接「\(item.name)」：这条连接发不出去")
        }
        let optInIDs = Set(ledger.internalLines.map(\.id) + ledger.agentSideLines.map(\.id))
        if !Set(defaultPlan.connections.flatMap(\.modelIDs)).isDisjoint(with: optInIDs) {
            failures.append("③ 默认那一下动了 Agent 侧 / 内部线路：这两类必须先经用户确认")
        }
        let widePlan = ledger.planAdoption(HubModel.AdoptionSelection(includeAgentSide: true, includeInternal: true))
        auditPlanCoverage(widePlan,
                          scope: ledger.adoptableLines + ledger.agentSideLines + ledger.internalLines,
                          label: "③ 确认后收编 Agent 侧 / 内部线路")
        for id in ledger.adoptedConnectionIDs where !ledger.connections.contains(where: { $0.id == id }) {
            failures.append("③ 还原清单里带着 router.json 里已经不存在的连接 \(id)：还原会去删一个没有的东西")
        }
        // 14) 地址只有一份算法：台账每行显示的地址，必须和「真正会被用来发请求」的那条一致。
        //     行里写了就用行里的（并说清它盖住了连接上的），行里没写才借连接的 —— 不能两处各说各话。
        // 三堆必须正好盖住全部行：「行里写了」「借连接的」「两处都没写」。
        // 「行里盖住连接的」是行里写了、连接里也有，地址以行里为准，单独点一句免得用户以为连接那份没生效。
        let writingOwn = ledger.routeLines.filter { !HubModel.isEmptyAddress($0.baseURL) }
        let borrowing = ledger.routeLines.filter {
            HubModel.isEmptyAddress($0.baseURL) && !HubModel.isEmptyAddress($0.connectionAddress)
        }
        let overriding = ledger.routeLines.filter {
            !HubModel.isEmptyAddress($0.baseURL) && !HubModel.isEmptyAddress($0.connectionAddress)
        }
        let addressless = ledger.linesWithoutAddress
        if writingOwn.count + borrowing.count + addressless.count != ledger.routeLines.count {
            failures.append("③ 地址统计三堆加起来 \(writingOwn.count + borrowing.count + addressless.count) "
                            + "行，台账却有 \(ledger.routeLines.count) 行：账对不上")
        }
        print("③ 地址 \(ledger.routeLines.count) 行：行里自己写了 \(writingOwn.count)"
              + " · 借连接的 \(borrowing.count) · 两处都没写 \(addressless.count)"
              + " · 行里盖住连接的 \(overriding.count)"
              + " · 要修 \(ledger.addressRepair.connections.count + ledger.addressRepair.lines.count) 处")
        for line in ledger.routeLines {
            let fact = ledger.addressFact(providerID: line.id, connectionID: line.connectionID)
            // 台账那格显示的是文件里的原文；网关真正会用的那条由 cleanedAddress 算。
            // 两条路必须同源，否则用户看到的地址和实际请求的地址会不一样。
            let shown = HubModel.cleanedAddress(line.effectiveAddress)
            if shown != fact.effective {
                failures.append("③ 线路「\(line.displayName)」台账那格会显示 \(shown.isEmpty ? "（空）" : shown)"
                                + "，地址算法算出来的是 \(fact.effective.isEmpty ? "（空）" : fact.effective)：两处各说各话")
            }
            if HubModel.addressDefect(line.effectiveAddress) == nil, fact.effective != line.effectiveAddress {
                failures.append("③ 线路「\(line.displayName)」的地址没毛病，算法却把 \(line.effectiveAddress) 换成了 \(fact.effective)")
            }
            // 来源说明要和取值同向：行里有地址就不能说成人话的「借」，行里没地址就得点名归属连接。
            if fact.fromLine, !line.addressOrigin.contains("自己写") {
                failures.append("③ 线路「\(line.displayName)」用的是行里的地址，来源却写成「\(line.addressOrigin)」")
            }
            if !fact.fromLine, fact.fromConnection {
                let owner = line.ownerName.isEmpty ? line.connectionID : line.ownerName
                if !line.addressOrigin.contains(owner) {
                    failures.append("③ 线路「\(line.displayName)」借的是连接「\(owner)」的地址，来源说明里没点名它："
                                    + "「\(line.addressOrigin)」")
                }
            }
        }
        // 两处都没写地址：只有「池内 / 可收编」这类真要发请求的行才算缺口。
        // Agent 侧和内部线路本来就不走网关地址，非模型行也不进模型池，列出来是为了说明白，不算错。
        let addressGaps = addressless.filter { $0.state == .pooled || $0.state == .adoptable }
        for line in addressGaps {
            failures.append("③ 线路「\(line.displayName)」是「\(line.state.title)」，却两处都没写地址：发请求时没有地址可用")
        }
        if !addressless.isEmpty {
            let byState = Dictionary(grouping: addressless, by: { $0.state.title })
                .map { "\($0.key) \($0.value.count)" }
                .sorted()
                .joined(separator: " / ")
            print("③ 两处都没写地址的 \(addressless.count) 行（其中真要发请求的 \(addressGaps.count) 行）：\(byState)")
        }
        // 对话框的毛病说明必须来自这份清单本身，不能写死成「重复粘贴」。
        let repairDefects = (ledger.addressRepair.connections.map { HubModel.addressDefect($0.from) }
                             + ledger.addressRepair.lines.map { HubModel.addressDefect($0.from) }).compactMap { $0 }
        for defect in Set(repairDefects) where !ledger.addressRepair.defectSummary.contains(defect) {
            failures.append("③ 修地址说明没点出要修的毛病：「\(defect)」不在「\(ledger.addressRepair.defectSummary)」里")
        }
        var repairSeen: Set<String> = []
        for fix in ledger.addressRepair.connections {
            if HubModel.addressDefect(fix.from) == nil {
                failures.append("③ 连接「\(fix.name)」地址没毛病却被列进修地址清单：一键修会白动一次写盘")
            }
            if fix.to.isEmpty || fix.to == fix.from {
                failures.append("③ 修地址没有真正改变「\(fix.name)」的地址，点一下只会多一次备份")
            }
            if !fix.from.contains(fix.to) {
                failures.append("③ 连接「\(fix.name)」的修法是重写 URL 而不是收拢原文，会改掉用户填的地址")
            }
            if !repairSeen.insert("c:\(fix.id)").inserted {
                failures.append("③ 同一连接 \(fix.id) 在修地址清单里出现了两次")
            }
        }
        for fix in ledger.addressRepair.lines {
            if HubModel.addressDefect(fix.from) == nil {
                failures.append("③ 线路「\(fix.id)」地址没毛病却被列进修地址清单")
            }
            if fix.to.isEmpty || fix.to == fix.from {
                failures.append("③ 修地址没有真正改变线路「\(fix.id)」的地址")
            }
            if !fix.from.contains(fix.to) {
                failures.append("③ 线路「\(fix.id)」的修法是重写 URL 而不是收拢原文")
            }
            if !repairSeen.insert("l:\(fix.id)").inserted {
                failures.append("③ 同一线路 \(fix.id) 在修地址清单里出现了两次")
            }
        }
        // 影响面要和地址算法同源：改一条连接的地址会连带所有「借它地址」的行，数错了用户就不知道会动到谁。
        for fix in ledger.addressRepair.connections {
            let dependents = ledger.linesDependingOnAddress(of: fix.id)
            let borrowed = ledger.routeLines.filter { line in
                line.connectionID == fix.id
                    && !ledger.addressFact(providerID: line.id, connectionID: line.connectionID).fromLine
            }.count
            if dependents != borrowed {
                failures.append("③ 连接「\(fix.name)」的影响面说 \(dependents) 条，实际借它地址的是 \(borrowed) 条")
            }
        }

        // 空白地址 / 多行地址 / 借连接地址：这三条规则要各走各的路，还得和网关算法同源。
        // 用纯函数 auditRouteLines 造行，不读不写任何文件，也就碰不到用户真实的 router.json。
        let addressFixture = HubModel.auditRouteLines(
            providers: [
                ["id": "blank-with-owner", "name": "空白地址 + 有连接", "model": "blank-a",
                 "kind": "openai_compatible", "source": "manual", "base_url": "   ",
                 "connection_id": "owner-1"],
                ["id": "blank-alone", "name": "空白地址 + 没连接", "model": "blank-b",
                 "kind": "openai_compatible", "source": "manual", "base_url": "  \n "],
                ["id": "duplicated-address", "name": "粘贴了两遍的地址", "model": "blank-c",
                 "kind": "openai_compatible", "source": "manual",
                 "base_url": "https://paste.example/v1\nhttps://paste.example/v1"],
            ],
            connections: [["id": "owner-1", "name": "有地址的连接",
                           "kind": "openai_compatible", "source": "manual",
                           "base_url": "https://owner.example/v1"]],
            pooledProviderIDs: [])
        let borrowed = addressFixture.first { $0.id == "blank-with-owner" }
        if borrowed?.effectiveAddress != "https://owner.example/v1" {
            failures.append("③ 地址只打了空白的行该借连接的地址，台账却要显示「\(borrowed?.effectiveAddress ?? "（读不到）")」")
        }
        if let borrowed, HubModel.isEmptyAddress(borrowed.effectiveAddress) {
            failures.append("③ 借到了连接地址的行被算成「两处都没写地址」：用户会去补一个不缺口的地方")
        }
        if let borrowed, !borrowed.addressOrigin.contains("有地址的连接") {
            failures.append("③ 借连接地址的行没说清地址是谁给的：「\(borrowed.addressOrigin)」")
        }
        let blankAlone = addressFixture.first { $0.id == "blank-alone" }
        if blankAlone?.state == .adoptable {
            failures.append("③ 地址只有空白的行被标成「可收编」：收编会造出一条没地址的连接")
        }
        if let blankAlone, !HubModel.isEmptyAddress(blankAlone.effectiveAddress) {
            failures.append("③ 地址只有空白的行没被算成缺地址，用户补不到点上")
        }
        let duplicated = addressFixture.first { $0.id == "duplicated-address" }
        if duplicated?.effectiveAddress.split(separator: "\n").first.map(String.init) != "https://paste.example/v1" {
            failures.append("③ 粘贴了两遍的地址，台账第一行（也就是网关真正发请求那条）不是 https://paste.example/v1")
        }
        if let defect = duplicated?.addressDefect {
            if !defect.contains("第一条") {
                failures.append("③ 粘贴了两遍的地址没把「网关只用第一条」说清楚：「\(defect)」")
            }
        } else {
            failures.append("③ 粘贴了两遍的地址没被标成要修")
        }
        // 空白地址是「没写」，不是「要修」：一字之差会让人去修一个根本不缺的地方。
        if HubModel.addressDefect("   ") != nil {
            failures.append("③ 只打了空格的地址被当成要修：该算没写，不该让用户去点修地址")
        }
        if HubModel.addressDefect("https://ok.example/v1") != nil {
            failures.append("③ 正常地址被当成要修：一键修会白动一次写盘")
        }
        if HubModel.cleanedAddress("  https://keep.example/v1  ") != "https://keep.example/v1" {
            failures.append("③ 去掉首尾空格时改动了 URL 本体：收编和修地址都不能重写地址")
        }
        if failures.filter({ $0.contains("空白") || $0.contains("两遍") }).isEmpty {
            print("③ 地址规则：空白算没写（借连接 / 自己归缺地址）· 多行用第一行并标要修")
        }

        guard failures.isEmpty else {
            failures.forEach { print("hub self-test failed: \($0)") }
            return 1
        }
        print("hub self-test passed")
        return 0
    }
}

extension VoiceController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = Date()
    }
}

@main
struct LocalModelVoiceMain {
    static func main() {
        if CommandLine.arguments.contains("--touchbar-state-self-test") {
            precondition(automaticStopSilence == 2.0)
            precondition(minimumRecordingDuration == 0.8)
            precondition(voicePowerThreshold == -50)
            precondition(touchBarStage(for: "🔴 说话中") == "recording")
            precondition(touchBarStage(for: "📝 识别中") == "recognizing")
            precondition(touchBarStage(for: "🧭 本地判断中") == "thinking")
            // 回答阶段跑的是本机 CLI：版本号有就带、读不到就不写那一项；
            // 「云端思考中」不许再映射到任何 stage（映射过就说明假话回来了）。
            precondition(touchBarStage(for: VoiceController.runningPillText(version: "0.155.1")) == "thinking")
            precondition(touchBarStage(for: VoiceController.runningPillText(version: nil)) == "thinking")
            precondition(touchBarStage(for: "☁️ 云端思考中") == nil)
            precondition(touchBarStage(for: "🔊 准备播放") == "preparing_speech")
            precondition(touchBarStage(for: "🔊 播放中") == "speaking")
            precondition(touchBarStage(for: "🎙 点击说话") == nil)
            print("touchbar-state self-test passed")
        } else if CommandLine.arguments.contains("--speech-text-self-test") {
            precondition(speechReadyText("**结论**\n- 查看 https://example.com\n- 已完成") == "结论。查看 链接。已完成。")
            precondition(speechReadyText("你好") == "你好。")
            print("speech text self-test passed")
        } else if CommandLine.arguments.contains("--sync-codex-catalog") {
            let result = HubCodexCatalogSync.sync(routerURL: RouterStore.defaultConfigURL)
            print(result.message)
            if let backupURL = result.backupURL {
                print("备份：\(backupURL.path)")
            }
            exit(result.ok ? 0 : 1)
        } else if CommandLine.arguments.contains("--hub-audit") {
            // 只读自检：算 ①②③④ 打印出来，不写盘。
            //   --hub-audit            只看
            //   --hub-audit --adopt    按当前范围收编（写前先备份；LOCAL_SIRI_AUDIT_SCOPE=all 走全部范围）
            //   --hub-audit --restore  还原上次收编
            //   --hub-audit verify     只打印验收断言，失败返回非零退出码
            let arguments = CommandLine.arguments
            if arguments.contains("verify") {
                let result = HubModel.auditVerify()
                print(result.text)
                exit(result.ok ? 0 : 1)
            }
            print(HubModel.auditReport(adopt: arguments.contains("--adopt"),
                                       restore: arguments.contains("--restore")))
            exit(0)
        } else if CommandLine.arguments.contains("--hub-self-test") {
            exit(VoiceController.hubSelfTest())
        } else if CommandLine.arguments.contains("--codex-stream-self-test") {
            exit(CodexStreamSelfTest.run())
        } else {
            let application = NSApplication.shared
            applicationController = VoiceController()
            application.delegate = applicationController
            // 中枢是常驻应用：要有 Dock 图标和菜单栏，关窗口不等于退出。
            application.setActivationPolicy(.regular)
            application.run()
        }
    }
}
