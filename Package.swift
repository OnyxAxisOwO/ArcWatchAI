// swift-tools-version: 5.10
import PackageDescription

let package = Package(name: "ArcWatchCore", platforms: [.macOS(.v14)], targets: [
    .target(name: "ArcWatchCore", path: "Shared", exclude: ["Interface", "Device"]),
    .testTarget(name: "ArcWatchCoreTests", dependencies: ["ArcWatchCore"], path: "Tests")
])
