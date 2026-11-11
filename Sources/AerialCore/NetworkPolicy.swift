import Foundation
import Network
import os

/// What the network looks like right now, as far as downloading is concerned.
public struct NetworkSnapshot: Equatable, Sendable {
    public var satisfied: Bool
    /// macOS marks a phone's Personal Hotspot (and cellular) as expensive.
    public var expensive: Bool
    /// Low Data Mode.
    public var constrained: Bool
    public var wifi: Bool
    public var wired: Bool
    /// IPv4 addresses of the Wi-Fi interface, to catch a hotspot the flag missed.
    public var wifiAddresses: [String]

    public init(satisfied: Bool, expensive: Bool = false, constrained: Bool = false, wifi: Bool = false, wired: Bool = false, wifiAddresses: [String] = []) {
        self.satisfied = satisfied
        self.expensive = expensive
        self.constrained = constrained
        self.wifi = wifi
        self.wired = wired
        self.wifiAddresses = wifiAddresses
    }

    public static let offline = NetworkSnapshot(satisfied: false)
}

public enum NetworkPolicy {
    /// Subnets phone hotspots hand out: iPhone (172.20.10.0/28), Android (192.168.43.0/24).
    static let hotspotPrefixes = ["172.20.10.", "192.168.43."]

    /// nil when downloading is allowed, otherwise the reason it isn't.
    public static func blockReason(_ snapshot: NetworkSnapshot, lowPowerMode: Bool) -> String? {
        guard snapshot.satisfied else { return "Offline" }
        guard snapshot.wifi || snapshot.wired else { return "Not on Wi-Fi or Ethernet" }
        guard !snapshot.expensive else { return "Personal Hotspot or metered network" }
        guard !snapshot.constrained else { return "Low Data Mode" }
        if !snapshot.wired, snapshot.wifiAddresses.contains(where: { address in hotspotPrefixes.contains { address.hasPrefix($0) } }) {
            return "Personal Hotspot"
        }
        guard !lowPowerMode else { return "Low Power Mode" }
        return nil
    }

    static func snapshot(of path: NWPath) -> NetworkSnapshot {
        let wifiNames = path.availableInterfaces.filter { $0.type == .wifi }.map(\.name)
        return NetworkSnapshot(
            satisfied: path.status == .satisfied,
            expensive: path.isExpensive,
            constrained: path.isConstrained,
            wifi: path.usesInterfaceType(.wifi),
            wired: path.usesInterfaceType(.wiredEthernet),
            wifiAddresses: ipv4Addresses(of: Set(wifiNames))
        )
    }

    static func ipv4Addresses(of names: Set<String>) -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  names.contains(String(cString: entry.ifa_name)) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return result
    }
}

/// Watches the network and reports each change.
public final class NetworkWatcher: Sendable {
    private let monitor = NWPathMonitor()
    private let latest = OSAllocatedUnfairLockBox(NetworkSnapshot.offline)

    public init(onChange: @escaping @Sendable (NetworkSnapshot) -> Void) {
        monitor.pathUpdateHandler = { [latest] path in
            let snapshot = NetworkPolicy.snapshot(of: path)
            latest.set(snapshot)
            onChange(snapshot)
        }
        monitor.start(queue: DispatchQueue(label: "aerial-rotator.network", qos: .utility))
    }

    public var current: NetworkSnapshot { latest.get() }

    deinit { monitor.cancel() }
}

/// A tiny lock-protected value.
final class OSAllocatedUnfairLockBox<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }
    func get() -> Value { lock.withLock { $0 } }
    func set(_ value: Value) { lock.withLock { $0 = value } }
}
