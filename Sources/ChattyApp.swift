import SwiftUI
import WatchKit

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

private let copyPressSeconds = 1.0
private let volumeBarDuration = Duration.seconds(1.5)

/// Fills from the bottom as the volume rises, like a level meter.
private struct VolumeBar: View {
    let volume: Double

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(.gray.opacity(0.4))
                .overlay(alignment: .bottom) {
                    Capsule().fill(.white).frame(height: geometry.size.height * volume)
                }
        }
        .frame(width: 4, height: 60)
        .padding(.trailing, 2)
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

    @State private var showsVolume = false
    @State private var hideVolume: Task<Void, Never>?

    private func flashVolume() {
        withAnimation { showsVolume = true }
        hideVolume?.cancel()
        hideVolume = Task {
            try? await Task.sleep(for: volumeBarDuration)
            if !Task.isCancelled { withAnimation { showsVolume = false } }
        }
    }

    private func copyReply() {
        let copied = !assistant.reply.isEmpty && Clipboard.copy(assistant.reply)
        trace("Chatty: reply copied to the clipboard: \(copied)")
        WKInterfaceDevice.current().play(copied ? .success : .failure)
    }

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
        .onLongPressGesture(minimumDuration: copyPressSeconds) { copyReply() }
        .background {
            if let color = assistant.phase.color { StateBorder(color: color, pixel: 1 / displayScale) }
        }
        .overlay(alignment: .trailing) {
            if showsVolume { VolumeBar(volume: volume).transition(.opacity) }
        }
        .animation(.easeInOut, value: assistant.phase)
        .focusable()
        .digitalCrownRotation($volume, from: 0, through: 1, by: 0.05, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        // the system's Crown indicator shows a scroll position and moves down when the volume goes up
        .digitalCrownAccessory(.hidden)
        .onChange(of: volume, initial: true) { assistant.setVolume(volume) }
        .onChange(of: volume) { flashVolume() }
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
