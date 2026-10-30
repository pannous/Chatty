import AVFoundation

/// Records one spoken question as AAC/M4A and stops by itself once the speaker falls silent.
/// Returns nil when nobody spoke within `noSpeechTimeout`.
@MainActor final class VoiceRecorder {
    private static let sampleRate = 16_000.0
    private static let speechThresholdDecibels: Float = -40
    private static let meteringInterval = Duration.milliseconds(100)
    private static let silenceToStop = Duration.milliseconds(1_200)
    private static let noSpeechTimeout = Duration.seconds(5)
    private static let maximumLength = Duration.seconds(30)

    private var recorder: AVAudioRecorder?

    func record() async throws -> URL? {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw AssistantError(message: "Microphone access denied: allow it in Settings › Privacy › Microphone")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("question.m4a")
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw AssistantError(message: "Recording could not start") }
        self.recorder = recorder
        defer {
            recorder.stop()
            self.recorder = nil
        }
        return try await waitForEndOfSpeech(recorder) ? url : nil
    }

    func stop() {
        recorder?.stop()
    }

    /// Returns whether any speech was heard.
    private func waitForEndOfSpeech(_ recorder: AVAudioRecorder) async throws -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        var heardSpeech = false
        var silenceStart: ContinuousClock.Instant?
        while recorder.isRecording {
            try await Task.sleep(for: Self.meteringInterval)
            recorder.updateMeters()
            let now = clock.now
            if recorder.averagePower(forChannel: 0) > Self.speechThresholdDecibels {
                heardSpeech = true
                silenceStart = nil
            } else if heardSpeech {
                let silenceBegan = silenceStart ?? now
                silenceStart = silenceBegan
                if now - silenceBegan >= Self.silenceToStop { return true }
            }
            if !heardSpeech && now - start >= Self.noSpeechTimeout { return false }
            if now - start >= Self.maximumLength { return true }
        }
        return heardSpeech
    }
}
