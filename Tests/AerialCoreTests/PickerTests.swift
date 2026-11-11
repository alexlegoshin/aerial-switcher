import Foundation
import Testing
@testable import AerialCore

@Suite struct PickerTests {
    func picks(_ picker: Picker, _ phase: SkyPhase, previous: Clip? = nil, recent: [String] = [], runs: Int = 600) -> [Pick] {
        (0..<runs).compactMap { seed in
            var rng = RandomSource(seed: UInt64(seed) &* 7919 &+ 1)
            return picker.choose(for: phase, previous: previous, recent: recent, rng: &rng)
        }
    }

    func clip(_ pick: Pick) -> Clip { Fixtures.all.first { $0.id == pick.clipID }! }

    @Test func nightGetsOnlyDarkClips() {
        let picker = Fixtures.picker(Fixtures.all)
        for pick in picks(picker, .night) {
            let clip = clip(pick)
            let darkWater = clip.zone == .water && (clip.brightness ?? 999) <= 80
            #expect(clip.tone == .night || darkWater, "\(clip.english) at night")
        }
    }

    @Test func dayNeverGetsNightOrEarth() {
        let picker = Fixtures.picker(Fixtures.all)
        for phase in [SkyPhase.dawn, .morning, .day, .golden, .dusk] {
            for pick in picks(picker, phase, runs: 200) {
                let clip = clip(pick)
                #expect(clip.zone != .earth && clip.tone != .night, "\(clip.english) at \(phase)")
            }
        }
    }

    @Test func sameSeedSamePick() {
        let picker = Fixtures.picker(Fixtures.all)
        var a = RandomSource(seed: 99), b = RandomSource(seed: 99)
        #expect(picker.choose(for: .day, previous: nil, recent: [], rng: &a) == picker.choose(for: .day, previous: nil, recent: [], rng: &b))
    }

    @Test func cityWithoutNightShotGetsEarthOfItsRegion() {
        let picker = Fixtures.picker([Fixtures.londonSkyline, Fixtures.europeNight, Fixtures.california]) { $0.continuity = 0 }
        let fromLondon = picks(picker, .night).filter { $0.reason == .cityEarth }
        #expect(!fromLondon.isEmpty)
        #expect(fromLondon.allSatisfy { $0.clipID == Fixtures.europeNight.id })
    }

    @Test func cityWithoutRegionalEarthIsSkippedAtNight() {
        let picker = Fixtures.picker([Fixtures.londonSkyline, Fixtures.california]) { $0.continuity = 0 }
        #expect(picks(picker, .night).allSatisfy { $0.clipID == Fixtures.california.id && $0.reason == .direct })
    }

    @Test func landscapeAtNightSplitsBetweenWaterAndEarthByWeight() {
        let picker = Fixtures.picker([Fixtures.icelandLake, Fixtures.kelpDark, Fixtures.aurora]) {
            $0.continuity = 0
            $0.nightWaterWeight = 0.7
            $0.nightEarthWeight = 0.3
        }
        let fallbacks = picks(picker, .night, runs: 3000).filter { $0.reason == .nightWater || $0.reason == .nightEarth }
        let water = Double(fallbacks.filter { $0.reason == .nightWater }.count) / Double(fallbacks.count)
        #expect(fallbacks.count > 500)
        #expect(abs(water - 0.7) < 0.05, "water share \(water)")
    }

    @Test func weightsAreNormalizedOverWhatExists() {
        // No Earth flight over Iceland's region in the pool: water takes every chance.
        let picker = Fixtures.picker([Fixtures.icelandLake, Fixtures.kelpDark, Fixtures.europeNight]) { $0.continuity = 0 }
        let fallbacks = picks(picker, .night).filter { $0.reason == .nightWater || $0.reason == .nightEarth }
        #expect(!fallbacks.isEmpty && fallbacks.allSatisfy { $0.reason == .nightWater })
    }

    @Test func underwaterFallbackFollowsThePalette() {
        // Iceland is blue-green (bin 6), like Kelp Dark; Seal Pod is orange (bin 1).
        let picker = Fixtures.picker([Fixtures.icelandLake, Fixtures.kelpDark, Fixtures.sealPod]) {
            $0.continuity = 0
            $0.nightEarthWeight = 0
        }
        let water = picks(picker, .night, runs: 3000).filter { $0.reason == .nightWater }
        let kelp = water.filter { $0.clipID == Fixtures.kelpDark.id }.count
        #expect(Double(kelp) / Double(water.count) > 0.6)
    }

    @Test func brightUnderwaterIsNotNight() {
        let picker = Fixtures.picker([Fixtures.whale, Fixtures.kelpDark]) { $0.continuity = 0 }
        #expect(picks(picker, .night).allSatisfy { $0.clipID == Fixtures.kelpDark.id })
        let stricter = Fixtures.picker([Fixtures.sealPod]) { $0.nightWaterMaxBrightness = 60 }
        #expect(picks(stricter, .night, runs: 20).isEmpty)
    }

    @Test func continuesTheSamePlace() {
        let picker = Fixtures.picker(Fixtures.all) { $0.continuity = 1 }
        let night = picks(picker, .night, previous: Fixtures.sequoiaMorning, runs: 50)
        #expect(night.allSatisfy { $0.clipID == Fixtures.sequoiaNight.id && $0.reason == .samePlace })
    }

    @Test func staysWithThePlaceAtNightThroughItsFallback() {
        let picker = Fixtures.picker(Fixtures.all) { $0.continuity = 1 }
        // London has no night shot: its own fallback, Earth over Europe.
        #expect(picks(picker, .night, previous: Fixtures.londonEvening, runs: 50).allSatisfy { $0.clipID == Fixtures.europeNight.id && $0.reason == .cityEarth })
        // Sonoma has none either: dark underwater or Earth over California.
        let sonoma = picks(picker, .night, previous: Fixtures.sonomaHorizon, runs: 200)
        #expect(sonoma.allSatisfy { [.nightWater, .nightEarth].contains($0.reason) })
        #expect(sonoma.filter { $0.reason == .nightEarth }.allSatisfy { $0.clipID == Fixtures.california.id })
    }

    @Test func neverTheSameClipTwiceInARow() {
        // Sonoma Clouds suits both morning and day; the next one is another shot of Sonoma.
        let picker = Fixtures.picker([Fixtures.sonomaClouds, Fixtures.sonomaHorizon, Fixtures.londonSkyline]) { $0.continuity = 1 }
        let result = picks(picker, .morning, previous: Fixtures.sonomaClouds, runs: 100)
        #expect(result.allSatisfy { $0.clipID != Fixtures.sonomaClouds.id })
    }

    @Test func avoidsWhatWasJustShown() {
        let pool = [Fixtures.londonSkyline, Fixtures.newYorkSkyline, Fixtures.sonomaClouds]
        let picker = Fixtures.picker(pool) { $0.continuity = 0 }
        let result = picks(picker, .day, recent: [Fixtures.londonSkyline.id], runs: 1000)
        let repeats = result.filter { $0.clipID == Fixtures.londonSkyline.id }.count
        #expect(repeats < 60, "\(repeats) repeats of 1000")
        // With nothing else at all, a repeat is still better than nothing.
        let single = Fixtures.picker([Fixtures.londonSkyline])
        #expect(picks(single, .day, recent: [Fixtures.londonSkyline.id], runs: 5).count == 5)
    }

    @Test func emptyPoolPicksNothing() {
        var rng = RandomSource(seed: 1)
        #expect(Fixtures.picker([]).choose(for: .day, previous: nil, recent: [], rng: &rng) == nil)
    }

    @Test func sunIsNearTheHorizonPicksSunsetLikeClips() {
        let sunset = Fixtures.clip("Grand Canyon Sunset", place: "Grand Canyon", zone: .land, brightness: 67)
        let warmTwilight = Fixtures.clip("Sonoma Horizon", place: "Sonoma", zone: .land, brightness: 70)
        let coldTwilight = Fixtures.clip("Kelp Forest", place: "Kelp Forest", zone: .water, brightness: 68, hues: Fixtures.hue(6))
        let sunnyDesert = Fixtures.clip("Goa Coast", place: "Goa", zone: .land, brightness: 91)
        let picker = Fixtures.picker([sunset, warmTwilight, coldTwilight, sunnyDesert]) { $0.continuity = 0 }
        for phase in [SkyPhase.dawn, .golden, .dusk] {
            let ids = Set(picks(picker, phase, runs: 400).map(\.clipID))
            #expect(ids == [sunset.id, warmTwilight.id], "\(phase): \(ids)")
        }
        // With nothing sunset-like at all, the best of the rest still beats nothing.
        let cold = Fixtures.picker([coldTwilight])
        #expect(picks(cold, .dusk, runs: 5).allSatisfy { $0.clipID == coldTwilight.id && $0.reason == .fallback })
    }

    @Test func aBetterShotOfThePlaceWins() {
        // Drawing Sonoma Clouds (bright) at golden hour leads to Sonoma Horizon.
        let picker = Fixtures.picker([Fixtures.sonomaClouds, Fixtures.sonomaHorizon]) { $0.continuity = 0 }
        #expect(picks(picker, .golden, runs: 200).allSatisfy { $0.clipID == Fixtures.sonomaHorizon.id })
    }

    @Test func theRealSunsetOfAPlaceBeatsItsEveningLight() {
        let hills = Fixtures.clip("Los Angeles Hills", place: "Los Angeles", zone: .city, brightness: 77,
                                  hues: [0.1, 0.1] + [Double](repeating: 0, count: 6) + [0.8, 0, 0, 0])  // warmth ≈ 0.29, as measured
        let sunset = Fixtures.clip("Los Angeles Sunset", place: "Los Angeles", zone: .city, brightness: 64)
        let picker = Fixtures.picker([hills, sunset]) { $0.continuity = 0 }
        let result = picks(picker, .golden, runs: 1000)
        let real = result.filter { $0.clipID == sunset.id }.count
        #expect(real > 700, "\(real) of 1000")
    }

    @Test func suitabilityTable() {
        let picker = Fixtures.picker(Fixtures.all)
        #expect(picker.suitability(of: Fixtures.sequoiaNight, for: .night) == 1)
        #expect(picker.suitability(of: Fixtures.sequoiaNight, for: .day) == 0)
        #expect(picker.suitability(of: Fixtures.sonomaClouds, for: .day) == 1)
        #expect(picker.suitability(of: Fixtures.sonomaHorizon, for: .dusk) >= 0.5)
        #expect(picker.suitability(of: Fixtures.sonomaHorizon, for: .night) == 0)
        #expect(picker.suitability(of: Fixtures.europeNight, for: .dusk) == 0)
        #expect(picker.suitability(of: Fixtures.sealPod, for: .night) == 0.8)
    }
}
