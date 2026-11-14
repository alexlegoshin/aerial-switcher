import Foundation
import Testing
@testable import AerialCore

@Suite struct RotationTests {
    let catalog = Catalog(clips: Fixtures.all)

    func rotation(_ pool: [Clip] = Fixtures.all, _ change: (inout Config) -> Void = { _ in }) -> Rotation {
        Rotation(catalog: catalog, config: Fixtures.config(pool: pool, change))
    }

    func state(shown: Clip, phase: SkyPhase, intended: String? = nil) -> RotationState {
        var state = RotationState()
        state.shown = Shown(clipID: shown.id, phase: phase, since: .distantPast, intended: intended)
        return state
    }

    @Test func staysWithinTheSamePartOfTheDayHoweverLong() {
        // Chosen for "day" long ago; it's "day" again (another date): nothing changes.
        let rules = rotation()
        var state = state(shown: Fixtures.londonSkyline, phase: .day)
        state.onDeck[.day] = Pick(clipID: Fixtures.sonomaClouds.id, reason: .direct)
        #expect(rules.decide(state, phase: .day, isOnDisk: { _ in true }) == .stay)
    }

    @Test func changesWithThePartOfTheDay() {
        let rules = rotation()
        var state = state(shown: Fixtures.londonSkyline, phase: .day)
        let pick = Pick(clipID: Fixtures.londonEvening.id, reason: .samePlace)
        state.onDeck[.golden] = pick
        #expect(rules.decide(state, phase: .golden, isOnDisk: { _ in true }) == .show(pick, phase: .golden, intended: nil))
    }

    @Test func standsInWhileThePickDownloadsThenUpgrades() {
        let rules = rotation()
        var state = state(shown: Fixtures.londonSkyline, phase: .day)
        state.onDeck[.night] = Pick(clipID: Fixtures.sequoiaNight.id, reason: .direct)
        let onDisk: Set<String> = [Fixtures.londonSkyline.id, Fixtures.europeNight.id]

        let first = rules.decide(state, phase: .night, isOnDisk: { onDisk.contains($0) })
        #expect(first == .show(Pick(clipID: Fixtures.europeNight.id, reason: .standIn), phase: .night, intended: Fixtures.sequoiaNight.id))
        rules.apply(first, to: &state, now: Date())
        #expect(state.onDeck[.night]?.clipID == Fixtures.sequoiaNight.id, "the pick stays wanted")

        // Not downloaded yet: keep the stand-in.
        #expect(rules.decide(state, phase: .night, isOnDisk: { onDisk.contains($0) }) == .stay)
        // Downloaded: it takes over, still in the same night.
        let second = rules.decide(state, phase: .night, isOnDisk: { _ in true })
        #expect(second == .show(Pick(clipID: Fixtures.sequoiaNight.id, reason: .direct), phase: .night, intended: nil))
        rules.apply(second, to: &state, now: Date())
        #expect(state.onDeck[.night] == nil && state.shown?.intended == nil)
    }

    @Test func standInPrefersPinned() {
        let rules = rotation { $0.pinned = [Fixtures.aurora.id] }
        var state = state(shown: Fixtures.londonSkyline, phase: .day)
        state.onDeck[.night] = Pick(clipID: Fixtures.sequoiaNight.id, reason: .direct)
        let onDisk: Set<String> = [Fixtures.europeNight.id, Fixtures.aurora.id, Fixtures.kelpDark.id]
        guard case let .show(pick, _, _) = rules.decide(state, phase: .night, isOnDisk: { onDisk.contains($0) }) else {
            Issue.record("expected a stand-in")
            return
        }
        #expect(pick.clipID == Fixtures.aurora.id)
    }

    @Test func waitsWhenNothingSuitableIsOnDisk() {
        let rules = rotation()
        var state = state(shown: Fixtures.londonSkyline, phase: .day)
        state.onDeck[.night] = Pick(clipID: Fixtures.sequoiaNight.id, reason: .direct)
        // Only day clips on disk: never put a day clip into the night.
        let onDisk: Set<String> = [Fixtures.londonSkyline.id, Fixtures.sonomaClouds.id]
        #expect(rules.decide(state, phase: .night, isOnDisk: { onDisk.contains($0) }) == .wait(for: Fixtures.sequoiaNight.id))
    }

    @Test func picksThatLeftThePoolAreDropped() {
        let rules = rotation([Fixtures.londonSkyline, Fixtures.sonomaClouds])
        var state = RotationState()
        state.onDeck[.day] = Pick(clipID: Fixtures.whale.id, reason: .direct)
        rules.refill(&state, starts: [.day: Date()])
        #expect(state.onDeck[.day]?.clipID != Fixtures.whale.id)
        #expect([Fixtures.londonSkyline.id, Fixtures.sonomaClouds.id].contains(state.onDeck[.day]?.clipID ?? ""))
    }

    @Test func refillLinesUpEveryComingPartOfTheDay() {
        let rules = rotation()
        var state = RotationState()
        let base = Fixtures.date(2026, 11, 11, 12)
        let starts = Fixtures.moscow.nextStarts(after: base)
        rules.refill(&state, starts: starts)
        #expect(Set(state.onDeck.keys) == Set(starts.keys))
        // Lined-up picks don't repeat each other when there's choice.
        let ids = state.onDeck.values.map(\.clipID)
        #expect(Set(ids).count >= ids.count - 1)
        // Refilling again changes nothing: picks are stable, so downloads aren't wasted.
        let before = state
        rules.refill(&state, starts: starts)
        #expect(state == before)
    }

    @Test func wantedPutsWhatIsDueFirst() {
        let rules = rotation { $0.pinned = [Fixtures.europeNight.id] }
        let now = Date(timeIntervalSince1970: 1_000_000)
        var state = state(shown: Fixtures.londonSkyline, phase: .day)
        state.onDeck = [.golden: Pick(clipID: "G", reason: .direct), .dusk: Pick(clipID: "D", reason: .direct),
                        .night: Pick(clipID: "N", reason: .direct), .dawn: Pick(clipID: "W", reason: .direct)]
        let starts: [SkyPhase: Date] = [.golden: now + 3600, .dusk: now + 7200, .night: now + 5 * 3600, .dawn: now + 20 * 3600]
        let wanted = rules.wanted(state, phase: .day, starts: starts, now: now).map(\.clipID)
        #expect(wanted == ["G", "D", "N", Fixtures.europeNight.id, "W"])
    }

    @Test func historyIsBoundedAndNewestFirst() {
        let rules = rotation()
        var state = RotationState()
        for i in 0..<60 {
            rules.apply(.show(Pick(clipID: "C\(i)", reason: .direct), phase: .day, intended: nil), to: &state, now: Date())
        }
        #expect(state.history.count == RotationState.historyLimit)
        #expect(state.history.first == "C59")
    }

    @Test func stateSurvivesARoundTrip() throws {
        var state = state(shown: Fixtures.londonSkyline, phase: .golden, intended: "X")
        state.onDeck[.night] = Pick(clipID: "N", reason: .cityEarth)
        state.history = ["A", "B"]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        try state.save(to: url)
        #expect(RotationState.load(from: url).shown?.clipID == Fixtures.londonSkyline.id)
        #expect(RotationState.load(from: url).onDeck[.night]?.reason == .cityEarth)
        #expect(RotationState.load(from: URL(fileURLWithPath: "/nonexistent")) == RotationState())
    }

    /// Plays `days` of changes of the part of the day and returns what went on screen.
    static func play(_ rules: Rotation, days: Int, from start: Date = Fixtures.date(2026, 11, 12, 0)) -> [String] {
        var state = RotationState()
        var shown: [String] = []
        var t = start
        for _ in 0..<(days * 6) {
            guard let next = Fixtures.moscow.transitions(after: t, horizon: 30 * 3600).first else { break }
            t = next.date + 1
            rules.refill(&state, starts: Fixtures.moscow.nextStarts(after: t))
            let decision = rules.decide(state, phase: next.phase, isOnDisk: { _ in true })
            rules.apply(decision, to: &state, now: t)
            if case let .show(pick, _, _) = decision { shown.append(pick.clipID) }
            rules.refill(&state, starts: Fixtures.moscow.nextStarts(after: t))
        }
        return shown
    }

    static func longestRun(_ ids: [String], place: (String) -> String?) -> Int {
        var best = 0, current = 0, last: String?
        for id in ids {
            let p = place(id)
            current = (p != nil && p == last) ? current + 1 : 1
            last = p
            best = max(best, current)
        }
        return best
    }

    @Test func aPlaceWithEveryPartOfTheDayDoesNotTakeOver() {
        // Los Angeles has a shot for every part of the day; continuity at 100 %.
        let la = ["Los Angeles Night", "Los Angeles Sunrise", "Los Angeles Morning", "Los Angeles Day", "Los Angeles Evening", "Los Angeles Sunset"]
            .map { Fixtures.clip($0, place: "Los Angeles", zone: .city, brightness: 90, region: "california") }
        let pool = la + Fixtures.all
        let rules = Rotation(catalog: Catalog(clips: pool), config: Fixtures.config(pool: pool) { $0.continuity = 1 })
        let shown = Self.play(rules, days: 6)
        #expect(shown.count >= 30)
        let place = { (id: String) in pool.first { $0.id == id }?.placeID }
        #expect(Self.longestRun(shown, place: place) <= 3, "\(shown)")
        // And it isn't stuck either: several places over a few days.
        #expect(Set(shown.compactMap(place)).count >= 5)
    }

    @Test func noClipComesBackWithinSixChanges() {
        let pool = Fixtures.all
        let rules = Rotation(catalog: Catalog(clips: pool), config: Fixtures.config(pool: pool) { $0.continuity = 1 })
        let shown = Self.play(rules, days: 6)
        for (i, id) in shown.enumerated() {
            let window = shown[max(0, i - 3)..<i]
            #expect(!window.contains(id), "\(id) again at \(i): \(shown)")
        }
    }
}
