import Foundation

struct LocalCommandInterpreter: Sendable {
    private struct OllamaRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct Options: Encodable {
            let numCtx: Int
            let numPredict: Int
            let temperature: Double
            let topP: Double

            enum CodingKeys: String, CodingKey {
                case numCtx = "num_ctx"
                case numPredict = "num_predict"
                case temperature
                case topP = "top_p"
            }
        }

        let model: String
        let messages: [Message]
        let stream: Bool
        let format: String?
        let keepAlive: String
        let think: Bool?
        let options: Options?

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, format, think, options
            case keepAlive = "keep_alive"
        }

        init(
            model: String,
            messages: [Message],
            stream: Bool,
            format: String?,
            keepAlive: String,
            think: Bool? = nil,
            options: Options? = nil
        ) {
            self.model = model
            self.messages = messages
            self.stream = stream
            self.format = format
            self.keepAlive = keepAlive
            self.think = think
            self.options = options
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(messages, forKey: .messages)
            try container.encode(stream, forKey: .stream)
            try container.encodeIfPresent(format, forKey: .format)
            try container.encode(keepAlive, forKey: .keepAlive)
            try container.encodeIfPresent(think, forKey: .think)
            try container.encodeIfPresent(options, forKey: .options)
        }
    }

    private struct OllamaResponse: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }

    private let endpoint = URL(string: "http://127.0.0.1:11434/api/chat")!
    private let model = "local-siri-qwen:latest"

    func interpret(_ text: String, providers: [RemoteProviderSummary]) async -> LocalIntent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return LocalIntent(
                action: .unknown,
                prompt: nil,
                providerName: nil,
                confidence: 1,
                explanation: "指令为空"
            )
        }

        if let deterministic = deterministicIntent(trimmed, providers: providers) {
            return deterministic
        }

        // 手机端会话内只和 Codex 账号沟通；不再用本地模型做指令分类（避免卡顿），
        // 其余内容一律作为 Codex prompt 直发。本地模型聊天走独立的 chat() 入口。
        return .directPrompt(trimmed)

        // 以下为旧的本地模型分类逻辑，保留供参考（不可达）。
        /*
        let providerNames = providers.map(\.name).joined(separator: "、")
        let system = """
        你是 Bar Control 的本地指令分类器。只做分类，不执行命令。
        允许动作：prompt、steer、stop、switchProvider、listProviders、status、unknown。
        可用 Codex 供应商：\(providerNames.isEmpty ? "无" : providerNames)。
        用户明确要求切换账号、供应商或模型来源时才使用 switchProvider，并把 providerName 写成可用供应商的完整名称。
        普通编程、提问、改代码、继续任务都使用 prompt；正在执行任务时追加要求可以使用 steer。
        不要生成 shell 命令，不要猜测供应商，不要输出 JSON 以外的内容。
        JSON 字段固定为 action、prompt、providerName、confidence、explanation。
        """
        let request = OllamaRequest(
            model: model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: trimmed)
            ],
            stream: false,
            format: "json",
            keepAlive: "2m"
        )

        do {
            var urlRequest = URLRequest(url: endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = 30
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(request)
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .directPrompt(trimmed)
            }
            let payload = try JSONDecoder().decode(OllamaResponse.self, from: data)
            let json = Self.extractJSONObject(payload.message.content)
            var intent = try JSONDecoder().decode(LocalIntent.self, from: Data(json.utf8))
            if intent.action == .switchProvider {
                guard let provider = resolveProvider(intent.providerName, providers: providers) else {
                    return LocalIntent(
                        action: .unknown,
                        prompt: nil,
                        providerName: intent.providerName,
                        confidence: intent.confidence,
                        explanation: "没有找到对应供应商"
                    )
                }
                intent = LocalIntent(
                    action: .switchProvider,
                    prompt: nil,
                    providerName: provider.name,
                    confidence: intent.confidence,
                    explanation: intent.explanation
                )
            }
            return intent
        } catch {
            return .directPrompt(trimmed)
        }
        */
    }

    /// 直接和本地 Ollama 模型聊天（手机端“本地模型”入口使用）。
    func chat(_ text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let system = """
        你是通过 Ollama 在用户 Mac 上运行的本地 AI 助手。用中文简洁回答；\
        涉及代码时给出可以直接使用的代码。你只运行在本机，不连接 Codex 账号或网络。
        """
        let request = OllamaRequest(
            model: model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: trimmed)
            ],
            stream: false,
            format: nil,
            keepAlive: "10m",
            think: false,
            options: .init(
                numCtx: 4096,
                numPredict: 256,
                temperature: 0.2,
                topP: 0.9
            )
        )
        do {
            var urlRequest = URLRequest(url: endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = 90
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(request)
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return "" }
            let payload = try JSONDecoder().decode(OllamaResponse.self, from: data)
            return payload.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    /// 列出本机 Ollama 已安装的模型（用于选择本地聊天模型，不硬编码某个模型）。
    func availableModels() async -> [String] {
        guard let tagsURL = URL(string: "http://127.0.0.1:11434/api/tags") else { return [] }
        var urlRequest = URLRequest(url: tagsURL)
        urlRequest.timeoutInterval = 5
        guard
            let (data, response) = try? await URLSession.shared.data(for: urlRequest),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = object["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
    }

    /// 流式调用本地 Ollama，逐块产出文本（手机端本地聊天用，避免等整段生成完才显示）。
    func chatStream(_ text: String, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    continuation.finish()
                    return
                }
                let system = """
                你是通过 Ollama 在用户 Mac 上运行的本地 AI 助手。用中文简洁回答；\
                涉及代码时给出可以直接使用的代码。你只运行在本机，不连接 Codex 账号或网络。
                """
                let request = OllamaRequest(
                    model: model,
                    messages: [
                        .init(role: "system", content: system),
                        .init(role: "user", content: trimmed)
                    ],
                    stream: true,
                    format: nil,
                    keepAlive: "10m",
                    think: false,
                    options: .init(
                        numCtx: 4096,
                        numPredict: 256,
                        temperature: 0.2,
                        topP: 0.9
                    )
                )
                do {
                    var urlRequest = URLRequest(url: endpoint)
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = 180
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.httpBody = try JSONEncoder().encode(request)
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        continuation.finish(throwing: OllamaError.httpStatus)
                        return
                    }
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        if let content = (object["message"] as? [String: Any])?["content"] as? String,
                           !content.isEmpty {
                            continuation.yield(content)
                        }
                        if (object["done"] as? Bool) == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum OllamaError: LocalizedError {
        case httpStatus
        var errorDescription: String? { "Ollama 返回了非 200 状态" }
    }

    private func deterministicIntent(
        _ text: String,
        providers: [RemoteProviderSummary]
    ) -> LocalIntent? {
        let normalized = text.lowercased()
        if ["停止当前任务", "停止任务", "取消当前任务", "停止 codex", "stop codex"].contains(where: normalized.contains) {
            return LocalIntent(
                action: .stop,
                prompt: nil,
                providerName: nil,
                confidence: 1,
                explanation: "停止当前 Codex turn"
            )
        }
        if ["有哪些账号", "有哪些供应商", "列出账号", "列出供应商"].contains(where: normalized.contains) {
            return LocalIntent(
                action: .listProviders,
                prompt: nil,
                providerName: nil,
                confidence: 1,
                explanation: "读取 CC Switch 供应商"
            )
        }
        let requestsSwitch = normalized.contains("切换") || normalized.contains("换到") || normalized.contains("改用")
        if requestsSwitch, let provider = resolveProvider(text, providers: providers) {
            return LocalIntent(
                action: .switchProvider,
                prompt: nil,
                providerName: provider.name,
                confidence: 1,
                explanation: "匹配到 CC Switch 供应商"
            )
        }
        if normalized == "状态" || normalized.contains("codex 状态") || normalized.contains("codex状态") {
            return LocalIntent(
                action: .status,
                prompt: nil,
                providerName: nil,
                confidence: 1,
                explanation: "读取远程控制状态"
            )
        }
        return nil
    }

    private func resolveProvider(
        _ candidate: String?,
        providers: [RemoteProviderSummary]
    ) -> RemoteProviderSummary? {
        guard let candidate else { return nil }
        let normalized = candidate.lowercased().replacingOccurrences(of: " ", with: "")
        return providers.first { provider in
            let name = provider.name.lowercased().replacingOccurrences(of: " ", with: "")
            return normalized.contains(name) || name.contains(normalized)
        }
    }

    private static func extractJSONObject(_ content: String) -> String {
        guard
            let start = content.firstIndex(of: "{"),
            let end = content.lastIndex(of: "}")
        else { return content }
        return String(content[start...end])
    }
}
