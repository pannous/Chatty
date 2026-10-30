import AVFoundation
import Observation
import os

/// A conversation of voice turns. Preferably speech-to-speech over the Realtime API (`RealtimeSession`);
/// if that fails, classic turns: listen → transcribe → stream the reply → speak each sentence as soon as it is complete.
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
    private static let routeActivationTimeout: TimeInterval = 6 // leaves time to choose in the device picker

    private(set) var phase = Phase.idle
    private(set) var transcript = ""
    private(set) var reply = ""

    @ObservationIgnored private let recorder = VoiceRecorder()
    @ObservationIgnored private let player = SpeechPlayer()
    @ObservationIgnored private var previousResponseID: String?
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var isConversing = false
    @ObservationIgnored private let wakeKeeper = WakeKeeper()
    @ObservationIgnored private var answerIsLongForm = false
    @ObservationIgnored private var headphonesDeclined = false
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
            let realtimeHandledIt = testAudioFile == nil ? await runRealtimeConversation() : false
            if !realtimeHandledIt {
                var isFollowUp = false
                while await runTurn(isFollowUp: isFollowUp) { isFollowUp = true }
                trace("Chatty: conversation ended")
            }
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
            await routeAnswerToHeadphones()
            try player.start()
            try await streamAndSpeakReply(client)
            player.enqueueTrailingSilence()
            await player.waitUntilDrained()
            try restoreRecordingRoute()
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

    /// Returns false when the Realtime API is unusable, so the caller falls back to classic turns.
    private func runRealtimeConversation() async -> Bool {
        let session: RealtimeSession
        do {
            let client = try OpenAIClient.fromBundle()
            try activateAudioSession()
            try player.start()
            session = RealtimeSession(apiKey: client.apiKey)
        } catch {
            return fail(error)
        }
        func listen() {
            guard isOnScreen else { return session.close() }
            session.setMicrophoneOpen(true)
            phase = .listening
        }
        var speechStopped = ContinuousClock.now
        do {
            try await withTaskCancellationHandler {
                for try await event in session.events() {
                    switch event {
                    case .ready:
                        trace("Chatty: realtime listening")
                        try session.startMicrophone()
                        listen()
                    case .speechStarted:
                        transcript = ""
                        reply = ""
                    case .speechStopped:
                        session.setMicrophoneOpen(false) // half duplex: the watch speaker would echo into the microphone
                        speechStopped = .now
                        phase = .thinking
                        await routeAnswerToHeadphones()
                    case .transcript(let text):
                        transcript = text
                        trace("Chatty: transcript: \(text)")
                    case .replyDelta(let delta):
                        if phase == .thinking { phase = .answering }
                        reply += delta
                    case .audio(let pcm):
                        if phase != .speaking {
                            phase = .speaking
                            trace("Chatty: realtime first audio after \(String(describing: ContinuousClock.now - speechStopped))")
                        }
                        player.enqueue(pcm16: pcm)
                    case .replyDone:
                        trace("Chatty: reply: \(self.reply)")
                        player.enqueueTrailingSilence()
                        await player.waitUntilDrained()
                        if try restoreRecordingRoute() { try session.restartMicrophone() }
                        listen()
                    }
                }
            } onCancel: {
                session.close()
            }
        } catch {
            return fail(error)
        }
        session.close()
        phase = .idle
        trace("Chatty: conversation ended")
        return true
    }

    private func fail(_ error: Error) -> Bool {
        if Task.isCancelled { return true }
        trace("Chatty: realtime failed: \(error.localizedDescription)")
        return false
    }

    /// Answers play like a podcast (long-form route). The first time watchOS shows its device picker; afterwards it
    /// reconnects the chosen AirPods by itself. Cancelling the picker keeps answers on the speaker until the app restarts.
    private func routeAnswerToHeadphones() async {
        guard !headphonesDeclined else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            answerIsLongForm = await Self.activate(session, within: Self.routeActivationTimeout)
        } catch {
            trace("Chatty: long-form route failed: \(error.localizedDescription)")
        }
        if !answerIsLongForm {
            headphonesDeclined = true
            do {
                // the failed long-form attempt leaves the session inactive ("Resource not available" on the next start)
                try? session.setActive(false)
                try activateAudioSession()
            } catch {
                trace("Chatty: restoring the speaker route failed: \(error.localizedDescription)")
            }
        }
        trace("Chatty: answer output \(session.currentRoute.outputs.map(\.portName))")
        do { try player.restart() } catch { trace("Chatty: player restart failed: \(error.localizedDescription)") } // a category change stops the engine
    }

    /// `activate` can wait indefinitely (for the device picker, or a route that never comes up);
    /// past the timeout the answer goes to the speaker instead of hanging the conversation.
    private static func activate(_ session: AVAudioSession, within timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool, String) -> Void = { activated, outcome in
                guard resumed.withLock({ wasResumed in defer { wasResumed = true }; return !wasResumed }) else { return }
                trace("Chatty: long-form activation \(outcome)")
                continuation.resume(returning: activated)
            }
            session.activate(options: []) { activated, error in
                finish(activated, activated ? "succeeded" : "failed: \(error?.localizedDescription ?? "declined")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false, "timed out") }
        }
    }

    /// Returns whether the route changed back, which stops any running microphone engine.
    @discardableResult private func restoreRecordingRoute() throws -> Bool {
        guard answerIsLongForm else { return false }
        answerIsLongForm = false
        try activateAudioSession()
        return true
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // watchOS keeps record-and-play sessions on the built-in speaker unless Bluetooth HFP is allowed;
        // with it, answers play on connected AirPods (and their microphone records the question)
        // policy .default explicitly: after a long-form attempt the session keeps that policy, which rejects record-and-play (-50)
        try session.setCategory(.playAndRecord, mode: .default, policy: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
        try session.setActive(true)
        // watchOS has no API to pick an output port (setPreferredInput is unavailable), so only record the route
        trace("Chatty: output \(session.currentRoute.outputs.map(\.portName))")
    }
}
