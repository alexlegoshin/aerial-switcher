import Foundation

/// Why a clip was picked, shown in the UI and the log.
public enum PickReason: String, Codable, Sendable {
    /// The clip itself suits the part of the day.
    case direct
    /// Same place as the previous wallpaper ("Sequoia Morning" → "Sequoia Night").
    case samePlace
    /// A landscape without a night shot → a dark underwater video with a similar palette.
    case nightWater
    /// A landscape without a night shot → an Earth flight over its region.
    case nightEarth
    /// A city without a night shot → an Earth flight over its region.
    case cityEarth
    /// Nothing better in the pool.
    case fallback
    /// The planned clip wasn't on disk; a downloaded one that suits the part of the day stands in.
    case standIn
}

public struct Pick: Codable, Hashable, Sendable {
    public var clipID: String
    public var reason: PickReason
    public init(clipID: String, reason: PickReason) {
        self.clipID = clipID
        self.reason = reason
    }
}

/// Deterministic random numbers (SplitMix64), so the same seed gives the same choices.
public struct RandomSource: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    /// A seed from several values, e.g. config seed + phase + date.
    public init(mixing values: UInt64...) {
        var s: UInt64 = 0x9E37_79B9_7F4A_7C15
        for value in values { s = (s ^ value) &* 0xBF58_476D_1CE4_E5B9; s ^= s >> 31 }
        state = s
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    public mutating func weighted<T>(_ options: [(T, Double)]) -> T? {
        let usable = options.filter { $0.1 > 0 && $0.1.isFinite }
        let total = usable.map(\.1).reduce(0, +)
        guard total > 0 else { return nil }
        var target = unit() * total
        for (value, weight) in usable {
            target -= weight
            if target < 0 { return value }
        }
        return usable.last?.0
    }
}

/// Chooses the next wallpaper for a part of the day from the pool.
///
/// Every pool clip is a ticket. A drawn ticket stands for itself if it suits the part of the
/// day, otherwise for another shot of the same place, otherwise (at night) for its fallback:
/// a city → an Earth flight over its region; a landscape → a dark underwater video with a
/// similar palette or an Earth flight over its region (chances normalized). Tickets with no
/// answer are dropped and another is drawn.
public struct Picker: Sendable {
    public let pool: [Clip]
    public let config: Config

    /// Clips shown this recently are avoided while there are others.
    static let freshWindow = 6
    /// Places shown this recently get fewer tickets.
    static let placeWindow = 3

    public init(pool: [Clip], config: Config) {
        self.pool = pool
        self.config = config
    }

    /// How well a clip suits a part of the day, 0 (not at all) … 1.
    public func suitability(of clip: Clip, for phase: SkyPhase) -> Double {
        if phase == .night {
            if clip.tone == .night { return 1 }
            if clip.zone == .water, let b = clip.brightness, b <= config.nightWaterMaxBrightness { return 0.8 }
            return 0
        }
        if clip.zone == .earth { return 0 }
        // Sun near the horizon: as close to a real sunrise or sunset as the pool allows.
        // Named shots first; then twilight-bright ones by how warm their palette is (cold
        // underwater blues drop out); sunlit day shots only when strongly warm, and never enough
        // to beat a real one.
        let warmth = clip.metrics?.warmth ?? 0
        let horizon = 0.4 + 0.6 * warmth
        switch (phase, clip.tone) {
        case (_, .night): return 0
        case (.dawn, .dawn), (.dusk, .dusk), (.golden, .golden), (.golden, .dusk): return 1
        case (.dawn, .dusk), (.dusk, .dawn), (.dusk, .golden), (.golden, .dawn): return 0.9
        case (.dawn, .golden): return 0.8
        case (.dawn, .twilight), (.dusk, .twilight), (.golden, .twilight): return horizon
        case (.dawn, .morning): return 0.7
        case (.golden, .morning): return 0.4
        case (.golden, .day), (.golden, .bright): return 0.15 + 0.3 * warmth
        case (.morning, .morning), (.day, .day), (.day, .bright): return 1
        case (.morning, .bright): return 0.8
        case (.morning, .day), (.day, .morning): return 0.7
        case (.morning, .dawn), (.morning, .golden): return 0.6
        case (.morning, .twilight), (.day, .golden): return 0.5
        default: return 0
        }
    }

    static let good = 0.5

    public func choose(for phase: SkyPhase, previous: Clip?, recent: [String], cached: Set<String> = [], rng: inout RandomSource) -> Pick? {
        guard !pool.isEmpty else { return nil }
        let recentClips = Array(recent.prefix(Self.freshWindow))
        let recentPlaces = Set(recent.prefix(Self.placeWindow).compactMap { id in pool.first { $0.id == id }?.placeID })

        func freshness(_ clip: Clip) -> Double {
            (recentClips.contains(clip.id) ? 0.05 : 1) * (cached.contains(clip.id) ? 1.5 : 1)
        }
        func pick(_ options: [(Clip, Double)], _ reason: PickReason) -> Pick? {
            rng.weighted(options.map { ($0.0, $0.1 * freshness($0.0)) }).map { Pick(clipID: $0.id, reason: reason) }
        }
        func samePlace(as clip: Clip, excluding: String?) -> [(Clip, Double)] {
            pool.filter { $0.placeID == clip.placeID && $0.id != excluding }
                .map { ($0, suitability(of: $0, for: phase)) }
                .filter { $0.1 >= Self.good }
        }

        func resolve(_ clip: Clip, excluding: String? = nil) -> Pick? {
            // The best shot of the drawn clip's place, strongly favored (weight = suitability³):
            // drawing "Los Angeles Hills" at golden hour leads to "Los Angeles Sunset".
            let place = pool.filter { $0.placeID == clip.placeID && $0.id != excluding }
                .map { ($0, suitability(of: $0, for: phase)) }
                .filter { $0.1 >= Self.good }
                .map { ($0.0, $0.1 * $0.1 * $0.1) }
            if let result = pick(place, .direct) { return result }
            guard phase == .night else { return nil }

            let earth = pool.filter { $0.zone == .earth && $0.region != nil && $0.region == clip.region }
                .map { ($0, suitability(of: $0, for: .night)) }.filter { $0.1 > 0 }
            switch clip.zone {
            case .city:
                return pick(earth, .cityEarth)
            case .land, .water:
                // Underwater with a palette close to the place's own.
                let reference = ImageMetrics.average(pool.filter { $0.placeID == clip.placeID }.compactMap(\.metrics))
                let water = pool.filter { $0.zone == .water && $0.id != clip.id && suitability(of: $0, for: .night) > 0 }
                    .map { candidate -> (Clip, Double) in
                        let similarity = reference.flatMap { ref in candidate.metrics.map { ref.similarity(to: $0) } } ?? 0.5
                        return (candidate, 0.2 + similarity * similarity)
                    }
                if clip.zone == .water { return pick(water, .nightWater) }
                // Water or Earth, chances normalized over whichever exist.
                var groups: [(PickReason, Double)] = []
                if !water.isEmpty { groups.append((.nightWater, max(config.nightWaterWeight, 0))) }
                if !earth.isEmpty { groups.append((.nightEarth, max(config.nightEarthWeight, 0))) }
                if groups.allSatisfy({ $0.1 == 0 }) { groups = groups.map { ($0.0, 1) } }
                switch rng.weighted(groups) {
                case .nightWater: return pick(water, .nightWater)
                case .nightEarth: return pick(earth, .nightEarth)
                default: return nil
                }
            default:
                return nil
            }
        }

        // Recent clips and places get fewer tickets (never none: a repeat beats nothing).
        // Stay with the previous place: another shot of it for this part of the day, or at night
        // its own fallback (London → Earth over Europe, Sonoma → similar underwater or Earth over
        // California). Never the very same clip twice in a row.
        if let previous, rng.unit() < config.continuity, var result = resolve(previous, excluding: previous.id) {
            if result.reason == .direct { result.reason = .samePlace }
            return result
        }

        // By day, a ticket counts as much as the best its place can offer, so a real sunset is
        // drawn more often than a passable one. At night the fallbacks decide instead.
        func fit(_ clip: Clip) -> Double {
            guard phase != .night else { return 1 }
            let best = pool.filter { $0.placeID == clip.placeID }.map { suitability(of: $0, for: phase) }.max() ?? 0
            return 0.05 + best * best * best
        }
        var tickets = pool.map { ($0, fit($0) * (recentPlaces.contains($0.placeID) ? 0.3 : 1.0) * (recentClips.contains($0.id) ? 0.05 : 1.0)) }
        while let ticket = rng.weighted(tickets.map { ($0.0, $0.1) }) {
            tickets.removeAll { $0.0.id == ticket.id }
            if let result = resolve(ticket) { return result }
        }

        // Nothing resolved: whatever suits best.
        let best = pool.map { ($0, suitability(of: $0, for: phase)) }.filter { $0.1 > 0 }
        return pick(best, .fallback)
    }
}
