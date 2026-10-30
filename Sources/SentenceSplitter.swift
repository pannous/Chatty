import Foundation

/// Cuts streamed reply text into sentences so each can be spoken while the rest is still arriving.
struct SentenceSplitter {
    private static let minimumSentenceLength = 12 // avoids speaking fragments like "Dr." or "1." on their own
    // Regex is not Sendable, but this one is immutable and only read
    nonisolated(unsafe) private static let sentenceEnd = /[.!?…]+["'”’)\]]*\s+|\n+/

    private var pending = ""

    mutating func append(_ delta: String) -> [String] {
        pending += delta
        var sentences: [String] = []
        var searchStart = pending.startIndex
        while let match = pending[searchStart...].firstRange(of: Self.sentenceEnd) {
            let sentence = pending[..<match.upperBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count < Self.minimumSentenceLength {
                searchStart = match.upperBound
                continue
            }
            sentences.append(sentence)
            pending = String(pending[match.upperBound...])
            searchStart = pending.startIndex
        }
        return sentences
    }

    mutating func finish() -> String? {
        let rest = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        return rest.isEmpty ? nil : rest
    }
}
