import Foundation
import os
import Testing
@testable import AerialCore

/// The whole loop on a throwaway home folder: manifest, wallpaper store, videos, state.
@MainActor @Suite struct EngineTests {
    static let ids = (night: "11111111-0000-0000-0000-000000000001", morning: "11111111-0000-0000-0000-000000000002",
                      london: "11111111-0000-0000-0000-000000000003", earth: "11111111-0000-0000-0000-000000000004",
                      day: "11111111-0000-0000-0000-000000000007")

    final class Clock: Sendable {
        private let value: OSAllocatedUnfairLock<Date>
        init(_ date: Date) { value = OSAllocatedUnfairLock(initialState: date) }
        var now: Date { value.withLock { $0 } }
        func set(_ date: Date) { value.withLock { $0 = date } }
    }

    final class Counter: Sendable {
        private let value = OSAllocatedUnfairLock(initialState: 0)
        func bump() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    struct Rig {
        let engine: Engine
        let paths: Paths
        let clock: Clock
        let reloads: Counter
        let server: StubServer
        var store: WallpaperStore { WallpaperStore(paths: paths) }
        var showing: String? {
            if case let .aerial(id) = try? store.state() { return id }
            return nil
        }
    }

    func rig(at date: Date, onDisk: [String], pinned: [String] = []) throws -> Rig {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        let server = StubServer(.init(body: Data(repeating: 9, count: 2000)))
        // The fixture manifest, with every video served by the stub.
        var json = try JSONSerialization.jsonObject(with: Fixtures.manifest) as! [String: Any]
        json["assets"] = (json["assets"] as! [[String: Any]]).map { asset in
            var asset = asset
            asset["url-4K-SDR-240FPS"] = "https://\(server.host)/\(asset["id"]!).mov"
            return asset
        }
        try FileManager.default.createDirectory(at: paths.manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: paths.manifest)
        var config = Config()
        config.pool = [Self.ids.night, Self.ids.morning, Self.ids.london, Self.ids.earth, Self.ids.day]
        config.pinned = pinned
        config.seed = 5
        try config.save(to: paths.config)
        try Fixtures.download(onDisk, into: paths)

        let clock = Clock(date)
        let reloads = Counter()
        let engine = Engine(paths: paths,
                            downloader: Downloader(paths: paths, makeConfiguration: StubProtocol.configuration, validate: { _ in true }),
                            reload: { reloads.bump() }, now: { clock.now }, lowPowerMode: { false },
                            log: Log(folder: paths.logs, enabled: false))
        return Rig(engine: engine, paths: paths, clock: clock, reloads: reloads, server: server)
    }

    @Test func putsANightClipOnAtNight() throws {
        let r = try rig(at: Fixtures.date(2026, 11, 11, 2), onDisk: [Self.ids.night, Self.ids.earth, Self.ids.day])
        r.engine.tick()
        #expect([Self.ids.night, Self.ids.earth].contains(r.showing ?? ""))
        #expect(r.engine.rotation.shown?.phase == .night)
        #expect(r.reloads.count == 1)
        #expect(r.store.hasBackup, "the user's wallpaper is kept for restoring")
    }

    @Test func keepsTheWallpaperWhenWakingInTheSamePartOfTheDay() throws {
        let r = try rig(at: Fixtures.date(2026, 11, 11, 2), onDisk: [Self.ids.night, Self.ids.earth])
        r.engine.tick()
        let first = r.showing
        // Next night, a whole day later (the Mac slept through the day): no change.
        r.clock.set(Fixtures.date(2026, 11, 12, 3))
        r.engine.tick()
        #expect(r.showing == first)
        #expect(r.reloads.count == 1)
    }

    @Test func changesWhenThePartOfTheDayChanges() throws {
        let r = try rig(at: Fixtures.date(2026, 11, 11, 2), onDisk: [Self.ids.night, Self.ids.earth, Self.ids.day, Self.ids.london])
        r.engine.tick()
        r.clock.set(Fixtures.date(2026, 11, 11, 12))
        r.engine.tick()
        #expect([Self.ids.day, Self.ids.london].contains(r.showing ?? ""))
        #expect(r.engine.rotation.shown?.phase == .day)
    }

    @Test func waitsRatherThanShowingTheWrongTimeOfDay() throws {
        let r = try rig(at: Fixtures.date(2026, 11, 11, 2), onDisk: [Self.ids.night])
        r.engine.tick()
        #expect(r.showing == Self.ids.night)
        // Day comes, no day clip on disk: the night clip stays until one arrives.
        r.clock.set(Fixtures.date(2026, 11, 11, 12))
        r.engine.tick()
        #expect(r.showing == Self.ids.night)
        #expect(r.engine.waitingFor != nil)
        try Fixtures.download([Self.ids.day, Self.ids.london], into: r.paths)
        r.engine.tick()
        #expect([Self.ids.day, Self.ids.london].contains(r.showing ?? ""))
    }

    @Test func choosesAgainWhenTheVideoOnScreenVanishes() throws {
        let r = try rig(at: Fixtures.date(2026, 11, 11, 2), onDisk: [Self.ids.night, Self.ids.earth])
        r.engine.tick()
        let first = try #require(r.showing)
        try FileManager.default.removeItem(at: r.paths.video(first))
        r.engine.tick()
        #expect(r.showing != first && r.showing != nil)
    }

    @Test func pauseAndOff() throws {
        let r = try rig(at: Fixtures.date(2026, 11, 11, 2), onDisk: [Self.ids.night, Self.ids.earth, Self.ids.day])
        r.engine.update { $0.paused = true }
        #expect(try r.store.state() == .other, "paused: nothing changes")
        r.engine.update { $0.paused = false }
        #expect(r.showing != nil)
        r.engine.update { $0.enabled = false }
        #expect(try r.store.state() == .other, "off: the original wallpaper is back")
        r.engine.update { $0.enabled = true }
        #expect(r.showing != nil, "on again: takes over at once")
    }

    @Test func statePersistsAcrossLaunches() throws {
        let r = try rig(at: Fixtures.date(2026, 11, 11, 2), onDisk: [Self.ids.night, Self.ids.earth])
        r.engine.tick()
        let again = Engine(paths: r.paths, reload: {}, now: { r.clock.now }, log: Log(folder: r.paths.logs, enabled: false))
        #expect(again.rotation.shown == r.engine.rotation.shown)
        #expect(!again.rotation.onDeck.isEmpty)
    }

    @Test func downloadsWhatIsComingUp() async throws {
        let r = try rig(at: Fixtures.date(2026, 11, 11, 12), onDisk: [], pinned: [Self.ids.earth])
        r.engine.networkChanged(.init(satisfied: true, wifi: true, wifiAddresses: ["192.168.1.5"]))
        r.engine.tick()
        r.engine.kickPrefetch(force: true)
        for _ in 0..<200 where r.engine.isDownloading { try await Task.sleep(for: .milliseconds(50)) }
        let onDisk = Set(CacheScanner.scan(r.paths.videos).map(\.id))
        #expect(onDisk.contains(Self.ids.earth), "pinned")
        for pick in r.engine.rotation.onDeck.values { #expect(onDisk.contains(pick.clipID)) }
        // And the day clip that arrived went on screen.
        #expect(r.showing != nil)
    }

    @Test func doesNotDownloadOverAHotspot() async throws {
        let r = try rig(at: Fixtures.date(2026, 11, 11, 12), onDisk: [])
        r.engine.networkChanged(.init(satisfied: true, expensive: true, wifi: true))
        r.engine.tick()
        r.engine.kickPrefetch(force: true)
        for _ in 0..<40 where r.engine.isDownloading { try await Task.sleep(for: .milliseconds(50)) }
        #expect(CacheScanner.scan(r.paths.videos).isEmpty)
        #expect(r.server.ranges.isEmpty)
    }
}
