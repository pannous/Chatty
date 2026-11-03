import AVFoundation

/// Plays 16-bit PCM chunks gaplessly as they stream in. Playback starts only once `prebufferSeconds` are queued and
/// pauses to refill whenever the queue runs dry mid-answer, so a slow connection gives one pause instead of stutter.
/// Audio route changes stop the engine silently (and with it every queued buffer), so it restarts on demand
/// and a drain wait gives up once the queued audio should long have finished.
@MainActor final class SpeechPlayer {
    private static let drainGraceSeconds = 2.0
    private static let prebufferSeconds = 1.0
    /// Volume 0…1 maps linearly onto this gain range; beyond 0 dB it boosts above the system volume (clipping loud peaks).
    private static let gainRangeDecibels: ClosedRange<Float> = -24...12
    static let unityVolume = Double(-gainRangeDecibels.lowerBound / (gainRangeDecibels.upperBound - gainRangeDecibels.lowerBound))

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: OpenAIConfig.speechSampleRate, channels: 1, interleaved: false)!
    private var queuedBuffers = 0
    private var queuedSeconds = 0.0 // scheduled, not yet played
    private var answerIsComplete = false // nothing more will come: play out whatever is queued
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    var muted = false
    /// Turning down acts at once on the player; boosting has to scale the samples, so it applies to audio queued afterwards.
    var volume = unityVolume {
        didSet { applyPlayerVolume() }
    }
    private var gain: Float {
        let range = Self.gainRangeDecibels
        return pow(10, (range.lowerBound + Float(volume) * (range.upperBound - range.lowerBound)) / 20)
    }

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineWasReconfigured() }
        }
    }

    func start() throws {
        if !engine.isRunning { try engine.start() }
        applyPlayerVolume()
        playIfBuffered()
    }

    func enqueue(pcm16 data: Data) {
        if !engine.isRunning {
            do { try start() } catch { trace("Chatty: player could not start: \(error.localizedDescription)") }
        }
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = buffer.floatChannelData![0]
        let scale = max(1, gain) / Float(Int16.max)
        data.withUnsafeBytes { raw in
            for frame in 0..<frameCount {
                let sample = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: frame * 2, as: Int16.self))) * scale
                samples[frame] = min(1, max(-1, sample))
            }
        }
        let seconds = Double(frameCount) / format.sampleRate
        queuedBuffers += 1
        queuedSeconds += seconds
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferFinished(seconds: seconds) }
        }
        playIfBuffered()
    }

    private func playIfBuffered() {
        guard engine.isRunning, !player.isPlaying, queuedBuffers > 0,
              answerIsComplete || queuedSeconds >= Self.prebufferSeconds else { return }
        player.play()
    }

    /// Nothing more comes for this answer: play out what is queued even if it is less than the prebuffer.
    func finishAnswer() {
        answerIsComplete = queuedBuffers > 0
        playIfBuffered()
    }

    func waitUntilDrained() async {
        if queuedBuffers == 0 { return }
        let deadline = Task { [queuedSeconds] in
            try? await Task.sleep(for: .seconds(queuedSeconds + Self.drainGraceSeconds))
            if !Task.isCancelled, queuedBuffers > 0 {
                trace("Chatty: playback stalled with \(queuedBuffers) buffers queued; giving up")
                stop()
            }
        }
        await withCheckedContinuation { drainWaiters.append($0) }
        deadline.cancel()
    }

    private func engineWasReconfigured() {
        trace("Chatty: audio engine reconfigured, \(queuedBuffers) buffers lost")
        stop() // the queued buffers are gone; nobody may wait for them
    }

    private func applyPlayerVolume() {
        player.volume = muted ? 0 : min(1, gain)
    }

    func stop() {
        player.stop()
        queuedBuffers = 0
        queuedSeconds = 0
        answerIsComplete = false
        resumeDrainWaiters()
    }

    private func bufferFinished(seconds: Double) {
        queuedBuffers = max(0, queuedBuffers - 1)
        queuedSeconds = max(0, queuedSeconds - seconds)
        guard queuedBuffers == 0 else { return }
        player.pause() // refill before playing on, unless this was the end of the answer
        if answerIsComplete {
            answerIsComplete = false
            resumeDrainWaiters()
        } else {
            trace("Chatty: speech ran dry, buffering")
        }
    }

    private func resumeDrainWaiters() {
        drainWaiters.forEach { $0.resume() }
        drainWaiters.removeAll()
    }
}
