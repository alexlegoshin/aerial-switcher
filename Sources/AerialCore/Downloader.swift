import AVFoundation
import Foundation
import os

/// What is known about a partial download, kept next to it so a download interrupted by
/// sleep, a network change or a quit resumes where it stopped.
struct PartialMeta: Codable, Equatable {
    var url: URL
    var expected: Int64?
    var etag: String?
    var lastModified: String?
}

public enum DownloadError: Error, Equatable, LocalizedError {
    case noURL
    case status(Int)
    /// Connection ended before the whole file arrived; the part is kept for resuming.
    case incomplete(received: Int64, expected: Int64)
    /// The whole file arrived but isn't a playable video; it was thrown away.
    case unplayable
    case notEnoughSpace

    public var errorDescription: String? {
        switch self {
        case .noURL: "The manifest has no download link for this video."
        case let .status(code): "The server answered \(code)."
        case let .incomplete(received, expected): "Download stopped at \(received) of \(expected) bytes."
        case .unplayable: "The downloaded file isn't a playable video."
        case .notEnoughSpace: "Not enough free disk space."
        }
    }
}

/// Downloads Aerial videos one at a time, resumable, at background priority, streaming to
/// disk (memory use stays flat whatever the size). A video reaches the macOS folder only
/// complete and verified, by an atomic rename.
public struct Downloader: Sendable {
    let paths: Paths
    let makeConfiguration: @Sendable () -> URLSessionConfiguration
    let validate: @Sendable (URL) async -> Bool

    public init(paths: Paths,
                makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration = Downloader.backgroundConfiguration,
                validate: @escaping @Sendable (URL) async -> Bool = Downloader.isPlayableVideo) {
        self.paths = paths
        self.makeConfiguration = makeConfiguration
        self.validate = validate
    }

    /// Never over a hotspot or Low Data Mode, low network priority, no HTTP cache.
    @Sendable public static func backgroundConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.allowsCellularAccess = false
        configuration.networkServiceType = .background
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }

    @Sendable public static func isPlayableVideo(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let (playable, duration) = try? await asset.load(.isPlayable, .duration) else { return false }
        return playable && duration.isValid && duration.seconds > 1
    }

    func partFile(_ id: String) -> URL { paths.partialDownloads.appendingPathComponent("\(id).partial.mov") }
    func metaFile(_ id: String) -> URL { paths.partialDownloads.appendingPathComponent("\(id).part.json") }

    /// Bytes already downloaded of an unfinished video.
    public func partialSize(_ id: String) -> Int64 {
        Int64((try? FileManager.default.attributesOfItem(atPath: partFile(id).path)[.size] as? Int) ?? 0)
    }

    public func discardPartial(_ id: String) {
        try? FileManager.default.removeItem(at: partFile(id))
        try? FileManager.default.removeItem(at: metaFile(id))
    }

    /// Size of a video from the server, without downloading it.
    public func remoteSize(of url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: makeConfiguration())
        defer { session.finishTasksAndInvalidate() }
        guard let response = try? await session.data(for: request).1 as? HTTPURLResponse, response.statusCode == 200 else { return nil }
        return response.expectedContentLength > 0 ? response.expectedContentLength : nil
    }

    /// Downloads (or resumes) a video and installs it as `videos/<id>.mov`.
    /// `progress` gets bytes so far and the total when known.
    public func download(id: String, from url: URL?, progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws {
        guard let url else { throw DownloadError.noURL }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.partialDownloads, withIntermediateDirectories: true)
        let part = partFile(id), metaURL = metaFile(id)

        // Resume only a part that belongs to this URL and has its notes.
        var meta = readJSON(PartialMeta.self, from: metaURL)
        if meta?.url != url || !fileManager.fileExists(atPath: part.path) {
            discardPartial(id)
            meta = PartialMeta(url: url)
        }
        var offset = partialSize(id)
        if let expected = meta?.expected, offset > expected {
            discardPartial(id)
            meta = PartialMeta(url: url)
            offset = 0
        }

        if let expected = meta?.expected, offset == expected, offset > 0 {
            // Already complete from an earlier run that stopped before installing.
        } else {
            var request = URLRequest(url: url)
            if offset > 0 {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                // If the file changed on the server, it sends the whole new one instead.
                if let validator = meta?.etag ?? meta?.lastModified { request.setValue(validator, forHTTPHeaderField: "If-Range") }
            }
            let writer = try PartWriter(file: part, offset: offset, meta: meta ?? PartialMeta(url: url), metaURL: metaURL, progress: progress)
            let session = URLSession(configuration: makeConfiguration(), delegate: writer, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            meta = try await writer.run(session.dataTask(with: request))
        }

        let received = partialSize(id)
        if let expected = meta?.expected, received != expected {
            if received > expected { discardPartial(id) }
            throw DownloadError.incomplete(received: received, expected: expected)
        }
        guard await validate(part) else {
            discardPartial(id)
            throw DownloadError.unplayable
        }

        try fileManager.createDirectory(at: paths.videos, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: part.path)
        // rename(2): atomic, replaces an existing file; same volume as Application Support.
        guard rename(part.path, paths.video(id).path) == 0 else {
            throw AerialError("Couldn't move the video into place: \(String(cString: strerror(errno)))")
        }
        try? fileManager.removeItem(at: metaURL)
    }
}

/// Appends a data task's body to the part file, or starts it over when the server sends the
/// whole file instead of the requested range.
private final class PartWriter: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var handle: FileHandle
        var meta: PartialMeta
        var continuation: CheckedContinuation<PartialMeta, Error>?
        var task: URLSessionTask?
        var cancelled = false
        var failure: Error?
        var received: Int64
        var lastReport: Int64 = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let offset: Int64
    private let metaURL: URL
    private let progress: @Sendable (Int64, Int64?) -> Void

    init(file: URL, offset: Int64, meta: PartialMeta, metaURL: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) throws {
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: UInt64(offset))
        self.offset = offset
        self.metaURL = metaURL
        self.progress = progress
        state = OSAllocatedUnfairLock(uncheckedState: State(handle: handle, meta: meta, received: offset))
    }

    func run(_ task: URLSessionDataTask) async throws -> PartialMeta {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLockUnchecked { state in
                    state.continuation = continuation
                    state.task = task
                    return state.cancelled
                }
                if cancelled { task.cancel(); finish(CancellationError()) } else { task.resume() }
            }
        } onCancel: {
            let task = state.withLockUnchecked { state in
                state.cancelled = true
                return state.task
            }
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            state.withLockUnchecked { $0.failure = DownloadError.status(0) }
            return .cancel
        }
        let etag = http.value(forHTTPHeaderField: "ETag"), lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        let ok: Bool = state.withLockUnchecked { state in
            switch http.statusCode {
            case 206:
                // "bytes <start>-<end>/<total>": must continue exactly where the part ends.
                let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                let numbers = range.split(whereSeparator: { !$0.isNumber }).compactMap { Int64($0) }
                guard numbers.count == 3, numbers[0] == offset else {
                    state.failure = DownloadError.status(206)
                    return false
                }
                state.meta.expected = numbers[2]
            case 200:
                // Whole file (server ignored the range or the file changed): start over.
                do {
                    try state.handle.truncate(atOffset: 0)
                } catch {
                    state.failure = error
                    return false
                }
                state.received = 0
                state.meta.expected = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            default:
                state.failure = DownloadError.status(http.statusCode)
                return false
            }
            state.meta.etag = etag
            state.meta.lastModified = lastModified
            try? writeJSONAtomically(state.meta, to: metaURL)
            return true
        }
        return ok ? .allow : .cancel
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let report: (Int64, Int64?)? = state.withLockUnchecked { state in
            do {
                try state.handle.write(contentsOf: data)
            } catch {
                state.failure = (error as NSError).code == NSFileWriteOutOfSpaceError ? DownloadError.notEnoughSpace : error
                dataTask.cancel()
                return nil
            }
            state.received += Int64(data.count)
            // Report about every 4 MB, not every packet.
            guard state.received - state.lastReport >= 4 << 20 || state.received == state.meta.expected else { return nil }
            state.lastReport = state.received
            return (state.received, state.meta.expected)
        }
        if let report { progress(report.0, report.1) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error)
    }

    private func finish(_ error: Error?) {
        let (continuation, result, meta) = state.withLockUnchecked { state in
            defer { state.continuation = nil }
            try? state.handle.synchronize()
            try? state.handle.close()
            let result: Error? = state.failure ?? (state.cancelled ? CancellationError() : error)
            return (state.continuation, result, state.meta)
        }
        if let result { continuation?.resume(throwing: result) } else { continuation?.resume(returning: meta) }
    }
}
