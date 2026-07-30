import Foundation

final class QuietLogger: @unchecked Sendable {
    static let shared = QuietLogger()

    private static let maximumLogBytes = 5 * 1024 * 1024
    let outputDirectory: URL
    private let logURL: URL
    private let queue = DispatchQueue(label: "com.fangchenfang.QuietRecorder.log")
    private let formatter = ISO8601DateFormatter()

    private init() {
        outputDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/QuietRecorder", isDirectory: true)
        logURL = outputDirectory.appendingPathComponent("QuietRecorder.log")
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            fputs("QuietRecorder cannot create output directory: \(error)\n", stderr)
        }
    }

    func log(_ message: String) {
        queue.sync { [self] in
            let timestamp = formatter.string(from: Date())
            let line = "\(timestamp) \(message)\n"
            let data = Data(line.utf8)
            do {
                try rotateLogIfNeeded(incomingByteCount: data.count)
                if FileManager.default.fileExists(atPath: logURL.path) {
                    let handle = try FileHandle(forWritingTo: logURL)
                    defer {
                        do { try handle.close() }
                        catch { fputs("QuietRecorder log close failed: \(error)\n", stderr) }
                    }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: logURL, options: .atomic)
                }
            } catch {
                fputs("QuietRecorder log write failed: \(error)\n", stderr)
            }
        }
    }

    private func rotateLogIfNeeded(incomingByteCount: Int) throws {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        guard let currentSize = attributes[.size] as? NSNumber,
              currentSize.intValue + incomingByteCount > Self.maximumLogBytes else { return }

        let previousURL = outputDirectory.appendingPathComponent("QuietRecorder.previous.log")
        if FileManager.default.fileExists(atPath: previousURL.path) {
            try FileManager.default.removeItem(at: previousURL)
        }
        try FileManager.default.moveItem(at: logURL, to: previousURL)
    }
}
