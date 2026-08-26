@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

@MainActor
final class SpeechInputController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: Task<Void, Never>?
    private var tapInstalled = false

    func requestPermissions() async -> Bool {
        let speechStatus = await Self.speechAuthorizationStatus()
        guard speechStatus == .authorized else {
            errorMessage = "请允许语音识别权限"
            return false
        }
        let microphoneAllowed = await Self.microphoneAuthorizationStatus()
        if !microphoneAllowed { errorMessage = "请允许麦克风权限" }
        return microphoneAllowed
    }

    nonisolated private static func speechAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    nonisolated private static func microphoneAuthorizationStatus() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    func toggle() async {
        if isRecording {
            stop()
        } else {
            await start()
        }
    }

    func start() async {
        guard await requestPermissions() else { return }
        stop()
        transcript = ""
        errorMessage = nil

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "语音识别不可用"
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        Self.installAudioTap(on: input, format: format, request: request)
        tapInstalled = true

        let stream = Self.makeRecognitionStream(recognizer: recognizer, request: request)
        recognitionTask = Task { [weak self] in
            do {
                for try await result in stream {
                    guard let self else { return }
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.stop()
                        return
                    }
                }
            } catch {
                guard let self else { return }
                self.errorMessage = error.localizedDescription
                self.stop()
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            if tapInstalled {
                input.removeTap(onBus: 0)
                tapInstalled = false
            }
            errorMessage = error.localizedDescription
            isRecording = false
        }
    }

    nonisolated private static func makeRecognitionStream(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest
    ) -> AsyncThrowingStream<SFSpeechRecognitionResult, Error> {
        AsyncThrowingStream { continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    continuation.yield(result)
                    if result.isFinal {
                        continuation.finish()
                    }
                } else if let error {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    nonisolated private static func installAudioTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    func stop() {
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
