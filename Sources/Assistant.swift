import AVFoundation
import Observation

/// A conversation of voice turns: listen → transcribe → stream the reply → speak each sentence as soon as it is complete.
/// It keeps listening while the app is on screen; when the screen goes off it finishes the answer and pauses.
@MainActor @Observable final class Assistant {
    enum Phase: String {
        case idle = "Tap to talk"
        case listening = "Listening…"
        case transcribing = "Transcribing…"
        case thinking = "Thinking…"
        case answering = "Answering…"
        case speaking = "Speaking…"
    }

    static let shared = Assistant()

    private(set) var phase = Phase.idle
    private(set) var transcript = ""
    private(set) var reply = ""

    @ObservationIgnored private let recorder = VoiceRecorder()
    @ObservationIgnored private let player = SpeechPlayer()
    @ObservationIgnored private var previousResponseID: String?
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var isConversing = false
    @ObservationIgnored private let wakeKeeper = WakeKeeper()
    /// Set by the view from the scene phase: off screen, the assistant stops listening once it has finished speaking.
    @ObservationIgnored var isOnScreen = true
    /// Launch arguments for headless tests: `-audioFile <m4a>` replaces the microphone, `-muted YES` silences playback.
    @ObservationIgnored private let testAudioFile = UserDefaults.standard.string(forKey: "audioFile").map(URL.init(fileURLWithPath:))

    private init() {
        player.muted = UserDefaults.standard.bool(forKey: "muted")
    }

    func setVolume(_ volume: Double) {
        player.volume = volume
    }

    /// Starts a new conversation; interrupts whatever is being recorded or spoken.
    func converse() {
        turnTask?.cancel()
        recorder.stop()
        player.stop()
        isConversing = true
        phase = .listening // green right away, before the microphone is actually running
        wakeKeeper.keepAwake()
        turnTask = Task {
            var isFollowUp = false
            while await runTurn(isFollowUp: isFollowUp) { isFollowUp = true }
            trace("Chatty: conversation ended")
            // a cancelled conversation was replaced by a new one, which still needs the watch awake
            if !Task.isCancelled { isConversing = false }
        }
    }

    /// Opening the app or raising the wrist starts listening, unless Siri or the Crown already did.
    func converseIfIdle() {
        guard !isConversing else { return }
        converse()
    }

    /// Chatty left the screen for good (another app, the watch face): let the watch sleep normally.
    func leftApp() {
        wakeKeeper.allowSleep()
    }

    /// A tap pauses listening; in any other phase (paused, thinking, speaking) it listens right away.
    func toggleListening() {
        if phase == .listening { pauseIfListening() } else { converse() }
    }

    /// The screen went off: stop listening right away, but let an answer that is under way finish.
    func pauseIfListening() {
        guard phase == .listening || phase == .idle else { return }
        turnTask?.cancel()
        recorder.stop()
        isConversing = false
        phase = .idle
        trace("Chatty: paused")
    }

    /// Returns whether the conversation goes on.
    private func runTurn(isFollowUp: Bool) async -> Bool {
        guard isOnScreen else {
            phase = .idle
            return false
        }
        do {
            let client = try OpenAIClient.fromBundle()
            try activateAudioSession()
            phase = .listening
            trace("Chatty: listening\(isFollowUp ? " for follow-up" : "")")
            // the test file stands in for the first question only; follow-ups use the microphone
            let audioFile = if let testAudioFile, !isFollowUp { testAudioFile } else { try await recorder.record() }
            guard let audioFile else { return true } // nobody spoke: keep listening
            phase = .transcribing
            transcript = try await client.transcribe(audioFile: audioFile)
            trace("Chatty: transcript: \(self.transcript)")
            try Task.checkCancellation()
            phase = .thinking
            reply = ""
            try player.start()
            try await streamAndSpeakReply(client)
            player.finishAnswer()
            await player.waitUntilDrained()
            return true
        } catch is CancellationError {
            return false
        } catch {
            trace("Chatty: error: \(error.localizedDescription)")
            phase = .idle
            return false
        }
    }

    private func streamAndSpeakReply(_ client: OpenAIClient) async throws {
        let started = ContinuousClock.now
        let (sentences, sentenceSink) = AsyncStream.makeStream(of: String.self)
        let speaker = Task { try await speak(sentences, with: client, startedAt: started) }
        try await withTaskCancellationHandler {
            var splitter = SentenceSplitter()
            for try await event in client.streamReply(to: transcript, previousResponseID: previousResponseID) {
                switch event {
                case .textDelta(let delta):
                    if phase == .thinking { phase = .answering }
                    reply += delta
                    splitter.append(delta).forEach { sentenceSink.yield($0) }
                case .completed(let responseID):
                    previousResponseID = responseID
                }
            }
            if let rest = splitter.finish() { sentenceSink.yield(rest) }
            sentenceSink.finish()
            trace("Chatty: reply: \(self.reply)")
            try await speaker.value
        } onCancel: {
            speaker.cancel()
        }
    }

    private func speak(_ sentences: AsyncStream<String>, with client: OpenAIClient, startedAt started: ContinuousClock.Instant) async throws {
        var spokenBytes = 0
        for await sentence in sentences {
            for try await chunk in client.streamSpeech(of: sentence) {
                if spokenBytes == 0 {
                    phase = .speaking
                    trace("Chatty: first audio after \(String(describing: ContinuousClock.now - started))")
                }
                spokenBytes += chunk.count
                player.enqueue(pcm16: chunk)
            }
        }
        trace("Chatty: spoke \(spokenBytes) bytes")
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // watchOS keeps record-and-play sessions on the built-in speaker unless Bluetooth HFP is allowed;
        // with it, answers play on connected AirPods (and their microphone records the question)
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
        try session.setActive(true)
        // watchOS has no API to pick an output port (setPreferredInput is unavailable), so only record the route
        trace("Chatty: output \(session.currentRoute.outputs.map(\.portName))")
    }
}
