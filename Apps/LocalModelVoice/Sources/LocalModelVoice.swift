import AppKit
import AVFoundation

private var applicationController: VoiceController?

private let automaticStopSilence: TimeInterval = 2.0
private let minimumRecordingDuration: TimeInterval = 0.8
private let voicePowerThreshold: Float = -50

private func touchBarStage(for text: String) -> String? {
    switch text {
    case "🔴 说话中": return "recording"
    case "📝 识别中": return "recognizing"
    case "🧭 本地判断中", "☁️ 云端思考中": return "thinking"
    case "🔊 准备播放": return "preparing_speech"
    case "🔊 播放中": return "speaking"
    default: return nil
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

final class VoiceController: NSObject, NSApplicationDelegate, AVAudioRecorderDelegate {
    private struct LocalDecision: Decodable {
        let route: String
        let answer: String?
        let reason: String?
    }

    private struct CloudProvider: Decodable {
        let name: String
        let executable: String
        let arguments: [String]
        let timeoutSeconds: Double

        private enum CodingKeys: String, CodingKey {
            case name, executable, arguments
            case timeoutSeconds = "timeout_seconds"
        }
    }

    private enum State {
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
    private var window: NSPanel!
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var stopRequestTimer: Timer?
    private var detectedVoice = false
    private var voiceFrameCount = 0
    private var recordingStartedAt = Date.distantPast
    private var lastVoiceAt = Date.distantPast
    private var audioURL: URL?
    private var state = State.preparing
    private var activeProcess: Process?
    private var warmupProcess: Process?
    private var speakingAudioURL: URL?
    private var spokenAnswer = ""
    private var speechWasError = false
    private var cancellationRequested = false
    private var interactionStarted = false

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
        try? FileManager.default.removeItem(at: runtimeLogURL)
        logStage("launch version=2.1.0 build=22")
        try? FileManager.default.removeItem(at: stopRequestURL)
        try? String(ProcessInfo.processInfo.processIdentifier)
            .write(to: runtimePIDURL, atomically: true, encoding: .utf8)
        buildWindow()
        stopRequestTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.checkStopRequest()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let query = debugQuery() {
            runDebugQuery(query)
            return
        }

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
            finishWithError("请在“隐私与安全性 → 麦克风”中允许“本地模型”")
        }
    }

    private func debugQuery() -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--debug-query"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private func runDebugQuery(_ query: String) {
        state = .processing
        updateStatus("正在诊断模型与语音…", detail: "跳过录音和 Whisper")
        logStage("debug-query start characters=\(query.count)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let answer = try self?.askModel(query) ?? ""
                guard let self, !self.isCancellationRequested() else { return }
                self.logStage("model-answer characters=\(answer.count)")
                self.logStage("speech-dispatch")
                DispatchQueue.main.async {
                    self.logStage("speech-closure")
                    self.prepareSiriSpeech(
                        answer,
                        audioURL: FileManager.default.temporaryDirectory.appendingPathComponent("local-siri-debug.wav")
                    )
                }
            } catch {
                self?.logStage("debug-query error=\(error.localizedDescription.prefix(120))")
                DispatchQueue.main.async { self?.finishWithError(error.localizedDescription) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRequestTimer?.invalidate()
        terminateChildProcesses()
        try? FileManager.default.removeItem(at: runtimePIDURL)
        try? FileManager.default.removeItem(at: stopRequestURL)
        try? FileManager.default.removeItem(at: touchBarStateURL)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if interactionStarted {
            logStage("reopen-cancel")
            handleToggle()
        } else {
            logStage("reopen-ignored-before-interaction")
        }
        return true
    }

    private func handleToggle() {
        switch state {
        case .preparing, .recording, .processing, .speaking:
            cancelCurrentWork()
        case .finished:
            break
        }
    }

    private func cancelCurrentWork() {
        logStage("cancel")
        state = .finished
        interactionStarted = false
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
        stopRequestTimer?.invalidate()
        stopRequestTimer = nil
        recorder?.stop()
        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        try? FileManager.default.removeItem(at: stopRequestURL)
        spinner.stopAnimation(nil)
        setReadyTouchBar()
        updateStatus("已取消", detail: "当前语音指令已停止")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSApp.terminate(nil)
        }
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

    private func buildWindow() {
        let size = NSSize(width: 430, height: 150)
        window = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "本地模型"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        window.contentView = effect

        spinner = NSProgressIndicator(frame: NSRect(x: 30, y: 61, width: 28, height: 28))
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        effect.addSubview(spinner)

        statusLabel = NSTextField(labelWithString: "正在启动…")
        statusLabel.frame = NSRect(x: 78, y: 76, width: 325, height: 28)
        statusLabel.font = .systemFont(ofSize: 21, weight: .semibold)
        statusLabel.textColor = .labelColor
        effect.addSubview(statusLabel)

        detailLabel = NSTextField(labelWithString: "语音在本机处理，复杂问题可升级到云端")
        detailLabel.frame = NSRect(x: 78, y: 46, width: 325, height: 24)
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        effect.addSubview(detailLabel)
    }

    private func updateStatus(_ status: String, detail: String) {
        statusLabel.stringValue = status
        detailLabel.stringValue = detail
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
        interactionStarted = true
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

    private func startRecording() {
        guard state == .preparing else { return }
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
        let now = Date()
        if recorder.averagePower(forChannel: 0) > voicePowerThreshold {
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
                    self?.prepareSiriSpeech(answer, audioURL: audioURL)
                }
            } catch {
                try? FileManager.default.removeItem(at: audioURL)
                guard self?.isCancellationRequested() == false else { return }
                DispatchQueue.main.async {
                    self?.finishWithError(error.localizedDescription)
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
            return try askCloudModel(query, reason: "本地判断不可用，自动使用云端")
        }
        if decision.route == "local", let answer = decision.answer, !answer.isEmpty {
            return answer
        }
        if decision.route == "cloud" {
            return try askCloudModel(query, reason: decision.reason ?? "本地模型请求升级")
        }
        return try askCloudModel(query, reason: "本地模型返回了无效分流结果")
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
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalSiriLLM/cloud-provider.json")
        let provider = try JSONDecoder().decode(CloudProvider.self, from: Data(contentsOf: configURL))
        guard provider.executable.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: provider.executable) else {
            throw NSError(
                domain: "LocalModelVoice",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "云端模型命令不可用"]
            )
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateStatus("正在请求云端模型…", detail: "\(provider.name)：\(reason)")
            self?.updateTouchBar(
                text: "☁️ 云端思考中",
                symbol: "cloud.fill",
                color: "40,92,150,255"
            )
        }

        let prompt = """
        你是本地语音助手按需调用的上级云端模型。请直接回答用户，不讨论分流过程。
        默认使用简体中文，先给结论，使用自然口语，不用 Markdown；通常控制在 180 个汉字内，确有必要最多 500 个汉字，以便语音播报。
        需要当前事实时主动联网核实。当前为只读问答：不要修改本机文件、发送消息、付款或执行会改变外部状态的操作；若用户要求实际操作，说明需要在有确认机制的任务中执行。

        用户原话：\(query)
        """
        let output = try runProcess(
            provider.executable,
            arguments: provider.arguments,
            input: prompt,
            timeout: provider.timeoutSeconds
        )
        let cleaned = output
            .replacingOccurrences(of: "```.*?```", with: "代码内容已省略。", options: [.regularExpression])
            .replacingOccurrences(of: "[*_#`>|]", with: "", options: [.regularExpression])
            .replacingOccurrences(of: "\\s+", with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(1_200))
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
            interactionStarted = false
            setReadyTouchBar()
            updateStatus("无法完成", detail: "Linfei 语音组件不可用")
            logStage("speech-helper-unavailable")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { NSApp.terminate(nil) }
            return
        }
        state = .speaking
        speakingAudioURL = audioURL
        spokenAnswer = speechText
        speechWasError = isError
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
                    self.interactionStarted = false
                    self.setReadyTouchBar()
                    self.updateStatus("无法完成", detail: "Linfei 语音播放失败")
                    NSApp.terminate(nil)
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
        interactionStarted = false
        stopRequestTimer?.invalidate()
        stopRequestTimer = nil
        setReadyTouchBar()
        updateStatus(speechWasError ? "无法完成" : "已完成", detail: spokenAnswer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSApp.terminate(nil)
        }
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

    private func finishWithError(_ message: String) {
        meterTimer?.invalidate()
        recorder?.stop()
        spinner.stopAnimation(nil)
        setReadyTouchBar()
        startSpeech(speechReadyText(message), isError: true, audioURL: audioURL)
    }
}

if CommandLine.arguments.contains("--touchbar-state-self-test") {
    precondition(automaticStopSilence == 2.0)
    precondition(minimumRecordingDuration == 0.8)
    precondition(voicePowerThreshold == -50)
    precondition(touchBarStage(for: "🔴 说话中") == "recording")
    precondition(touchBarStage(for: "📝 识别中") == "recognizing")
    precondition(touchBarStage(for: "🧭 本地判断中") == "thinking")
    precondition(touchBarStage(for: "☁️ 云端思考中") == "thinking")
    precondition(touchBarStage(for: "🔊 准备播放") == "preparing_speech")
    precondition(touchBarStage(for: "🔊 播放中") == "speaking")
    precondition(touchBarStage(for: "🎙 点击说话") == nil)
    print("touchbar-state self-test passed")
} else if CommandLine.arguments.contains("--speech-text-self-test") {
    precondition(speechReadyText("**结论**\n- 查看 https://example.com\n- 已完成") == "结论。查看 链接。已完成。")
    precondition(speechReadyText("你好") == "你好。")
    print("speech text self-test passed")
} else {
    let application = NSApplication.shared
    applicationController = VoiceController()
    application.delegate = applicationController
    application.setActivationPolicy(.accessory)
    application.run()
}
