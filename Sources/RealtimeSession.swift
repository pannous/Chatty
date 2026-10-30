import AVFoundation
import os

/// Protocol verified from the Mac with probes/realtime-protocol.py.
enum RealtimeConfig {
    static let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1")!
    static let voice = "marin"
    static let transcriptionModel = OpenAIConfig.transcriptionModel
    static let endOfSpeechSilenceMilliseconds = 600
    static let microphoneBufferFrames: AVAudioFrameCount = 2_400
}

enum RealtimeEvent: Sendable {
    case ready
    case speechStarted
    case speechStopped
    case transcript(String)
    case replyDelta(String)
    case audio(Data)
    case replyDone
}

/// One speech-to-speech session over the OpenAI Realtime WebSocket: the microphone streams up while it is open,
/// the server detects the end of speech and streams the spoken answer back.
final class RealtimeSession: @unchecked Sendable {
    private let socket: URLSessionWebSocketTask
    private let engine = AVAudioEngine()
    private let microphoneOpen = OSAllocatedUnfairLock(initialState: false)
    private let closedOnPurpose = OSAllocatedUnfairLock(initialState: false)
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: OpenAIConfig.speechSampleRate, channels: 1, interleaved: true)!

    init(apiKey: String) {
        var request = URLRequest(url: RealtimeConfig.url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        socket = URLSession.shared.webSocketTask(with: request)
    }

    /// Server events until the session is closed; ends without error after `close()`.
    func events() -> AsyncThrowingStream<RealtimeEvent, Error> {
        socket.resume()
        send(sessionUpdate())
        return AsyncThrowingStream { continuation in
            let receiver = Task {
                do {
                    while true {
                        guard case .string(let text) = try await socket.receive() else { continue }
                        if let event = try Self.parse(text) { continuation.yield(event) }
                    }
                } catch {
                    continuation.finish(throwing: closedOnPurpose.withLock { $0 } ? nil : error)
                }
            }
            continuation.onTermination = { _ in receiver.cancel() }
        }
    }

    func startMicrophone() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: pcmFormat) else {
            throw AssistantError(message: "Microphone format \(inputFormat) cannot be converted")
        }
        input.installTap(onBus: 0, bufferSize: RealtimeConfig.microphoneBufferFrames, format: inputFormat) { [self] buffer, _ in
            guard microphoneOpen.withLock({ $0 }), let pcm = convert(buffer, with: converter) else { return }
            send(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
        }
        try engine.start()
    }

    /// After an audio route change the input format may differ, so the tap is installed afresh.
    func restartMicrophone() throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try startMicrophone()
    }

    func setMicrophoneOpen(_ open: Bool) {
        microphoneOpen.withLock { $0 = open }
    }

    func close() {
        closedOnPurpose.withLock { $0 = true }
        setMicrophoneOpen(false)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        socket.cancel(with: .normalClosure, reason: nil)
    }

    private func sessionUpdate() -> [String: Any] {
        ["type": "session.update", "session": [
            "type": "realtime",
            "instructions": OpenAIConfig.replyInstructions,
            "output_modalities": ["audio"],
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": Int(OpenAIConfig.speechSampleRate)],
                    "transcription": ["model": RealtimeConfig.transcriptionModel],
                    "turn_detection": ["type": "server_vad", "silence_duration_ms": RealtimeConfig.endOfSpeechSilenceMilliseconds],
                ],
                "output": [
                    "format": ["type": "audio/pcm", "rate": Int(OpenAIConfig.speechSampleRate)],
                    "voice": RealtimeConfig.voice,
                ],
            ],
        ]]
    }

    private func send(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> Data? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * pcmFormat.sampleRate / buffer.format.sampleRate) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var consumed = false
        converter.convert(to: output, error: nil) { _, status in
            status.pointee = consumed ? .noDataNow : .haveData
            defer { consumed = true }
            return consumed ? nil : buffer
        }
        guard output.frameLength > 0 else { return nil }
        return Data(bytes: output.int16ChannelData![0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    private static func parse(_ text: String) throws -> RealtimeEvent? {
        guard let event = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = event["type"] as? String else { return nil }
        switch type {
        case "session.updated": return .ready
        case "input_audio_buffer.speech_started": return .speechStarted
        case "input_audio_buffer.speech_stopped": return .speechStopped
        case "conversation.item.input_audio_transcription.completed": return .transcript(event["transcript"] as? String ?? "")
        case "response.output_audio_transcript.delta": return .replyDelta(event["delta"] as? String ?? "")
        case "response.output_audio.delta": return (event["delta"] as? String).flatMap { Data(base64Encoded: $0) }.map(RealtimeEvent.audio)
        case "response.done": return .replyDone
        case "error": throw AssistantError(message: "Realtime: \(text)")
        default: return nil
        }
    }
}
