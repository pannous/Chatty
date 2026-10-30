import SwiftUI

@main
struct ChattyApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

private let screenCornerRadius = 40.0 // Series 7 display corners
private let softBorderOpacity = 0.5

/// A crisp pixel line on the very edge of the screen, softened by a half-transparent line just inside it.
private struct StateBorder: View {
    let color: Color
    let pixel: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: screenCornerRadius).strokeBorder(color, lineWidth: pixel)
            RoundedRectangle(cornerRadius: screenCornerRadius - pixel).strokeBorder(color.opacity(softBorderOpacity), lineWidth: pixel)
                .padding(pixel)
        }
        .ignoresSafeArea()
    }
}

extension Assistant.Phase {
    /// Green while the microphone is open, yellow until the reply starts, orange while it streams in, blue while it is spoken.
    var color: Color? {
        switch self {
        case .listening: .green
        case .speaking: .blue
        case .transcribing, .thinking: .yellow
        case .answering: .orange
        case .idle: nil
        }
    }
}

struct ContentView: View {
    @State private var assistant = Assistant.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @AppStorage("volume") private var volume = SpeechPlayer.unityVolume
    /// Headless tests that feed an `-audioFile` start talking only with `-autostart YES`, so they can test the idle app.
    private let listensOnOpen = UserDefaults.standard.object(forKey: "autostart") != nil
        ? UserDefaults.standard.bool(forKey: "autostart")
        : UserDefaults.standard.string(forKey: "audioFile") == nil

    var body: some View {
        // swipe scrolls; the Crown rotation sets the volume (the modifier below takes it from the ScrollView);
        // the view follows the newest line while an answer streams in
        ScrollView {
            // the border color shows the phase; no status text
            VStack(alignment: .leading, spacing: 8) {
                if !assistant.transcript.isEmpty { Text(assistant.transcript).foregroundStyle(.secondary) }
                if !assistant.reply.isEmpty { Text(assistant.reply) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { assistant.toggleListening() } // a tap anywhere: listening pauses, otherwise it listens
        .background {
            if let color = assistant.phase.color { StateBorder(color: color, pixel: 1 / displayScale) }
        }
        .animation(.easeInOut, value: assistant.phase)
        .focusable()
        .digitalCrownRotation($volume, from: 0, through: 1, by: 0.05, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: volume, initial: true) { assistant.setVolume(volume) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            assistant.isOnScreen = phase == .active
            switch phase {
            case .active: if listensOnOpen { assistant.converseIfIdle() }
            case .inactive: assistant.pauseIfListening()
            case .background: assistant.pauseIfListening(); assistant.leftApp()
            @unknown default: break
            }
        }
    }
}
