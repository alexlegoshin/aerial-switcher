import Foundation
import Testing
@testable import AerialCore

/// Upstream's tests of the wallpaper store, kept: this is the part that touches the user's settings.
@Suite struct WallpaperStoreTests {
    @Test func readsState() throws {
        #expect(try WallpaperStore(paths: Fixtures.paths(store: Fixtures.store(Fixtures.aerialChoice))).state() == .aerial(assetID: "OLD"))
        #expect(try WallpaperStore(paths: Fixtures.paths(store: Fixtures.store(Fixtures.defaultChoice))).state() == .systemDefault)
        #expect(try WallpaperStore(paths: Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))).state() == .other)
    }

    @Test func setsAnyWallpaperToTheAerial() throws {
        for choice in [Fixtures.aerialChoice, Fixtures.imageChoice, Fixtures.defaultChoice] {
            let store = WallpaperStore(paths: try Fixtures.paths(store: Fixtures.store(choice)))
            #expect(try store.setAerial("NEW") == 2)
            #expect(try store.state() == .aerial(assetID: "NEW"))
        }
    }

    @Test func keepsTheOriginalForRestore() throws {
        let store = WallpaperStore(paths: try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice)))
        try store.setAerial("A")
        try store.setAerial("B")
        try store.restoreBackup()
        #expect(try store.state() == .other)
        #expect(!store.hasBackup)
    }

    @Test func backsUpAWallpaperPickedSince() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        let store = WallpaperStore(paths: paths)
        try store.setAerial("A")
        try Fixtures.write(Fixtures.store(Fixtures.defaultChoice), to: paths)
        try store.setAerial("B")
        try store.restoreBackup()
        #expect(try store.state() == .systemDefault)
    }

    @Test func leavesAWallpaperPickedSinceOnRestore() throws {
        let paths = try Fixtures.paths(store: Fixtures.store(Fixtures.imageChoice))
        let store = WallpaperStore(paths: paths)
        try store.setAerial("A")
        try Fixtures.write(Fixtures.store(Fixtures.defaultChoice), to: paths)
        #expect(try store.restoreBackup() == false)
        #expect(try store.state() == .systemDefault)
        #expect(!store.hasBackup)
    }

    @Test func leavesAnImageScreenSaverAlone() throws {
        var scope = Fixtures.store(Fixtures.imageChoice)["AllSpacesAndDisplays"] as! [String: Any]
        scope["Idle"] = ["Content": ["Choices": [Fixtures.imageChoice]]]
        let paths = try Fixtures.paths(store: ["AllSpacesAndDisplays": scope])
        #expect(try WallpaperStore(paths: paths).setAerial("NEW") == 1)
        let saved = NSDictionary(contentsOf: paths.store)!
        let idle = (saved.value(forKeyPath: "AllSpacesAndDisplays.Idle.Content.Choices") as! [NSDictionary])[0]
        #expect(idle["Provider"] as? String == "com.apple.wallpaper.choice.image")
    }

    @Test func switchesADisplaySetOnItsOwn() throws {
        let display: [String: Any] = [
            "Desktop": ["Content": ["Choices": [Fixtures.aerialChoice("X")], "Shuffle": "$null"]],
            "Idle": ["Content": ["Choices": [Fixtures.aerialChoice("SAVER")], "Shuffle": "$null"]],
            "Type": "individual",
        ]
        var store = Fixtures.store(Fixtures.aerialChoice("Y"))
        store["AllSpacesAndDisplays"] = "$null"
        store["Displays"] = ["D1": display]
        let paths = try Fixtures.paths(store: store)
        let wallpaper = WallpaperStore(paths: paths)
        #expect(wallpaper.referencedAssetIDs() == ["X", "Y", "SAVER"])
        try wallpaper.setAerial("NEW")
        #expect(try wallpaper.state() == .aerial(assetID: "NEW"))
    }

    @Test func switchesEachSpace() throws {
        let linked = { (choice: [String: Any]) -> [String: Any] in
            ["Linked": ["Content": ["Choices": [choice], "Shuffle": "$null"]], "Type": "linked"]
        }
        let store: [String: Any] = [
            "AllSpacesAndDisplays": "$null",
            "SystemDefault": linked(Fixtures.defaultChoice),
            "Displays": ["D1": linked(Fixtures.imageChoice)],
            "Spaces": ["S1": ["Default": linked(Fixtures.imageChoice), "Displays": ["D1": linked(Fixtures.defaultChoice)]]],
        ]
        let paths = try Fixtures.paths(store: store)
        try WallpaperStore(paths: paths).setAerial("NEW")
        let saved = NSDictionary(contentsOf: paths.store)!
        let choice = (saved.value(forKeyPath: "Spaces.S1.Displays.D1.Linked.Content.Choices") as! [NSDictionary])[0]
        #expect(choice["Provider"] as? String == "com.apple.wallpaper.choice.aerials")
        #expect(try WallpaperStore(paths: paths).state() == .aerial(assetID: "NEW"))
    }

    @Test func missingStoreThrows() {
        let paths = Paths(home: URL(fileURLWithPath: "/nonexistent"))
        #expect(throws: AerialError.self) { try WallpaperStore(paths: paths).state() }
        #expect(WallpaperStore(paths: paths).referencedAssetIDs().isEmpty)
    }
}

@Suite struct ConfigTests {
    @Test func roundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        var config = Config()
        config.pool = ["A", "B"]
        config.pinned = ["A"]
        config.seed = 7
        try config.save(to: url)
        #expect(Config.load(from: url) == config)
    }

    @Test func fillsMissingKeysWithDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        try Data(#"{"paused": true, "setID": "tahoe", "pool": ["A"]}"#.utf8).write(to: url)
        let config = Config.load(from: url)
        #expect(config.paused && config.pool == ["A"] && config.cacheSoftLimitMB == 3072 && config.cacheHardLimitMB == 5120)
        #expect(config.seed != 0)
    }

    @Test func keepsABrokenFileAside() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("config.json")
        try Data("{not json".utf8).write(to: url)
        let config = Config.load(from: url)
        #expect(config.pool.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains { $0.hasPrefix("config.json.broken-") })
    }

    @Test func hardLimitIsNeverBelowSoft() {
        var config = Config()
        config.cacheSoftLimitMB = 4000
        config.cacheHardLimitMB = 1000
        #expect(config.hardLimitBytes == config.softLimitBytes)
    }
}
