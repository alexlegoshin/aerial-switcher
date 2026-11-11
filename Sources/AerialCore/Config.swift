import Foundation

/// What the user picked, saved as JSON in the app's Application Support folder.
/// Every key is optional when reading, so a file from an older version keeps working.
public struct Config: Codable, Equatable, Sendable {
    /// Off: no switching, and the wallpaper from before the app is put back.
    public var enabled = true
    /// Paused: no switching, the wallpaper showing stays.
    public var paused = false

    /// Asset IDs the rotation picks from.
    public var pool: [String] = []
    /// Asset IDs always kept on disk, so the wallpaper keeps following the sun offline.
    public var pinned: [String] = []

    /// Where the sun is computed for. Default: Moscow.
    public var latitude = 55.7558
    public var longitude = 37.6173
    public var placeName = "Moscow"

    /// The video cache aims to stay under the soft limit and never goes over the hard one.
    /// Going past the soft limit is allowed only for the next video due and the pinned ones.
    public var cacheSoftLimitMB = 3072
    public var cacheHardLimitMB = 5120

    /// Night fallback for landscapes that have no night shot: chance of underwater vs. Earth
    /// (normalized over whichever are available).
    public var nightWaterWeight = 0.7
    public var nightEarthWeight = 0.3
    /// Underwater videos up to this brightness (0–255, measured on the thumbnail) count as dark enough for night.
    public var nightWaterMaxBrightness = 80.0
    /// Chance of staying at the same place when it has a shot for the next part of the day.
    public var continuity = 0.8
    /// Region overrides: place (manifest subcategory English name) → region key, see `Regions`.
    public var regions: [String: String] = [:]
    /// Makes the choices reproducible; set once on first launch.
    public var seed: UInt64 = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? d.paused
        pool = try c.decodeIfPresent([String].self, forKey: .pool) ?? d.pool
        pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? d.pinned
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude) ?? d.latitude
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude) ?? d.longitude
        placeName = try c.decodeIfPresent(String.self, forKey: .placeName) ?? d.placeName
        cacheSoftLimitMB = try c.decodeIfPresent(Int.self, forKey: .cacheSoftLimitMB) ?? d.cacheSoftLimitMB
        cacheHardLimitMB = try c.decodeIfPresent(Int.self, forKey: .cacheHardLimitMB) ?? d.cacheHardLimitMB
        nightWaterWeight = try c.decodeIfPresent(Double.self, forKey: .nightWaterWeight) ?? d.nightWaterWeight
        nightEarthWeight = try c.decodeIfPresent(Double.self, forKey: .nightEarthWeight) ?? d.nightEarthWeight
        nightWaterMaxBrightness = try c.decodeIfPresent(Double.self, forKey: .nightWaterMaxBrightness) ?? d.nightWaterMaxBrightness
        continuity = try c.decodeIfPresent(Double.self, forKey: .continuity) ?? d.continuity
        regions = try c.decodeIfPresent([String: String].self, forKey: .regions) ?? d.regions
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? d.seed
    }

    public var softLimitBytes: Int64 { Int64(max(cacheSoftLimitMB, 256)) * 1_048_576 }
    public var hardLimitBytes: Int64 { max(Int64(cacheHardLimitMB) * 1_048_576, softLimitBytes) }

    /// A missing or broken file gives the defaults (with a fresh seed); the broken file is
    /// kept next to it rather than silently overwritten.
    public static func load(from url: URL) -> Config {
        var config: Config
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode(Config.self, from: data) {
                config = decoded
            } else {
                try? FileManager.default.copyItem(at: url, to: url.appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970))"))
                config = Config()
            }
        } else {
            config = Config()
        }
        if config.seed == 0 { config.seed = UInt64.random(in: 1...UInt64.max) }
        return config
    }

    public func save(to url: URL) throws {
        try writeJSONAtomically(self, to: url)
    }
}
