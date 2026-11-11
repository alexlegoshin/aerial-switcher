import Foundation
import Testing
@testable import AerialCore

@Suite struct SolarClockTests {
    let moscow = Fixtures.moscow

    /// Published sunrise/sunset for Moscow (sun's upper limb with refraction = −0.833°), ±3 min.
    @Test(arguments: [
        (2026, 6, 21, 3, 44, true), (2026, 6, 21, 21, 18, false),
        (2026, 12, 21, 8, 59, true), (2026, 12, 21, 15, 57, false),
        (2026, 3, 20, 6, 32, true), (2026, 3, 20, 18, 43, false),
    ])
    func sunriseAndSunsetMatchPublishedTimes(year: Int, month: Int, day: Int, hour: Int, minute: Int, rising: Bool) throws {
        let expected = Fixtures.date(year, month, day, hour, minute)
        let found = try #require(moscow.nextCrossing(of: -0.833, rising: rising, after: Fixtures.date(year, month, day, 0)))
        #expect(abs(found.timeIntervalSince(expected)) < 3 * 60, "\(found) vs \(expected)")
    }

    @Test func phasesFollowTheSunThroughADay() {
        // 11 November 2026, Moscow: sunrise ≈ 07:46, sunset ≈ 16:23.
        #expect(moscow.phase(at: Fixtures.date(2026, 11, 11, 3)) == .night)
        #expect(moscow.phase(at: Fixtures.date(2026, 11, 11, 7, 30)) == .dawn)
        #expect(moscow.phase(at: Fixtures.date(2026, 11, 11, 8, 30)) == .morning)
        #expect(moscow.phase(at: Fixtures.date(2026, 11, 11, 12)) == .day)
        #expect(moscow.phase(at: Fixtures.date(2026, 11, 11, 15, 30)) == .golden)
        #expect(moscow.phase(at: Fixtures.date(2026, 11, 11, 16, 30)) == .dusk)
        #expect(moscow.phase(at: Fixtures.date(2026, 11, 11, 20)) == .night)
    }

    @Test func transitionsComeInDayOrder() {
        let transitions = moscow.transitions(after: Fixtures.date(2026, 11, 11, 0), horizon: 24 * 3600)
        #expect(transitions.map(\.phase) == [.dawn, .morning, .day, .golden, .dusk, .night])
        for (a, b) in zip(transitions, transitions.dropFirst()) { #expect(a.date < b.date) }
        // Each change is where the phase actually flips.
        for transition in transitions {
            #expect(moscow.phase(at: transition.date) == transition.phase)
            #expect(moscow.phase(at: transition.date - 15) != transition.phase)
        }
    }

    @Test func winterDayStillHasADay() {
        // Noon sun ≈ 10.8° in late December: the day threshold drops to 6.5°.
        let transitions = moscow.transitions(after: Fixtures.date(2026, 12, 22, 0), horizon: 24 * 3600)
        #expect(transitions.map(\.phase).contains(.day))
    }

    @Test func polarSummerHasNoNight() {
        let svalbard = SolarClock(latitude: 78.2, longitude: 15.6)
        let starts = svalbard.nextStarts(after: Fixtures.date(2026, 6, 21, 0, zone: .gmt))
        #expect(starts[.night] == nil)
        #expect(svalbard.phase(at: Fixtures.date(2026, 6, 21, 0, zone: .gmt)) != .night)
    }

    @Test func polarWinterIsNightAllDay() {
        let svalbard = SolarClock(latitude: 78.2, longitude: 15.6)
        #expect(svalbard.transitions(after: Fixtures.date(2026, 12, 21, 0, zone: .gmt), horizon: 24 * 3600).isEmpty)
        #expect(svalbard.phase(at: Fixtures.date(2026, 12, 21, 11, zone: .gmt)) == .night)
    }

    @Test func nextStartsGivesEachPhaseOnce() {
        let starts = moscow.nextStarts(after: Fixtures.date(2026, 11, 11, 12))
        #expect(Set(starts.keys) == Set(SkyPhase.allCases))
        #expect(starts[.golden]! < starts[.night]!)
        #expect(starts[.night]! < starts[.dawn]!)
    }
}
