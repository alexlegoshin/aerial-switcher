import Foundation
import os
import Testing
@testable import AerialCore

/// A fake HTTP server, one per test host so tests can run in parallel.
final class StubServer: Sendable {
    struct Behavior: Sendable {
        var body: Data
        var etag = "\"v1\""
        var status = 200
        var honorsRange = true
        /// Cut the connection after this many bytes of the next response, once.
        var dropAfter: Int?
    }

    private static let registry = OSAllocatedUnfairLock<[String: StubServer]>(initialState: [:])
    let host = "stub-\(UUID().uuidString.lowercased()).test"
    private let state: OSAllocatedUnfairLock<(behavior: Behavior, ranges: [String?], requests: Int)>

    init(_ behavior: Behavior) {
        state = OSAllocatedUnfairLock(initialState: (behavior, [], 0))
        Self.registry.withLock { $0[host] = self }
    }

    var url: URL { URL(string: "https://\(host)/video.mov")! }
    var ranges: [String?] { state.withLock { $0.ranges } }
    func update(_ change: @Sendable (inout Behavior) -> Void) { state.withLock { change(&$0.behavior) } }

    static func server(for request: URLRequest) -> StubServer? {
        request.url?.host.flatMap { host in registry.withLock { $0[host] } }
    }

    /// What to send: status, headers, body, and whether to fail midway.
    func respond(to request: URLRequest) -> (Int, [String: String], Data, Bool) {
        state.withLock { s in
            let range = request.value(forHTTPHeaderField: "Range")
            if request.httpMethod != "HEAD" { s.ranges.append(range) }
            let b = s.behavior
            var headers = ["ETag": b.etag, "Accept-Ranges": "bytes"]
            guard b.status == 200 else { return (b.status, headers, Data(), false) }
            if request.httpMethod == "HEAD" {
                headers["Content-Length"] = "\(b.body.count)"
                return (200, headers, Data(), false)
            }
            var status = 200, body = b.body
            let ifRange = request.value(forHTTPHeaderField: "If-Range")
            if let range, b.honorsRange, ifRange == nil || ifRange == b.etag,
               let start = Int(range.dropFirst("bytes=".count).dropLast()), start < b.body.count {
                status = 206
                body = b.body.subdata(in: start..<b.body.count)
                headers["Content-Range"] = "bytes \(start)-\(b.body.count - 1)/\(b.body.count)"
            }
            headers["Content-Length"] = "\(body.count)"
            var drop = false
            if let limit = b.dropAfter, limit < body.count {
                body = body.prefix(limit)
                drop = true
                s.behavior.dropAfter = nil
            }
            return (status, headers, body, drop)
        }
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { StubServer.server(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = StubServer.server(for: request) else { return }
        let (status, headers, body, drop) = server.respond(to: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In chunks, like a real connection.
        var offset = 0
        while offset < body.count {
            let end = min(offset + 64, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
        }
        if drop {
            // A real connection drops some time after the last bytes arrived.
            let client = client
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    @Sendable static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }
}

@Suite struct DownloaderTests {
    let body = Data((0..<1000).map { UInt8($0 % 251) })

    func setUp(_ behavior: StubServer.Behavior, valid: Bool = true) throws -> (Downloader, Paths, StubServer) {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        let server = StubServer(behavior)
        let downloader = Downloader(paths: paths, makeConfiguration: StubProtocol.configuration, validate: { _ in valid })
        return (downloader, paths, server)
    }

    @Test func downloadsAndInstallsAtomically() async throws {
        let (downloader, paths, server) = try setUp(.init(body: body))
        try await downloader.download(id: "A", from: server.url)
        #expect(try Data(contentsOf: paths.video("A")) == body)
        let permissions = try FileManager.default.attributesOfItem(atPath: paths.video("A").path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(downloader.partialSize("A") == 0)
        #expect(!FileManager.default.fileExists(atPath: downloader.metaFile("A").path))
    }

    /// Leaves what an interrupted download leaves: the first bytes and the notes about them.
    func interrupted(_ downloader: Downloader, _ server: StubServer, bytes: Int, etag: String = "\"v1\"") throws {
        try FileManager.default.createDirectory(at: downloader.paths.partialDownloads, withIntermediateDirectories: true)
        try body.prefix(bytes).write(to: downloader.partFile("A"))
        try writeJSONAtomically(PartialMeta(url: server.url, expected: Int64(body.count), etag: etag), to: downloader.metaFile("A"))
    }

    @Test func aDroppedConnectionInstallsNothing() async throws {
        var behavior = StubServer.Behavior(body: body)
        behavior.dropAfter = 300
        let (downloader, paths, server) = try setUp(behavior)
        await #expect(throws: (any Error).self) { try await downloader.download(id: "A", from: server.url) }
        #expect(!FileManager.default.fileExists(atPath: paths.video("A").path), "nothing half-done in the macOS folder")
        try await downloader.download(id: "A", from: server.url)
        #expect(try Data(contentsOf: paths.video("A")) == body)
    }

    @Test func resumesWhereItStopped() async throws {
        let (downloader, paths, server) = try setUp(.init(body: body))
        try interrupted(downloader, server, bytes: 300)
        try await downloader.download(id: "A", from: server.url)
        #expect(server.ranges == ["bytes=300-"])
        #expect(try Data(contentsOf: paths.video("A")) == body)
    }

    @Test func finishedButNotInstalledIsJustInstalled() async throws {
        let (downloader, paths, server) = try setUp(.init(body: body))
        try interrupted(downloader, server, bytes: body.count)
        try await downloader.download(id: "A", from: server.url)
        #expect(server.ranges.isEmpty)
        #expect(try Data(contentsOf: paths.video("A")) == body)
    }

    @Test func partForAnotherURLIsDiscarded() async throws {
        let (downloader, paths, server) = try setUp(.init(body: body))
        try FileManager.default.createDirectory(at: paths.partialDownloads, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 300).write(to: downloader.partFile("A"))
        try writeJSONAtomically(PartialMeta(url: URL(string: "https://elsewhere.test/x.mov")!, expected: 1000), to: downloader.metaFile("A"))
        try await downloader.download(id: "A", from: server.url)
        #expect(server.ranges == [nil])
        #expect(try Data(contentsOf: paths.video("A")) == body)
    }

    @Test func startsOverWhenTheServerIgnoresTheRange() async throws {
        var behavior = StubServer.Behavior(body: body)
        behavior.honorsRange = false
        let (downloader, paths, server) = try setUp(behavior)
        try interrupted(downloader, server, bytes: 300)
        try await downloader.download(id: "A", from: server.url)
        #expect(try Data(contentsOf: paths.video("A")) == body)
    }

    @Test func startsOverWhenTheFileChangedOnTheServer() async throws {
        let (downloader, paths, server) = try setUp(.init(body: body))
        try interrupted(downloader, server, bytes: 300)
        let newBody = Data(repeating: 7, count: 800)
        server.update { $0.body = newBody; $0.etag = "\"v2\"" }
        try await downloader.download(id: "A", from: server.url)
        #expect(try Data(contentsOf: paths.video("A")) == newBody)
    }

    @Test func throwsAwayAnUnplayableFile() async throws {
        let (downloader, paths, server) = try setUp(.init(body: body), valid: false)
        await #expect(throws: DownloadError.unplayable) { try await downloader.download(id: "A", from: server.url) }
        #expect(!FileManager.default.fileExists(atPath: paths.video("A").path))
        #expect(downloader.partialSize("A") == 0)
    }

    @Test func reportsServerErrors() async throws {
        var behavior = StubServer.Behavior(body: body)
        behavior.status = 404
        let (downloader, paths, server) = try setUp(behavior)
        await #expect(throws: DownloadError.status(404)) { try await downloader.download(id: "A", from: server.url) }
        #expect(!FileManager.default.fileExists(atPath: paths.video("A").path))
        await #expect(throws: DownloadError.noURL) { try await downloader.download(id: "B", from: nil) }
    }

    @Test func replacesAnExistingFile() async throws {
        let (downloader, paths, server) = try setUp(.init(body: body))
        try Fixtures.download(["A"], into: paths, size: 5)
        try await downloader.download(id: "A", from: server.url)
        #expect(try Data(contentsOf: paths.video("A")) == body)
    }

    @Test func readsTheSizeWithoutDownloading() async throws {
        let (downloader, _, server) = try setUp(.init(body: body))
        #expect(await downloader.remoteSize(of: server.url) == 1000)
        #expect(server.ranges.isEmpty)
    }

    @Test(.enabled(if: !CacheScanner.scan(Paths.live.videos).isEmpty))
    func realVideoIsPlayable() async throws {
        let file = try #require(CacheScanner.scan(Paths.live.videos).first)
        #expect(await Downloader.isPlayableVideo(Paths.live.video(file.id)))
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        try Data(repeating: 0, count: 4096).write(to: junk)
        #expect(await Downloader.isPlayableVideo(junk) == false)
    }
}
