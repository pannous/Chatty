import AppIntents

/// "Siri, Chatty": opens Chatty and starts a conversation, like a double press of the Crown.
struct TalkIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        Assistant.shared.converse()
        return .result()
    }
}

struct ChattyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkIntent(),
            phrases: ["\(.applicationName)", "Talk with \(.applicationName)", "Ask \(.applicationName)"],
            shortTitle: "Talk",
            systemImageName: "waveform"
        )
    }
}
