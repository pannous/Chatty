import Foundation
import os

private let traceLog = Logger(subsystem: "com.pannous.chatty", category: "trace")
private let traceFile = URL.documentsDirectory.appending(path: "chatty.log")
private let traceFileLimitBytes = 200_000
private let traceQueue = DispatchQueue(label: "com.pannous.chatty.trace")

/// Logs to the unified log and to Documents/chatty.log, which the Mac can fetch without root:
/// `tools/watch-log.sh` (`log collect` cannot reach the watch).
func trace(_ message: String) {
    traceLog.notice("\(message, privacy: .public)")
    let line = Data("\(Date.now.formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)\n".utf8)
    traceQueue.async {
        let size = (try? FileManager.default.attributesOfItem(atPath: traceFile.path)[.size] as? Int) ?? 0
        if size > traceFileLimitBytes { try? FileManager.default.removeItem(at: traceFile) }
        if let handle = try? FileHandle(forWritingTo: traceFile) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: traceFile)
        }
    }
}
