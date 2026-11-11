// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AerialRotator",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "AerialRotator", targets: ["AerialRotator"]),
    ],
    targets: [
        .target(name: "AerialCore"),
        .executableTarget(name: "AerialRotator", dependencies: ["AerialCore"]),
        .testTarget(name: "AerialCoreTests", dependencies: ["AerialCore"]),
    ]
)
