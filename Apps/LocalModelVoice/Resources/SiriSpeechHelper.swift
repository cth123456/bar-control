import AVFoundation
import Foundation

final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var finished = false
    var succeeded = false

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        succeeded = true
        finished = true
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finished = true
    }
}

let text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
guard !text.isEmpty else { exit(2) }

let identifiers = [
    "com.apple.ttsbundle.gryphon-neural_Linfei_zh-CN_premium",
    "com.apple.siri.natural.Linfei",
]
let voice = identifiers.lazy.compactMap(AVSpeechSynthesisVoice.init(identifier:)).first
guard let voice else { exit(3) }

let delegate = SpeechDelegate()
let synthesizer = AVSpeechSynthesizer()
synthesizer.delegate = delegate
let utterance = AVSpeechUtterance(string: text)
utterance.voice = voice
utterance.rate = 0.48
utterance.pitchMultiplier = 1.0
utterance.preUtteranceDelay = 0.05
synthesizer.speak(utterance)

let deadline = Date().addingTimeInterval(max(30, min(180, Double(text.count) * 0.35)))
while !delegate.finished && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
guard delegate.finished, delegate.succeeded else { exit(4) }
print(voice.identifier)
