import Foundation

enum OpenAIConfig {
    static let baseURL = URL(string: "https://api.openai.com/v1/")!
    static let apiKeyInfoPlistKey = "OpenAIAPIKey"
    static let transcriptionModel = "gpt-4o-mini-transcribe"
    static let replyModel = "gpt-5.5"
    static let replyReasoningEffort = "low"
    static let replyInstructions = """
        You are a voice assistant on the user's Apple Watch. Your answers are spoken aloud: \
        answer briefly in plain conversational language, without markdown, lists, links or emoji.
        """
    static let speechModel = "gpt-4o-mini-tts"
    static let speechVoice = "nova"
    // measured 2026-10-30: speed alone shortens gpt-4o-mini-tts German speech only ~7 %, with the instruction ~13 %
    static let speechSpeed = 1.25
    static let speechInstructions = "Speak briskly and lively, without long pauses."
    static let speechSampleRate = 24_000.0 // response_format "pcm": 24 kHz, 16-bit little-endian, mono
    static let speechChunkBytes = 9_600 // 0.2 s of audio per playback buffer
}

struct AssistantError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ReplyEvent: Sendable {
    case textDelta(String)
    case completed(responseID: String)
}

struct OpenAIClient: Sendable {
    let apiKey: String

    static func fromBundle() throws -> OpenAIClient {
        guard let key = Bundle.main.object(forInfoDictionaryKey: OpenAIConfig.apiKeyInfoPlistKey) as? String, key.hasPrefix("sk-") else {
            throw AssistantError(message: "OPENAI_API_KEY missing: put it in .env and rebuild with tools/build-chatty.sh")
        }
        return OpenAIClient(apiKey: key)
    }

    func transcribe(audioFile: URL) async throws -> String {
        let boundary = UUID().uuidString
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        appendField("model", OpenAIConfig.transcriptionModel)
        appendField("response_format", "text")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audioFile.lastPathComponent)\"\r\nContent-Type: audio/mp4\r\n\r\n")
        body.append(try Data(contentsOf: audioFile))
        body.append("\r\n--\(boundary)--\r\n")
        let request = request("audio/transcriptions", contentType: "multipart/form-data; boundary=\(boundary)", body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, body: data)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Streams the reply text (server-sent events); `previousResponseID` keeps the conversation context server-side.
    func streamReply(to text: String, previousResponseID: String?) -> AsyncThrowingStream<ReplyEvent, Error> {
        streamRequest {
            var payload: [String: Any] = [
                "model": OpenAIConfig.replyModel,
                "reasoning": ["effort": OpenAIConfig.replyReasoningEffort],
                "instructions": OpenAIConfig.replyInstructions,
                "input": text,
                "stream": true,
            ]
            if let previousResponseID { payload["previous_response_id"] = previousResponseID }
            return try jsonRequest("responses", payload)
        } consume: { bytes, continuation in
            for try await line in bytes.lines where line.hasPrefix("data:") {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any] else { continue }
                switch event["type"] as? String {
                case "response.output_text.delta":
                    continuation.yield(.textDelta(event["delta"] as? String ?? ""))
                case "response.completed":
                    let response = event["response"] as? [String: Any]
                    continuation.yield(.completed(responseID: response?["id"] as? String ?? ""))
                case "error", "response.failed":
                    throw AssistantError(message: "Reply failed: \(line)")
                default:
                    break
                }
            }
        }
    }

    /// Streams raw PCM speech for `text` in playback-sized chunks.
    func streamSpeech(of text: String) -> AsyncThrowingStream<Data, Error> {
        streamRequest {
            try jsonRequest("audio/speech", [
                "model": OpenAIConfig.speechModel,
                "voice": OpenAIConfig.speechVoice,
                "input": text,
                "response_format": "pcm",
                "speed": OpenAIConfig.speechSpeed,
                "instructions": OpenAIConfig.speechInstructions,
            ])
        } consume: { bytes, continuation in
            var chunk = Data(capacity: OpenAIConfig.speechChunkBytes)
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == OpenAIConfig.speechChunkBytes {
                    continuation.yield(chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty { continuation.yield(chunk) }
        }
    }

    private func streamRequest<Element: Sendable>(
        _ makeRequest: @escaping @Sendable () throws -> URLRequest,
        consume: @escaping @Sendable (URLSession.AsyncBytes, AsyncThrowingStream<Element, Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: try makeRequest())
                    if (response as? HTTPURLResponse)?.statusCode != 200 {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        try Self.check(response, body: body)
                    }
                    try await consume(bytes, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func request(_ path: String, contentType: String, body: Data) -> URLRequest {
        var request = URLRequest(url: OpenAIConfig.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private func jsonRequest(_ path: String, _ payload: [String: Any]) throws -> URLRequest {
        request(path, contentType: "application/json", body: try JSONSerialization.data(withJSONObject: payload))
    }

    private static func check(_ response: URLResponse, body: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AssistantError(message: "OpenAI HTTP \(status): \(String(decoding: body, as: UTF8.self))")
        }
    }
}

private extension Data {
    mutating func append(_ text: String) { append(Data(text.utf8)) }
}
