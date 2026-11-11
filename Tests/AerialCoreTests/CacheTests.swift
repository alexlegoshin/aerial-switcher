import Foundation
import Testing
@testable import AerialCore

@Suite struct CachePolicyTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let mb: Int64 = 1_000_000

    func file(_ id: String, _ size: Int64, age: TimeInterval = 0) -> CachedFile {
        CachedFile(id: id, size: size * mb, modified: now - age)
    }

    func policy(soft: Int64 = 3000, hard: Int64 = 5000, protected: Set<String> = [], needs: [String: Date] = [:],
                lastShown: [String: Date] = [:], deletable: Set<String>? = nil) -> CachePolicy {
        CachePolicy(softLimit: soft * mb, hardLimit: hard * mb, protected: protected, needs: needs, lastShown: lastShown,
                    deletable: deletable ?? ["A", "B", "C", "D", "E", "X"])
    }

    @Test func admitsWithinTheSoftLimitWithoutDeleting() {
        let admission = policy().admit(size: 500 * mb, needed: now, urgent: false, files: [file("A", 1000), file("B", 1000)])
        #expect(admission == .init(allowed: true, evict: []))
    }

    @Test func deletesUnneededLeastRecentlyShownFirst() {
        let files = [file("A", 1000), file("B", 1000), file("C", 1000)]
        let p = policy(lastShown: ["A": now - 10, "B": now - 1000, "C": now - 100])
        #expect(p.admit(size: 900 * mb, needed: now + 60, urgent: false, files: files).evict == ["B"])
    }

    @Test func givesUpLaterNeedsBeforeSoonerOnes() {
        let files = [file("A", 1500), file("B", 1500)]
        // A is needed in 10 h, B in 20 h; the incoming one in 1 h.
        let p = policy(needs: ["A": now + 10 * 3600, "B": now + 20 * 3600])
        #expect(p.admit(size: 500 * mb, needed: now + 3600, urgent: false, files: files).evict == ["B"])
    }

    @Test func neverGivesUpWhatIsNeededSooner() {
        let files = [file("A", 1500), file("B", 1500)]
        let p = policy(needs: ["A": now + 3600, "B": now + 2 * 3600])
        let admission = p.admit(size: 500 * mb, needed: now + 10 * 3600, urgent: false, files: files)
        #expect(admission == .init(allowed: false, evict: []))
    }

    @Test func urgentMayGoUpToTheHardLimit() {
        let files = [file("A", 1500), file("B", 1500)]
        let p = policy(protected: ["A", "B"])
        #expect(p.admit(size: 1000 * mb, needed: now, urgent: false, files: files).allowed == false)
        #expect(p.admit(size: 1000 * mb, needed: now, urgent: true, files: files) == .init(allowed: true, evict: []))
        #expect(p.admit(size: 2500 * mb, needed: now, urgent: true, files: files).allowed == false)
    }

    @Test func urgentStillPrefersGettingUnderTheSoftLimit() {
        let files = [file("A", 1500), file("B", 1500)]
        let p = policy(protected: ["A"])
        #expect(p.admit(size: 1000 * mb, needed: now, urgent: true, files: files).evict == ["B"])
    }

    @Test func protectedAndForeignFilesAreNeverDeleted() {
        let files = [file("A", 2000), file("FOREIGN", 2000)]
        let p = policy(protected: ["A"], deletable: ["A", "B"])
        #expect(p.admit(size: 100 * mb, needed: now, urgent: false, files: files).allowed == false)
        #expect(p.tidy(files).isEmpty)
    }

    @Test func tidyDeletesOnlyUnneededDownToTheSoftLimit() {
        let files = [file("A", 1500, age: 30), file("B", 1500, age: 20), file("C", 1500, age: 10)]
        let p = policy(needs: ["A": now + 3600])
        #expect(p.tidy(files) == ["B"])
        #expect(policy().tidy([file("A", 100)]).isEmpty)
    }

    @Test func scannerSeesOnlyVideos() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString
        try Data(count: 10).write(to: folder.appendingPathComponent("\(id).mov"))
        try Data(count: 10).write(to: folder.appendingPathComponent("notes.txt"))
        try Data(count: 10).write(to: folder.appendingPathComponent("not-a-uuid.mov"))
        #expect(CacheScanner.scan(folder).map(\.id) == [id])
        #expect(CacheScanner.scan(URL(fileURLWithPath: "/nonexistent")).isEmpty)
    }
}

@Suite struct FailureLogTests {
    @Test func backsOffThenRestsADay() {
        var log = FailureLog()
        let t = Date(timeIntervalSince1970: 0)
        #expect(log.canRetry("A", now: t))
        log.failed("A", now: t)
        #expect(!log.canRetry("A", now: t + 60) && log.canRetry("A", now: t + 5 * 60))
        log.failed("A", now: t)
        #expect(!log.canRetry("A", now: t + 10 * 60) && log.canRetry("A", now: t + 15 * 60))
        log.failed("A", now: t)
        #expect(!log.canRetry("A", now: t + 23 * 3600) && log.canRetry("A", now: t + 24 * 3600))
        log.succeeded("A")
        #expect(log.canRetry("A", now: t))
    }
}

@Suite struct NetworkPolicyTests {
    @Test func allowsOrdinaryWiFiAndEthernet() {
        #expect(NetworkPolicy.blockReason(.init(satisfied: true, wifi: true, wifiAddresses: ["192.168.1.20"]), lowPowerMode: false) == nil)
        #expect(NetworkPolicy.blockReason(.init(satisfied: true, wired: true), lowPowerMode: false) == nil)
    }

    @Test func blocksHotspotsMeteredAndOffline() {
        #expect(NetworkPolicy.blockReason(.offline, lowPowerMode: false) == "Offline")
        #expect(NetworkPolicy.blockReason(.init(satisfied: true, expensive: true, wifi: true), lowPowerMode: false) != nil)
        #expect(NetworkPolicy.blockReason(.init(satisfied: true, constrained: true, wifi: true), lowPowerMode: false) == "Low Data Mode")
        // The flag missed it (e.g. behind a VPN), the address gives it away.
        #expect(NetworkPolicy.blockReason(.init(satisfied: true, wifi: true, wifiAddresses: ["172.20.10.3"]), lowPowerMode: false) == "Personal Hotspot")
        #expect(NetworkPolicy.blockReason(.init(satisfied: true), lowPowerMode: false) == "Not on Wi-Fi or Ethernet")
        #expect(NetworkPolicy.blockReason(.init(satisfied: true, wifi: true), lowPowerMode: true) == "Low Power Mode")
    }
}
