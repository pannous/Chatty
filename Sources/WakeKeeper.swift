import WatchKit

/// Keeps Chatty frontmost and running while the screen dims (up to the session limit of an hour), so answers
/// are not cut off and raising the wrist shows Chatty again instead of the watch face.
/// The session type comes from `WKBackgroundModes` (mindfulness) in Info.plist.
@MainActor final class WakeKeeper: NSObject, WKExtendedRuntimeSessionDelegate {
    private var session: WKExtendedRuntimeSession?

    func keepAwake() {
        guard session?.state != .running else { return }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        self.session = session
    }

    func allowSleep() {
        session?.invalidate()
        session = nil
    }

    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: (any Error)?) {
        if let error { trace("Chatty: keep-awake session ended: \(error.localizedDescription)") }
    }
}
