// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TempBar",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "TempBarCore"),
        .executableTarget(name: "TempBar", dependencies: ["TempBarCore"]),
        .testTarget(name: "TempBarCoreTests", dependencies: ["TempBarCore"]),
    ]
)
