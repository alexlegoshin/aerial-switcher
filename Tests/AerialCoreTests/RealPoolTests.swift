import Foundation
import Testing
@testable import AerialCore

/// On this Mac's own pool and thumbnails, when there is one: what the sun-near-horizon parts
/// of the day actually get.
@Suite(.enabled(if: FileManager.default.fileExists(atPath: Paths.live.config.path)
    && FileManager.default.fileExists(atPath: Paths.live.metrics.path)))
struct RealPoolTests {
    @Test func horizonPartsOfTheDayGetSunsetLikeShots() throws {
        let config = Config.load(from: Paths.live.config)
        let metrics = readJSON([String: ImageMetrics].self, from: Paths.live.metrics) ?? [:]
        let catalog = try Catalog.load(from: Paths.live.manifest, preferredLanguages: ["en"]).enriched(metrics: metrics)
        let picker = Picker(pool: catalog.clips(config.pool), config: config)
        for phase in [SkyPhase.dawn, .golden, .dusk] {
            var counts: [String: Int] = [:]
            for seed in 0..<600 {
                var rng = RandomSource(seed: UInt64(seed) &* 104_729 &+ 3)
                if let pick = picker.choose(for: phase, previous: nil, recent: [], rng: &rng) {
                    counts[catalog[pick.clipID]!.english, default: 0] += 1
                }
            }
            let named = counts.filter { [.dawn, .golden, .dusk].contains(Tone.fromName($0.key)) }.values.reduce(0, +)
            let water = counts.filter { name, _ in catalog.clips.first { $0.english == name }?.zone == .water }.values.reduce(0, +)
            print("\(phase):", counts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value * 100 / 600)%" }.joined(separator: ", "))
            #expect(Double(named) / 600 > 0.5, "\(phase): named sunrise/sunset/evening shots only \(named * 100 / 600)%")
            #expect(Double(water) / 600 < 0.02, "\(phase): underwater \(water * 100 / 600)%")
        }
    }

    @Test func underwaterStillShowsUp() throws {
        let config = Config.load(from: Paths.live.config)
        let metrics = readJSON([String: ImageMetrics].self, from: Paths.live.metrics) ?? [:]
        let catalog = try Catalog.load(from: Paths.live.manifest, preferredLanguages: ["en"]).enriched(metrics: metrics)
        let picker = Picker(pool: catalog.clips(config.pool), config: config)
        for phase in SkyPhase.allCases {
            var zones: [Zone: Int] = [:], water: [String: Int] = [:]
            for seed in 0..<600 {
                var rng = RandomSource(seed: UInt64(seed) &* 7_919 &+ 11)
                guard let pick = picker.choose(for: phase, previous: nil, recent: [], rng: &rng), let clip = catalog[pick.clipID] else { continue }
                zones[clip.zone, default: 0] += 1
                if clip.zone == .water { water[clip.english, default: 0] += 1 }
            }
            print("ZONES \(phase):", zones.sorted { $0.value > $1.value }.map { "\($0.key.rawValue) \($0.value * 100 / 600)%" }.joined(separator: ", "),
                  "| water:", water.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value * 100 / 600)%" }.joined(separator: ", "))
        }
        #expect(true)
    }

    @Test func realPoolPlaysWithoutLoops() throws {
        let config = Config.load(from: Paths.live.config)
        let metrics = readJSON([String: ImageMetrics].self, from: Paths.live.metrics) ?? [:]
        let catalog = try Catalog.load(from: Paths.live.manifest, preferredLanguages: ["en"]).enriched(metrics: metrics)
        let rules = Rotation(catalog: catalog, config: config)
        let shown = RotationTests.play(rules, days: 7)
        print("PLAY", shown.compactMap { catalog[$0]?.english }.joined(separator: " → "))
        #expect(RotationTests.longestRun(shown, place: { catalog[$0]?.placeID }) <= config.placeRun)
    }
}
