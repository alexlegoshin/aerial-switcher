import Foundation

/// Locations of the macOS wallpaper files this app reads and writes, and of its own state.
/// Injectable so tests can point everything at a temporary directory.
public struct Paths: Sendable {
    public var manifest: URL
    public var store: URL
    public var videos: URL
    public var thumbnails: URL
    public var appSupport: URL

    public init(manifest: URL, store: URL, videos: URL, thumbnails: URL, appSupport: URL) {
        self.manifest = manifest
        self.store = store
        self.videos = videos
        self.thumbnails = thumbnails
        self.appSupport = appSupport
    }

    public init(home: URL) {
        let wallpaper = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper")
        self.init(
            manifest: wallpaper.appendingPathComponent("aerials/manifest/entries.json"),
            store: wallpaper.appendingPathComponent("Store/Index.plist"),
            videos: wallpaper.appendingPathComponent("aerials/videos"),
            thumbnails: wallpaper.appendingPathComponent("aerials/thumbnails"),
            appSupport: home.appendingPathComponent("Library/Application Support/AerialRotator")
        )
    }

    public static let live = Paths(home: FileManager.default.homeDirectoryForCurrentUser)

    public var config: URL { appSupport.appendingPathComponent("config.json") }
    public var state: URL { appSupport.appendingPathComponent("state") }
    /// The user's wallpaper store from before the first change, put back when switching is turned off.
    public var storeBackup: URL { state.appendingPathComponent("Index.original.plist") }
    /// The Aerial this app last put on screen, to tell its own change from the user's.
    public var lastSet: URL { state.appendingPathComponent("LastSet.txt") }
    /// What is showing, for which part of the day, and what comes next for each part.
    public var rotation: URL { state.appendingPathComponent("rotation.json") }
    /// Download failures, so a broken video is not retried in a loop.
    public var cacheState: URL { state.appendingPathComponent("cache.json") }
    /// Brightness and colors measured from thumbnails, keyed by asset ID.
    public var metrics: URL { state.appendingPathComponent("metrics.json") }
    /// Videos being downloaded (`<id>.mov.part` + `<id>.part.json`), moved into `videos` once verified.
    public var partialDownloads: URL { appSupport.appendingPathComponent("downloads") }
    public var logs: URL { appSupport.appendingPathComponent("logs") }

    public func video(_ id: String) -> URL { videos.appendingPathComponent("\(id).mov") }
    public func thumbnail(_ id: String) -> URL { thumbnails.appendingPathComponent("\(id).png") }
}

public struct AerialError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Writes `value` as JSON through a temporary file and a rename, so a crash or a full disk
/// midway leaves the previous file intact.
func writeJSONAtomically<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(value).write(to: url, options: .atomic)
}

/// nil when the file is missing or unreadable: every state file can be rebuilt.
func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(type, from: data)
}
