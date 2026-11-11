import Foundation
import os

/// Appends lines to `logs/rotator.log` (rotated at 1 MB, two old files kept) and to the
/// unified log (`log stream --predicate 'subsystem == "aerial-rotator"'`).
public final class Log: Sendable {
    public static let shared = Log(folder: Paths.live.logs)

    private let file: URL
    private let lock = OSAllocatedUnfairLock()
    private let logger = Logger(subsystem: "aerial-rotator", category: "engine")
    private let enabled: Bool

    public init(folder: URL, enabled: Bool = true) {
        file = folder.appendingPathComponent("rotator.log")
        self.enabled = enabled
    }

    public func info(_ message: String) { write("INFO", message) }
    public func error(_ message: String) { write("ERROR", message) }

    private func write(_ level: String, _ message: String) {
        logger.log("\(level, privacy: .public) \(message, privacy: .public)")
        guard enabled else { return }
        let line = "\(Date().formatted(.iso8601)) \(level) \(message)\n"
        lock.withLock {
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? fileManager.attributesOfItem(atPath: file.path)[.size] as? Int, size > 1_000_000 {
                let old1 = file.appendingPathExtension("1"), old2 = file.appendingPathExtension("2")
                try? fileManager.removeItem(at: old2)
                try? fileManager.moveItem(at: old1, to: old2)
                try? fileManager.moveItem(at: file, to: old1)
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }
}
